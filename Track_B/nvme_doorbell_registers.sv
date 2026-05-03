// ============================================================================
// NVMe Doorbell Register Module (FIXED – correct SQ/CQ decode)
// ============================================================================
module nvme_doorbell_registers #(
    parameter NUM_QUEUES = 8,
    parameter QUEUE_DEPTH_BITS = 5
)(
    input wire clk,
    input wire reset_n,

    // PCIe Register Interface
    input wire [31:0] reg_addr,
    input wire [31:0] reg_wr_data,
    input wire        reg_wr_en,
    input wire        reg_rd_en,
    output reg [31:0] reg_rd_data,
    output reg        reg_rd_valid,

    // Queue Control Interfaces (update pulses)
    output reg [NUM_QUEUES-1:0] sq_tail_update,
    output reg [NUM_QUEUES-1:0] cq_head_update,

    // Admin Queue Doorbells (update pulses)
    output reg admin_sq_tail_update,
    output reg admin_cq_head_update,

    // Queue Value Outputs (current tail/head values)
    output reg [QUEUE_DEPTH_BITS-1:0] sq_tail_value [NUM_QUEUES],
    output reg [QUEUE_DEPTH_BITS-1:0] cq_head_value [NUM_QUEUES],
    output reg [QUEUE_DEPTH_BITS-1:0] admin_sq_tail_value,
    output reg [QUEUE_DEPTH_BITS-1:0] admin_cq_head_value,

    // Status
    output reg [31:0] doorbell_status
);

    localparam SQ0_TDBL_BASE  = 32'h1000;
    localparam ADMIN_SQ_TDBL  = 32'h1080;
    localparam ADMIN_CQ_HDBL  = 32'h1084;
    localparam ZERO_WIDTH     = 32 - QUEUE_DEPTH_BITS;

    reg [QUEUE_DEPTH_BITS-1:0] sq_tail_shadow [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] cq_head_shadow [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] admin_sq_tail_shadow;
    reg [QUEUE_DEPTH_BITS-1:0] admin_cq_head_shadow;

    reg [QUEUE_DEPTH_BITS-1:0] sq_tail_reg [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] cq_head_reg [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] admin_sq_tail_reg;
    reg [QUEUE_DEPTH_BITS-1:0] admin_cq_head_reg;

    integer i;
    integer queue_idx;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                sq_tail_reg[i]     <= 0;
                sq_tail_shadow[i]  <= 0;
                cq_head_reg[i]     <= 0;
                cq_head_shadow[i]  <= 0;
                sq_tail_value[i]   <= 0;
                cq_head_value[i]   <= 0;
            end
            admin_sq_tail_reg     <= 0;
            admin_sq_tail_shadow  <= 0;
            admin_cq_head_reg     <= 0;
            admin_cq_head_shadow  <= 0;
            admin_sq_tail_value   <= 0;
            admin_cq_head_value   <= 0;

            sq_tail_update        <= 0;
            cq_head_update        <= 0;
            admin_sq_tail_update  <= 0;
            admin_cq_head_update  <= 0;
            doorbell_status       <= 0;
            reg_rd_valid          <= 0;
            reg_rd_data           <= 0;
        end else begin
            sq_tail_update        <= 0;
            cq_head_update        <= 0;
            admin_sq_tail_update  <= 0;
            admin_cq_head_update  <= 0;
            reg_rd_valid          <= 0;

            // ---- WRITES ----
            if (reg_wr_en) begin
                if (reg_addr[15:0] == ADMIN_SQ_TDBL[15:0]) begin
                    admin_sq_tail_shadow <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    admin_sq_tail_update <= 1'b1;
                    admin_sq_tail_value  <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    //$display("Doorbell: Admin SQ tail update, value=%0d", reg_wr_data[QUEUE_DEPTH_BITS-1:0]);
                end
                else if (reg_addr[15:0] == ADMIN_CQ_HDBL[15:0]) begin
                    admin_cq_head_shadow <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    admin_cq_head_update <= 1'b1;
                    admin_cq_head_value  <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    //$display("*** DOORBELL: Admin CQ head update, value=%0d at time %t",
                    //    reg_wr_data[QUEUE_DEPTH_BITS-1:0], $time);
                end
                else if ((reg_addr[15:0] >= SQ0_TDBL_BASE[15:0]) &&
                         (reg_addr[15:0] <  (SQ0_TDBL_BASE[15:0] + NUM_QUEUES * 8))) begin
                    queue_idx = (reg_addr[15:0] - SQ0_TDBL_BASE[15:0]) / 8;
                    if (queue_idx < NUM_QUEUES) begin
                        if (reg_addr[2] == 1'b0) begin
                            sq_tail_shadow[queue_idx] <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            sq_tail_update[queue_idx] <= 1'b1;
                            sq_tail_value[queue_idx]  <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            //$display("Doorbell: I/O SQ%0d tail update, value=%0d (addr %h)",
                            //    queue_idx, reg_wr_data[QUEUE_DEPTH_BITS-1:0], reg_addr);
                        end else begin
                            cq_head_shadow[queue_idx] <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            cq_head_update[queue_idx] <= 1'b1;
                            cq_head_value[queue_idx]  <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            //$display("*** DOORBELL: I/O CQ%0d head update, value=%0d (addr %h)",
                            //    queue_idx, reg_wr_data[QUEUE_DEPTH_BITS-1:0], reg_addr);
                        end
                    end
                end
            end

            // ---- READS ----
            if (reg_rd_en) begin
                reg_rd_valid <= 1'b1;
                if (reg_addr[15:0] == ADMIN_SQ_TDBL[15:0])
                    reg_rd_data <= { {ZERO_WIDTH{1'b0}}, admin_sq_tail_shadow };
                else if (reg_addr[15:0] == ADMIN_CQ_HDBL[15:0])
                    reg_rd_data <= { {ZERO_WIDTH{1'b0}}, admin_cq_head_shadow };
                else if ((reg_addr[15:0] >= SQ0_TDBL_BASE[15:0]) &&
                         (reg_addr[15:0] <  (SQ0_TDBL_BASE[15:0] + NUM_QUEUES * 8))) begin
                    queue_idx = (reg_addr[15:0] - SQ0_TDBL_BASE[15:0]) / 8;
                    if (queue_idx < NUM_QUEUES) begin
                        if (reg_addr[2] == 1'b0)
                            reg_rd_data <= { {ZERO_WIDTH{1'b0}}, sq_tail_shadow[queue_idx] };
                        else
                            reg_rd_data <= { {ZERO_WIDTH{1'b0}}, cq_head_shadow[queue_idx] };
                    end else
                        reg_rd_data <= 32'hFFFFFFFF;
                end
                else
                    reg_rd_data <= 32'hDEADBEEF;
            end

            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                if (sq_tail_update[i]) sq_tail_reg[i] <= sq_tail_shadow[i];
                if (cq_head_update[i]) cq_head_reg[i] <= cq_head_shadow[i];
            end
            if (admin_sq_tail_update) admin_sq_tail_reg <= admin_sq_tail_shadow;
            if (admin_cq_head_update) admin_cq_head_reg <= admin_cq_head_shadow;
        end
    end
endmodule