// ============================================================================
// Updated Top Module with Debug Outputs and Latency Tracking
// ============================================================================
module windows_storage_stack_core #(
    parameter CMD_FIFO_DEPTH = 64,
    parameter NUM_IO_QUEUES = 8,
    parameter PRP_POOL_SIZE = 256
)(
    input wire clk,
    input wire reset_n,

    // Command Input Interface
    input wire        cmd_in_valid,
    input wire [127:0] cmd_in_data,
    output wire       cmd_in_ready,

    // Completion Output Interface
    output wire       completion_out_valid,
    output wire [31:0] completion_status,
    output wire [31:0] completion_info,

    // NVMe Physical Interface
    output wire        nvme_cmd_valid,
    output wire [511:0] nvme_cmd_data,
    input wire         nvme_cmd_ready,
    input wire         nvme_cpl_valid,
    input wire [127:0] nvme_cpl_data,
    output wire        nvme_cpl_ready,

    // Real Performance Statistics
    output wire [63:0] stat_total_cycles,
    output wire [63:0] stat_total_commands,
    output wire [63:0] stat_total_bytes,
    output wire [31:0] stat_read_count,
    output wire [31:0] stat_write_count,
    output wire [31:0] stat_max_queue_depth,
    output wire [31:0] stat_irps_created,
    output wire [31:0] stat_srbs_created,
    output wire [31:0] stat_nvme_cmds_issued,
    output wire [31:0] stat_nvme_cpls_received,
    output wire [63:0] stat_iops,
    output wire [63:0] stat_avg_throughput,

    // Latency Statistics
    output wire [31:0] stat_min_latency,
    output wire [31:0] stat_max_latency,
    output wire [31:0] stat_avg_latency,
    output wire [31:0] stat_p95_latency,
    output wire [31:0] stat_p99_latency,
    output wire [31:0] stat_commands_with_latency,

    // DEBUG OUTPUTS
    output wire [3:0]  debug_blk_state,
    output wire [31:0] debug_blk_fifo_count,
    output wire [31:0] debug_blk_srb_fifo_count,
    output wire [15:0] debug_blk_current_irp_id,
    output wire [3:0]  debug_nvme_state,
    output wire [31:0] debug_nvme_srb_fifo_count,
    output wire [31:0] debug_nvme_cpl_fifo_count,
    output wire [31:0] debug_nvme_queue_counts_sum,
    output wire [15:0] completion_irp_id_out
);

    // Internal interfaces
    wire [127:0] parsed_cmd_data;
    wire         parsed_cmd_valid;
    wire         parsed_cmd_ready;
    wire [511:0] irp_data;
    wire         irp_valid;
    wire         irp_ready;
    wire [1023:0] srb_data;
    wire         srb_valid;
    wire         srb_ready;
    wire [15:0]  completion_irp_id;
    wire         completion_int_valid;
    wire [31:0]  completion_int_status;
    wire [31:0]  completion_int_info;

    wire [31:0] block_layer_cycles;
    wire [31:0] irps_processed;

    wire [63:0] nvme_cmds_issued;
    wire [63:0] nvme_cpls_received;
    wire [31:0] nvme_queue_util;

    wire [63:0] total_irps_created;
    wire [31:0] active_irp_count;

    wire command_received;
    wire command_is_write;
    wire [31:0] command_size_bytes;
    wire irp_created;
    wire srb_created;
    wire nvme_cmd_issued;
    wire nvme_cpl_received;

    reg [15:0] command_id_counter;
    wire [15:0] current_command_id;
    wire latency_track_enable;

    assign parsed_cmd_valid = cmd_in_valid;
    assign parsed_cmd_data  = cmd_in_data;
    assign cmd_in_ready     = parsed_cmd_ready;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            command_id_counter <= 0;
        end else if (cmd_in_valid && cmd_in_ready) begin
            command_id_counter <= command_id_counter + 1;
        end
    end

    assign current_command_id   = command_id_counter;
    assign latency_track_enable = 1'b1;

    assign command_received  = parsed_cmd_valid && parsed_cmd_ready;
    assign command_is_write  = parsed_cmd_data[0];
    assign command_size_bytes = parsed_cmd_data[95:64];
    assign irp_created       = irp_valid && irp_ready;
    assign srb_created       = srb_valid && srb_ready;
    assign nvme_cmd_issued   = nvme_cmd_valid && nvme_cmd_ready;
    assign nvme_cpl_received = nvme_cpl_valid && nvme_cpl_ready;

    assign completion_irp_id_out = completion_irp_id;

    irp_manager #(
        .MAX_IRPS(256),
        .IRP_ID_WIDTH(8)
    ) irp_mgr (
        .clk(clk),
        .reset_n(reset_n),
        .command_valid(parsed_cmd_valid),
        .command_lba(parsed_cmd_data[63:32]),
        .command_size(parsed_cmd_data[95:64]),
        .command_data({32'h0, parsed_cmd_data[127:96]}),
        .command_is_write(parsed_cmd_data[0]),
        .command_ready(parsed_cmd_ready),
        .irp_valid(irp_valid),
        .irp_data(irp_data),
        .irp_ready(irp_ready),
        .completion_valid(completion_int_valid),
        .completion_irp_id(completion_irp_id),
        .completion_status(completion_int_status),
        .completion_information(completion_int_info),
        .total_irps_created(total_irps_created),
        .active_irp_count(active_irp_count)
    );

    block_layer_processor #(
        .QUEUE_DEPTH(64),
        .DATA_WIDTH(512)
    ) block_layer (
        .clk(clk),
        .reset_n(reset_n),
        .irp_in_valid(irp_valid),
        .irp_in_data(irp_data),
        .irp_in_ready(irp_ready),
        .srb_out_valid(srb_valid),
        .srb_out_data(srb_data),
        .srb_out_ready(srb_ready),
        .mdl_request_valid(),
        .mdl_buffer_addr(),
        .mdl_buffer_size(),
        .mdl_request_ready(1'b1),
        .mdl_complete_valid(1'b1),
        .mdl_physical_addr(64'h1000),
        .block_layer_cycles(block_layer_cycles),
        .irps_processed(irps_processed),
        .debug_state(debug_blk_state),
        .debug_fifo_count(debug_blk_fifo_count),
        .debug_srb_fifo_count(debug_blk_srb_fifo_count),
        .debug_current_irp_id(debug_blk_current_irp_id)
    );

    nvme_driver_core #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES),
        .QUEUE_DEPTH(32),
        .PRP_POOL_SIZE(PRP_POOL_SIZE)
    ) nvme_driver (
        .clk(clk),
        .reset_n(reset_n),
        .srb_in_valid(srb_valid),
        .srb_in_data(srb_data),
        .srb_in_ready(srb_ready),
        .nvme_cmd_valid(nvme_cmd_valid),
        .nvme_cmd_data(nvme_cmd_data),
        .nvme_cmd_ready(nvme_cmd_ready),
        .nvme_cpl_valid(nvme_cpl_valid),
        .nvme_cpl_data(nvme_cpl_data),
        .nvme_cpl_ready(nvme_cpl_ready),
        .completion_valid(completion_int_valid),
        .completion_irp_id(completion_irp_id),
        .completion_status(completion_int_status),
        .prp_alloc_valid(),
        .prp_alloc_size(),
        .prp_alloc_ready(1'b1),
        .prp_alloc_complete(1'b1),
        .prp_physical_addr(64'h2000),
        .nvme_commands_issued(nvme_cmds_issued),
        .nvme_completions(nvme_cpls_received),
        .queue_utilization(nvme_queue_util),
        .debug_state(debug_nvme_state),
        .debug_srb_fifo_count(debug_nvme_srb_fifo_count),
        .debug_cpl_fifo_count(debug_nvme_cpl_fifo_count),
        .debug_queue_counts_sum(debug_nvme_queue_counts_sum),
        .debug_srb_fifo_full(),
        .debug_srb_fifo_empty(),
        .debug_srb_fifo_rd_ptr(),
        .debug_srb_fifo_wr_ptr(),
        .debug_srb_valid_bit()
    );

    performance_statistics #(
        .CYCLE_COUNTER_WIDTH(64),
        .MAX_COMMANDS(1000),
        .LATENCY_HISTORY_DEPTH(1024)
    ) perf_stats (
        .clk(clk),
        .reset_n(reset_n),
        .command_received(command_received),
        .command_is_write(command_is_write),
        .command_size_bytes(command_size_bytes),
        .irp_created(irp_created),
        .srb_created(srb_created),
        .nvme_cmd_issued(nvme_cmd_issued),
        .nvme_cpl_received(nvme_cpl_received),
        .current_queue_depth(nvme_queue_util),
        .command_id_received(current_command_id),
        .command_id_completed(completion_irp_id),
        .latency_track_enable(latency_track_enable),
        .total_cycles(stat_total_cycles),
        .total_commands(stat_total_commands),
        .total_bytes(stat_total_bytes),
        .read_commands(stat_read_count),
        .write_commands(stat_write_count),
        .max_queue_depth(stat_max_queue_depth),
        .irps_created_count(stat_irps_created),
        .srbs_created_count(stat_srbs_created),
        .nvme_cmds_issued_count(stat_nvme_cmds_issued),
        .nvme_cpls_received_count(stat_nvme_cpls_received),
        .min_latency_cycles(stat_min_latency),
        .max_latency_cycles(stat_max_latency),
        .total_latency_cycles(),
        .average_latency_cycles(stat_avg_latency),
        .p95_latency_cycles(stat_p95_latency),
        .p99_latency_cycles(stat_p99_latency),
        .commands_with_latency(stat_commands_with_latency),
        .iops(stat_iops),
        .avg_throughput_Bps(stat_avg_throughput)
    );

    assign completion_out_valid = completion_int_valid;
    assign completion_status    = completion_int_status;
    assign completion_info      = completion_int_info;

endmodule