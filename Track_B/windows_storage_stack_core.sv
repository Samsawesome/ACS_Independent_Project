module windows_storage_stack_core #(
    parameter NUM_IO_QUEUES = 8
)(
    input wire clk,
    input wire reset,

    input wire cmd_in_valid,
    input wire [127:0] cmd_in_data,
    output wire cmd_in_ready,

    output wire nvme_cmd_valid,
    output wire [511:0] nvme_cmd_data,
    input wire nvme_cmd_ready,
    input wire nvme_cpl_valid,
    input wire [127:0] nvme_cpl_data,
    output wire nvme_cpl_ready,

    output wire [63:0] stat_total_cycles,
    output wire [63:0] stat_total_commands,
    output wire [63:0] stat_total_bytes,
    output wire [31:0] stat_read_count,
    output wire [31:0] stat_write_count,
    output wire [31:0] stat_irps_created,
    output wire [31:0] stat_srbs_created,
    output wire [31:0] stat_nvme_cmds_issued,
    output wire [31:0] stat_nvme_cpls_received,
    output wire [63:0] stat_iops,
    output wire [63:0] stat_avg_throughput,

    output wire [31:0] stat_min_latency,
    output wire [31:0] stat_max_latency,
    output wire [31:0] stat_avg_latency,
    output wire [31:0] stat_p95_latency,
    output wire [31:0] stat_p99_latency
);

    wire [511:0] irp_data;
    wire irp_valid;
    wire irp_ready;
    wire [1023:0] srb_data;
    wire srb_valid;
    wire srb_ready;
    wire [15:0] completion_irp_id;

    wire command_received;
    wire completion_int_valid;
    wire irp_created;
    wire srb_created;
    wire nvme_cmd_issued;
    wire nvme_cpl_received;
    wire [31:0] completion_status;


    assign command_received = cmd_in_valid && cmd_in_ready;
    assign irp_created = irp_valid && irp_ready;
    assign srb_created = srb_valid && srb_ready;
    assign nvme_cmd_issued = nvme_cmd_valid && nvme_cmd_ready;
    assign nvme_cpl_received = nvme_cpl_valid && nvme_cpl_ready;

    irp_manager #(
        .MAX_IRPS(256)
    ) irp_mgr (
        .clk(clk),
        .reset(reset),
        .command_valid(cmd_in_valid),
        .command_lba(cmd_in_data[63:32]),
        .command_size(cmd_in_data[95:64]),
        .command_data({32'h0, cmd_in_data[127:96]}),
        .command_is_write(cmd_in_data[0]),
        .command_ready(cmd_in_ready),
        .irp_valid(irp_valid),
        .irp_data(irp_data),
        .irp_ready(irp_ready),
        .completion_valid(completion_int_valid),
        .completion_irp_id(completion_irp_id),
        .completion_status(completion_status)
    );

    block_layer_processor #(
        .QUEUE_DEPTH(64),
        .DATA_WIDTH(512)
    ) block_layer (
        .clk(clk),
        .reset(reset),
        .irp_in_valid(irp_valid),
        .irp_in_data(irp_data),
        .irp_in_ready(irp_ready),
        .srb_out_valid(srb_valid),
        .srb_out_data(srb_data),
        .srb_out_ready(srb_ready)
    );

    nvme_driver_core #(
        .NUM_IO_QUEUES(NUM_IO_QUEUES),
        .QUEUE_DEPTH(32)
    ) nvme_driver (
        .clk(clk),
        .reset(reset),
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
        .completion_status(completion_status)
    );

    performance_statistics #(
        .CYCLE_COUNTER_WIDTH(64),
        .MAX_COMMANDS(1000),
        .LATENCY_HISTORY_DEPTH(1024)
    ) perf_stats (
        .clk(clk),
        .reset(reset),
        .command_received(command_received),
        .command_is_write(cmd_in_data[0]),
        .command_size_bytes(cmd_in_data[95:64]),
        .irp_created(irp_created),
        .srb_created(srb_created),
        .nvme_cmd_issued(nvme_cmd_issued),
        .nvme_cpl_received(nvme_cpl_received),
        .total_cycles(stat_total_cycles),
        .total_commands(stat_total_commands),
        .total_bytes(stat_total_bytes),
        .read_commands(stat_read_count),
        .write_commands(stat_write_count),
        .irps_created_count(stat_irps_created),
        .srbs_created_count(stat_srbs_created),
        .nvme_cmds_issued_count(stat_nvme_cmds_issued),
        .nvme_cpls_received_count(stat_nvme_cpls_received),
        .min_latency_cycles(stat_min_latency),
        .max_latency_cycles(stat_max_latency),
        .average_latency_cycles(stat_avg_latency),
        .p95_latency_cycles(stat_p95_latency),
        .p99_latency_cycles(stat_p99_latency),
        .iops(stat_iops),
        .avg_throughput_Bps(stat_avg_throughput)
    );
endmodule