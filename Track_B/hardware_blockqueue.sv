// Testbench
// IO Chip Module - COMPLETELY REWRITTEN STATE MACHINE
// IO Chip Module - COMPLETELY REWRITTEN STATE MACHINE
module io_chip (
    input        clk,
    input        rst_n,
    // CPU Interface
    input        cpu_valid,
    output reg   cpu_ready,
    input  [7:0] cpu_opcode,
    input  [63:0] cpu_lba,
    input  [31:0] cpu_length,
    input  [63:0] cpu_data_in,
    output [63:0] cpu_data_out,
    output reg   cpu_data_valid,
    // SSD Controller Interface
    output reg   ssd_cmd_valid,
    input        ssd_cmd_ready,
    output [7:0]  ssd_opcode,
    output [63:0] ssd_lba,
    output [31:0] ssd_length,
    output [63:0] ssd_data,
    input         ssd_data_ready
);

    // Internal states - SIMPLIFIED
    parameter [2:0] IDLE = 0,
                    DECODE = 1,
                    SEND_TO_SSD = 2,
                    WAIT_SSD = 3,
                    COMPLETE = 4;

    reg [2:0] current_state, next_state;
    
    // Command buffer
    reg [7:0]  cmd_opcode;
    reg [63:0] cmd_lba;
    reg [31:0] cmd_length;
    reg [63:0] cmd_data;
    
    // Block processing variables
    parameter BLOCK_SIZE = 4096;
    
    reg [31:0] bytes_remaining;
    reg [63:0] current_lba;
    reg [31:0] current_transfer_size;
    reg        is_write_op;
    
    // FIFO for command queuing
    reg [7:0]  fifo_opcode [0:7];
    reg [63:0] fifo_lba [0:7];
    reg [31:0] fifo_length [0:7];
    reg [63:0] fifo_data [0:7];
    
    reg [2:0] fifo_head, fifo_tail;
    reg [2:0] fifo_count;
    wire      fifo_full, fifo_empty;
    
    // Performance counters
    reg [31:0] total_cycles;
    reg [31:0] commands_processed;
    reg        measuring;
    
    // FIFO status
    assign fifo_empty = (fifo_count == 0);
    assign fifo_full = (fifo_count == 7);
    
    // Main state machine - COMBINATIONAL
    always @(*) begin
        // Default values
        next_state = current_state;
        cpu_ready = 1'b0;
        ssd_cmd_valid = 1'b0;
        cpu_data_valid = 1'b0;
        
        case (current_state)
            IDLE: begin
                cpu_ready = !fifo_full;
                if (!fifo_empty) begin
                    next_state = DECODE;
                end
            end
            
            DECODE: begin
                next_state = SEND_TO_SSD;
            end
            
            SEND_TO_SSD: begin
                if (bytes_remaining > 0) begin
                    ssd_cmd_valid = 1'b1;
                    if (ssd_cmd_ready) begin
                        next_state = WAIT_SSD;
                    end
                end else begin
                    next_state = COMPLETE;
                end
            end
            
            WAIT_SSD: begin
                if (ssd_data_ready) begin
                    if (bytes_remaining > 0) begin
                        next_state = SEND_TO_SSD;
                    end else begin
                        next_state = COMPLETE;
                    end
                end
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
        endcase
    end
    
    // Sequential logic - ALL UPDATES IN ONE PLACE
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
            fifo_head <= 0;
            fifo_tail <= 0;
            fifo_count <= 0;
            total_cycles <= 0;
            commands_processed <= 0;
            measuring <= 0;
            
            // Initialize outputs
            cpu_ready <= 1;
            cpu_data_valid <= 0;
            ssd_cmd_valid <= 0;
            bytes_remaining <= 0;
            current_lba <= 0;
            current_transfer_size <= 0;
            is_write_op <= 0;
            
            // Initialize command buffer
            cmd_opcode <= 0;
            cmd_lba <= 0;
            cmd_length <= 0;
            cmd_data <= 0;
        end else begin
            current_state <= next_state;
            
            // Count cycles during measurement
            if (measuring) begin
                total_cycles <= total_cycles + 1;
            end
            
            // Handle state transitions and updates
            case (current_state)
                IDLE: begin
                    // Accept new commands into FIFO
                    if (cpu_valid && cpu_ready && !fifo_full) begin
                        fifo_opcode[fifo_tail] <= cpu_opcode;
                        fifo_lba[fifo_tail] <= cpu_lba;
                        fifo_length[fifo_tail] <= cpu_length;
                        fifo_data[fifo_tail] <= cpu_data_in;
                        fifo_tail <= fifo_tail + 1;
                        fifo_count <= fifo_count + 1;
                        $display("Time %0t: DUT accepted command %0d into FIFO", 
                                 $time, fifo_count + 1);
                        
                        if (!measuring) begin
                            measuring <= 1;
                        end
                    end
                end
                
                DECODE: begin
                    // Load command from FIFO and initialize processing
                    cmd_opcode <= fifo_opcode[fifo_head];
                    cmd_lba <= fifo_lba[fifo_head];
                    cmd_length <= fifo_length[fifo_head];
                    cmd_data <= fifo_data[fifo_head];
                    bytes_remaining <= fifo_length[fifo_head];
                    current_lba <= fifo_lba[fifo_head];
                    is_write_op <= (fifo_opcode[fifo_head] == 1);
                    current_transfer_size <= 0;
                    
                    $display("Time %0t: DUT decoding command: op=%0d, lba=%0d, len=%0d", 
                             $time, fifo_opcode[fifo_head], fifo_lba[fifo_head], fifo_length[fifo_head]);
                end
                
                SEND_TO_SSD: begin
                    // Calculate transfer size for current block
                    if (bytes_remaining > 0) begin
                        reg [31:0] offset_in_block;
                        reg [31:0] space_in_block;
                        reg [31:0] transfer_size;
                        
                        offset_in_block = current_lba % BLOCK_SIZE;
                        space_in_block = BLOCK_SIZE - offset_in_block;
                        
                        if (bytes_remaining <= space_in_block) begin
                            transfer_size = bytes_remaining;
                        end else begin
                            transfer_size = space_in_block;
                        end
                        
                        current_transfer_size <= transfer_size;
                        
                        if (ssd_cmd_valid && ssd_cmd_ready) begin
                            $display("Time %0t: DUT sending to SSD: lba=%0d, len=%0d, remaining=%0d", 
                                     $time, current_lba, transfer_size, bytes_remaining - transfer_size);
                        end
                    end
                end
                
                WAIT_SSD: begin
                    // Update state after SSD completes transfer
                    if (ssd_data_ready) begin
                        // SAFETY CHECK: Only update if we have a valid transfer size
                        if (current_transfer_size > 0 && bytes_remaining >= current_transfer_size) begin
                            bytes_remaining <= bytes_remaining - current_transfer_size;
                            current_lba <= current_lba + current_transfer_size;
                            current_transfer_size <= 0; // Reset for next transfer
                            
                            if (bytes_remaining == current_transfer_size) begin
                                $display("Time %0t: Last block transfer completed", $time);
                            
                            end else if (current_transfer_size > bytes_remaining) begin
                            $display("Time %0t: ERROR: Transfer size %0d > remaining %0d", 
                                     $time, current_transfer_size, bytes_remaining);
                            bytes_remaining <= 0; // Force completion
                            end
                        end
                    end
                end
                
                COMPLETE: begin
                    // Command completed
                    commands_processed <= commands_processed + 1;
                    fifo_head <= fifo_head + 1;
                    fifo_count <= fifo_count - 1;
                    $display("Time %0t: DUT completed command %0d", 
                             $time, commands_processed + 1);
                end
            endcase
        end
    end
    
    // SSD interface assignments
    assign ssd_opcode = cmd_opcode;
    assign ssd_lba = current_lba;
    assign ssd_length = current_transfer_size;
    assign ssd_data = cmd_data;
    
    // Simple data path for reads
    assign cpu_data_out = ssd_data;

