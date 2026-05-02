// ============================================================================
// Module: Enhanced Performance Statistics Collector with Latency Percentiles
// ============================================================================
module performance_statistics #(
    parameter CYCLE_COUNTER_WIDTH = 64,
    parameter MAX_COMMANDS = 1000,
    parameter LATENCY_HISTORY_DEPTH = 1024
)(
    input wire clk,
    input wire reset_n,
    
    // Command input tracking
    input wire command_received,
    input wire command_is_write,
    input wire [31:0] command_size_bytes,
    
    // Pipeline stage tracking
    input wire irp_created,
    input wire srb_created,
    input wire nvme_cmd_issued,
    input wire nvme_cpl_received,
    
    // Queue monitoring
    input wire [31:0] current_queue_depth,
    
    // Latency tracking – now uses in‑order FIFO instead of IDs
    input wire [15:0] command_id_received,      // unused, kept for compatibility
    input wire [15:0] command_id_completed,     // unused
    input wire latency_track_enable,
    
    // Statistics outputs
    output reg [63:0] total_cycles,
    output reg [63:0] total_commands,
    output reg [63:0] total_bytes,
    output reg [31:0] read_commands,
    output reg [31:0] write_commands,
    output reg [31:0] max_queue_depth,
    output reg [31:0] irps_created_count,
    output reg [31:0] srbs_created_count,
    output reg [31:0] nvme_cmds_issued_count,
    output reg [31:0] nvme_cpls_received_count,
    
    // Latency statistics
    output reg [31:0] min_latency_cycles,
    output reg [31:0] max_latency_cycles,
    output reg [63:0] total_latency_cycles,
    output reg [31:0] average_latency_cycles,
    output reg [31:0] p95_latency_cycles,
    output reg [31:0] p99_latency_cycles,
    output reg [31:0] commands_with_latency,
    output reg [63:0] iops,               // I/O operations per second
    output reg [63:0] avg_throughput_Bps   // Average bytes per second
);
    
    // Cycle counter
    reg [CYCLE_COUNTER_WIDTH-1:0] cycle_counter;
    
    // Queue depth tracking
    reg [31:0] current_depth;
    
    // In‑order start time FIFO
    reg [63:0] start_time_fifo [0:MAX_COMMANDS-1];
    reg [$clog2(MAX_COMMANDS)-1:0] fifo_wr_ptr, fifo_rd_ptr;
    reg [31:0] fifo_count;
    
    // Latency history for percentile calculation
    reg [31:0] command_latencies [0:LATENCY_HISTORY_DEPTH-1];
    reg [9:0] latency_write_ptr;
    reg [9:0] latency_read_ptr;
    
    // Temporary storage for percentile sorting
    reg [31:0] sorted_latencies [0:MAX_COMMANDS-1];
    reg [31:0] temp_latency;
    integer i, j;
    
    // Internal registers for percentile calculation
    reg [31:0] p95_index, p99_index;
    reg [31:0] latency_count;   // total number of valid latency samples
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            total_cycles <= 0;
            total_commands <= 0;
            total_bytes <= 0;
            read_commands <= 0;
            write_commands <= 0;
            max_queue_depth <= 0;
            irps_created_count <= 0;
            srbs_created_count <= 0;
            nvme_cmds_issued_count <= 0;
            nvme_cpls_received_count <= 0;
            cycle_counter <= 0;
            current_depth <= 0;
            
            // Initialize latency tracking
            min_latency_cycles <= 32'hFFFFFFFF;
            max_latency_cycles <= 0;
            total_latency_cycles <= 0;
            average_latency_cycles <= 0;
            p95_latency_cycles <= 0;
            p99_latency_cycles <= 0;
            commands_with_latency <= 0;
            latency_write_ptr <= 0;
            latency_read_ptr <= 0;
            latency_count <= 0;
            
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            fifo_count <= 0;
            
            // Initialize arrays
            for (i = 0; i < MAX_COMMANDS; i++) begin
                start_time_fifo[i] <= 0;
            end
            for (i = 0; i < LATENCY_HISTORY_DEPTH; i++) begin
                command_latencies[i] <= 0;
            end
            for (i = 0; i < MAX_COMMANDS; i++) begin
                sorted_latencies[i] <= 0;
            end
            
        end else begin
            // Count cycles
            cycle_counter <= cycle_counter + 1;
            total_cycles <= cycle_counter;

            if (cycle_counter > 0) begin
                iops <= (total_commands * 64'd1_000_000_000) / (cycle_counter * 10);
                avg_throughput_Bps <= (total_bytes * 64'd1_000_000_000) / (cycle_counter * 10);
            end
            
            // Track commands
            if (command_received) begin
                total_commands <= total_commands + 1;
                total_bytes <= total_bytes + command_size_bytes;
                if (command_is_write) begin
                    write_commands <= write_commands + 1;
                end else begin
                    read_commands <= read_commands + 1;
                end
                
                // Store start time in FIFO
                if (latency_track_enable && fifo_count < MAX_COMMANDS) begin
                    start_time_fifo[fifo_wr_ptr] <= cycle_counter;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    fifo_count <= fifo_count + 1;
                end
            end
            
            // Track pipeline stages
            if (irp_created) irps_created_count <= irps_created_count + 1;
            if (srb_created) srbs_created_count <= srbs_created_count + 1;
            if (nvme_cmd_issued) nvme_cmds_issued_count <= nvme_cmds_issued_count + 1;
            
            // Track completions and calculate latency using FIFO
            if (nvme_cpl_received && fifo_count > 0) begin
                // Read the oldest start time
                automatic reg [63:0] start_time = start_time_fifo[fifo_rd_ptr];
                automatic reg [63:0] end_time = cycle_counter;
                automatic reg [31:0] latency;

                nvme_cpls_received_count <= nvme_cpls_received_count + 1;
                
                
                
                // Calculate latency in cycles
                if (end_time >= start_time) begin
                    latency = end_time - start_time;
                end else begin
                    // Handle counter wrap-around
                    latency = (64'hFFFFFFFFFFFFFFFF - start_time) + end_time + 1;
                end
                
                // Advance FIFO read pointer
                fifo_rd_ptr <= fifo_rd_ptr + 1;
                fifo_count <= fifo_count - 1;
                
                // Store latency in history for percentile calculation
                if (latency_write_ptr < LATENCY_HISTORY_DEPTH) begin
                    command_latencies[latency_write_ptr] <= latency;
                    latency_write_ptr <= latency_write_ptr + 1;
                    latency_count <= latency_count + 1;
                    
                    // Update min/max
                    if (latency < min_latency_cycles) min_latency_cycles <= latency;
                    if (latency > max_latency_cycles) max_latency_cycles <= latency;
                    
                    // Update total for average
                    total_latency_cycles <= total_latency_cycles + latency;
                    
                    // Update average (use integer division)
                    if (latency_count > 0) begin
                        average_latency_cycles <= (total_latency_cycles + latency) / (latency_count + 1);
                    end else begin
                        average_latency_cycles <= latency;
                    end
                    
                    commands_with_latency <= latency_count + 1;
                end
                
                // Calculate percentiles periodically (every 64 completions or on every completion)
                if ((latency_count + 1) >= 10 && ((latency_count + 1) % 64 == 0 || nvme_cpl_received)) begin
                    calculate_percentiles();
                end
            end
            
            // Track queue depth
            current_depth <= current_queue_depth;
            if (current_depth > max_queue_depth) begin
                max_queue_depth <= current_depth;
            end
        end
    end
    
    // Task to calculate p95 and p99 percentiles
    task calculate_percentiles;
        automatic integer sorted_count = 0;
        automatic integer p95_pos, p99_pos;
        begin
            // Copy valid latencies to temporary array
            sorted_count = 0;
            for (i = 0; i < latency_write_ptr; i++) begin
                if (command_latencies[i] > 0) begin
                    sorted_latencies[sorted_count] = command_latencies[i];
                    sorted_count = sorted_count + 1;
                end
            end
            
            if (sorted_count > 0) begin
                // Simple bubble sort
                for (i = 0; i < sorted_count - 1; i++) begin
                    for (j = 0; j < sorted_count - i - 1; j++) begin
                        if (sorted_latencies[j] > sorted_latencies[j + 1]) begin
                            temp_latency = sorted_latencies[j];
                            sorted_latencies[j] = sorted_latencies[j + 1];
                            sorted_latencies[j + 1] = temp_latency;
                        end
                    end
                end
                
                // Calculate percentile indices (round up)
                p95_pos = (sorted_count * 95 + 99) / 100;
                p99_pos = (sorted_count * 99 + 99) / 100;
                
                // Ensure indices are within bounds
                if (p95_pos >= sorted_count) p95_pos = sorted_count - 1;
                if (p99_pos >= sorted_count) p99_pos = sorted_count - 1;
                
                // Set percentile values
                p95_latency_cycles <= sorted_latencies[p95_pos];
                p99_latency_cycles <= sorted_latencies[p99_pos];
            end
        end
    endtask
    
endmodule