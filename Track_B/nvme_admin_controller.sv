// ============================================================================
// NVMe Admin Queue Controller (FIXED with persistent read request)
// ============================================================================
module nvme_admin_controller #(
    parameter QUEUE_DEPTH = 8,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset_n,

    // Doorbell Interface
    input wire sq_tail_update,
    input wire [4:0] sq_tail_value,
    input wire cq_head_update,
    input wire [4:0] cq_head_value,

    // Queue Memory Interface
    output wire admin_rd_en,
    output wire [63:0] admin_rd_addr,
    input wire [DATA_WIDTH-1:0] admin_rd_data,
    input wire admin_rd_valid,

    output wire admin_wr_en,
    output wire [63:0] admin_wr_addr,
    output wire [DATA_WIDTH-1:0] admin_wr_data,

    // Controller Command Interface (unused)
    output reg admin_cmd_valid,
    output reg [DATA_WIDTH-1:0] admin_cmd_data,
    input wire admin_cmd_ready,

    // Controller Completion Interface (unused)
    input wire admin_cpl_valid,
    input wire [DATA_WIDTH-1:0] admin_cpl_data,
    output wire admin_cpl_ready,

    // IO Queue Configuration Interface
    output reg create_io_queue_valid,
    output reg [15:0] create_io_queue_id,
    output reg [15:0] create_io_queue_size,
    output reg create_io_queue_type,
    output reg [15:0] create_io_cq_id,
    output reg [15:0] create_io_sq_id,
    output reg [63:0] create_io_queue_addr,
    input wire create_io_queue_ready,

    // Queue Base Addresses
    input wire [63:0] admin_sq_base_addr,
    input wire [63:0] admin_cq_base_addr,

    // Controller Status
    output reg [31:0] admin_controller_status,
    output reg [15:0] admin_sq_head,
    output reg [15:0] admin_sq_tail,
    output reg [15:0] admin_cq_head,
    output reg [15:0] admin_cq_tail,

    // Interrupt
    output reg admin_interrupt_pending
);

    typedef enum logic [7:0] {
        ADMIN_OPC_IDENTIFY        = 8'h06,
        ADMIN_OPC_CREATE_SQ       = 8'h01,
        ADMIN_OPC_CREATE_CQ       = 8'h05,
        ADMIN_OPC_DELETE_SQ       = 8'h00,
        ADMIN_OPC_DELETE_CQ       = 8'h04,
        ADMIN_OPC_GET_FEATURES    = 8'h0A,
        ADMIN_OPC_SET_FEATURES    = 8'h09,
        ADMIN_OPC_GET_LOG_PAGE    = 8'h02
    } admin_opcode_t;

    typedef enum logic [2:0] {
        ADMIN_IDLE,
        ADMIN_READ_CMD,
        ADMIN_PARSE_CMD,
        ADMIN_EXECUTE,
        ADMIN_WRITE_CPL,
        ADMIN_WAIT_WRITE,
        ADMIN_WAIT
    } admin_state_t;

    admin_state_t current_state, next_state;

    reg [4:0] sq_head_ptr;
    reg [4:0] sq_tail_ptr;
    reg [4:0] cq_head_ptr;
    reg [4:0] cq_tail_ptr;
    reg       cq_phase;

    reg [DATA_WIDTH-1:0] current_cmd;
    reg [7:0] current_opcode;
    reg [15:0] current_cmd_id;
    reg [31:0] current_nsid;

    reg [DATA_WIDTH-1:0] current_cpl;
    reg [15:0] cpl_status;

    reg [31:0] timeout_counter;

    reg [DATA_WIDTH-1:0] identify_buffer [0:7];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= ADMIN_IDLE;
            sq_head_ptr <= 0;
            sq_tail_ptr <= 0;
            cq_head_ptr <= 0;
            cq_tail_ptr <= 0;
            cq_phase <= 1'b1;

            admin_controller_status <= 0;
            admin_interrupt_pending <= 0;
            timeout_counter <= 0;

            for (int i = 0; i < 8; i = i + 1) identify_buffer[i] <= 0;
            identify_buffer[0][15:0]   <= 16'h8086;
            identify_buffer[0][63:48]  <= 16'h0953;
            identify_buffer[0][77:76]  <= 2'b01;
            identify_buffer[0][79:78]  <= 2'b00;
            identify_buffer[0][25:24]  <= 16'h0001;

            admin_sq_head <= 0;
            admin_sq_tail <= 0;
            admin_cq_head <= 0;
            admin_cq_tail <= 0;
            create_io_queue_valid <= 0;
        end else begin
            current_state <= next_state;

            // Doorbell updates
            if (sq_tail_update) begin
                sq_tail_ptr <= sq_tail_value;
                admin_sq_tail <= sq_tail_value;
            end
            if (cq_head_update) begin
                cq_head_ptr <= cq_head_value;
                admin_cq_head <= cq_head_value;
            end
            admin_sq_head <= sq_head_ptr;
            admin_cq_tail <= cq_tail_ptr;

            if (cq_head_update && admin_interrupt_pending)
                admin_interrupt_pending <= 0;
                
            if (sq_tail_update) $display("Admin: Doorbell update received, new tail=%0d", sq_tail_value);
            if (cq_head_update) $display("*** ADMIN: CQ head update received, new head=%0d at time %t", cq_head_value, $time);

            case (current_state)
                ADMIN_IDLE: begin
                    //$display("Admin: IDLE, head=%0d, tail=%0d", sq_head_ptr, sq_tail_ptr);
                    timeout_counter <= 0;
                end

                ADMIN_READ_CMD: begin
                    $display("Admin: READ_CMD, rd_en=1, addr=%h", admin_sq_base_addr + (sq_head_ptr * 64));
                    if (admin_rd_valid) begin
                        $display("Admin: READ_CMD received valid data: opcode=%h, cid=%0d", 
                                admin_rd_data[7:0], admin_rd_data[31:16]);
                        current_cmd <= admin_rd_data;
                        timeout_counter <= 0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                        if (timeout_counter % 10000 == 0) $display("Admin: READ_CMD timeout count=%0d", timeout_counter);
                    end
                end

                ADMIN_PARSE_CMD: begin
                    current_opcode <= current_cmd[7:0];
                    current_cmd_id <= current_cmd[31:16];
                    current_nsid    <= current_cmd[63:32];
                    $display("Admin: PARSE_CMD, opcode=%h, cid=%0d, nsid=%0d",
                 current_cmd[7:0], current_cmd[31:16], current_cmd[63:32]);
                end

                ADMIN_EXECUTE: begin
                    case (current_opcode)
                        ADMIN_OPC_IDENTIFY: begin
                            $display("Admin: EXECUTE, opcode=%h", current_opcode);
                            cpl_status <= 16'h0000;
                        end
                        ADMIN_OPC_CREATE_SQ: begin
                            automatic logic [15:0] sq_id = current_cmd[351:336];   // bits 31:16 of DW10
                            automatic logic [15:0] queue_size = current_cmd[335:320] + 1; // bits 15:0 of DW10
                            automatic logic [15:0] cq_id = current_cmd[383:368];   // bits 31:16 of DW11
                            automatic logic [63:0] base_addr = current_cmd[127:64]; // PRP1
                            $display("Admin: Creating IO SQ%0d (size=%0d) associated with CQ%0d at addr %h",
                                    sq_id, queue_size, cq_id, base_addr);
                            create_io_queue_valid <= 1'b1;
                            create_io_queue_id    <= sq_id;
                            create_io_queue_size  <= queue_size;
                            create_io_queue_type  <= 1'b0;  // SQ
                            create_io_cq_id       <= cq_id;
                            create_io_queue_addr  <= base_addr;
                            cpl_status <= 16'h0000;
                        end
                        ADMIN_OPC_CREATE_CQ: begin
                            automatic logic [15:0] cq_id = current_cmd[351:336];   // bits 31:16 of DW10
                            automatic logic [15:0] queue_size = current_cmd[335:320] + 1; // bits 15:0 of DW10
                            automatic logic [63:0] base_addr = current_cmd[127:64]; // PRP1
                            $display("Admin: Creating IO CQ%0d (size=%0d) at addr %h",
                                    cq_id, queue_size, base_addr);
                            create_io_queue_valid <= 1'b1;
                            create_io_queue_id    <= cq_id;
                            create_io_queue_size  <= queue_size;
                            create_io_queue_type  <= 1'b1;  // CQ
                            create_io_queue_addr  <= base_addr;
                            cpl_status <= 16'h0000;
                        end
                        default: begin
                            $display("Admin: Unsupported opcode %h", current_opcode);
                            cpl_status <= 16'h0001;
                        end
                    endcase
                    timeout_counter <= timeout_counter + 1;
                end

                ADMIN_WRITE_CPL: begin
                    $display("Admin: WRITE_CPL, building completion for cid=%0d", current_cmd_id);
                    current_cpl <= 512'h0;
                    current_cpl[31:0]   <= 32'h0;
                    current_cpl[47:32]  <= sq_head_ptr;
                    current_cpl[63:48]  <= 16'h0;          // SQ ID (Admin queue is 0)
                    current_cpl[79:64]  <= current_cmd_id;
                    current_cpl[95:80]  <= cpl_status;
                    current_cpl[96]      <= cq_phase;
                    timeout_counter <= timeout_counter + 1;
                end

                ADMIN_WAIT_WRITE: begin
                    // Write is active; assume it completes this cycle
                    cq_tail_ptr <= cq_tail_ptr + 1;
                    sq_head_ptr <= sq_head_ptr + 1;
                    if (cq_tail_ptr == QUEUE_DEPTH-1)
                        cq_phase <= ~cq_phase;
                    admin_interrupt_pending <= 1'b1;
                    $display("Admin: WAIT_WRITE, writing completion at addr %h", admin_cq_base_addr + (cq_tail_ptr * 16));
                    timeout_counter <= 0;
                end

                ADMIN_WAIT: begin
                    $display("Admin: WAIT, create_queue_valid=%0d, ready=%0d", 
                 create_io_queue_valid, create_io_queue_ready);
                    if (create_io_queue_ready && create_io_queue_valid)
                        create_io_queue_valid <= 0;
                    timeout_counter <= timeout_counter + 1;
                end
            endcase

            if (timeout_counter > 32'd1000000) begin
                $display("Admin: Timeout in state %0d", current_state);
                current_state <= ADMIN_IDLE;
                timeout_counter <= 0;
            end
        end
    end

    always_comb begin
        next_state = current_state;
        case (current_state)
            ADMIN_IDLE: if (sq_head_ptr != sq_tail_ptr) next_state = ADMIN_READ_CMD;
            ADMIN_READ_CMD: if (admin_rd_valid) next_state = ADMIN_PARSE_CMD;
            ADMIN_PARSE_CMD: next_state = ADMIN_EXECUTE;
            ADMIN_EXECUTE: begin
                if (current_opcode == ADMIN_OPC_CREATE_SQ ||
                    current_opcode == ADMIN_OPC_CREATE_CQ)
                    next_state = ADMIN_WAIT;
                else
                    next_state = ADMIN_WRITE_CPL;
            end
            ADMIN_WRITE_CPL: next_state = ADMIN_WAIT_WRITE;
            ADMIN_WAIT_WRITE: next_state = ADMIN_IDLE;
            ADMIN_WAIT: if (!create_io_queue_valid || create_io_queue_ready)
                            next_state = ADMIN_WRITE_CPL;
        endcase
    end

    // Read enable stays high while in ADMIN_READ_CMD
    assign admin_rd_en   = (current_state == ADMIN_READ_CMD);
    assign admin_rd_addr = admin_sq_base_addr + (sq_head_ptr * 64);

    // Write enable is high during WRITE_CPL and WAIT_WRITE
    assign admin_wr_en   = (current_state == ADMIN_WRITE_CPL) || (current_state == ADMIN_WAIT_WRITE);
    assign admin_wr_addr = admin_cq_base_addr + (cq_tail_ptr * 16);
    assign admin_wr_data = current_cpl;

    assign admin_cpl_ready = 1'b1;

endmodule