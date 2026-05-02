// ============================================================================
// Testbench Debug Ports with Enhanced Latency Statistics (ORIGINAL TESTBENCH)
// ============================================================================
/*module tb_windows_storage_stack;
    
    reg clk;
    reg reset_n;
    
    // Command interface
    reg cmd_valid;
    reg [127:0] cmd_data;
    wire cmd_ready;
    
    // Completion interface
    wire completion_valid;
    wire [31:0] completion_status;
    wire [31:0] completion_info;
    wire [15:0] completion_irp_id;
    
    // NVMe interface
    wire nvme_cmd_valid;
    wire [511:0] nvme_cmd_data;
    reg nvme_cmd_ready;
    reg nvme_cpl_valid;
    reg [127:0] nvme_cpl_data;
    wire nvme_cpl_ready;
    
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
    wire [3:0] debug_nvme_state;
    wire [31:0] debug_nvme_srb_fifo_count;
    wire [31:0] debug_nvme_cpl_fifo_count;
    wire [31:0] debug_nvme_queue_counts_sum;
    
    // Test commands
    reg [127:0] test_commands [0:99];  // Increased to 100 commands maximum
    integer num_commands;  // Number of commands actually read from file
    integer command_index;
    integer completions_received;
    
    // Latency tracking arrays
    reg [63:0] command_start_time [0:99];
    reg [63:0] command_end_time [0:99];
    reg [31:0] command_latency [0:99];
    reg [31:0] latencies_sorted [0:99];
    integer latency_count;
    
    // Debug state tracking
    reg [3:0] prev_blk_state;
    reg [31:0] prev_blk_fifo_count;
    reg [3:0] prev_nvme_state;
    reg [31:0] prev_nvme_srb_fifo_count;
    
    // DUT instantiation
    windows_storage_stack_core_fixed #(
        .CMD_FIFO_DEPTH(64),
        .NUM_IO_QUEUES(8),
        .PRP_POOL_SIZE(256)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .cmd_in_valid(cmd_valid),
        .cmd_in_data(cmd_data),
        .cmd_in_ready(cmd_ready),
        .completion_out_valid(completion_valid),
        .completion_status(completion_status),
        .completion_info(completion_info),
        .nvme_cmd_valid(nvme_cmd_valid),
        .nvme_cmd_data(nvme_cmd_data),
        .nvme_cmd_ready(nvme_cmd_ready),
        .nvme_cpl_valid(nvme_cpl_valid),
        .nvme_cpl_data(nvme_cpl_data),
        .nvme_cpl_ready(nvme_cpl_ready),
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
        // Latency Statistics
        .stat_min_latency(stat_min_latency),
        .stat_max_latency(stat_max_latency),
        .stat_avg_latency(stat_avg_latency),
        .stat_p95_latency(stat_p95_latency),
        .stat_p99_latency(stat_p99_latency),
        .stat_commands_with_latency(stat_commands_with_latency),
        // DEBUG OUTPUTS
        .debug_blk_state(debug_blk_state),
        .debug_blk_fifo_count(debug_blk_fifo_count),
        .debug_blk_srb_fifo_count(debug_blk_srb_fifo_count),
        .debug_blk_current_irp_id(debug_blk_current_irp_id),
        .debug_nvme_state(debug_nvme_state),
        .debug_nvme_srb_fifo_count(debug_nvme_srb_fifo_count),
        .debug_nvme_cpl_fifo_count(debug_nvme_cpl_fifo_count),
        .debug_nvme_queue_counts_sum(debug_nvme_queue_counts_sum),
        .completion_irp_id_out(completion_irp_id)
    );
    
    // Clock generation (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Read commands from file and determine actual count
    task read_commands_from_file;
        input [2000:0] filename;
        integer file;
        integer scan_count;
        integer temp_data_pattern;
        integer temp_size_bytes;
        integer temp_lba;
        integer temp_is_write;
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
            num_commands = command_count;  // Store the actual number of commands
            $display("Read %0d commands from file", num_commands);
            
            // Initialize the rest of the array to zeros
            for (command_count = num_commands; command_count < 100; command_count = command_count + 1) begin
                test_commands[command_count] = 128'b0;
            end
        end
    endtask
    
    // Initialize test commands from file
    initial begin
        $display("Reading commands from input file...");
        //read_commands_from_file("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track_B/Commands/7_cpu_commands.txt");
        read_commands_from_file("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track_B/Commands/70_cpu_commands.txt");
        // Display summary of commands read
        if (num_commands > 0) begin
            $display("Successfully read %0d commands from file", num_commands);
            for (integer i = 0; i < num_commands; i = i + 1) begin
                $display("Command %0d: %s LBA=%0d, Size=%0d bytes", 
                         i, (test_commands[i][0] ? "WRITE" : "READ"),
                         test_commands[i][63:32],
                         test_commands[i][95:64]);
            end
        end else begin
            $display("WARNING: No commands read from file! Using default test commands.");
            // Fallback to default test commands
            test_commands[0] = {32'h00000000, 32'd4096, 32'd1024, 31'b0, 1'b0};  // Read: LBA=1024, Size=4096
            test_commands[1] = {32'h12345678, 32'd8192, 32'd2048, 31'b0, 1'b1};  // Write: LBA=2048, Size=8192
            test_commands[2] = {32'h00000000, 32'd2048, 32'd4096, 31'b0, 1'b0};  // Read: LBA=4096, Size=2048
            test_commands[3] = {32'h6EDCBA98, 32'd4096, 32'd8192, 31'b0, 1'b1};  // Write: LBA=8192, Size=4096
            test_commands[4] = {32'h00000000, 32'd8192, 32'd16384, 31'b0, 1'b0}; // Read: LBA=16384, Size=8192
            test_commands[5] = {32'h11223344, 32'd4096, 32'd32768, 31'b0, 1'b1}; // Write: LBA=32768, Size=4096
            test_commands[6] = {32'h00000000, 32'd16384, 32'd65536, 31'b0, 1'b0}; // Read: LBA=65536, Size=16384
            num_commands = 7;
            $display("Using %0d default test commands", num_commands);
        end
    end
    
    // Initialize completion data
    initial begin
        for (int i = 0; i < 100; i++) begin
            nvme_cpl_data = 128'h0;  // Initialize to known value
        end
    end
    
    // Initialize latency tracking arrays
    initial begin
        for (int i = 0; i < 100; i++) begin
            command_start_time[i] = 0;
            command_end_time[i] = 0;
            command_latency[i] = 0;
            latencies_sorted[i] = 0;
        end
        latency_count = 0;
    end
    
    // Test sequence - now dynamic based on num_commands
    initial begin
        reset_n = 0;
        cmd_valid = 0;
        nvme_cmd_ready = 0;
        nvme_cpl_valid = 0;
        command_index = 0;
        completions_received = 0;
        
        // Initialize debug tracking
        prev_blk_state = 0;
        prev_blk_fifo_count = 0;
        prev_nvme_state = 0;
        prev_nvme_srb_fifo_count = 0;
        
        // Apply reset
        #100 reset_n = 1;
        
        // Wait for initialization
        #200;
        
        $display("=== Starting Command Processing ===");
        $display("Number of commands to process: %0d", num_commands);
        $display("Block Layer States: 0=IDLE, 1=FETCH_IRP, 2=PARSE_IRP, 3=BUILD_MDL, 4=WAIT_MDL, 5=BUILD_SRB, 6=QUEUE_SRB, 7=COMPLETE");
        $display("NVMe States: 0=IDLE, 1=FETCH_SRB, 2=PARSE_SRB, 3=ALLOC_PRP, 4=WAIT_PRP, 5=BUILD_CMD, 6=SELECT_QUEUE, 7=SUBMIT_CMD, 8=WAIT_COMPLETION");
        $display("");
        
        // Send test commands
        if (num_commands == 0) begin
            $display("ERROR: No commands to process!");
            $finish;
        end
        
        for (command_index = 0; command_index < num_commands; command_index = command_index + 1) begin
            @(posedge clk);
            cmd_valid = 1;
            cmd_data = test_commands[command_index];
            
            // Record start time for latency tracking
            command_start_time[command_index] = stat_total_cycles;
            $display("Time %0t: Recording start time for command %0d at cycle %0d", 
                     $time, command_index, stat_total_cycles);
            
            // Wait for ready signal
            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 0;
            
            $display("Time %0t: Sent command %0d/%0d - %s LBA=%0d, Size=%0d bytes", 
                     $time, command_index+1, num_commands,
                     (test_commands[command_index][0] ? "WRITE" : "READ"),
                     test_commands[command_index][63:32],
                     test_commands[command_index][95:64]);
            
            // Small delay between commands
            repeat(10) @(posedge clk);
        end
        
        $display("\n=== All %0d commands sent, monitoring pipeline ===", num_commands);
        
        // Monitor pipeline activity with debug outputs
        fork
            // Debug monitor for block layer
            begin : debug_blk_monitor
                forever begin
                    @(posedge clk);
                    if (reset_n) begin
                        if (prev_blk_state !== debug_blk_state || prev_blk_fifo_count !== debug_blk_fifo_count) begin
                            $display("Time %0t: BLOCK LAYER - State=%0d, IRP FIFO=%0d, SRB FIFO=%0d, Current IRP ID=%0d",
                                     $time, debug_blk_state, debug_blk_fifo_count, 
                                     debug_blk_srb_fifo_count, debug_blk_current_irp_id);
                            prev_blk_state <= debug_blk_state;
                            prev_blk_fifo_count <= debug_blk_fifo_count;
                        end
                    end
                end
            end
            
            // Debug monitor for NVMe driver
            begin : debug_nvme_monitor
                forever begin
                    @(posedge clk);
                    if (reset_n) begin
                        if (prev_nvme_state !== debug_nvme_state || prev_nvme_srb_fifo_count !== debug_nvme_srb_fifo_count) begin
                            //$display("Time %0t: NVMe DRIVER - State=%0d, SRB FIFO=%0d, CPL FIFO=%0d, Queue Sum=%0d",
                            //         $time, debug_nvme_state, debug_nvme_srb_fifo_count,
                            //         debug_nvme_cpl_fifo_count, debug_nvme_queue_counts_sum);
                            //prev_nvme_state <= debug_nvme_state;
                            //prev_nvme_srb_fifo_count <= debug_nvme_srb_fifo_count;
                        end
                    end
                end
            end
            
            // Monitor IRP creation
            begin : irp_monitor
                automatic integer irp_count = 0;
                forever begin
                    @(posedge clk);
                    if (stat_irps_created > irp_count) begin
                        irp_count = stat_irps_created;
                        $display("Time %0t: STATS - IRP created (%0d total, expected %0d)", $time, irp_count, num_commands);
                    end
                end
            end
            
            // Monitor SRB creation
            begin : srb_monitor
                automatic integer srb_count = 0;
                forever begin
                    @(posedge clk);
                    if (stat_srbs_created > srb_count) begin
                        srb_count = stat_srbs_created;
                        $display("Time %0t: STATS - SRB created (%0d total, expected %0d)", $time, srb_count, num_commands);
                    end
                end
            end
            
            // Monitor NVMe commands
            begin : nvme_monitor
                automatic integer nvme_cmd_count = 0;
                forever begin
                    @(posedge clk);
                    if (stat_nvme_cmds_issued > nvme_cmd_count) begin
                        nvme_cmd_count = stat_nvme_cmds_issued;
                        $display("Time %0t: STATS - NVMe command issued (%0d total, expected %0d)", $time, nvme_cmd_count, num_commands);
                    end
                end
            end
            
            // Simple NVMe completion handler
            begin : nvme_handler
                automatic integer cmd_counter = 0;
                automatic logic [15:0] last_cmd_id = 0;
                static reg [2:0] delay_counter = 0;
                automatic reg sending_completion = 0;
                
                forever begin
                    @(posedge clk);
                    
                    if (nvme_cmd_valid && !sending_completion) begin
                        // Accept the command
                        nvme_cmd_ready = 1;
                        cmd_counter = cmd_counter + 1;
                        
                        // Extract command ID - NVMe command format:
                        // Byte 0: opcode, Byte 1: flags, Bytes 2-3: command_id
                        last_cmd_id = nvme_cmd_data[31:16];
                        
                        $display("Time %0t: NVMe - Accepting command %0d/%0d with ID %0d", 
                                $time, cmd_counter, num_commands, last_cmd_id);
                        
                        // Start completion process
                        sending_completion = 1;
                        delay_counter = 0;
                        
                        @(posedge clk);
                        nvme_cmd_ready = 0;
                    end
                    
                    // Generate completion after delay
                    if (sending_completion) begin
                        if (delay_counter < 3) begin
                            delay_counter <= delay_counter + 1;
                        end else begin
                            // Send completion
                            nvme_cpl_valid = 1;
                            // Completion format: [111:96] = command_id, [127:112] = status
                            nvme_cpl_data = 128'b0;
                            nvme_cpl_data[111:96] = last_cmd_id;
                            nvme_cpl_data[127:112] = 16'h0000;  // Success
                            
                            $display("Time %0t: NVMe - Sending completion for command ID %0d", 
                                    $time, last_cmd_id);
                            
                            @(posedge clk);
                            nvme_cpl_valid = 0;
                            sending_completion = 0;
                        end
                    end
                end
            end
            
            // Monitor completions - now dynamic based on num_commands
            begin : completion_monitor
                automatic integer expected_completions = num_commands;
                automatic integer last_completion_count = 0;
                
                $display("Waiting for %0d completions...", expected_completions);
                
                while (completions_received < expected_completions) begin
                    @(posedge clk);
                    
                    if (stat_nvme_cpls_received > last_completion_count) begin
                        completions_received = completions_received + (stat_nvme_cpls_received - last_completion_count);
                        last_completion_count = stat_nvme_cpls_received;
                        $display("Time %0t: COMPLETION %0d/%0d - Detected via stat_nvme_cpls_received=%0d", 
                            $time, completions_received, expected_completions, stat_nvme_cpls_received);
                    end
                    
                    // Add a simple timeout check
                    if ($time > 2000000 && completions_received == 0) begin  // 2ms timeout
                        $display("ERROR: No completions detected by time %0t", $time);
                        $display("Checking pipeline state:");
                        $display("  stat_nvme_cpls_received = %0d", stat_nvme_cpls_received);
                        $display("  NVMe Driver State: %0d", debug_nvme_state);
                        print_final_statistics();
                        $finish;
                    end
                end
                
                if (completions_received >= expected_completions) begin
                    $display("\n=== All %0d commands completed successfully ===", num_commands);
                    
                    // Calculate and display latency statistics
                    //calculate_latency_statistics();
                    
                    #1000;
                    print_final_statistics();
                    write_final_statistics_to_file();
                    $finish;
                end
            end
            
            // Timeout - scale with number of commands
            begin : timeout
                #(1000000 + num_commands * 100000);  // Scale timeout with command count
                $display("\n=== SIMULATION TIMEOUT ===");
                $display("Pipeline stuck. Current debug states:");
                $display("  Block Layer: State=%0d, IRP FIFO=%0d, SRB FIFO=%0d", 
                         debug_blk_state, debug_blk_fifo_count, debug_blk_srb_fifo_count);
                $display("  NVMe Driver: State=%0d, SRB FIFO=%0d, Queue Sum=%0d",
                         debug_nvme_state, debug_nvme_srb_fifo_count, debug_nvme_queue_counts_sum);
                $display("\nCurrent statistics:");
                $display("  Commands sent: %0d", num_commands);
                $display("  IRPs: %0d, SRBs: %0d, NVMe Cmds: %0d, Completions: %0d",
                         stat_irps_created, stat_srbs_created, 
                         stat_nvme_cmds_issued, stat_nvme_cpls_received);
                print_final_statistics();
                write_final_statistics_to_file();
                $finish;
            end
        join_any
        
        // Stop all monitors
        disable fork;
    end
    
    // Monitor IRP IDs dynamically
    initial begin
        automatic integer expected_irp_ids[0:99];  // Up to 100 commands
        automatic integer irp_index = 0;
        
        // Initialize expected IRP IDs based on num_commands
        for (integer i = 0; i < num_commands; i = i + 1) begin
            expected_irp_ids[i] = i;
        end
        
        forever begin
            @(posedge clk);
            
            // Check IRP creation
            if (debug_blk_state == 1) begin  // BL_FETCH_IRP
                if (irp_index < num_commands) begin
                    $display("Time %0t: Block layer fetching IRP, debug_irp_id=%0d, expected=%0d",
                            $time, debug_blk_current_irp_id, expected_irp_ids[irp_index]);
                    //if (debug_blk_current_irp_id != expected_irp_ids[irp_index]) begin
                    //    $display("ERROR: IRP ID mismatch! Expected %0d, got %0d",
                    //            expected_irp_ids[irp_index], debug_blk_current_irp_id);
                    //end
                    irp_index = irp_index + 1;
                end
            end
            
            // Check completion and record end time
            if (completion_valid) begin
                // Record end time for latency calculation
                if (completion_irp_id < num_commands) begin
                    command_end_time[completion_irp_id] = stat_total_cycles;
                    $display("Time %0t: Completion received for IRP %0d, status=%s, end_time=%0d",
                            $time, completion_irp_id,
                            (completion_status == 0 ? "SUCCESS" : "ERROR"),
                            stat_total_cycles);
                end
            end
        end
    end
    
    // Function to calculate latency statistics
    function void calculate_latency_statistics();
        automatic integer i, j;
        automatic integer temp_latency;
        automatic integer p95_index, p99_index;
        automatic integer valid_latencies = 0;
        automatic integer total_latency = 0;
        
        $display("\n=== LATENCY STATISTICS CALCULATION ===");
        
        // Calculate latencies and count valid ones
        for (i = 0; i < num_commands; i = i + 1) begin
            if (command_start_time[i] > 0 && command_end_time[i] > 0) begin
                if (command_end_time[i] >= command_start_time[i]) begin
                    command_latency[i] = command_end_time[i] - command_start_time[i];
                end else begin
                    // Handle wrap-around
                    command_latency[i] = (64'hFFFFFFFFFFFFFFFF - command_start_time[i]) + command_end_time[i] + 1;
                end
                latencies_sorted[valid_latencies] = command_latency[i];
                valid_latencies = valid_latencies + 1;
                $display("  Command %0d: Start=%0d, End=%0d, Latency=%0d cycles", 
                        i, command_start_time[i], command_end_time[i], command_latency[i]);
            end
        end
        
        if (valid_latencies > 0) begin
            // Sort latencies (bubble sort for simplicity)
            for (i = 0; i < valid_latencies - 1; i = i + 1) begin
                for (j = 0; j < valid_latencies - i - 1; j = j + 1) begin
                    if (latencies_sorted[j] > latencies_sorted[j + 1]) begin
                        temp_latency = latencies_sorted[j];
                        latencies_sorted[j] = latencies_sorted[j + 1];
                        latencies_sorted[j + 1] = temp_latency;
                    end
                end
            end
            
            // Calculate percentiles
            p95_index = (valid_latencies * 95 + 99) / 100; // Round up
            p99_index = (valid_latencies * 99 + 99) / 100; // Round up
            
            // Ensure indices are within bounds
            if (p95_index >= valid_latencies) p95_index = valid_latencies - 1;
            if (p99_index >= valid_latencies) p99_index = valid_latencies - 1;
            
            $display("\n  Total commands with latency data: %0d", valid_latencies);
            $display("  p95 latency: %0d cycles (index %0d)", latencies_sorted[p95_index], p95_index);
            $display("  p99 latency: %0d cycles (index %0d)", latencies_sorted[p99_index], p99_index);
            $display("  Min latency: %0d cycles", latencies_sorted[0]);
            $display("  Max latency: %0d cycles", latencies_sorted[valid_latencies-1]);
            
            // Calculate average
            for (i = 0; i < valid_latencies; i = i + 1) begin
                total_latency = total_latency + latencies_sorted[i];
            end
            $display("  Average latency: %0.1f cycles", real'(total_latency) / real'(valid_latencies));
        end else begin
            $display("  No latency data available!");
        end
        $display("=======================================\n");
    endfunction
    
    // Function to print final statistics
    function void print_final_statistics();
        real bytes_per_cycle;
        real estimated_iops;
        real efficiency;
        real cycles_per_command;
        real bytes_per_command;
        real actual_throughput_cycles;
        real actual_throughput_seconds;
        
        $display("\n=== FINAL WINDOWS STORAGE STACK STATISTICS ===");
        $display("Simulation Time: %0t ns", $time);
        $display("Number of Commands Processed: %0d (expected %0d)", stat_total_commands, num_commands);
        $display("Total Clock Cycles: %0d", stat_total_cycles);
        $display("Total Bytes: %0d", stat_total_bytes);
        $display("  Read Commands: %0d", stat_read_count);
        $display("  Write Commands: %0d", stat_write_count);
        $display("Maximum Queue Depth: %0d", stat_max_queue_depth);
        $display("\nPipeline Statistics:");
        $display("  IRPs Created: %0d (expected %0d)", stat_irps_created, num_commands);
        $display("  SRBs Created: %0d (expected %0d)", stat_srbs_created, num_commands);
        $display("  NVMe Commands Issued: %0d (expected %0d)", stat_nvme_cmds_issued, num_commands);
        $display("  NVMe Completions Received: %0d (expected %0d)", stat_nvme_cpls_received, num_commands);
        
        $display("\n=== LATENCY STATISTICS ===");
        $display("  Commands with Latency Data: %0d", stat_commands_with_latency);
        $display("  Minimum Latency: %0d cycles", stat_min_latency);
        $display("  Maximum Latency: %0d cycles", stat_max_latency);
        $display("  Average Latency: %0d cycles", stat_avg_latency);
        $display("  95th Percentile (p95): %0d cycles", stat_p95_latency);
        $display("  99th Percentile (p99): %0d cycles", stat_p99_latency);
        
        // Calculate throughput
        if (stat_total_cycles > 0 && stat_total_bytes > 0 && stat_total_commands > 0) begin
            bytes_per_cycle = real'(stat_total_bytes) / real'(stat_total_cycles);
            cycles_per_command = real'(stat_total_cycles) / real'(stat_total_commands);
            bytes_per_command = real'(stat_total_bytes) / real'(stat_total_commands);
            actual_throughput_cycles = real'(stat_total_bytes) / real'(stat_total_cycles);
            actual_throughput_seconds = real'(actual_throughput_cycles) * real'(100_000_000.0);
            
            // Efficiency calculation
            efficiency = (stat_total_bytes / (64.0*stat_total_cycles*8.0)) * 100.0;
            
            $display("\n=== PERFORMANCE METRICS ===");
            $display("  Bytes per Cycle: %0.4f", bytes_per_cycle);
            $display("  Efficiency: %0.2f%%", efficiency);
            
            // Estimate IOPS at 100MHz
            estimated_iops = (real'(stat_total_commands) / real'(stat_total_cycles)) * 100_000_000.0;
            $display("  Estimated IOPS @100MHz: %0.0f", estimated_iops);
            $display("  Average Cycles per Command: %0.1f", cycles_per_command);
            $display("  Average Bytes per Command: %0.1f", bytes_per_command);
            $display("  Average Throughput GB/s: %0.1f", actual_throughput_seconds/1_000_000_000.0);
            
            // Calculate average latency in microseconds (assuming 100MHz clock)
            if (stat_avg_latency > 0) begin
                automatic real avg_latency_us = real'(stat_avg_latency) / 100.0; // Convert cycles to us at 100MHz
                automatic real p95_latency_us = real'(stat_p95_latency) / 100.0;
                automatic real p99_latency_us = real'(stat_p99_latency) / 100.0;
                $display("\n=== LATENCY IN REAL TIME ===");
                $display("  Average Latency: %0.2f us", avg_latency_us);
                $display("  p95 Latency: %0.2f us", p95_latency_us);
                $display("  p99 Latency: %0.2f us", p99_latency_us);
            end
            
            // Check completion status
            if (stat_nvme_cpls_received == num_commands) begin
                $display("\n  SUCCESS: All %0d commands completed successfully!", num_commands);
            end else begin
                $display("\n  WARNING: Only %0d/%0d commands completed", stat_nvme_cpls_received, num_commands);
            end
        end
        $display("================================================\n");
    endfunction
    
    // Function to write final statistics to file
    function void write_final_statistics_to_file();
        integer output_file;
        real bytes_per_cycle;
        real estimated_iops;
        real cycles_per_command;
        real bytes_per_command;
        real actual_throughput_cycles;
        real actual_throughput_seconds;
        real efficiency;
        real avg_latency_us, p95_latency_us, p99_latency_us;
        
        output_file = $fopen("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track_B/Outputs/hardware_output.txt", "w");
        if (output_file == 0) begin
            $display("ERROR: Could not open hardware_output.txt for writing");
            return;
        end
        
        // Calculate performance metrics if we have data
        if (stat_total_cycles > 0 && stat_total_bytes > 0 && stat_total_commands > 0) begin
            bytes_per_cycle = real'(stat_total_bytes) / real'(stat_total_cycles);
            cycles_per_command = real'(stat_total_cycles) / real'(stat_total_commands);
            bytes_per_command = real'(stat_total_bytes) / real'(stat_total_commands);
            actual_throughput_cycles = real'(stat_total_bytes) / real'(stat_total_cycles);
            actual_throughput_seconds = real'(actual_throughput_cycles) * real'(100_000_000.0);
            efficiency = (stat_total_bytes / (64.0*stat_total_cycles*8.0)) * 100.0;
            estimated_iops = (real'(stat_total_commands) / real'(stat_total_cycles)) * 100_000_000.0;
            
            // Calculate latency in microseconds
            avg_latency_us = real'(stat_avg_latency) / 100.0;
            p95_latency_us = real'(stat_p95_latency) / 100.0;
            p99_latency_us = real'(stat_p99_latency) / 100.0;
        end
        
        $fdisplay(output_file, "========================================================================");
        $fdisplay(output_file, "WINDOWS STORAGE STACK - HARDWARE SIMULATION RESULTS");
        $fdisplay(output_file, "========================================================================");
        $fdisplay(output_file, "Timestamp: %0t ns", $time);
        $fdisplay(output_file, "");
        $fdisplay(output_file, "1. COMMAND STATISTICS");
        $fdisplay(output_file, "   Total Commands Processed: %0d", stat_total_commands);
        $fdisplay(output_file, "   Commands from Input File: %0d", num_commands);
        $fdisplay(output_file, "   Read Commands:  %0d", stat_read_count);
        $fdisplay(output_file, "   Write Commands: %0d", stat_write_count);
        $fdisplay(output_file, "   Total Bytes:    %0d", stat_total_bytes);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "2. PIPELINE STATISTICS");
        $fdisplay(output_file, "   IRPs Created:              %0d", stat_irps_created);
        $fdisplay(output_file, "   SRBs Created:              %0d", stat_srbs_created);
        $fdisplay(output_file, "   NVMe Commands Issued:      %0d", stat_nvme_cmds_issued);
        $fdisplay(output_file, "   NVMe Completions Received: %0d", stat_nvme_cpls_received);
        $fdisplay(output_file, "   Max Queue Depth:           %0d", stat_max_queue_depth);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "3. LATENCY STATISTICS (CYCLES)");
        $fdisplay(output_file, "   Commands with Latency Data: %0d", stat_commands_with_latency);
        $fdisplay(output_file, "   Minimum Latency:            %0d cycles", stat_min_latency);
        $fdisplay(output_file, "   Maximum Latency:            %0d cycles", stat_max_latency);
        $fdisplay(output_file, "   Average Latency:            %0d cycles", stat_avg_latency);
        $fdisplay(output_file, "   95th Percentile (p95):      %0d cycles", stat_p95_latency);
        $fdisplay(output_file, "   99th Percentile (p99):      %0d cycles", stat_p99_latency);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "4. LATENCY STATISTICS (MICROSECONDS @100MHz)");
        $fdisplay(output_file, "   Average Latency:            %0.2f us", avg_latency_us);
        $fdisplay(output_file, "   95th Percentile (p95):      %0.2f us", p95_latency_us);
        $fdisplay(output_file, "   99th Percentile (p99):      %0.2f us", p99_latency_us);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "5. PERFORMANCE METRICS");
        $fdisplay(output_file, "   Total Clock Cycles:         %0d", stat_total_cycles);
        $fdisplay(output_file, "   Average Cycles per Command: %0.2f", cycles_per_command);
        $fdisplay(output_file, "   Average Bytes per Command:  %0.2f", bytes_per_command);
        $fdisplay(output_file, "   Bytes per Cycle:            %0.4f", bytes_per_cycle);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "6. THROUGHPUT ESTIMATES (100MHz Clock)");
        $fdisplay(output_file, "   Estimated IOPS:             %0.0f", estimated_iops);
        $fdisplay(output_file, "   Average Throughput:         %0.2f GB/s", actual_throughput_seconds/1_000_000_000.0);
        $fdisplay(output_file, "   System Efficiency:          %0.2f%%", efficiency);
        $fdisplay(output_file, "");
        
        $fdisplay(output_file, "7. COMPLETION STATUS");
        if (stat_nvme_cpls_received == num_commands) begin
            $fdisplay(output_file, "   SUCCESS: All %0d commands completed", num_commands);
        end else begin
            $fdisplay(output_file, "   WARNING: Only %0d/%0d commands completed", stat_nvme_cpls_received, num_commands);
        end
        $fdisplay(output_file, "");
        
        //$fdisplay(output_file, "8. DEBUG STATE INFORMATION");
        //$fdisplay(output_file, "   Block Layer State:          %0d", debug_blk_state);
        //$fdisplay(output_file, "   NVMe Driver State:          %0d", debug_nvme_state);
        //$fdisplay(output_file, "   Block IRP FIFO Count:       %0d", debug_blk_fifo_count);
        //$fdisplay(output_file, "   Block SRB FIFO Count:       %0d", debug_blk_srb_fifo_count);
        //$fdisplay(output_file, "   NVMe SRB FIFO Count:        %0d", debug_nvme_srb_fifo_count);
        //$fdisplay(output_file, "   NVMe CPL FIFO Count:        %0d", debug_nvme_cpl_fifo_count);
        //$fdisplay(output_file, "   NVMe Queue Counts Sum:      %0d", debug_nvme_queue_counts_sum);
        //$fdisplay(output_file, "========================================================================");
        
        $fclose(output_file);
        $display("Statistics written to hardware_output.txt");
    endfunction
    
endmodule*/