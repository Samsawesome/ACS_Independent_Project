// ============================================================================
// Module: IRP Manager
// ============================================================================
module irp_manager #(
    parameter MAX_IRPS = 256,
    parameter IRP_ID_WIDTH = 8
)(
    input wire clk,
    input wire reset_n,

    // Command Interface
    input wire command_valid,
    input wire [31:0] command_lba,
    input wire [31:0] command_size,
    input wire [63:0] command_data,
    input wire command_is_write,
    output wire command_ready,

    // IRP Interface to Block Layer
    output wire irp_valid,
    output wire [511:0] irp_data,
    input wire irp_ready,

    // Completion Interface
    input wire completion_valid,
    input wire [15:0] completion_irp_id,
    input wire [31:0] completion_status,
    input wire [31:0] completion_information,

    // Statistics
    output wire [63:0] total_irps_created,
    output wire [31:0] active_irp_count
);

    import windows_storage_pkg::*;

    // Internal registers
    reg [15:0] irp_id_counter = 0;
    reg [511:0] irp_fifo [0:MAX_IRPS-1];
    reg [MAX_IRPS-1:0] irp_valid_bits;
    reg [7:0] irp_read_ptr;
    reg [7:0] irp_write_ptr;
    reg [63:0] irp_creation_count;
    reg [31:0] active_irps;

    // IRP Creation State Machine
    typedef enum logic [2:0] {
        IRP_IDLE,
        IRP_ALLOCATE,
        IRP_BUILD,
        IRP_QUEUE,
        IRP_WAIT
    } irp_state_t;

    irp_state_t current_state, next_state;

    // Temporary IRP storage
    irp_t current_irp;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= IRP_IDLE;
            irp_id_counter <= 0;
            irp_creation_count <= 0;
            active_irps <= 0;
            irp_read_ptr <= 0;
            irp_write_ptr <= 0;
            irp_valid_bits <= 0;
            for (int i = 0; i < MAX_IRPS; i = i + 1) begin
                irp_fifo[i] <= 512'b0;
            end
            //$display("IRP_MGR: Reset complete");
        end else begin
            current_state <= next_state;

            // Completion tracking with IRP ID extraction
            if (completion_valid) begin
                //$display("DEBUG IRP_MGR: Completion for IRP %0d with status %h",
                //        completion_irp_id, completion_status);

                for (int i = 0; i < MAX_IRPS; i++) begin
                    if (irp_valid_bits[i]) begin
                        logic [192:0] packed_irp;
                        automatic logic [15:0] stored_irp_id;

                        packed_irp = irp_fifo[i][192:0];  // Get 193-bit packed IRP
                        stored_irp_id = packed_irp[183:168];

                        //$display("DEBUG IRP_MGR: Checking FIFO slot %0d, stored IRP ID=%0d",
                        //        i, stored_irp_id);

                        if (stored_irp_id == completion_irp_id) begin
                            irp_valid_bits[i] <= 0;
                            if (active_irps > 0) active_irps <= active_irps - 1;
                            //$display("DEBUG IRP_MGR: IRP %0d completed and removed", completion_irp_id);
                            break;
                        end
                    end
                end
            end

            // Clear IRP from FIFO when consumed by block layer
            if (irp_valid && irp_ready) begin
                irp_valid_bits[irp_read_ptr] <= 0;
                irp_read_ptr <= irp_read_ptr + 1;
                //$display("DEBUG IRP_MGR: IRP consumed from FIFO position %0d", irp_read_ptr);
            end
        end
    end

    // State machine
    always_comb begin
        next_state = current_state;

        case (current_state)
            IRP_IDLE: begin
                if (command_valid && active_irps < MAX_IRPS) begin
                    next_state = IRP_ALLOCATE;
                end
            end

            IRP_ALLOCATE: begin
                next_state = IRP_BUILD;
            end

            IRP_BUILD: begin
                next_state = IRP_QUEUE;
            end

            IRP_QUEUE: begin
                if (!irp_valid_bits[irp_write_ptr]) begin
                    next_state = IRP_IDLE;
                end else begin
                    next_state = IRP_WAIT;
                end
            end

            IRP_WAIT: begin
                if (!irp_valid_bits[irp_write_ptr]) begin
                    next_state = IRP_IDLE;
                end
            end
        endcase
    end

    // IRP Building Logic
    always_ff @(posedge clk) begin
        if (current_state == IRP_ALLOCATE) begin
            current_irp.irp_id <= irp_id_counter;

            //$display("DEBUG IRP_MGR: Building IRP with ID %0d, is_write=%0d, LBA=%0d, Size=%0d",
            //        irp_id_counter, command_is_write, command_lba, command_size);

            current_irp.major_function <= command_is_write ?
                irp_major_function_t'(IRP_MJ_WRITE) : irp_major_function_t'(IRP_MJ_READ);
            current_irp.minor_function <= 0;
            current_irp.status <= STATUS_PENDING;
            current_irp.information <= command_lba;
            current_irp.user_buffer_ptr <= command_data;
            current_irp.buffer_length <= command_size;
            current_irp.cancel <= 0;
            current_irp.stack_location <= 0;

            irp_id_counter <= irp_id_counter + 1;
        end

        if (current_state == IRP_QUEUE) begin
            logic [192:0] packed_irp;  // 193 bits total

            irp_fifo[irp_write_ptr] <= 512'b0;

            //   [192:185] stack_location   (8 bits)
            //   [184:169] irp_id           (16 bits)
            //   [168] cancel               (1 bit)
            //   [167:136] buffer_length    (32 bits)
            //   [135:72] user_buffer_ptr   (64 bits)
            //   [71:40] information (LBA)  (32 bits)
            //   [39:8]  status             (32 bits)
            //   [7:4]   minor_function     (4 bits)
            //   [3:0]   major_function     (4 bits)

            packed_irp = {
                current_irp.stack_location,
                current_irp.irp_id,
                current_irp.cancel,
                current_irp.buffer_length,
                current_irp.user_buffer_ptr,
                current_irp.information,
                current_irp.status,
                current_irp.minor_function,
                current_irp.major_function
            };

            irp_fifo[irp_write_ptr][192:0] <= packed_irp;

            irp_valid_bits[irp_write_ptr] <= 1'b1;
            irp_write_ptr <= irp_write_ptr + 1;
            irp_creation_count <= irp_creation_count + 1;
            active_irps <= active_irps + 1;

            //$display("DEBUG IRP_MGR: IRP %0d queued, LBA=%0d, Size=%0d, Write=%0d, packed=%h",
            //        current_irp.irp_id, current_irp.information,
            //        current_irp.buffer_length, current_irp.major_function == 4'h1,
            //        packed_irp);
        end
    end

    // Output assignments
    assign command_ready = (current_state == IRP_IDLE) && (active_irps < MAX_IRPS);
    assign irp_valid = irp_valid_bits[irp_read_ptr];
    assign irp_data  = irp_fifo[irp_read_ptr];

    assign total_irps_created = irp_creation_count;
    assign active_irp_count   = active_irps;

    // Debug: Monitor IRP FIFO state
    always @(posedge clk) begin
        if (irp_valid) begin
            logic [15:0] debug_irp_id;
            debug_irp_id = irp_data[184:169];

            //$display("DEBUG IRP_MGR: FIFO output has IRP %0d at position %0d",
            //        debug_irp_id, irp_read_ptr);
        end
    end

endmodule