endmodule

// Testbench - SIMPLIFIED AND WORKING
// Testbench - WITH ERROR DETECTION
// Testbench - FIXED CYCLE COUNTING AND THROUGHPUT
module tb_io_chip;

    reg        clk;
    reg        rst_n;
    // CPU Interface
    reg        cpu_valid;
    wire       cpu_ready;
    reg [7:0]  cpu_opcode;
    reg [63:0] cpu_lba;
    reg [31:0] cpu_length;
    reg [63:0] cpu_data_in;
    wire [63:0] cpu_data_out;
    wire        cpu_data_valid;
    // SSD Controller Interface
    wire        ssd_cmd_valid;
    reg         ssd_cmd_ready;
    wire [7:0]  ssd_opcode;
    wire [63:0] ssd_lba;
    wire [31:0] ssd_length;
    wire [63:0] ssd_data;
    reg         ssd_data_ready;

    // Performance monitoring
    integer total_clock_cycles;
    reg        simulation_done;
    
    // Command storage
    reg [7:0]  cmd_opcode [0:99];
    reg [63:0] cmd_lba [0:99];
    reg [31:0] cmd_length [0:99];
    reg [63:0] cmd_data [0:99];
    integer command_count;
    integer commands_sent;
    integer total_commands_to_process;
    
    // Debug counters
    integer ssd_commands_processed;
    integer error_count;
    
    // Clock generation
    always #5 clk = ~clk;
    
    // Cycle counter - FIXED: Use integer and proper initialization
    initial begin
        total_clock_cycles = 0;
        forever begin
            @(posedge clk);
            if (!simulation_done) begin
                total_clock_cycles = total_clock_cycles + 1;
            end
        end
    end
    
    // Instantiate IO Chip
    io_chip dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_valid(cpu_valid),
        .cpu_ready(cpu_ready),
        .cpu_opcode(cpu_opcode),
        .cpu_lba(cpu_lba),
        .cpu_length(cpu_length),
        .cpu_data_in(cpu_data_in),
        .cpu_data_out(cpu_data_out),
        .cpu_data_valid(cpu_data_valid),
        .ssd_cmd_valid(ssd_cmd_valid),
        .ssd_cmd_ready(ssd_cmd_ready),
        .ssd_opcode(ssd_opcode),
        .ssd_lba(ssd_lba),
        .ssd_length(ssd_length),
        .ssd_data(ssd_data),
        .ssd_data_ready(ssd_data_ready)
    );
    
    // Initialize test
    initial begin
        // Initialize signals
        clk = 0;
        rst_n = 0;
        cpu_valid = 0;
        ssd_cmd_ready = 1;
        ssd_data_ready = 0;
        simulation_done = 0;
        commands_sent = 0;
        command_count = 0;
        ssd_commands_processed = 0;
        error_count = 0;
        
        // Initialize command arrays
        begin : init_arrays
            integer i;
            for (i = 0; i < 100; i = i + 1) begin
                cmd_opcode[i] = 0;
                cmd_lba[i] = 0;
                cmd_length[i] = 0;
                cmd_data[i] = 0;
            end
        end
        
        // Reset sequence
        #20;
        rst_n = 1;
        #10;
        
        // Read commands from file
        $display("Reading commands from input file...");
        read_commands_from_file("C:/Users/samsa/OneDrive/Desktop/Advance Computer Systems/ACS_Independent_Project/Track B/cpu_commands.txt");
        total_commands_to_process = command_count;
        $display("Will process %0d commands", total_commands_to_process);
        
        // Start simulation tasks
        fork
            send_commands();
            simulate_ssd();
            monitor_simulation();
            emergency_timeout();
        join
    end
    
    // Task to read commands from file
    task read_commands_from_file;
        input [2000:0] filename;
        integer file;
        integer scan_count;
        integer temp_opcode;
        integer temp_lba;
        integer temp_length;
        longint temp_data;
        
        begin
            file = $fopen(filename, "r");
            if (file == 0) begin
                $display("Error: Could not open file %s", filename);
                $finish;
            end
            
            command_count = 0;
            while (!$feof(file) && command_count < 100) begin
                scan_count = $fscanf(file, "%d %d %d %h", 
                                   temp_opcode, temp_lba, temp_length, temp_data);
                if (scan_count == 4) begin
                    cmd_opcode[command_count] = temp_opcode;
                    cmd_lba[command_count] = temp_lba;
                    cmd_length[command_count] = temp_length;
                    cmd_data[command_count] = temp_data;
                    $display("Read command: op=%0d, lba=%0d, len=%0d, data=0x%0h", 
                             temp_opcode, temp_lba, temp_length, temp_data);
                    command_count = command_count + 1;
                end
            end
            
            $fclose(file);
            $display("Read %0d commands from file", command_count);
        end
    endtask
    
    // Task to send commands
    task send_commands;
        integer i;
        
        begin
            for (i = 0; i < command_count; i = i + 1) begin
                // Wait for DUT to be ready
                wait(cpu_ready == 1);
                @(posedge clk);
                
                // Send command
                cpu_valid = 1;
                cpu_opcode = cmd_opcode[i];
                cpu_lba = cmd_lba[i];
                cpu_length = cmd_length[i];
                cpu_data_in = cmd_data[i];
                
                @(posedge clk);
                cpu_valid = 0;
                commands_sent = commands_sent + 1;
                
                $display("Time %0t: Sent command %0d: op=%0d, lba=%0d, len=%0d", 
                         $time, commands_sent, cmd_opcode[i], cmd_lba[i], cmd_length[i]);
                
                // Wait a bit before next command
                #20;
            end
            
            $display("Time %0t: All %0d commands sent", $time, commands_sent);
        end
    endtask
    
    // Task to simulate SSD - FIXED: Proper timing and length handling
    task simulate_ssd;
        begin
            forever begin
                @(posedge clk);
                
                // Always ready to accept commands
                ssd_cmd_ready = 1;
                
                // When command is valid, process it after a delay
                if (ssd_cmd_valid && ssd_cmd_ready) begin
                    ssd_commands_processed = ssd_commands_processed + 1;
                    $display("Time %0t: SSD processing command %0d - op=%0d, lba=%0d, len=%0d", 
                             $time, ssd_commands_processed, ssd_opcode, ssd_lba, ssd_length);
                    
                    // Wait 2 cycles then acknowledge
                    repeat(2) @(posedge clk);
                    
                    ssd_data_ready = 1;
                    @(posedge clk);
                    ssd_data_ready = 0;
                    
                    $display("Time %0t: SSD completed command %0d", $time, ssd_commands_processed);
                end
            end
        end
    endtask
    
    // Monitor simulation progress - FIXED: Proper completion detection
    task monitor_simulation;
        begin
            // Wait for all commands to be sent
            wait(commands_sent == total_commands_to_process);
            $display("Time %0t: All commands sent, waiting for DUT to complete...", $time);
            
            // Wait for DUT to process all commands
            wait(dut.commands_processed == total_commands_to_process);
            
            // Small delay to ensure all cycles are counted
            #100;
            
            $display("\n=== HARDWARE IO CHIP PERFORMANCE RESULTS ===");
            $display("Total clock cycles: %0d", total_clock_cycles);
            $display("Total commands processed: %0d", dut.commands_processed);
            $display("SSD commands processed: %0d", ssd_commands_processed);
            
            if (dut.commands_processed > 0) begin
                $display("Average cycles per command: %0.1f", 
                         $itor(total_clock_cycles) / $itor(dut.commands_processed));
            end
            
            $display("Total bytes processed: %0d", calculate_total_bytes());
            
            if (total_clock_cycles > 0) begin
                $display("Throughput: %0.6f MB/cycle", 
                         $itor(calculate_total_bytes()) / (1024.0 * 1024.0) / $itor(total_clock_cycles));
                $display("Throughput: %0.2f bytes/cycle", 
                         $itor(calculate_total_bytes()) / $itor(total_clock_cycles));
            end else begin
                $display("ERROR: Total clock cycles is 0!");
            end
            
            simulation_done = 1;
            #100;
            $finish;
        end
    endtask
    
    // Emergency timeout
    task emergency_timeout;
        begin
            #50000; // 50,000 time units timeout
            if (!simulation_done) begin
                $display("Time %0t: EMERGENCY TIMEOUT - Simulation stuck!", $time);
                $display("Commands sent: %0d, DUT completed: %0d", commands_sent, dut.commands_processed);
                $display("Current state: %0d, Bytes remaining: %0d", dut.current_state, dut.bytes_remaining);
                $display("FIFO count: %0d, Total cycles: %0d", dut.fifo_count, total_clock_cycles);
                $finish;
            end
        end
    endtask
    
    // Calculate total bytes processed
    function integer calculate_total_bytes;
        integer total_bytes;
        integer i;
        
        begin
            total_bytes = 0;
            for (i = 0; i < command_count; i = i + 1) begin
                total_bytes = total_bytes + cmd_length[i];
            end
            calculate_total_bytes = total_bytes;
        end
    endfunction

endmodule