// ============================================================================
// Complete NVMe Controller Top Module (FIXED – no hierarchical refs, arbiter added)
// ============================================================================
module nvme_controller_complete (
    input wire clk,
    input wire reset_n,

    input wire [7:0]  pcie_cfg_addr,
    input wire [31:0] pcie_cfg_wr_data,
    input wire        pcie_cfg_wr_en,
    input wire        pcie_cfg_rd_en,
    output wire [31:0] pcie_cfg_rd_data,
    output wire        pcie_cfg_rd_valid,

    input wire [63:0]  pcie_mem_addr,
    input wire [511:0] pcie_mem_wr_data,
    input wire         pcie_mem_wr_en,
    input wire [63:0]  pcie_mem_wr_be,
    input wire         pcie_mem_rd_en,
    output wire [511:0] pcie_mem_rd_data,
    output wire         pcie_mem_rd_valid,

    output wire        pcie_msi_wr_en,
    output wire [63:0] pcie_msi_addr,
    output wire [31:0] pcie_msi_data,
    output wire [3:0]  pcie_msi_be,
    input  wire        pcie_msi_ready,

    output wire        nvme_cmd_valid,
    output wire [511:0] nvme_cmd_data,
    input  wire        nvme_cmd_ready,
    input  wire        nvme_cpl_valid,
    input  wire [127:0] nvme_cpl_data,
    output wire        nvme_cpl_ready,

    output wire [31:0] controller_status,
    output wire [63:0] admin_queue_status,
    output wire [63:0] io_queue_status_0,
    output wire [63:0] io_queue_status_1,
    output wire [63:0] io_queue_status_2,
    output wire [63:0] io_queue_status_3,
    output wire [63:0] io_queue_status_4,
    output wire [63:0] io_queue_status_5,
    output wire [63:0] io_queue_status_6,
    output wire [63:0] io_queue_status_7,

    output wire [31:0] interrupt_status,
    output wire [31:0] interrupt_pending,

    output wire [31:0] debug_queue_access_count,
    output wire [31:0] debug_doorbell_updates,
    output wire [31:0] debug_msi_sent_count,
    output wire        io_processor_done
);

    localparam NUM_IO_QUEUES = 8;
    localparam QUEUE_DEPTH = 32;
    localparam ADMIN_QUEUE_DEPTH = 8;

    // Internal wires
    wire [31:0] cfg_rd_data;
    wire        cfg_rd_valid;
    wire [63:0] bar0_base_addr;
    wire [63:0] bar1_base_addr;
    wire        bar0_enabled;
    wire        bar1_enabled;
    wire        mem_space_enabled;
    wire        bus_master_enabled;
    wire        msi_enabled;
    wire [2:0]  msi_capability;
    wire [31:0] msi_address;
    wire [15:0] msi_data;
    wire [5:0]  msi_vector_control;
    wire [2:0]  power_state;
    wire [15:0] config_status;

    wire [NUM_IO_QUEUES-1:0] sq_tail_update;
    wire [4:0]  sq_tail_value [0:NUM_IO_QUEUES-1];
    wire [NUM_IO_QUEUES-1:0] cq_head_update;
    wire [4:0]  cq_head_value [0:NUM_IO_QUEUES-1];
    wire        admin_sq_tail_update;
    wire [4:0]  admin_sq_tail_value;
    wire        admin_cq_head_update;
    wire [4:0]  admin_cq_head_value;
    wire [31:0] doorbell_status;

    wire [15:0] sq_head [0:NUM_IO_QUEUES];
    wire [15:0] sq_tail [0:NUM_IO_QUEUES];
    wire [15:0] cq_head [0:NUM_IO_QUEUES];
    wire [15:0] cq_tail [0:NUM_IO_QUEUES];
    wire [31:0] queue_access_count;
    wire [31:0] queue_error_count;

    wire        admin_interrupt_pending;
    wire [31:0] admin_controller_status;
    wire [15:0] admin_sq_head;
    wire [15:0] admin_sq_tail;
    wire [15:0] admin_cq_head;
    wire [15:0] admin_cq_tail;
    wire        create_io_queue_valid;
    wire [15:0] create_io_queue_id;
    wire [15:0] create_io_queue_size;
    wire        create_io_queue_type;
    wire [15:0] create_io_cq_id;
    wire [15:0] create_io_sq_id;
    wire [63:0] create_io_queue_addr;
    wire        create_io_queue_ready;

    wire [NUM_IO_QUEUES:0] interrupt_request;
    wire [5:0]  interrupt_vector [0:NUM_IO_QUEUES];
    wire [31:0] msi_interrupt_status;
    wire [31:0] msi_interrupt_mask;
    wire [31:0] msi_interrupt_pending;
    wire [31:0] msi_sent_count;

    wire        admin_rd_en;
    wire [63:0] admin_rd_addr;
    wire [511:0] admin_rd_data;
    wire        admin_rd_valid;
    wire        admin_wr_en;
    wire [63:0] admin_wr_addr;
    wire [511:0] admin_wr_data;

    wire [NUM_IO_QUEUES-1:0] io_interrupt_req;
    wire [31:0] io_commands_processed;
    wire        io_ctrl_req;
    wire        io_ctrl_rd_wr_n;
    wire [63:0] io_ctrl_addr;
    wire [511:0] io_ctrl_wr_data;

    wire [511:0] queue_mgr_rd_data;
    wire         queue_mgr_rd_valid;

    wire        queue_mgr_ctrl_rd_en;
    wire        queue_mgr_ctrl_wr_en;
    wire [63:0] queue_mgr_ctrl_addr;
    wire [511:0] queue_mgr_ctrl_wr_data;

    reg [63:0] io_sq_base_reg [0:NUM_IO_QUEUES-1];
    reg [63:0] io_cq_base_reg [0:NUM_IO_QUEUES-1];
    reg [15:0] io_sq_size_reg [0:NUM_IO_QUEUES-1];
    reg [15:0] io_cq_size_reg [0:NUM_IO_QUEUES-1];
    integer i;

    wire [63:0] admin_sq_base_addr = bar0_base_addr;
    wire [63:0] admin_cq_base_addr = bar0_base_addr + 64'h2000;

    wire admin_active  = admin_rd_en | admin_wr_en;
    wire ctrl_grant_io = !admin_active && io_ctrl_req;

    assign queue_mgr_ctrl_rd_en   = (admin_active && admin_rd_en) || (ctrl_grant_io && !io_ctrl_rd_wr_n);
    assign queue_mgr_ctrl_wr_en   = (admin_active && admin_wr_en) || (ctrl_grant_io &&  io_ctrl_rd_wr_n);
    assign queue_mgr_ctrl_addr    = admin_active ? (admin_rd_en ? admin_rd_addr : admin_wr_addr) : io_ctrl_addr;
    assign queue_mgr_ctrl_wr_data = admin_active ? admin_wr_data : io_ctrl_wr_data;

    assign admin_rd_data  = (admin_active && admin_rd_en) ? queue_mgr_rd_data : 512'h0;
    assign admin_rd_valid = (admin_active && admin_rd_en) ? queue_mgr_rd_valid : 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                io_sq_base_reg[i] <= 0;
                io_cq_base_reg[i] <= 0;
                io_sq_size_reg[i] <= 0;
                io_cq_size_reg[i] <= 0;
            end
        end else if (create_io_queue_valid && create_io_queue_ready) begin
            if (create_io_queue_type == 1'b0) begin
                if (create_io_queue_id < NUM_IO_QUEUES) begin
                    io_sq_base_reg[create_io_queue_id] <= create_io_queue_addr;
                    io_sq_size_reg[create_io_queue_id] <= create_io_queue_size;
                end
            end else begin
                if (create_io_queue_id < NUM_IO_QUEUES) begin
                    io_cq_base_reg[create_io_queue_id] <= create_io_queue_addr;
                    io_cq_size_reg[create_io_queue_id] <= create_io_queue_size;
                end
            end
        end
    end

    assign interrupt_vector[0] = 0;
    for (genvar g = 0; g < NUM_IO_QUEUES; g++) begin
        assign interrupt_vector[g+1] = g + 1;
    end

    pcie_config_space #(
        .VENDOR_ID(16'h8086), .DEVICE_ID(16'h0953),
        .SUBSYSTEM_VENDOR_ID(16'h8086), .SUBSYSTEM_ID(16'h0001),
        .CLASS_CODE(24'h010802), .REVISION_ID(8'h02)
    ) pcie_cfg (
        .clk, .reset_n,
        .cfg_addr        (pcie_cfg_addr),
        .cfg_wr_data     (pcie_cfg_wr_data),
        .cfg_wr_en       (pcie_cfg_wr_en),
        .cfg_rd_en       (pcie_cfg_rd_en),
        .cfg_rd_data     (cfg_rd_data),
        .cfg_rd_valid    (cfg_rd_valid),
        .bar0_base_addr  (bar0_base_addr),
        .bar1_base_addr  (bar1_base_addr),
        .bar0_enabled    (bar0_enabled),
        .bar1_enabled    (bar1_enabled),
        .mem_space_enabled(mem_space_enabled),
        .bus_master_enabled(bus_master_enabled),
        .msi_enabled     (msi_enabled),
        .msi_capability  (msi_capability),
        .msi_address     (msi_address),
        .msi_data        (msi_data),
        .msi_vector_control(msi_vector_control),
        .power_state     (power_state),
        .config_status   (config_status)
    );

    nvme_doorbell_registers #(
        .NUM_QUEUES(NUM_IO_QUEUES), .QUEUE_DEPTH_BITS(5)
    ) doorbells (
        .clk, .reset_n,
        .reg_addr        (pcie_mem_addr[31:0]),
        .reg_wr_data     (pcie_mem_wr_data[31:0]),
        .reg_wr_en       (pcie_mem_wr_en && (pcie_mem_addr[15:12] == 4'h1)),
        .reg_rd_en       (pcie_mem_rd_en && (pcie_mem_addr[15:12] == 4'h1)),
        .reg_rd_data     (pcie_mem_rd_data[31:0]),
        .reg_rd_valid    (pcie_mem_rd_valid),
        .sq_tail_update  (sq_tail_update),
        .sq_tail_value   (sq_tail_value),
        .cq_head_update  (cq_head_update),
        .cq_head_value   (cq_head_value),
        .admin_sq_tail_update(admin_sq_tail_update),
        .admin_sq_tail_value (admin_sq_tail_value),
        .admin_cq_head_update(admin_cq_head_update),
        .admin_cq_head_value (admin_cq_head_value),
        .doorbell_status (doorbell_status)
    );

    nvme_queue_manager #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES),
        .QUEUE_DEPTH(QUEUE_DEPTH),
        .ADMIN_QUEUE_DEPTH(ADMIN_QUEUE_DEPTH),
        .DATA_WIDTH(512)
    ) queue_mgr (
        .clk, .reset_n,
        .mem_addr       (pcie_mem_addr),
        .mem_wr_data    (pcie_mem_wr_data),
        .mem_wr_en      (pcie_mem_wr_en && (pcie_mem_addr[15:12] != 4'h1)),
        .mem_wr_be      (pcie_mem_wr_be),
        .mem_rd_en      (pcie_mem_rd_en && (pcie_mem_addr[15:12] != 4'h1)),
        .mem_rd_data    (pcie_mem_rd_data),
        .mem_rd_valid   (pcie_mem_rd_valid),
        .admin_sq_base_addr(admin_sq_base_addr),
        .admin_cq_base_addr(admin_cq_base_addr),
        .io_sq_base_addr(io_sq_base_reg),
        .io_cq_base_addr(io_cq_base_reg),
        .controller_rd_en  (queue_mgr_ctrl_rd_en),
        .controller_wr_en  (queue_mgr_ctrl_wr_en),
        .controller_addr   (queue_mgr_ctrl_addr),
        .controller_wr_data(queue_mgr_ctrl_wr_data),
        .controller_rd_data(queue_mgr_rd_data),
        .controller_rd_valid(queue_mgr_rd_valid),
        .sq_head(sq_head), .sq_tail(sq_tail),
        .cq_head(cq_head), .cq_tail(cq_tail),
        .interrupt_coalescing_threshold(8'h04),
        .interrupt_coalescing_time(8'hFF),
        .queue_access_count(queue_access_count),
        .queue_error_count(queue_error_count)
    );

    nvme_admin_controller #(
        .QUEUE_DEPTH(ADMIN_QUEUE_DEPTH), .DATA_WIDTH(512)
    ) admin_ctrl (
        .clk, .reset_n,
        .sq_tail_update (admin_sq_tail_update),
        .sq_tail_value  (admin_sq_tail_value),
        .cq_head_update (admin_cq_head_update),
        .cq_head_value  (admin_cq_head_value),
        .admin_rd_en    (admin_rd_en),
        .admin_rd_addr  (admin_rd_addr),
        .admin_rd_data  (admin_rd_data),
        .admin_rd_valid (admin_rd_valid),
        .admin_wr_en    (admin_wr_en),
        .admin_wr_addr  (admin_wr_addr),
        .admin_wr_data  (admin_wr_data),
        .admin_cmd_valid(),
        .admin_cmd_data (),
        .admin_cmd_ready(1'b0),
        .admin_cpl_valid(1'b0),
        .admin_cpl_data (512'h0),
        .admin_cpl_ready(),
        .create_io_queue_valid (create_io_queue_valid),
        .create_io_queue_id    (create_io_queue_id),
        .create_io_queue_size  (create_io_queue_size),
        .create_io_queue_type  (create_io_queue_type),
        .create_io_cq_id       (create_io_cq_id),
        .create_io_sq_id       (create_io_sq_id),
        .create_io_queue_addr  (create_io_queue_addr),
        .create_io_queue_ready (create_io_queue_ready),
        .admin_controller_status(admin_controller_status),
        .admin_sq_head  (admin_sq_head),
        .admin_sq_tail  (admin_sq_tail),
        .admin_cq_head  (admin_cq_head),
        .admin_cq_tail  (admin_cq_tail),
        .admin_interrupt_pending(admin_interrupt_pending),
        .admin_sq_base_addr(admin_sq_base_addr),
        .admin_cq_base_addr(admin_cq_base_addr)
    );

    msi_interrupt_controller #(
        .NUM_VECTORS(32), .NUM_QUEUES(NUM_IO_QUEUES)
    ) msi_ctrl (
        .clk, .reset_n,
        .msi_address    (msi_address),
        .msi_data_base  (msi_data),
        .msi_enabled    (msi_enabled),
        .msi_capability (msi_capability),
        .interrupt_request(interrupt_request),
        .interrupt_vector(interrupt_vector),
        .msi_mem_wr_en  (pcie_msi_wr_en),
        .msi_mem_addr   (pcie_msi_addr),
        .msi_mem_data   (pcie_msi_data),
        .msi_mem_be     (pcie_msi_be),
        .msi_mem_ready  (pcie_msi_ready),
        .interrupt_status(msi_interrupt_status),
        .interrupt_mask (msi_interrupt_mask),
        .interrupt_pending(msi_interrupt_pending),
        .msi_sent_count (msi_sent_count),
        .interrupt_count()
    );

    wire [4:0] io_queue1_sq_tail = sq_tail_value[1];
    io_processor #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES), .QUEUE_DEPTH(QUEUE_DEPTH),
        .DATA_WIDTH(512), .SSD_LATENCY_CYCLES(5000)
    ) io_proc (
        .clk, .reset_n,
        .ctrl_req      (io_ctrl_req),
        .ctrl_rd_wr_n  (io_ctrl_rd_wr_n),
        .ctrl_addr     (io_ctrl_addr),
        .ctrl_rd_data  (queue_mgr_rd_data),
        .ctrl_rd_valid (queue_mgr_rd_valid && ctrl_grant_io && !admin_active),
        .ctrl_wr_data  (io_ctrl_wr_data),
        .ctrl_grant    (ctrl_grant_io),
        .doorbell_sq_tail('{sq_tail_value[0], sq_tail_value[1], sq_tail_value[2], sq_tail_value[3],
                             sq_tail_value[4], sq_tail_value[5], sq_tail_value[6], sq_tail_value[7]}),
        .doorbell_cq_head('{cq_head_value[0], cq_head_value[1], cq_head_value[2], cq_head_value[3],
                             cq_head_value[4], cq_head_value[5], cq_head_value[6], cq_head_value[7]}),
        .queue1_sq_tail (io_queue1_sq_tail),
        .sq_base('{io_sq_base_reg[0], io_sq_base_reg[1], io_sq_base_reg[2], io_sq_base_reg[3],
                   io_sq_base_reg[4], io_sq_base_reg[5], io_sq_base_reg[6], io_sq_base_reg[7]}),
        .cq_base('{io_cq_base_reg[0], io_cq_base_reg[1], io_cq_base_reg[2], io_cq_base_reg[3],
                   io_cq_base_reg[4], io_cq_base_reg[5], io_cq_base_reg[6], io_cq_base_reg[7]}),
        .sq_size('{io_sq_size_reg[0], io_sq_size_reg[1], io_sq_size_reg[2], io_sq_size_reg[3],
                   io_sq_size_reg[4], io_sq_size_reg[5], io_sq_size_reg[6], io_sq_size_reg[7]}),
        .cq_size('{io_cq_size_reg[0], io_cq_size_reg[1], io_cq_size_reg[2], io_cq_size_reg[3],
                   io_cq_size_reg[4], io_cq_size_reg[5], io_cq_size_reg[6], io_cq_size_reg[7]}),
        .interrupt_request(io_interrupt_req),
        .commands_processed(io_commands_processed),
        .io_done        (io_processor_done)
    );

    assign interrupt_request[NUM_IO_QUEUES] = admin_interrupt_pending;
    for (genvar g = 0; g < NUM_IO_QUEUES; g++) begin
        assign interrupt_request[g] = io_interrupt_req[g];
    end

    assign pcie_cfg_rd_data  = cfg_rd_data;
    assign pcie_cfg_rd_valid = cfg_rd_valid;
    assign controller_status = admin_controller_status;
    assign admin_queue_status = {admin_cq_tail, admin_cq_head, admin_sq_tail, admin_sq_head};
    assign io_queue_status_0 = {cq_tail[1], cq_head[1], sq_tail[1], sq_head[1]};
    assign io_queue_status_1 = {cq_tail[2], cq_head[2], sq_tail[2], sq_head[2]};
    assign io_queue_status_2 = {cq_tail[3], cq_head[3], sq_tail[3], sq_head[3]};
    assign io_queue_status_3 = {cq_tail[4], cq_head[4], sq_tail[4], sq_head[4]};
    assign io_queue_status_4 = {cq_tail[5], cq_head[5], sq_tail[5], sq_head[5]};
    assign io_queue_status_5 = {cq_tail[6], cq_head[6], sq_tail[6], sq_head[6]};
    assign io_queue_status_6 = {cq_tail[7], cq_head[7], sq_tail[7], sq_head[7]};
    assign io_queue_status_7 = {cq_tail[8], cq_head[8], sq_tail[8], sq_head[8]};
    assign interrupt_status  = msi_interrupt_status;
    assign interrupt_pending = msi_interrupt_pending;
    assign debug_queue_access_count = queue_access_count;
    assign debug_doorbell_updates   = doorbell_status;
    assign debug_msi_sent_count     = msi_sent_count;
    assign nvme_cmd_valid = 1'b0;
    assign nvme_cmd_data  = 512'h0;
    assign nvme_cpl_ready = 1'b1;
    assign create_io_queue_ready = 1'b1;

endmodule