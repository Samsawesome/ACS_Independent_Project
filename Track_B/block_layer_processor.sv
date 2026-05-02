// ============================================================================
// Module: Block Layer Processor
// ============================================================================
module block_layer_processor #(
    parameter QUEUE_DEPTH = 64,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset_n,
    
    // IRP Input Interface
    input wire irp_in_valid,
    input wire [511:0] irp_in_data,
    output wire irp_in_ready,
    
    // SRB Output Interface (to Port Driver)
    output wire srb_out_valid,
    output wire [1023:0] srb_out_data,
    input wire srb_out_ready,
    
    // MDL Interface
    output reg mdl_request_valid,
    output reg [63:0] mdl_buffer_addr,
    output reg [31:0] mdl_buffer_size,
    input wire mdl_request_ready,
    input wire mdl_complete_valid,
    input wire [63:0] mdl_physical_addr,
    
    // Statistics
    output wire [31:0] block_layer_cycles,
    output wire [31:0] irps_processed,
    
    // DEBUG OUTPUTS
    output wire [3:0] debug_state,
    output wire [31:0] debug_fifo_count,
    output wire [31:0] debug_srb_fifo_count,
    output wire [15:0] debug_current_irp_id
);
    
    import windows_storage_pkg::*;
    
    // Internal FIFOs
    reg [511:0] irp_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] irp_fifo_valid;
    reg [5:0] irp_fifo_rd_ptr;
    reg [5:0] irp_fifo_wr_ptr;
    reg [31:0] fifo_count;
    
    // SRB FIFO
    reg [1023:0] srb_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] srb_fifo_valid;
    reg [5:0] srb_fifo_rd_ptr;
    reg [5:0] srb_fifo_wr_ptr;
    reg [31:0] srb_fifo_count;
    
    // Processing State Machine
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
    
    // Current processing context
    irp_t current_irp;
    srb_t current_srb;
    reg [31:0] current_lba;
    reg [31:0] current_size;
    reg is_write_op;
    reg [15:0] current_irp_id;
    reg [63:0] current_physical_addr;
    reg [31:0] sector_count;
    reg [31:0] cycles_counter;
    reg [31:0] irp_processed_count;
    
    // MDL State
    reg mdl_in_progress;
    reg [31:0] mdl_wait_cycles;
    
    // Debug tracking
    reg [15:0] last_irp_id_processed;
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= BL_IDLE;
            irp_fifo_valid <= 0;
            srb_fifo_valid <= 0;
            irp_fifo_rd_ptr <= 0;
            irp_fifo_wr_ptr <= 0;
            srb_fifo_rd_ptr <= 0;
            srb_fifo_wr_ptr <= 0;
            fifo_count <= 0;
            srb_fifo_count <= 0;
            cycles_counter <= 0;
            irp_processed_count <= 0;
            mdl_in_progress <= 0;
            mdl_wait_cycles <= 0;
            mdl_request_valid <= 0;
            mdl_buffer_addr <= 0;
            mdl_buffer_size <= 0;
            current_irp_id <= 0;
            last_irp_id_processed <= 0;
            sector_count <= 0;


            for (int i = 0; i < QUEUE_DEPTH; i = i + 1) begin
                srb_fifo[i] <= 1024'b0;
                srb_fifo_valid[i] <= 1'b0;
            end
            
        end else begin
            current_state <= next_state;
            
            // Update FIFO pointers
            if (irp_in_valid && irp_in_ready) begin
                irp_fifo[irp_fifo_wr_ptr] <= irp_in_data;
                irp_fifo_valid[irp_fifo_wr_ptr] <= 1'b1;
                irp_fifo_wr_ptr <= irp_fifo_wr_ptr + 1;
                fifo_count <= fifo_count + 1;
            end
            
            if (irp_fifo_valid[irp_fifo_rd_ptr] && current_state == BL_FETCH_IRP) begin
                irp_fifo_valid[irp_fifo_rd_ptr] <= 1'b0;
                irp_fifo_rd_ptr <= irp_fifo_rd_ptr + 1;
                fifo_count <= fifo_count - 1;
            end
            
             // Write SRB to FIFO in BUILD_SRB state with valid bit
            if (current_state == BL_BUILD_SRB && srb_out_ready) begin
                // same packing and writes
                srb_fifo_valid[srb_fifo_wr_ptr] <= 1'b1;
                srb_fifo_wr_ptr <= srb_fifo_wr_ptr + 1;
                srb_fifo_count <= srb_fifo_count + 1;
            end
                        
            // Clear valid bit when SRB is consumed
            if (srb_out_valid && srb_out_ready) begin
                srb_fifo_valid[srb_fifo_rd_ptr] <= 1'b0;
                srb_fifo_rd_ptr <= srb_fifo_rd_ptr + 1;
                srb_fifo_count <= srb_fifo_count - 1;
                //$display("DEBUG BLOCK: SRB consumed from position %0d", srb_fifo_rd_ptr);
            end
            
            // Update statistics
            if (current_state != BL_IDLE) begin
                cycles_counter <= cycles_counter + 1;
            end
            
            // In the always_ff block, add this update:
            if (current_state == BL_COMPLETE) begin
                last_irp_id_processed <= current_irp_id;  // Update with the current IRP ID
                irp_processed_count <= irp_processed_count + 1;
            end
            
            // MDL tracking
            if (mdl_request_valid && mdl_request_ready) begin
                mdl_in_progress <= 1'b1;
                mdl_wait_cycles <= 0;
            end
            
            if (mdl_in_progress) begin
                mdl_wait_cycles <= mdl_wait_cycles + 1;
                if (mdl_complete_valid) begin
                    mdl_in_progress <= 1'b0;
                end
            end
            
            // Handle MDL output signals
            if (current_state == BL_BUILD_MDL) begin
                mdl_request_valid <= 1'b1;
                mdl_buffer_addr <= current_irp.user_buffer_ptr;
                mdl_buffer_size <= current_irp.buffer_length;
            end else begin
                mdl_request_valid <= 1'b0;
            end
        end
    end
    
    // State machine
    always_comb begin
    next_state = current_state;
    
    case (current_state)
        BL_IDLE: begin
            if (fifo_count > 0) begin
                next_state = BL_FETCH_IRP;
            end
        end
        
        BL_FETCH_IRP: begin
            next_state = BL_PARSE_IRP;
        end
        
        BL_PARSE_IRP: begin
            // Parse IRP and calculate sector count (512-byte sectors)
            // This is combinatorial, move to next state
            next_state = BL_BUILD_MDL;
        end
        
        BL_BUILD_MDL: begin
            // MDL request is made, wait for it to be accepted
            if (mdl_request_ready || !mdl_in_progress) begin
                next_state = BL_WAIT_MDL;
            end
        end
        
        BL_WAIT_MDL: begin
            if (mdl_complete_valid) begin
                next_state = BL_BUILD_SRB;
            end
        end
        
        BL_BUILD_SRB: begin
            if (srb_out_ready)                     // wait for NVMe driver to have room
                next_state = BL_QUEUE_SRB;
            else
                next_state = BL_BUILD_SRB;
        end
        
        BL_QUEUE_SRB: begin
            // Move to COMPLETE immediately after queuing
            next_state = BL_COMPLETE;
        end
        
        BL_COMPLETE: begin
            next_state = BL_IDLE;
        end
    endcase
