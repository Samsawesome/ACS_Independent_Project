module io_processor #(
    parameter NUM_IO_QUEUES = 8,
    parameter QUEUE_DEPTH = 32,
    parameter DATA_WIDTH = 512,
    parameter SSD_LATENCY_CYCLES = 5000
)(
    input wire clk,
    input wire reset_n,

    output reg         ctrl_req,
    output reg         ctrl_rd_wr_n,
    output reg [63:0]  ctrl_addr,
    input  wire [DATA_WIDTH-1:0] ctrl_rd_data,
    input  wire         ctrl_rd_valid,
    output reg [DATA_WIDTH-1:0] ctrl_wr_data,
    input  wire         ctrl_grant,

    input  wire [4:0]   doorbell_sq_tail [0:NUM_IO_QUEUES-1],
    input  wire [4:0]   doorbell_cq_head [0:NUM_IO_QUEUES-1],
    input  wire [4:0]   queue1_sq_tail,

    input  wire [63:0]  sq_base [0:NUM_IO_QUEUES-1],
    input  wire [63:0]  cq_base [0:NUM_IO_QUEUES-1],
    input  wire [15:0]  sq_size [0:NUM_IO_QUEUES-1],
    input  wire [15:0]  cq_size [0:NUM_IO_QUEUES-1],

    output reg [NUM_IO_QUEUES-1:0] interrupt_request,
    output reg [31:0]  commands_processed,
    output reg io_done
);

    reg [4:0] dev_sq_head [0:NUM_IO_QUEUES-1];
    reg [4:0] dev_cq_tail [0:NUM_IO_QUEUES-1];
    reg       cq_phase [0:NUM_IO_QUEUES-1];

    typedef enum logic [3:0] {
        IDLE,
        START_READ,
        WAIT_READ,
        PROCESS_DELAY,
        WRITE_CPL,
        UPDATE_PTRS
    } state_t;
    state_t state;

    integer         current_q;
    reg [15:0]      current_cid;
    reg [511:0]     cmd_data;
    reg [511:0]     cpl_data;
    integer i;

    reg [31:0] delay_counter;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < NUM_IO_QUEUES; i++) begin
                dev_sq_head[i] <= 0;
                dev_cq_tail[i] <= 0;
                cq_phase[i]   <= 1'b1;
                io_done <= 0;
            end
            state <= IDLE;
            ctrl_req <= 0;
            ctrl_rd_wr_n <= 0;
            ctrl_addr <= 0;
            ctrl_wr_data <= 0;
            interrupt_request <= 0;
            commands_processed <= 0;
            delay_counter <= 0;
            current_cid <= 0;
            current_q = -1;
        end else begin
            ctrl_req <= 0;
            interrupt_request <= 0;

            case (state)
                IDLE: begin
                    io_done <= 0;
                    current_q = -1;
                    delay_counter <= 0;
                    if (dev_sq_head[1] != queue1_sq_tail) begin
                        current_q = 1;
                    end else begin
                        for (i = 0; i < NUM_IO_QUEUES; i++) begin
                            if (i == 1) continue;
                            if (dev_sq_head[i] != doorbell_sq_tail[i]) begin
                                current_q = i;
                                break;
                            end
                        end
                    end
                    if (current_q != -1) begin
                        ctrl_req <= 1;
                        ctrl_rd_wr_n <= 0;
                        ctrl_addr <= sq_base[current_q] + (dev_sq_head[current_q] * 64);
                        state <= START_READ;
                    end
                end

                START_READ: begin
                    ctrl_req <= 1;
                    ctrl_rd_wr_n <= 0;
                    state <= WAIT_READ;
                end

                WAIT_READ: begin
                    ctrl_req <= 1;
                    ctrl_rd_wr_n <= 0;
                    if (ctrl_rd_valid) begin
                        cmd_data <= ctrl_rd_data;
                        current_cid <= ctrl_rd_data[31:16];
                        // Build completion
                        cpl_data <= 512'h0;
                        cpl_data[31:0]   <= 32'h0;
                        cpl_data[47:32]  <= dev_sq_head[current_q];
                        cpl_data[63:48]  <= current_q;
                        cpl_data[79:64]  <= current_cid;
                        cpl_data[96]     <= cq_phase[current_q];
                        delay_counter <= 0;
                        state <= PROCESS_DELAY;
                    end
                end

                PROCESS_DELAY: begin
                    ctrl_req <= 0;
                    if (delay_counter < SSD_LATENCY_CYCLES) begin
                        delay_counter <= delay_counter + 1;
                        state <= PROCESS_DELAY;
                    end else begin
                        ctrl_req <= 1;
                        ctrl_rd_wr_n <= 1;
                        ctrl_addr <= cq_base[current_q] + (dev_cq_tail[current_q] * 16);
                        ctrl_wr_data <= cpl_data;
                        state <= WRITE_CPL;
                    end
                end

                WRITE_CPL: begin
                    ctrl_req <= 1;
                    ctrl_rd_wr_n <= 1;
                    io_done <= 1'b1;
                    //$display("IO_PROC: io_done pulsed (completion written for queue %0d)", current_q);
                    state <= UPDATE_PTRS;
                end

                UPDATE_PTRS: begin
                    ctrl_req <= 0;
                    dev_cq_tail[current_q] <= (dev_cq_tail[current_q] + 1) % cq_size[current_q];
                    if (dev_cq_tail[current_q] == cq_size[current_q] - 1)
                        cq_phase[current_q] <= ~cq_phase[current_q];
                    dev_sq_head[current_q] <= (dev_sq_head[current_q] + 1) % sq_size[current_q];
                    interrupt_request[current_q] <= 1'b1;
                    commands_processed <= commands_processed + 1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule