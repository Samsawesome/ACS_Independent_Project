module nvme_controller_complete (
    input wire clk,
    input wire reset,

    input wire [7:0] pcie_cfg_addr,
    input wire [31:0] pcie_cfg_wr_data,
    input wire pcie_cfg_wr_en,

    input wire [63:0] pcie_mem_addr,
    input wire [511:0] pcie_mem_wr_data,
    input wire pcie_mem_wr_en,
    input wire pcie_mem_rd_en,
    output wire [511:0] pcie_mem_rd_data,
    output wire pcie_mem_rd_valid,

    output wire pcie_msi_wr_en,

    output wire io_processor_done
);

    localparam NUM_IO_QUEUES = 8;
    localparam QUEUE_DEPTH = 32;
    localparam ADMIN_QUEUE_DEPTH = 8;

    wire [63:0] bar0_base_addr;
    wire msi_enabled;
    wire [31:0] msi_address;
    wire [15:0] msi_data;

    wire [4:0] sq_tail_value [0:NUM_IO_QUEUES-1];
    wire admin_sq_tail_update;
    wire [4:0] admin_sq_tail_value;
    wire admin_cq_head_update;
    wire [4:0] admin_cq_head_value;

    wire admin_interrupt_pending;
    wire create_io_queue_valid;
    wire [15:0] create_io_queue_id;
    wire [15:0] create_io_queue_size;
    wire create_io_queue_type;
    wire [63:0] create_io_queue_addr;

    wire [NUM_IO_QUEUES:0] interrupt_request;
    wire [5:0] interrupt_vector [0:NUM_IO_QUEUES];

    wire admin_rd_en;
    wire [63:0] admin_rd_addr;
    wire [511:0] admin_rd_data;
    wire admin_rd_valid;
    wire admin_wr_en;
    wire [63:0] admin_wr_addr;
    wire [511:0] admin_wr_data;

    wire [NUM_IO_QUEUES-1:0] io_interrupt_req;
    wire io_ctrl_req;
    wire io_ctrl_rd_wr_n;
    wire [63:0] io_ctrl_addr;
    wire [511:0] io_ctrl_wr_data;

    wire [511:0] queue_mgr_rd_data;
    wire queue_mgr_rd_valid;

    wire queue_mgr_ctrl_rd_en;
    wire queue_mgr_ctrl_wr_en;
    wire [63:0] queue_mgr_ctrl_addr;
    wire [511:0] queue_mgr_ctrl_wr_data;

    reg [63:0] io_sq_base_reg [0:NUM_IO_QUEUES-1];
    reg [63:0] io_cq_base_reg [0:NUM_IO_QUEUES-1];
    reg [15:0] io_sq_size_reg [0:NUM_IO_QUEUES-1];
    reg [15:0] io_cq_size_reg [0:NUM_IO_QUEUES-1];
    integer i;

    wire [63:0] admin_cq_base_addr = bar0_base_addr + 64'h2000;

    wire admin_active = admin_rd_en | admin_wr_en;
    wire ctrl_grant_io = !admin_active && io_ctrl_req;

    assign queue_mgr_ctrl_rd_en =(admin_active && admin_rd_en) ||(ctrl_grant_io && !io_ctrl_rd_wr_n);
    assign queue_mgr_ctrl_wr_en =(admin_active && admin_wr_en) ||(ctrl_grant_io && io_ctrl_rd_wr_n);
    assign queue_mgr_ctrl_addr = admin_active ?(admin_rd_en ? admin_rd_addr : admin_wr_addr) : io_ctrl_addr;
    assign queue_mgr_ctrl_wr_data = admin_active ? admin_wr_data : io_ctrl_wr_data;

    assign admin_rd_data =(admin_active && admin_rd_en) ? queue_mgr_rd_data : 512'h0;
    assign admin_rd_valid =(admin_active && admin_rd_en) ? queue_mgr_rd_valid : 1'b0;

    always @(posedge clk or posedge reset) begin
        if(reset) begin
            for(i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                io_sq_base_reg[i] <= 0; io_cq_base_reg[i] <= 0;
                io_sq_size_reg[i] <= 0; io_cq_size_reg[i] <= 0;
            end
        end else if(create_io_queue_valid) begin
            if(!create_io_queue_type) begin
                if(create_io_queue_id < NUM_IO_QUEUES) begin
                    io_sq_base_reg[create_io_queue_id] <= create_io_queue_addr;
                    io_sq_size_reg[create_io_queue_id] <= create_io_queue_size;
                end
            end else begin
                if(create_io_queue_id < NUM_IO_QUEUES) begin
                    io_cq_base_reg[create_io_queue_id] <= create_io_queue_addr;
                    io_cq_size_reg[create_io_queue_id] <= create_io_queue_size;
                end
            end
        end
    end

    assign interrupt_vector[0] = 0;
    for(genvar g = 1; g < NUM_IO_QUEUES; g++) begin
        assign interrupt_vector[g] = g;
    end

    pcie_config_space pcie_cfg(
        .clk, 
        .reset,
        .cfg_addr(pcie_cfg_addr),
        .cfg_wr_data(pcie_cfg_wr_data),
        .cfg_wr_en(pcie_cfg_wr_en),
        .bar0_base_addr(bar0_base_addr),
        .msi_enabled(msi_enabled),
        .msi_address(msi_address),
        .msi_data(msi_data)
    );

    nvme_doorbell_registers #(
        .NUM_QUEUES(NUM_IO_QUEUES),
        .QUEUE_DEPTH_BITS(5)
    ) doorbells(
        .clk, 
        .reset,
        .reg_addr(pcie_mem_addr[31:0]),
        .reg_wr_data(pcie_mem_wr_data[31:0]),
        .reg_wr_en(pcie_mem_wr_en &&(pcie_mem_addr[15:12] == 4'h1)),
        .reg_rd_en(pcie_mem_rd_en &&(pcie_mem_addr[15:12] == 4'h1)),
        .reg_rd_data(pcie_mem_rd_data[31:0]),
        .reg_rd_valid(pcie_mem_rd_valid),
        .sq_tail_value(sq_tail_value),
        .admin_sq_tail_update(admin_sq_tail_update),
        .admin_sq_tail_value(admin_sq_tail_value),
        .admin_cq_head_update(admin_cq_head_update),
        .admin_cq_head_value(admin_cq_head_value)
    );

    nvme_queue_manager #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES),
        .QUEUE_DEPTH(QUEUE_DEPTH),
        .ADMIN_QUEUE_DEPTH(ADMIN_QUEUE_DEPTH),
        .DATA_WIDTH(512)
    ) queue_mgr(
        .clk, 
        .reset,
        .mem_addr(pcie_mem_addr),
        .mem_wr_data(pcie_mem_wr_data),
        .mem_wr_en(pcie_mem_wr_en &&(pcie_mem_addr[15:12] != 4'h1)),
        .mem_rd_en(pcie_mem_rd_en &&(pcie_mem_addr[15:12] != 4'h1)),
        .mem_rd_data(pcie_mem_rd_data),
        .mem_rd_valid(pcie_mem_rd_valid),
        .admin_sq_base_addr(bar0_base_addr),
        .admin_cq_base_addr(admin_cq_base_addr),
        .io_sq_base_addr(io_sq_base_reg),
        .io_cq_base_addr(io_cq_base_reg),
        .controller_rd_en(queue_mgr_ctrl_rd_en),
        .controller_wr_en(queue_mgr_ctrl_wr_en),
        .controller_addr(queue_mgr_ctrl_addr),
        .controller_wr_data(queue_mgr_ctrl_wr_data),
        .controller_rd_data(queue_mgr_rd_data),
        .controller_rd_valid(queue_mgr_rd_valid)
    );

    nvme_admin_controller #(
        .QUEUE_DEPTH(ADMIN_QUEUE_DEPTH),
        .DATA_WIDTH(512)
    ) admin_ctrl(
        .clk, 
        .reset,
        .sq_tail_update(admin_sq_tail_update),
        .sq_tail_value(admin_sq_tail_value),
        .cq_head_update(admin_cq_head_update),
        .cq_head_value(admin_cq_head_value),
        .admin_rd_en(admin_rd_en),
        .admin_rd_addr(admin_rd_addr),
        .admin_rd_data(admin_rd_data),
        .admin_rd_valid(admin_rd_valid),
        .admin_wr_en(admin_wr_en),
        .admin_wr_addr(admin_wr_addr),
        .admin_wr_data(admin_wr_data),
        .create_io_queue_valid(create_io_queue_valid),
        .create_io_queue_id(create_io_queue_id),
        .create_io_queue_size(create_io_queue_size),
        .create_io_queue_type(create_io_queue_type),
        .create_io_queue_addr(create_io_queue_addr),
        .admin_interrupt_pending(admin_interrupt_pending),
        .admin_sq_base_addr(bar0_base_addr),
        .admin_cq_base_addr(admin_cq_base_addr)
    );

    msi_interrupt_controller #(
        .NUM_VECTORS(32),
        .NUM_QUEUES(NUM_IO_QUEUES)
    ) msi_ctrl(
        .clk,
        .reset,
        .msi_address(msi_address),
        .msi_data_base(msi_data),
        .msi_enabled(msi_enabled),
        .interrupt_request(interrupt_request),
        .interrupt_vector(interrupt_vector),
        .msi_mem_wr_en(pcie_msi_wr_en)
    );


    io_processor #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES),
        .DATA_WIDTH(512), 
        .SSD_LATENCY_CYCLES(5000)
    ) io_proc(
        .clk,
        .reset,
        .ctrl_req(io_ctrl_req),
        .ctrl_rd_wr_n(io_ctrl_rd_wr_n),
        .ctrl_addr(io_ctrl_addr),
        .ctrl_rd_data(queue_mgr_rd_data),
        .ctrl_rd_valid(queue_mgr_rd_valid && ctrl_grant_io && !admin_active),
        .ctrl_wr_data(io_ctrl_wr_data),
        .doorbell_sq_tail(sq_tail_value[0:7]),
        .queue1_sq_tail(sq_tail_value[1]),
        .sq_base(io_sq_base_reg[0:7]),
        .cq_base(io_cq_base_reg[0:7]),
        .sq_size(io_sq_size_reg[0:7]),
        .cq_size(io_cq_size_reg[0:7]),
        .interrupt_request(io_interrupt_req),
        .io_done(io_processor_done)
    );

    assign interrupt_request[NUM_IO_QUEUES] = admin_interrupt_pending;
    for(genvar g = 0; g < NUM_IO_QUEUES; g++) begin
        assign interrupt_request[g] = io_interrupt_req[g];
    end
endmodule