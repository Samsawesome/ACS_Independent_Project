module irp_manager #(
    parameter MAX_IRPS = 256
)(
    input wire clk,
    input wire reset,

    input wire command_valid,
    input wire [31:0] command_lba,
    input wire [31:0] command_size,
    input wire [63:0] command_data,
    input wire command_is_write,
    output wire command_ready,

    output wire irp_valid,
    output wire [511:0] irp_data,
    input wire irp_ready,

    input wire completion_valid,
    input wire [15:0] completion_irp_id,
    input wire [31:0] completion_status
);
    import windows_storage_pkg::*;

    reg [15:0] irp_id_counter = 0;
    reg [511:0] irp_fifo [0:MAX_IRPS-1];
    reg [MAX_IRPS-1:0] irp_valid_bits;
    reg [7:0] irp_read_ptr;
    reg [7:0] irp_write_ptr;
    reg [31:0] active_irps;

    typedef enum logic [2:0] {
        IRP_IDLE,
        IRP_ALLOCATE,
        IRP_BUILD,
        IRP_QUEUE,
        IRP_WAIT
    } irp_state_t;
    irp_state_t current_state, next_state;

    irp_t current_irp; //enum from testbench

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= IRP_IDLE;
            irp_id_counter <= 0;
            active_irps <= 0;
            irp_read_ptr <= 0;
            irp_write_ptr <= 0;
            irp_valid_bits <= 0;
            for (int i = 0; i < MAX_IRPS; i = i + 1) irp_fifo[i] <= 512'b0;
        end else begin
            current_state <= next_state;

            if (completion_valid) begin
                //$display("DEBUG IRP_MGR: Completion for IRP %0d with status %h",
                //completion_irp_id, completion_status);
                for (int i = 0; i < MAX_IRPS; i++) begin
                    if (irp_valid_bits[i]) begin //if valid completion and valid irp
                        logic [192:0] packed_irp;
                        automatic logic [15:0] stored_irp_id;

                        packed_irp = irp_fifo[i][192:0];//get packed irp
                        stored_irp_id = packed_irp[183:168];//to store id
                        //$display("DEBUG IRP_MGR: Checking FIFO slot %0d, stored IRP ID=%0d",
                        //i, stored_irp_id);

                        if (stored_irp_id == completion_irp_id) begin
                            irp_valid_bits[i] <= 0; //if complete, no longer valid
                            if (active_irps > 0) active_irps <= active_irps - 1;//and one less active
                            //$display("DEBUG IRP_MGR: IRP %0d completed and removed", completion_irp_id);
                            break;
                        end
                    end
                end
            end
            if (irp_valid && irp_ready) begin
                irp_valid_bits[irp_read_ptr] <= 0;
                irp_read_ptr <= irp_read_ptr + 1; //move to next when valid and ready
                //$display("DEBUG IRP_MGR: IRP consumed from FIFO position %0d", irp_read_ptr);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (current_state == IRP_ALLOCATE) begin
            current_irp.irp_id <= irp_id_counter;
            //$display("DEBUG IRP_MGR: Building IRP with ID %0d, is_write=%0d, LBA=%0d, Size=%0d",
            //irp_id_counter, command_is_write, command_lba, command_size);
            //build IRP when in allocation stage
            current_irp.major_function <= command_is_write ?
                irp_major_function_t'(IRP_MJ_WRITE) : irp_major_function_t'(IRP_MJ_READ); //from testbench, matches real life specs
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
            logic [192:0] packed_irp;

            irp_fifo[irp_write_ptr] <= 512'b0;

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

            irp_fifo[irp_write_ptr][192:0] <= packed_irp; //put packed in fifo

            irp_valid_bits[irp_write_ptr] <= 1'b1;
            irp_write_ptr <= irp_write_ptr + 1;
            active_irps <= active_irps + 1;

            //$display("DEBUG IRP_MGR: IRP %0d queued, LBA=%0d, Size=%0d, Write=%0d, packed=%h",
            //current_irp.irp_id, current_irp.information,
            //current_irp.buffer_length, current_irp.major_function == 4'h1,
            //packed_irp);
        end
    end

    always_comb begin
        next_state = current_state;
        case (current_state)
            IRP_IDLE: if (command_valid && active_irps < MAX_IRPS) next_state = IRP_ALLOCATE; //allocate if valid and theres room
            IRP_ALLOCATE: next_state = IRP_BUILD;
            IRP_BUILD: next_state = IRP_QUEUE;
            IRP_QUEUE: next_state = irp_valid_bits[irp_write_ptr] ? IRP_WAIT : IRP_IDLE; //idle if cmd isnt valid yet
            IRP_WAIT: if (!irp_valid_bits[irp_write_ptr]) next_state = IRP_IDLE; //once finished, go back to idle
            default: next_state = IRP_IDLE;
        endcase
    end

    assign command_ready = (current_state == IRP_IDLE) && (active_irps < MAX_IRPS);
    assign irp_valid = irp_valid_bits[irp_read_ptr];
    assign irp_data = irp_fifo[irp_read_ptr];

    /*always @(posedge clk) begin
        if (irp_valid) begin
            logic [15:0] debug_irp_id;
            debug_irp_id = irp_data[184:169];
            $display("DEBUG IRP_MGR: FIFO output has IRP %0d at position %0d", debug_irp_id, irp_read_ptr);
        end
    end*/
endmodule