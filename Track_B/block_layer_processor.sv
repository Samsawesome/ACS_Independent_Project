module block_layer_processor #(
    parameter QUEUE_DEPTH = 64,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset,

    input wire irp_in_valid,
    input wire [511:0] irp_in_data,
    output wire irp_in_ready,

    output wire srb_out_valid,
    output wire [1023:0] srb_out_data,
    input wire srb_out_ready
);

    import windows_storage_pkg::*;

    reg [511:0] irp_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] irp_fifo_valid;
    reg [5:0] irp_fifo_rd_ptr;
    reg [5:0] irp_fifo_wr_ptr;
    reg [31:0] fifo_count;

    reg [1023:0] srb_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] srb_fifo_valid;
    reg [5:0] srb_fifo_rd_ptr;
    reg [5:0] srb_fifo_wr_ptr;

    typedef enum logic [3:0] {
        BL_IDLE,
        BL_FETCH_IRP,
        BL_PARSE_IRP,
        BL_BUILD_MDL,
        BL_WAIT_MDL,
        BL_BUILD_SRB,
        BL_QUEUE_SRB,
        BL_COMPLETE
    } bl_state_t;

    bl_state_t current_state, next_state;

    irp_t current_irp;
    srb_t current_srb;
    reg [31:0] current_lba;
    reg [31:0] current_size;
    reg is_write_op;
    reg [15:0] current_irp_id;
    reg [31:0] sector_count;
    reg [31:0] cycles_counter;
    reg [31:0] irp_processed_count;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= BL_IDLE;
            irp_fifo_valid <= 0;
            srb_fifo_valid <= 0;
            irp_fifo_rd_ptr <= 0;
            irp_fifo_wr_ptr <= 0;
            srb_fifo_rd_ptr <= 0;
            srb_fifo_wr_ptr <= 0;
            fifo_count <= 0;
            cycles_counter <= 0;
            irp_processed_count <= 0;
            current_irp_id <= 0;
            sector_count <= 0;
            for (int i = 0; i < QUEUE_DEPTH; i = i + 1) begin
                srb_fifo[i] <= 1024'b0;
                srb_fifo_valid[i] <= 1'b0;
            end
        end else begin
            current_state <= next_state;
            //update FIFO (add)
            if (irp_in_valid && irp_in_ready) begin
                irp_fifo[irp_fifo_wr_ptr] <= irp_in_data;
                irp_fifo_valid[irp_fifo_wr_ptr] <= 1'b1;
                irp_fifo_wr_ptr <= irp_fifo_wr_ptr + 1;
                fifo_count <= fifo_count + 1;
            end
            //update FIFO (remove)
            if (irp_fifo_valid[irp_fifo_rd_ptr] && current_state == BL_FETCH_IRP) begin
                irp_fifo_valid[irp_fifo_rd_ptr] <= 1'b0;
                irp_fifo_rd_ptr <= irp_fifo_rd_ptr + 1;
                fifo_count <= fifo_count - 1;
            end
            //SRB to FIFO when BUILD_SRB
            if (current_state == BL_BUILD_SRB && srb_out_ready) begin
                srb_fifo_valid[srb_fifo_wr_ptr] <= 1'b1;
                srb_fifo_wr_ptr <= srb_fifo_wr_ptr + 1;
            end
            //empty valid when SRB finished
            if (srb_out_valid && srb_out_ready) begin
                srb_fifo_valid[srb_fifo_rd_ptr] <= 1'b0;
                srb_fifo_rd_ptr <= srb_fifo_rd_ptr + 1;
                //$display("DEBUG BLOCK: SRB consumed from position %0d", srb_fifo_rd_ptr);
            end
            if (current_state != BL_IDLE) begin
                cycles_counter <= cycles_counter + 1;
            end
            if (current_state == BL_COMPLETE) begin
                irp_processed_count <= irp_processed_count + 1;
            end
        end
    end

    always_comb begin
        next_state = current_state;
        case (current_state)
            BL_IDLE: if (fifo_count > 0) next_state = BL_FETCH_IRP;
            BL_FETCH_IRP: next_state = BL_PARSE_IRP;
            BL_PARSE_IRP: next_state = BL_BUILD_MDL;
            BL_BUILD_MDL: next_state = BL_WAIT_MDL;
            BL_WAIT_MDL: next_state = BL_BUILD_SRB;
            BL_BUILD_SRB: next_state = srb_out_ready ? BL_QUEUE_SRB: BL_BUILD_SRB;
            BL_QUEUE_SRB: next_state = BL_COMPLETE;
            BL_COMPLETE: next_state = BL_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (current_state == BL_FETCH_IRP) begin
            logic [192:0] packed_irp;
            packed_irp = irp_fifo[irp_fifo_rd_ptr][192:0];

            //$display("DEBUG BLOCK: Raw packed_irp=%h", packed_irp);

            //packed_irp structure:
            current_irp.stack_location <= packed_irp[192:185];
            current_irp.irp_id <= packed_irp[184:169];
            current_irp.cancel <= packed_irp[168];
            current_irp.buffer_length <= packed_irp[167:136];
            current_irp.user_buffer_ptr <= packed_irp[135:72];
            current_irp.information <= packed_irp[71:40];//information/LBA
            current_irp.status <= packed_irp[39:8];
            current_irp.minor_function <= packed_irp[7:4];
            current_irp.major_function <= packed_irp[3:0];

            is_write_op = (packed_irp[3:0] == 4'h1);
            current_irp_id = packed_irp[184:169];

            current_lba = packed_irp[71:40];
            current_size = packed_irp[167:136];

            sector_count = (current_size + 511) / 512;

            //$display("DEBUG BLOCK: Extracted IRP %0d, LBA=%0d (0x%h), Size=%0d, is_write=%0d, Sectors=%0d",
            //current_irp_id, current_lba, current_lba, current_size, is_write_op, sector_count);

            current_srb.length <= 64;
            current_srb.srb_function <= is_write_op ? 8'h2A : 8'h28;//r/w
            current_srb.srb_status <= 8'h04;
            current_srb.scsi_status <= 8'h00;
            current_srb.data_transfer_length <= current_size;
            current_srb.timeout_value <= 32'd1000;//1 sec
            current_srb.cdb <= is_write_op ?
                {8'h2A, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0} :
                {8'h28, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0};
            current_srb.data_buffer_ptr <= current_irp.user_buffer_ptr;
            current_srb.original_irp_id <= current_irp_id;
            current_srb.lba <= current_lba;
            current_srb.sector_count <= sector_count;
            //$display("DEBUG BLOCK: Built SRB for IRP %0d, LBA=%0d, Sector Count=%0d, is_write=%0d",
            //current_irp_id, current_lba, sector_count, is_write_op);
        end
    end

    assign irp_in_ready = (fifo_count < QUEUE_DEPTH);
    assign srb_out_valid = srb_fifo_valid[srb_fifo_rd_ptr];
    assign srb_out_data = srb_fifo[srb_fifo_rd_ptr];

endmodule