end
    
    // IRP Parsing
    always_ff @(posedge clk) begin
        if (current_state == BL_FETCH_IRP) begin
            // Extract correct 193-bit packed IRP
            logic [192:0] packed_irp;
            packed_irp = irp_fifo[irp_fifo_rd_ptr][192:0];
            
            // Debug the raw packed IRP
            //$display("DEBUG BLOCK: Raw packed_irp=%h (193 bits)", packed_irp);
            
            // FIXED: CORRECT UNPACKING (reverse of packing)
            // packed_irp structure:
            //   [192:185] = stack_location (8 bits)
            //   [184:169] = irp_id (16 bits)
            //   [168] = cancel (1 bit)
            //   [167:136] = buffer_length (32 bits)
            //   [135:72] = user_buffer_ptr (64 bits)
            //   [71:40] = information/LBA (32 bits)
            //   [39:8] = status (32 bits)
            //   [7:4] = minor_function (4 bits)
            //   [3:0] = major_function (4 bits)
            
            current_irp.stack_location <= packed_irp[192:185];
            current_irp.irp_id <= packed_irp[184:169];
            current_irp.cancel <= packed_irp[168];
            current_irp.buffer_length <= packed_irp[167:136];
            current_irp.user_buffer_ptr <= packed_irp[135:72];
            current_irp.information <= packed_irp[71:40];  // LBA
            current_irp.status <= packed_irp[39:8];
            current_irp.minor_function <= packed_irp[7:4];
            current_irp.major_function <= packed_irp[3:0];
            
            is_write_op = (packed_irp[3:0] == 4'h1);
            current_irp_id = packed_irp[184:169];
            
            // Extract LBA and size
            current_lba = packed_irp[71:40];
            current_size = packed_irp[167:136];
            
            // Calculate sector count (512-byte sectors)
            sector_count = (current_size + 511) / 512;
            
            //$display("DEBUG BLOCK: Extracted IRP %0d, LBA=%0d (0x%h), Size=%0d, is_write=%0d, Sectors=%0d",
            //        current_irp_id, current_lba, current_lba, current_size, is_write_op, sector_count);
            

            current_srb.length <= 64;
            current_srb.srb_function <= is_write_op ? 8'h2A : 8'h28;  // SCSIOP_WRITE or SCSIOP_READ
            current_srb.srb_status <= 8'h04;  // SRB_STATUS_PENDING
            current_srb.scsi_status <= 8'h00;
            current_srb.data_transfer_length <= current_size;
            current_srb.timeout_value <= 32'd1000;  // 1 second timeout
            current_srb.cdb <= is_write_op ? 
                {8'h2A, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0} :  // Write(10) CDB
                {8'h28, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0};   // Read(10) CDB
            current_srb.data_buffer_ptr <= current_irp.user_buffer_ptr;
            current_srb.original_irp_id <= current_irp_id;
            current_srb.lba <= current_lba;
            current_srb.sector_count <= sector_count;
            
            //$display("DEBUG BLOCK: Built SRB for IRP %0d, LBA=%0d, Sector Count=%0d, is_write=%0d",
            //        current_irp_id, current_lba, sector_count, is_write_op);
        end
    end
    
    // Output assignments
    assign irp_in_ready = (fifo_count < QUEUE_DEPTH);
    assign srb_out_valid = srb_fifo_valid[srb_fifo_rd_ptr];
    assign srb_out_data = srb_fifo[srb_fifo_rd_ptr];
    
    assign block_layer_cycles = cycles_counter;
    assign irps_processed = irp_processed_count;
    
    // DEBUG OUTPUTS
    assign debug_state = current_state;
    assign debug_fifo_count = fifo_count;
    assign debug_srb_fifo_count = srb_fifo_count;
    assign debug_current_irp_id = last_irp_id_processed;
    
endmodule