module host_pcie_bridge #(
    parameter QUEUE_SIZE          = 32,
    parameter SSD_LATENCY_CYCLES = 5000
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        enable,
    input  wire [511:0] host_cmd_data,
    input  wire        host_cmd_valid,
    output wire        host_cmd_ready,
    output reg  [127:0] host_cpl_data,
    output reg         host_cpl_valid,
    input  wire        host_cpl_ready,
    output reg  [63:0]  pcie_addr,
    output reg  [511:0] pcie_wr_data,
    output reg         pcie_wr_en,
    output reg  [63:0]  pcie_wr_be,
    output reg         pcie_rd_en,
    input  wire [511:0] pcie_rd_data,
    input  wire         pcie_rd_valid,
    input  wire         msi_wr_en,
    input  wire [63:0]  msi_addr,
    input  wire [31:0]  msi_data,
    input  wire [63:0]  io_sq_base,
    input  wire [63:0]  io_cq_base,
    input  wire [15:0]  queue_size,
    input  wire [63:0]  sq_tail_doorbell_addr,
    input  wire [63:0]  cq_head_doorbell_addr,
    output reg  [31:0]  commands_sent,
    output reg  [31:0]  completions_received
);
    // ── Command FIFO (stores full 512-bit command) ─
    localparam FIFO_DEPTH = QUEUE_SIZE - 1;      // 31 entries
    reg [511:0] cmd_fifo [0:FIFO_DEPTH-1];
    reg [5:0]   fifo_wptr, fifo_rptr;
    reg [5:0]   fifo_cnt;                        // 0..FIFO_DEPTH
    wire        fifo_empty = (fifo_cnt == 0);
    wire        fifo_full  = (fifo_cnt == FIFO_DEPTH);

    assign host_cmd_ready = !fifo_full && enable;

    // ── Blocking processor ──────────────────────
    typedef enum logic [2:0] { IDLE, WRITE_SQ, DOORBELL, WAIT_DELAY, SEND_CPL } state_t;
    state_t state, next_state;
    reg [15:0] sq_tail;
    reg [511:0] current_cmd;
    reg [15:0]  current_cid;
    reg [31:0]  delay_counter;

    integer i;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fifo_wptr <= 0;
            fifo_rptr <= 0;
            fifo_cnt  <= 0;
            for (i = 0; i < FIFO_DEPTH; i++) cmd_fifo[i] <= 512'b0;

            state       <= IDLE;
            sq_tail     <= 0;
            commands_sent <= 0;
            completions_received <= 0;
            pcie_wr_en  <= 0;
            pcie_rd_en  <= 0;
            host_cpl_valid <= 0;
            delay_counter <= 0;
        end else begin
            // ── FIFO write ──────────────────────
            if (host_cmd_valid && host_cmd_ready) begin
                cmd_fifo[fifo_wptr] <= host_cmd_data;
                fifo_wptr <= fifo_wptr + 1;
                if (fifo_wptr == FIFO_DEPTH-1) fifo_wptr <= 0;
                fifo_cnt  <= fifo_cnt + 1;
            end

            // ── Processor FSM ───────────────────
            state <= next_state;
            pcie_wr_en  <= 0;
            pcie_rd_en  <= 0;
            host_cpl_valid <= 0;

            case (state)
                IDLE: begin
                    delay_counter <= 0;
                    if (!fifo_empty) begin
                        // Pop next command
                        current_cmd <= cmd_fifo[fifo_rptr];
                        current_cid <= cmd_fifo[fifo_rptr][31:16];
                        fifo_rptr <= fifo_rptr + 1;
                        if (fifo_rptr == FIFO_DEPTH-1) fifo_rptr <= 0;
                        fifo_cnt  <= fifo_cnt - 1;
                        // Move to write SQ entry
                        //$display("Bridge: processing command cid=%0d", cmd_fifo[fifo_rptr][31:16]);
                    end
                end

                WRITE_SQ: begin
                    pcie_addr   <= io_sq_base + (sq_tail * 64);
                    pcie_wr_data <= current_cmd;
                    pcie_wr_en  <= 1;
                    pcie_wr_be  <= 64'hFFFFFFFFFFFFFFFF;
                end

                DOORBELL: begin
                    automatic logic [15:0] next_tail = (sq_tail == queue_size - 1) ? 0 : sq_tail + 1;
                    sq_tail       <= next_tail;
                    commands_sent <= commands_sent + 1;
                    pcie_addr     <= sq_tail_doorbell_addr;
                    pcie_wr_data  <= {48'b0, next_tail};
                    pcie_wr_en    <= 1;
                    pcie_wr_be    <= 64'h0F;
                    delay_counter <= 0;
                end

                WAIT_DELAY: begin
                    if (delay_counter < SSD_LATENCY_CYCLES)
                        delay_counter <= delay_counter + 1;
                end

                SEND_CPL: begin
                    host_cpl_data  <= {16'h0, current_cid, 16'h0, 16'h0, 64'h0};
                    host_cpl_valid <= 1;
                    if (host_cpl_ready) begin
                        completions_received <= completions_received + 1;
                    end
                end
            endcase
        end
    end

    // ── Combinational next state ────────────────
    always_comb begin
        next_state = state;
        case (state)
            IDLE:        if (!fifo_empty) next_state = WRITE_SQ;
            WRITE_SQ:    next_state = DOORBELL;
            DOORBELL:    next_state = WAIT_DELAY;
            WAIT_DELAY:  if (delay_counter >= SSD_LATENCY_CYCLES) next_state = SEND_CPL;
            SEND_CPL:    if (host_cpl_ready) next_state = IDLE;
            default:     next_state = IDLE;
        endcase
    end

endmodule