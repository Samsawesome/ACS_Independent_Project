module nvme_doorbell_registers #(
    parameter NUM_QUEUES = 8,
    parameter QUEUE_DEPTH_BITS = 5
)(
    input wire clk,
    input wire reset,

    input wire [31:0] reg_addr,
    input wire [31:0] reg_wr_data,
    input wire reg_wr_en,
    input wire reg_rd_en,
    output reg [31:0] reg_rd_data,
    output reg reg_rd_valid,

    output reg [QUEUE_DEPTH_BITS-1:0] sq_tail_value [NUM_QUEUES],
    output reg admin_sq_tail_update,
    output reg [QUEUE_DEPTH_BITS-1:0] admin_sq_tail_value,
    output reg admin_cq_head_update,
    output reg [QUEUE_DEPTH_BITS-1:0] admin_cq_head_value
);

    localparam SQ0_TDBL_BASE = 32'h1000;
    localparam ADMIN_SQ_TDBL = 32'h1080;
    localparam ADMIN_CQ_HDBL = 32'h1084;
    localparam ZERO_WIDTH = 32 - QUEUE_DEPTH_BITS;

    reg [QUEUE_DEPTH_BITS-1:0] sq_tail_shadow [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] cq_head_shadow [NUM_QUEUES];
    reg [QUEUE_DEPTH_BITS-1:0] admin_sq_tail_shadow;
    reg [QUEUE_DEPTH_BITS-1:0] admin_cq_head_shadow;

    integer i;
    integer queue_idx;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                sq_tail_shadow[i] <= 0;
                cq_head_shadow[i] <= 0;
                sq_tail_value[i] <= 0;
            end
            admin_sq_tail_shadow <= 0;
            admin_cq_head_shadow <= 0;
            admin_sq_tail_value <= 0;
            admin_cq_head_value <= 0;

            admin_sq_tail_update <= 0;
            admin_cq_head_update <= 0;
            reg_rd_valid <= 0;
            reg_rd_data <= 0;
        end else begin
            admin_sq_tail_update <= 0;
            admin_cq_head_update <= 0;
            reg_rd_valid <= 0;

            if (reg_wr_en) begin //if write
                if (reg_addr[15:0] == ADMIN_SQ_TDBL[15:0]) begin //if SQ, update SQ
                    admin_sq_tail_shadow <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    admin_sq_tail_update <= 1'b1;
                    admin_sq_tail_value <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    //$display("Doorbell: Admin SQ tail update, value=%0d", reg_wr_data[QUEUE_DEPTH_BITS-1:0]);
                end
                else if (reg_addr[15:0] == ADMIN_CQ_HDBL[15:0]) begin //if CQ, update CQ
                    admin_cq_head_shadow <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    admin_cq_head_update <= 1'b1;
                    admin_cq_head_value <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                    //$display("*** DOORBELL: Admin CQ head update, value=%0d at time %t", reg_wr_data[QUEUE_DEPTH_BITS-1:0], $time);
                end
                else if ((reg_addr[15:0] >= SQ0_TDBL_BASE[15:0]) &&
                         (reg_addr[15:0] < (SQ0_TDBL_BASE[15:0] + NUM_QUEUES * 8))) begin
                    queue_idx = (reg_addr[15:0] - SQ0_TDBL_BASE[15:0]) / 8; //otherwise through in correct queue
                    if (queue_idx < NUM_QUEUES) begin
                        if (reg_addr[2] == 1'b0) begin
                            sq_tail_shadow[queue_idx] <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            sq_tail_value[queue_idx] <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            //$display("Doorbell: I/O SQ%0d tail update, value=%0d (addr %h)", queue_idx, reg_wr_data[QUEUE_DEPTH_BITS-1:0], reg_addr);
                        end else begin
                            cq_head_shadow[queue_idx] <= reg_wr_data[QUEUE_DEPTH_BITS-1:0];
                            //$display("*** DOORBELL: I/O CQ%0d head update, value=%0d (addr %h)", queue_idx, reg_wr_data[QUEUE_DEPTH_BITS-1:0], reg_addr);
                        end
                    end
                end
            end

            if (reg_rd_en) begin //if read
                reg_rd_valid <= 1'b1;
                if (reg_addr[15:0] == ADMIN_SQ_TDBL[15:0]) //read SQ if SQ
                    reg_rd_data <= { {ZERO_WIDTH{1'b0}}, admin_sq_tail_shadow};

                else if (reg_addr[15:0] == ADMIN_CQ_HDBL[15:0]) //CQ if CQ
                    reg_rd_data <= { {ZERO_WIDTH{1'b0}}, admin_cq_head_shadow};

                else if ((reg_addr[15:0] >= SQ0_TDBL_BASE[15:0]) &&
                         (reg_addr[15:0] < (SQ0_TDBL_BASE[15:0] + NUM_QUEUES * 8))) begin
                    queue_idx = (reg_addr[15:0] - SQ0_TDBL_BASE[15:0]) / 8; //other queue if other queue

                    if (queue_idx < NUM_QUEUES) begin
                        if (reg_addr[2] == 1'b0) reg_rd_data <= { {ZERO_WIDTH{1'b0}}, sq_tail_shadow[queue_idx]};
                        else reg_rd_data <= { {ZERO_WIDTH{1'b0}}, cq_head_shadow[queue_idx]};

                    end else reg_rd_data <= 32'hFFFFFFFF;
                end
                else reg_rd_data <= 32'hDEADBEEF;
            end
        end
    end
endmodule