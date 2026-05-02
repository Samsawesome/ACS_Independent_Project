`timescale 1ns/1ps

// ============================================================================
// Package: Windows Storage Stack Constants
// ============================================================================
package windows_storage_pkg;
    
    // IRP Major Function Codes
    typedef enum logic [3:0] {
        IRP_MJ_READ         = 4'h0,
        IRP_MJ_WRITE        = 4'h1,
        IRP_MJ_FLUSH_BUFFERS= 4'h2,
        IRP_MJ_DEVICE_CONTROL= 4'h3
    } irp_major_function_t;
    
    // NVMe Command Opcodes
    typedef enum logic [7:0] {
        NVME_OPC_READ       = 8'h02,
        NVME_OPC_WRITE      = 8'h01,
        NVME_OPC_FLUSH      = 8'h00,
        NVME_OPC_DSM        = 8'h09  // Dataset Management
    } nvme_opcode_t;
    
    // SCSI Operation Codes
    typedef enum logic [7:0] {
        SCSIOP_READ         = 8'h28,
        SCSIOP_WRITE        = 8'h2A,
        SCSIOP_READ_CAPACITY= 8'h25
    } scsi_opcode_t;
    
    // Windows Status Codes
    typedef enum logic [31:0] {
        STATUS_SUCCESS      = 32'h00000000,
        STATUS_PENDING      = 32'h00000103,
        STATUS_INVALID_PARAMETER = 32'hC000000D
    } ntstatus_t;
    
    // Windows Device Types
    typedef enum logic [31:0] {
        FILE_DEVICE_DISK        = 32'h00000007,
        FILE_DEVICE_DISK_FILE_SYSTEM = 32'h00000008
    } device_type_t;
    
    // Storage Bus Types
    typedef enum logic [7:0] {
        BusTypeNvme         = 8'h11,
        BusTypeScsi         = 8'h01,
        BusTypeSata         = 8'h0B
    } storage_bus_type_t;
    
    // SRB Status Codes
    typedef enum logic [7:0] {
        SRB_STATUS_PENDING  = 8'h04,
        SRB_STATUS_SUCCESS  = 8'h01,
        SRB_STATUS_ERROR    = 8'h02
    } srb_status_t;
    
    // Command Structure Types
    typedef struct packed {
        logic [31:0]    lba;
        logic [31:0]    size_bytes;
        logic [63:0]    data_pattern;
        logic           is_write;
        logic [15:0]    command_id;
        logic [7:0]     cmd_priority;
    } io_command_t;
    
    // IRP (I/O Request Packet) Structure
    typedef struct packed {
        logic [3:0]     major_function;
        logic [3:0]     minor_function;
        logic [31:0]    status;
        logic [31:0]    information;
        logic [63:0]    user_buffer_ptr;
        logic [31:0]    buffer_length;
        logic           cancel;
        logic [15:0]    irp_id;
        logic [7:0]     stack_location;
    } irp_t;
    
    // SCSI Request Block (SRB) Structure
    typedef struct packed {
        logic [31:0]    length;
        logic [7:0]     srb_function;
        logic [7:0]     srb_status;
        logic [7:0]     scsi_status;
        logic [31:0]    data_transfer_length;
        logic [31:0]    timeout_value;
        logic [127:0]   cdb;
        logic [63:0]    data_buffer_ptr;
        logic [15:0]    original_irp_id;
        logic [31:0]    lba;
        logic [31:0]    sector_count;
    } srb_t;
    
    // NVMe Command Structure (64 bytes)
    typedef struct packed {
        logic [7:0]     opcode;
        logic [7:0]     flags;
        logic [15:0]    command_id;
        logic [31:0]    namespace_id;
        logic [63:0]    dptr1;
        logic [63:0]    dptr2;
        logic [31:0]    cdw10;
        logic [31:0]    cdw11;
        logic [31:0]    cdw12;
        logic [31:0]    cdw13;
        logic [31:0]    cdw14;
        logic [31:0]    cdw15;
        logic [31:0]    metadata_ptr;
        logic [95:0]    reserved;
    } nvme_command_t;
    
    // NVMe Completion Structure (16 bytes)
    typedef struct packed {
        logic [31:0]    command_specific;
        logic [31:0]    reserved;
        logic [15:0]    sq_head;
        logic [15:0]    sq_id;
        logic [15:0]    command_id;
        logic [15:0]    status;
    } nvme_completion_t;
    
endpackage

// ============================================================================
// Testbench: Windows Storage Stack + Complete NVMe Controller (WITH ADMIN SETUP)
// ============================================================================
module tb_windows_storage_stack_complete;

    reg clk;
    reg reset_n;
    
    // PCIe Configuration Interface
    reg [7:0] pcie_cfg_addr;
    reg [31:0] pcie_cfg_wr_data;
    reg pcie_cfg_wr_en;
    reg pcie_cfg_rd_en;
    wire [31:0] pcie_cfg_rd_data;
    wire pcie_cfg_rd_valid;
    
    // Testbench direct PCIe signals (used during admin setup)
    reg [63:0]  tb_pcie_mem_addr;
    reg [511:0] tb_pcie_mem_wr_data;
    reg         tb_pcie_mem_wr_en;
    reg [63:0]  tb_pcie_mem_wr_be;
    reg         tb_pcie_mem_rd_en;
    
    // Bridge PCIe signals (from host_pcie_bridge)
    wire [63:0]  bridge_pcie_addr;
    wire [511:0] bridge_pcie_wr_data;
    wire         bridge_pcie_wr_en;
    wire [63:0]  bridge_pcie_wr_be;
    wire         bridge_pcie_rd_en;
    
    // Muxed signals to controller
    wire [63:0]  pcie_mem_addr_ctrl;
    wire [511:0] pcie_mem_wr_data_ctrl;
    wire         pcie_mem_wr_en_ctrl;
    wire [63:0]  pcie_mem_wr_be_ctrl;
    wire         pcie_mem_rd_en_ctrl;
    
    // Controller outputs
    wire [511:0] pcie_mem_rd_data;
    wire         pcie_mem_rd_valid;
    
    // PCIe MSI Interface
    wire pcie_msi_wr_en;
    wire [63:0] pcie_msi_addr;
    wire [31:0] pcie_msi_data;
    wire [3:0] pcie_msi_be;
    reg pcie_msi_ready;
    
    // Command interface (to Windows Storage Stack)
    reg cmd_valid;
    reg [127:0] cmd_data;
    wire cmd_ready;
    
    // Completion interface
    wire completion_valid;
    wire [31:0] completion_status;
    wire [31:0] completion_info;
    wire [15:0] completion_irp_id;
    
    // Statistics
    wire [63:0] stat_total_cycles;
    wire [63:0] stat_total_commands;
    wire [63:0] stat_total_bytes;
    wire [31:0] stat_read_count;
    wire [31:0] stat_write_count;
    wire [31:0] stat_max_queue_depth;
    wire [31:0] stat_irps_created;
    wire [31:0] stat_srbs_created;
    wire [31:0] stat_nvme_cmds_issued;
    wire [31:0] stat_nvme_cpls_received;
    
    // Latency Statistics
    wire [31:0] stat_min_latency;
    wire [31:0] stat_max_latency;
    wire [31:0] stat_avg_latency;
    wire [31:0] stat_p95_latency;
    wire [31:0] stat_p99_latency;
    wire [31:0] stat_commands_with_latency;
    
    // DEBUG OUTPUTS
    wire [3:0] debug_blk_state;
    wire [31:0] debug_blk_fifo_count;
    wire [31:0] debug_blk_srb_fifo_count;
    wire [15:0] debug_blk_current_irp_id;
    
    // Controller Status
    wire [31:0] controller_status;
    wire [63:0] admin_queue_status;
    wire [63:0] io_queue_status_0;
    wire [63:0] io_queue_status_1;
    wire [63:0] io_queue_status_2;
    wire [63:0] io_queue_status_3;
    wire [63:0] io_queue_status_4;
    wire [63:0] io_queue_status_5;
    wire [63:0] io_queue_status_6;
    wire [63:0] io_queue_status_7;
    wire [31:0] interrupt_status;
    wire [31:0] interrupt_pending;
    wire [31:0] debug_queue_access_count;
    wire [31:0] debug_doorbell_updates;
    wire [31:0] debug_msi_sent_count;

    // Bridge enable (0 during admin setup, 1 afterwards)
    reg bridge_enable;

    // Bridge configuration signals
    reg [63:0] bridge_bar0_base;
    reg [63:0] bridge_io_sq_base;
    reg [63:0] bridge_io_cq_base;
    reg [63:0] bridge_sq_tail_doorbell;
    reg [63:0] bridge_cq_head_doorbell;

    // Bridge interface signals
    wire [511:0] host_cmd_data;
    wire         host_cmd_valid;
    wire         host_cmd_ready;
    wire [127:0] host_cpl_data;
    wire         host_cpl_valid;
    wire         host_cpl_ready;   // from storage stack

    // Test commands array
    reg [127:0] test_commands [0:99];
    integer num_commands;
    integer command_index;
    integer completions_received;

    wire [63:0] stat_iops;
    wire [63:0] stat_avg_throughput;

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Task to read commands from file
    task read_commands_from_file(input [2000:0] filename);
        integer file, scan_count, temp_data_pattern, temp_size_bytes, temp_lba, temp_is_write;
        integer command_count;
        begin
            file = $fopen(filename, "r");
            if (file == 0) begin
                $display("Error: Could not open file %s", filename);
                $finish;
            end
            command_count = 0;
            while (!$feof(file) && command_count < 100) begin
                scan_count = $fscanf(file, "%h %d %d %d",
                                   temp_data_pattern, temp_size_bytes, temp_lba, temp_is_write);
                if (scan_count == 4) begin
                    test_commands[command_count] = {temp_data_pattern[31:0], temp_size_bytes[31:0], temp_lba[31:0], 31'b0, temp_is_write[0]};
                    command_count = command_count + 1;
                end
            end
            $fclose(file);
            num_commands = command_count;
            $display("Read %0d commands from file", num_commands);
        end
    endtask

  

    // ============================================================
    // Task: Setup Admin Queues (Create I/O SQ and CQ)
    // ============================================================
    task setup_admin_queues;
        reg [63:0] admin_sq_base;
        reg [63:0] admin_cq_base;
        reg [63:0] io_cq_base;
        reg [63:0] io_sq_base;
        integer i;
        reg [511:0] cmd_data;
        reg [31:0] status;
        reg [15:0] cid;
        integer done;
        reg [4:0] cq_rd_ptr; // pointer into CQ (0-based)
    begin
        // Use offsets that avoid the doorbell region (0x1000-0x1FFF)
        admin_sq_base = 64'h80000000;   // offset 0x0000
        admin_cq_base = 64'h80002000;   // offset 0x2000
        io_sq_base    = 64'h80003000;   // offset 0x3000
        io_cq_base    = 64'h80004000;   // offset 0x4000
        bridge_io_sq_base = io_sq_base;          // 64'h80003000
        bridge_io_cq_base = io_cq_base;          // 64'h80004000
        bridge_sq_tail_doorbell = 64'h80001008;  // BAR0 + 0x1008
        bridge_cq_head_doorbell = 64'h8000100C;  // BAR0 + 0x100C
        $display("setup_admin_queues: bridge_io_sq_base=%h", bridge_io_sq_base);

        $display("Bridge config: SQ base=%h, CQ base=%h, SQ doorbell=%h, CQ doorbell=%h",
         bridge_io_sq_base, bridge_io_cq_base,
         bridge_sq_tail_doorbell, bridge_cq_head_doorbell);

        $display("Setting up admin queues at addresses: SQ=%h, CQ=%h", admin_sq_base, admin_cq_base);

        // Write create CQ command to admin SQ entry 0
        // Create CQ command
        cmd_data = 512'b0;
        cmd_data[7:0]   = 8'h05;                     // opcode
        cmd_data[15:8]  = 8'h00;                     // flags
        cmd_data[31:16] = 16'h0001;                  // command ID
        cmd_data[63:32] = 32'h00000000;               // namespace ID
        cmd_data[127:64] = io_cq_base;                // PRP1 (CQ base address)
        cmd_data[191:128] = 64'h0;                    // PRP2
        cmd_data[335:320] = 16'd31;                   // DW10[15:0] = queue size-1 (31)
        cmd_data[351:336] = 16'd1;                    // DW10[31:16] = queue ID (1)
        cmd_data[367:352] = 16'h0003;                 // DW11[15:0] = interrupt vector (0)
        cmd_data[383:368] = 16'h0;                     // DW11[31:16] = flags (IEN, PC)

        tb_pcie_mem_addr <= admin_sq_base;
        tb_pcie_mem_wr_data <= cmd_data;
        tb_pcie_mem_wr_en <= 1;
        tb_pcie_mem_wr_be <= 64'hFFFFFFFFFFFFFFFF;
        @(posedge clk);
        tb_pcie_mem_wr_en <= 0;

        // Write create SQ command to admin SQ entry 1 (offset 64)
        cmd_data = 512'b0;
        cmd_data[7:0]   = 8'h01;                     // opcode: Create I/O SQ
        cmd_data[15:8]  = 8'h00;                     // flags
        cmd_data[31:16] = 16'h0002;                  // command ID
        cmd_data[63:32] = 32'h00000000;               // namespace ID
        cmd_data[127:64] = io_sq_base;                // PRP1 (SQ base address)
        cmd_data[191:128] = 64'h0;                    // PRP2
        cmd_data[335:320] = 16'd31;                   // DW10[15:0] = queue size-1 (31)
        cmd_data[351:336] = 16'd1;                    // DW10[31:16] = queue ID (1)
        cmd_data[367:352] = 16'd1;                     // DW11[15:0] = associated CQ ID (1)
        cmd_data[383:368] = 16'h0001;                  // DW11[31:16] = priority (01)

        tb_pcie_mem_addr <= admin_sq_base + 64;
        tb_pcie_mem_wr_data <= cmd_data;
        tb_pcie_mem_wr_en <= 1;
        @(posedge clk);
        tb_pcie_mem_wr_en <= 0;

        // Ring admin SQ doorbell (tail = 2)
        tb_pcie_mem_addr <= 64'h80001080; // admin SQ tail doorbell (offset 0x1080)
        tb_pcie_mem_wr_data <= 32'd2;
        tb_pcie_mem_wr_en <= 1;
        tb_pcie_mem_wr_be <= 64'h0000000F;
        @(posedge clk);
        tb_pcie_mem_wr_en <= 0;

        // Poll admin CQ for completions
        done = 0;
        cq_rd_ptr = 0;
        for (i = 0; i < 100; i = i + 1) begin
            #100;
            tb_pcie_mem_addr <= admin_cq_base + (cq_rd_ptr * 16);
            tb_pcie_mem_rd_en <= 1;
            @(posedge clk);                // wait one cycle for read to be processed
            while (!pcie_mem_rd_valid) @(posedge clk); // wait until valid
            tb_pcie_mem_rd_en <= 0;
            status = pcie_mem_rd_data[127:112];
            cid = pcie_mem_rd_data[111:96];
            $display("Admin completion: entry %0d, status=%h, cid=%0d", cq_rd_ptr, status, cid);

            // Update CQ head doorbell to indicate we've consumed this completion
            tb_pcie_mem_addr <= 64'h80001084; // admin CQ head doorbell (offset 0x1084)
            tb_pcie_mem_wr_data <= cq_rd_ptr + 1; // new head
            tb_pcie_mem_wr_en <= 1;
            tb_pcie_mem_wr_be <= 64'h0000000F;
            @(posedge clk);
            tb_pcie_mem_wr_en <= 0;
            $display("*** TESTBENCH: Issued admin CQ head doorbell write with value %0d at time %t", cq_rd_ptr+1, $time);
            $display("Testbench: Writing admin CQ head doorbell with value %0d", cq_rd_ptr + 1);

            cq_rd_ptr = cq_rd_ptr + 1;
            done = done + 1; // count both completions, regardless of status
            if (done >= 2) break;
        end

        if (done == 2)
            $display("Admin queues created successfully.");
        else
            $display("ERROR: Admin queue creation failed.");
        $display("Bridge CQ base = %h", bridge_io_cq_base);
    end     
    endtask


    // ============================================================
    // Instantiate the bridge
    // ============================================================
    host_pcie_bridge #(
    .QUEUE_SIZE(32),
    .SSD_LATENCY_CYCLES(5000)   // 50 µs
    ) bridge (
        .clk(clk),
        .reset_n(reset_n),
        .enable(bridge_enable),
        .host_cmd_data(host_cmd_data),
        .host_cmd_valid(host_cmd_valid),
        .host_cmd_ready(host_cmd_ready),
        .host_cpl_data(host_cpl_data),
        .host_cpl_valid(host_cpl_valid),
        .host_cpl_ready(host_cpl_ready),
        .pcie_addr(bridge_pcie_addr),
        .pcie_wr_data(bridge_pcie_wr_data),
        .pcie_wr_en(bridge_pcie_wr_en),
        .pcie_wr_be(bridge_pcie_wr_be),
        .pcie_rd_en(bridge_pcie_rd_en),
        .pcie_rd_data(pcie_mem_rd_data),
        .pcie_rd_valid(pcie_mem_rd_valid),
        .msi_wr_en(pcie_msi_wr_en),
        .msi_addr(pcie_msi_addr),
        .msi_data(pcie_msi_data),
        .io_sq_base(bridge_io_sq_base),
        .io_cq_base(bridge_io_cq_base),
        .queue_size(16'd32),
        .sq_tail_doorbell_addr(bridge_sq_tail_doorbell),
        .cq_head_doorbell_addr(bridge_cq_head_doorbell),
        .commands_sent(),
        .completions_received()
    );

    // ============================================================
    // Mux PCIe signals to controller
    // ============================================================
    assign pcie_mem_addr_ctrl   = bridge_enable ? bridge_pcie_addr   : tb_pcie_mem_addr;
    assign pcie_mem_wr_data_ctrl = bridge_enable ? bridge_pcie_wr_data : tb_pcie_mem_wr_data;
    assign pcie_mem_wr_en_ctrl   = bridge_enable ? bridge_pcie_wr_en   : tb_pcie_mem_wr_en;
    assign pcie_mem_wr_be_ctrl   = bridge_enable ? bridge_pcie_wr_be   : tb_pcie_mem_wr_be;
    assign pcie_mem_rd_en_ctrl   = bridge_enable ? bridge_pcie_rd_en   : tb_pcie_mem_rd_en;

    wire nvme_native_cpl_valid;   // from controller
    wire [127:0] nvme_native_cpl_data;
    wire nvme_cpl_ready;

    // ============================================================
    // Instantiate complete NVMe controller
    // ============================================================
    nvme_controller_complete nvme_controller (
        .clk(clk),
        .reset_n(reset_n),
        .pcie_cfg_addr(pcie_cfg_addr),
        .pcie_cfg_wr_data(pcie_cfg_wr_data),
        .pcie_cfg_wr_en(pcie_cfg_wr_en),
        .pcie_cfg_rd_en(pcie_cfg_rd_en),
        .pcie_cfg_rd_data(pcie_cfg_rd_data),
        .pcie_cfg_rd_valid(pcie_cfg_rd_valid),
        .pcie_mem_addr(pcie_mem_addr_ctrl),
        .pcie_mem_wr_data(pcie_mem_wr_data_ctrl),
        .pcie_mem_wr_en(pcie_mem_wr_en_ctrl),
        .pcie_mem_wr_be(pcie_mem_wr_be_ctrl),
        .pcie_mem_rd_en(pcie_mem_rd_en_ctrl),
        .pcie_mem_rd_data(pcie_mem_rd_data),
        .pcie_mem_rd_valid(pcie_mem_rd_valid),
        .pcie_msi_wr_en(pcie_msi_wr_en),
        .pcie_msi_addr(pcie_msi_addr),
        .pcie_msi_data(pcie_msi_data),
        .pcie_msi_be(pcie_msi_be),
        .pcie_msi_ready(pcie_msi_ready),
        .nvme_cmd_valid(),
        .nvme_cmd_data(),
        .nvme_cmd_ready(),
        .nvme_cpl_valid(nvme_native_cpl_valid),
        .nvme_cpl_data(nvme_native_cpl_data),
        .nvme_cpl_ready(nvme_cpl_ready),
        .controller_status(controller_status),
        .admin_queue_status(admin_queue_status),
        .io_queue_status_0(io_queue_status_0),
        .io_queue_status_1(io_queue_status_1),
        .io_queue_status_2(io_queue_status_2),
        .io_queue_status_3(io_queue_status_3),
        .io_queue_status_4(io_queue_status_4),
        .io_queue_status_5(io_queue_status_5),
        .io_queue_status_6(io_queue_status_6),
        .io_queue_status_7(io_queue_status_7),
        .interrupt_status(interrupt_status),
        .interrupt_pending(interrupt_pending),
        .debug_queue_access_count(debug_queue_access_count),
        .debug_doorbell_updates(debug_doorbell_updates),
        .debug_msi_sent_count(debug_msi_sent_count)
    );

    // ============================================================
    // Instantiate Windows Storage Stack (host side)
    // ============================================================
    windows_storage_stack_core #(
        .CMD_FIFO_DEPTH(64),
        .NUM_IO_QUEUES(8),
        .PRP_POOL_SIZE(256)
    ) storage_stack (
        .clk(clk),
        .reset_n(reset_n),
        .cmd_in_valid(cmd_valid),
        .cmd_in_data(cmd_data),
        .cmd_in_ready(cmd_ready),
        .completion_out_valid(completion_valid),
        .completion_status(completion_status),
        .completion_info(completion_info),
        .nvme_cmd_valid(host_cmd_valid),
        .nvme_cmd_data(host_cmd_data),
        .nvme_cmd_ready(host_cmd_ready),
        .nvme_cpl_valid(host_cpl_valid),
        .nvme_cpl_data(host_cpl_data),
        .nvme_cpl_ready(host_cpl_ready),
        //.nvme_cpl_valid(nvme_native_cpl_valid),
        //.nvme_cpl_data(nvme_native_cpl_data),
        //.nvme_cpl_ready(nvme_cpl_ready),
        .stat_total_cycles(stat_total_cycles),
        .stat_total_commands(stat_total_commands),
        .stat_total_bytes(stat_total_bytes),
        .stat_read_count(stat_read_count),
        .stat_write_count(stat_write_count),
        .stat_max_queue_depth(stat_max_queue_depth),
        .stat_irps_created(stat_irps_created),
        .stat_srbs_created(stat_srbs_created),
        .stat_nvme_cmds_issued(stat_nvme_cmds_issued),
        .stat_nvme_cpls_received(stat_nvme_cpls_received),
        .stat_iops(stat_iops),
        .stat_avg_throughput(stat_avg_throughput),
        .stat_min_latency(stat_min_latency),
        .stat_max_latency(stat_max_latency),
        .stat_avg_latency(stat_avg_latency),
        .stat_p95_latency(stat_p95_latency),
        .stat_p99_latency(stat_p99_latency),
        .stat_commands_with_latency(stat_commands_with_latency),
        .debug_blk_state(debug_blk_state),
        .debug_blk_fifo_count(debug_blk_fifo_count),
        .debug_blk_srb_fifo_count(debug_blk_srb_fifo_count),
        .debug_blk_current_irp_id(debug_blk_current_irp_id),
        .debug_nvme_state(),
        .debug_nvme_srb_fifo_count(),
        .debug_nvme_cpl_fifo_count(),
        .debug_nvme_queue_counts_sum(),
        .completion_irp_id_out(completion_irp_id)        
    );

    // ============================================================
    // Main test sequence
    // ============================================================

    always @(posedge clk) begin
        if (pcie_msi_wr_en) $display("Testbench: pcie_msi_wr_en = 1 at time %t", $time);
    end
    initial begin
        reset_n = 0;
        cmd_valid = 0;
        pcie_cfg_addr = 0;
        pcie_cfg_wr_data = 0;
        pcie_cfg_wr_en = 0;
        pcie_cfg_rd_en = 0;
        tb_pcie_mem_addr = 0;
        tb_pcie_mem_wr_data = 0;
        tb_pcie_mem_wr_en = 0;
        tb_pcie_mem_wr_be = 0;
        tb_pcie_mem_rd_en = 0;
        pcie_msi_ready = 1;
        bridge_enable = 0;               // bridge disabled during init
        bridge_bar0_base = 64'h80000000;   // from BAR0 config

        #100 reset_n = 1;

        // Enable memory space and bus master

        // Read commands from file (adjust path as needed)
        read_commands_from_file("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track_B/Commands/70_cpu_commands.txt");

        // ========================================================
        // PCIe Configuration (enable memory, bus master, MSI)
        // ========================================================
        #200;
        $display("Initializing PCIe Configuration...");
        // Assign BAR0 base address (e.g., 0x80000000)
        pcie_cfg_addr = 8'h10;                     // BAR0 low
        pcie_cfg_wr_data = 32'h80000000 | 4;       // 64-bit memory, prefetchable, address 0x80000000
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        pcie_cfg_addr = 8'h14;                     // BAR0 high (BAR1)
        pcie_cfg_wr_data = 32'h00000000;           // upper 32 bits = 0
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        #200; // Let BAR propagate

        // Enable memory space and bus master
        pcie_cfg_addr = 8'h04;
        pcie_cfg_wr_data = 32'h0007;   // bits: 0=I/O space, 1=memory space, 2=bus master
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;
        $display("PCIe Config: Command register updated to enable memory and bus master");

        // Configure MSI (enable interrupts)
        // ------------------------------------------------------------------
        // MSI message lower address (any valid 32-bit address; e.g. LAPIC base)
        pcie_cfg_addr = 8'h44;
        pcie_cfg_wr_data = 32'hFEE00000;  // typical LAPIC address
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        // MSI message upper address (0 if using 32-bit; we use 64-bit capable)
        pcie_cfg_addr = 8'h48;
        pcie_cfg_wr_data = 32'h0;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        // MSI message data (base value; actual data will be base + vector)
        pcie_cfg_addr = 8'h4C;
        pcie_cfg_wr_data = 32'h0;         // base data = 0
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        // Enable MSI: set bit 0 of Message Control register
        pcie_cfg_addr = 8'h42;
        pcie_cfg_wr_data = 32'h0001;      // enable, single message
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;
        $display("MSI enabled.");


        // ========================================================
        // Create I/O queues via admin commands
        // ========================================================
        // Note: bridge is still disabled, we drive PCIe directly via tb_*
        setup_admin_queues();

        // ========================================================
        // Enable bridge and start sending I/O commands
        // ========================================================
        bridge_enable = 1;
        repeat(10) @(posedge clk);   // Allow bridge to see new base addresses
        $display("Bridge enabled, io_sq_base=%h", bridge_io_sq_base);
        $display("=== Starting Command Processing with Complete NVMe Controller ===");

        command_index = 0;
        completions_received = 0;

        // Send all commands
        for (command_index = 0; command_index < num_commands; command_index = command_index + 1) begin
            @(posedge clk);
            cmd_valid = 1;
            cmd_data = test_commands[command_index];

            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 0;

            $display("Sent command %0d/%0d", command_index+1, num_commands);
            repeat(50) @(posedge clk); // small gap
        end

        $display("All commands sent. Waiting for completions...");

        // Wait for all completions (simple timeout)
        fork
            begin: wait_completions
                while (stat_nvme_cpls_received < num_commands) begin
                    #1000;
                end
                $display("All %0d commands completed.", num_commands);
            end
            begin: timeout
                #200000000; // 200 ms timeout
                $display("ERROR: Timeout waiting for completions.");
            end
        join_any
        disable fork;

        // Print final statistics
        $display("\n=== FINAL STATISTICS ===");
        $display("Total commands: %0d", stat_total_commands);
        $display("Total bytes: %0d", stat_total_bytes);
        $display("Reads: %0d, Writes: %0d", stat_read_count, stat_write_count);
        $display("IRPs created: %0d", stat_irps_created);
        $display("SRBs created: %0d", stat_srbs_created);
        $display("NVMe commands issued: %0d", stat_nvme_cmds_issued);
        $display("NVMe completions received: %0d", stat_nvme_cpls_received);
        $display("IOPS: %0d", stat_iops);
        $display("Avg Throughput: %0d bytes/s", stat_avg_throughput);
        $display("Min latency: %0d cycles", stat_min_latency);
        $display("Max latency: %0d cycles", stat_max_latency);
        $display("Avg latency: %0d cycles", stat_avg_latency);
        $display("p95 latency: %0d cycles", stat_p95_latency);
        $display("p99 latency: %0d cycles", stat_p99_latency);
        

        #100;
        $finish;
    end

endmodule