`timescale 1ns/1ps
package windows_storage_pkg;
    //all definitions of real windows enums
    typedef enum logic [3:0] {
        IRP_MJ_READ = 4'h0,
        IRP_MJ_WRITE = 4'h1,
        IRP_MJ_FLUSH_BUFFERS= 4'h2,
        IRP_MJ_DEVICE_CONTROL= 4'h3
    } irp_major_function_t;
    
    typedef enum logic [7:0] {
        NVME_OPC_READ = 8'h02,
        NVME_OPC_WRITE = 8'h01,
        NVME_OPC_FLUSH = 8'h00,
        NVME_OPC_DSM = 8'h09
    } nvme_opcode_t;
    
    /*ones that are commented out are correct but not used
    typedef enum logic [7:0] {
        SCSIOP_READ = 8'h28,
        SCSIOP_WRITE = 8'h2A,
        SCSIOP_READ_CAPACITY= 8'h25
    } scsi_opcode_t;*/
    
    typedef enum logic [31:0] {
        STATUS_SUCCESS = 32'h00000000,
        STATUS_PENDING = 32'h00000103,
        STATUS_INVALID_PARAMETER = 32'hC000000D
    } ntstatus_t;
    
    /*typedef enum logic [31:0] {
        FILE_DEVICE_DISK = 32'h00000007,
        FILE_DEVICE_DISK_FILE_SYSTEM = 32'h00000008
    } device_type_t;*/
    
    /*typedef enum logic [7:0] {
        BusTypeNvme = 8'h11,
        BusTypeScsi = 8'h01,
        BusTypeSata = 8'h0B
    } storage_bus_type_t;*/
    
    /*typedef enum logic [7:0] {
        SRB_STATUS_PENDING = 8'h04,
        SRB_STATUS_SUCCESS = 8'h01,
        SRB_STATUS_ERROR = 8'h02
    } srb_status_t;*/
    
    /*typedef struct packed {
        logic [31:0] lba;
        logic [31:0] size_bytes;
        logic [63:0] data_pattern;
        logic is_write;
        logic [15:0] command_id;
        logic [7:0] cmd_priority;
    } io_command_t;*/
    
    typedef struct packed {
        logic [3:0] major_function;
        logic [3:0] minor_function;
        logic [31:0] status;
        logic [31:0] information;
        logic [63:0] user_buffer_ptr;
        logic [31:0] buffer_length;
        logic cancel;
        logic [15:0] irp_id;
        logic [7:0] stack_location;
    } irp_t;
    
    typedef struct packed {
        logic [31:0] length;
        logic [7:0] srb_function;
        logic [7:0] srb_status;
        logic [7:0] scsi_status;
        logic [31:0] data_transfer_length;
        logic [31:0] timeout_value;
        logic [127:0] cdb;
        logic [63:0] data_buffer_ptr;
        logic [15:0] original_irp_id;
        logic [31:0] lba;
        logic [31:0] sector_count;
    } srb_t;
    
    typedef struct packed {
        logic [7:0] opcode;
        logic [7:0] flags;
        logic [15:0] command_id;
        logic [31:0] namespace_id;
        logic [63:0] dptr1;
        logic [63:0] dptr2;
        logic [31:0] cdw10;
        logic [31:0] cdw11;
        logic [31:0] cdw12;
        logic [31:0] cdw13;
        logic [31:0] cdw14;
        logic [31:0] cdw15;
        logic [31:0] metadata_ptr;
        logic [95:0] reserved;
    } nvme_command_t;
    
    typedef struct packed {
        logic [31:0] command_specific;
        logic [31:0] reserved;
        logic [15:0] sq_head;
        logic [15:0] sq_id;
        logic [15:0] command_id;
        logic [15:0] status;
    } nvme_completion_t;
    
endpackage

module tb_windows_storage_stack_complete;

    reg clk;
    reg reset;
    
    reg [7:0] pcie_cfg_addr;
    reg [31:0] pcie_cfg_wr_data;
    reg pcie_cfg_wr_en;
    
    reg [63:0] tb_pcie_mem_addr;
    reg [511:0] tb_pcie_mem_wr_data;
    reg tb_pcie_mem_wr_en;
    reg [63:0] tb_pcie_mem_wr_be;
    reg tb_pcie_mem_rd_en;
    
    wire [63:0] bridge_pcie_addr;
    wire [511:0] bridge_pcie_wr_data;
    wire bridge_pcie_wr_en;
    
    wire [63:0] pcie_mem_addr_ctrl;
    wire [511:0] pcie_mem_wr_data_ctrl;
    wire pcie_mem_wr_en_ctrl;
    wire pcie_mem_rd_en_ctrl;
    
    wire [511:0] pcie_mem_rd_data;
    wire pcie_mem_rd_valid;
    
    wire pcie_msi_wr_en;
    
    reg cmd_valid;
    reg [127:0] cmd_data;
    wire cmd_ready;

    wire io_done_signal;
    
    wire [63:0] stat_total_cycles;
    wire [63:0] stat_total_commands;
    wire [63:0] stat_total_bytes;
    wire [31:0] stat_read_count;
    wire [31:0] stat_write_count;
    wire [31:0] stat_irps_created;
    wire [31:0] stat_srbs_created;
    wire [31:0] stat_nvme_cmds_issued;
    wire [31:0] stat_nvme_cpls_received;
    
    wire [31:0] stat_min_latency;
    wire [31:0] stat_max_latency;
    wire [31:0] stat_avg_latency;
    wire [31:0] stat_p95_latency;
    wire [31:0] stat_p99_latency;
    
    wire [63:0] stat_iops;
    wire [63:0] stat_avg_throughput;

    reg bridge_enable;
    reg [63:0] bridge_io_sq_base;
    reg [63:0] bridge_io_cq_base;
    reg [63:0] bridge_sq_tail_doorbell;
    reg [63:0] bridge_cq_head_doorbell;

    wire [511:0] host_cmd_data;
    wire host_cmd_valid;
    wire host_cmd_ready;
    wire [127:0] host_cpl_data;
    wire host_cpl_valid;
    wire host_cpl_ready;

    reg [127:0] test_commands [0:99];
    integer num_commands;
    integer command_index;

    initial begin //100 MHz
        clk = 0;
        forever #5 clk = ~clk;
    end

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
                scan_count = $fscanf(file, "%h %d %d %d", temp_data_pattern, temp_size_bytes, temp_lba, temp_is_write);
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
        reg [4:0] cq_rd_ptr;
    begin
        admin_sq_base = 64'h80000000; //hardcoded from windows specifications
        admin_cq_base = 64'h80002000;
        io_sq_base = 64'h80003000;
        io_cq_base = 64'h80004000;
        bridge_io_sq_base = io_sq_base;
        bridge_io_cq_base = io_cq_base;
        bridge_sq_tail_doorbell = 64'h80001008;
        bridge_cq_head_doorbell = 64'h8000100C;

        //CQ command
        cmd_data = 512'b0;
        cmd_data[7:0] = 8'h05;
        cmd_data[15:8] = 8'h00;
        cmd_data[31:16] = 16'h0001;
        cmd_data[63:32] = 32'h00000000;
        cmd_data[127:64] = io_cq_base;
        cmd_data[191:128] = 64'h0;
        cmd_data[335:320] = 16'd31;
        cmd_data[351:336] = 16'd1;
        cmd_data[367:352] = 16'h0003;
        cmd_data[383:368] = 16'h0;

        tb_pcie_mem_addr <= admin_sq_base;
        tb_pcie_mem_wr_data <= cmd_data;
        tb_pcie_mem_wr_en <= 1; //write the command
        tb_pcie_mem_wr_be <= 64'hFFFFFFFFFFFFFFFF;
        @(posedge clk); //wait a cycle for it to register
        tb_pcie_mem_wr_en <= 0;

        //SQ command
        cmd_data = 512'b0;
        cmd_data[7:0] = 8'h01;
        cmd_data[15:8] = 8'h00;
        cmd_data[31:16] = 16'h0002;
        cmd_data[63:32] = 32'h00000000;
        cmd_data[127:64] = io_sq_base;
        cmd_data[191:128] = 64'h0;
        cmd_data[335:320] = 16'd31;
        cmd_data[351:336] = 16'd1;
        cmd_data[367:352] = 16'd1;
        cmd_data[383:368] = 16'h0001;

        tb_pcie_mem_addr <= admin_sq_base + 64;
        tb_pcie_mem_wr_data <= cmd_data;
        tb_pcie_mem_wr_en <= 1; //write command
        @(posedge clk); //wait cycle for computation
        tb_pcie_mem_wr_en <= 0;

        //ring admin SQ doorbell
        tb_pcie_mem_addr <= 64'h80001080;
        tb_pcie_mem_wr_data <= 32'd2;
        tb_pcie_mem_wr_en <= 1;
        tb_pcie_mem_wr_be <= 64'h0000000F;
        @(posedge clk);
        tb_pcie_mem_wr_en <= 0;

        //check admin CQ for completions
        done = 0;
        cq_rd_ptr = 0;
        for (i = 0; i < 100; i++) begin
            #100; //wait so that time for completions is given
            tb_pcie_mem_addr <= admin_cq_base + (cq_rd_ptr * 16);
            tb_pcie_mem_rd_en <= 1;
            @(posedge clk);
            while (!pcie_mem_rd_valid) @(posedge clk); //wait for a response
            tb_pcie_mem_rd_en <= 0;
            status = pcie_mem_rd_data[127:112];
            cid = pcie_mem_rd_data[111:96];
            //$display("Admin completion: entry %0d, status=%h, cid=%0d", cq_rd_ptr, status, cid);

            tb_pcie_mem_addr <= 64'h80001084;
            tb_pcie_mem_wr_data <= cq_rd_ptr + 1;
            tb_pcie_mem_wr_en <= 1;
            tb_pcie_mem_wr_be <= 64'h0000000F;
            @(posedge clk);
            tb_pcie_mem_wr_en <= 0;
            //$display("*** TESTBENCH: Issued admin CQ head doorbell write with value %0d at time %t", cq_rd_ptr+1, $time);
            //$display("Testbench: Writing admin CQ head doorbell with value %0d", cq_rd_ptr + 1);

            cq_rd_ptr = cq_rd_ptr + 1;
            done = done + 1;
            if (done >= 2) break; //once admin queues created, quit
        end

        if (done == 2)
            $display("Admin queues created successfully.");
        else
            $display("ERROR: Admin queue creation failed.");
        //$display("Bridge CQ base = %h", bridge_io_cq_base);
    end
    endtask

    host_pcie_bridge #(
        .QUEUE_SIZE(32)
    ) bridge (
        .clk(clk),
        .reset(reset),
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
        .io_sq_base(bridge_io_sq_base),
        .sq_tail_doorbell_addr(bridge_sq_tail_doorbell),
        .cq_head_doorbell_addr(bridge_cq_head_doorbell),
        .io_processing_done(io_done_signal)
    );

    assign pcie_mem_addr_ctrl = bridge_enable ? bridge_pcie_addr : tb_pcie_mem_addr;
    assign pcie_mem_wr_data_ctrl = bridge_enable ? bridge_pcie_wr_data : tb_pcie_mem_wr_data;
    assign pcie_mem_wr_en_ctrl = bridge_enable ? bridge_pcie_wr_en : tb_pcie_mem_wr_en;
    assign pcie_mem_rd_en_ctrl = bridge_enable ? 0 : tb_pcie_mem_rd_en;



    nvme_controller_complete nvme_controller (
        .clk(clk),
        .reset(reset),
        .pcie_cfg_addr(pcie_cfg_addr),
        .pcie_cfg_wr_data(pcie_cfg_wr_data),
        .pcie_cfg_wr_en(pcie_cfg_wr_en),
        .pcie_mem_addr(pcie_mem_addr_ctrl),
        .pcie_mem_wr_data(pcie_mem_wr_data_ctrl),
        .pcie_mem_wr_en(pcie_mem_wr_en_ctrl),
        .pcie_mem_rd_en(pcie_mem_rd_en_ctrl),
        .pcie_mem_rd_data(pcie_mem_rd_data),
        .pcie_mem_rd_valid(pcie_mem_rd_valid),
        .pcie_msi_wr_en(pcie_msi_wr_en),
        .io_processor_done(io_done_signal)
    );

    windows_storage_stack_core #(
        .NUM_IO_QUEUES(8)
    ) storage_stack (
        .clk(clk),
        .reset(reset),
        .cmd_in_valid(cmd_valid),
        .cmd_in_data(cmd_data),
        .cmd_in_ready(cmd_ready),
        .nvme_cmd_valid(host_cmd_valid),
        .nvme_cmd_data(host_cmd_data),
        .nvme_cmd_ready(host_cmd_ready),
        .nvme_cpl_valid(host_cpl_valid),
        .nvme_cpl_data(host_cpl_data),
        .nvme_cpl_ready(host_cpl_ready),
        .stat_total_cycles(stat_total_cycles),
        .stat_total_commands(stat_total_commands),
        .stat_total_bytes(stat_total_bytes),
        .stat_read_count(stat_read_count),
        .stat_write_count(stat_write_count),
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
        .stat_p99_latency(stat_p99_latency)
    );

    /*always @(posedge clk) begin
        if (pcie_msi_wr_en) $display("Testbench: pcie_msi_wr_en = 1 at time %t", $time);
    end*/

    //print statements below do a lot of the explination of what is happening
    //i didnt want to make redundant comments
    initial begin
        reset = 1;
        cmd_valid = 0;
        pcie_cfg_addr = 0;
        pcie_cfg_wr_data = 0;
        pcie_cfg_wr_en = 0;
        tb_pcie_mem_addr = 0;
        tb_pcie_mem_wr_data = 0;
        tb_pcie_mem_wr_en = 0;
        tb_pcie_mem_wr_be = 0;
        tb_pcie_mem_rd_en = 0;
        bridge_enable = 0;

        #100 reset = 0;

        //change file path for the location of 70_cpu_commands when running on a different machine
        read_commands_from_file("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track_B/Commands/70_cpu_commands.txt");
        #200;

        $display("Initializing PCIe Configuration...");
        pcie_cfg_addr = 8'h10;
        pcie_cfg_wr_data = 32'h80000000 | 4;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        pcie_cfg_addr = 8'h14;
        pcie_cfg_wr_data = 32'h00000000;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        #200;

        pcie_cfg_addr = 8'h04;
        pcie_cfg_wr_data = 32'h0007;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;
        $display("PCIe Config: Command register updated to enable memory and bus master");

        pcie_cfg_addr = 8'h44;
        pcie_cfg_wr_data = 32'hFEE00000;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        pcie_cfg_addr = 8'h48;
        pcie_cfg_wr_data = 32'h0;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        pcie_cfg_addr = 8'h4C;
        pcie_cfg_wr_data = 32'h0;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;

        pcie_cfg_addr = 8'h42;
        pcie_cfg_wr_data = 32'h0001;
        pcie_cfg_wr_en = 1;
        @(posedge clk);
        pcie_cfg_wr_en = 0;
        $display("MSI enabled.");

        setup_admin_queues();

        bridge_enable = 1;
        repeat(10) @(posedge clk);
        //$display("Bridge enabled, io_sq_base=%h", bridge_io_sq_base);
        $display("=== Starting Command Processing with Complete NVMe Controller ===");

        command_index = 0;

        for (command_index = 0; command_index < num_commands; command_index++) begin
            @(posedge clk);
            cmd_valid = 1;
            cmd_data = test_commands[command_index];
            wait(cmd_ready); //important part!!! wait till the command is ready to send
            @(posedge clk);
            cmd_valid = 0;
            $display("Sent command %0d/%0d", command_index+1, num_commands);
            repeat(50) @(posedge clk);
        end

        $display("All commands sent. Waiting for completions...");

        fork
            begin: wait_completions
                while (stat_nvme_cpls_received < num_commands) #1000;
                $display("All %0d commands completed.", num_commands);
            end
            begin: timeout //safety, not triggered
                #50000000;
                $display("ERROR: Timeout waiting for completions.");
            end
        join_any
        disable fork;

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
        $display("Total cycles: %0d cycles", stat_total_cycles);

        #100;
        $finish;
    end
endmodule