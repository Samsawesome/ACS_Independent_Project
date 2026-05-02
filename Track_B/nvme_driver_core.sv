// ============================================================================
// Module: NVMe Driver Core (FIXED – increased SRB FIFO depth)
// ============================================================================
module nvme_driver_core #(
    parameter NUM_IO_QUEUES = 8,
    parameter QUEUE_DEPTH = 32,
    parameter PRP_POOL_SIZE = 256,
    parameter SRB_FIFO_DEPTH = 64,         // Must be >= block layer SRB FIFO depth (64)
    parameter CPL_FIFO_DEPTH = 256
)(
    input wire clk,
    input wire reset_n,
    
    // SRB Input Interface
    input wire srb_in_valid,
    input wire [1023:0] srb_in_data,
    output wire srb_in_ready,
    
    // NVMe Command Output Interface
    output wire nvme_cmd_valid,
    output wire [511:0] nvme_cmd_data,
    input wire nvme_cmd_ready,
    
    // NVMe Completion Input Interface
    input wire nvme_cpl_valid,
    input wire [127:0] nvme_cpl_data,
    output wire nvme_cpl_ready,
    
    // Completion Notification Output
    output reg completion_valid,
    output reg [15:0] completion_irp_id,
    output reg [31:0] completion_status,
    
    // PRP Management Interface
    output reg prp_alloc_valid,
    output reg [31:0] prp_alloc_size,
    input wire prp_alloc_ready,
    input wire prp_alloc_complete,
    input wire [63:0] prp_physical_addr,
    
    // Statistics
    output reg [63:0] nvme_commands_issued,
    output reg [63:0] nvme_completions,
    output reg [31:0] queue_utilization,
    
    // DEBUG OUTPUTS
    output wire [3:0] debug_state,
    output wire [31:0] debug_srb_fifo_count,
    output wire [31:0] debug_cpl_fifo_count,
    output wire [31:0] debug_queue_counts_sum,
    output wire debug_srb_fifo_full,
    output wire debug_srb_fifo_empty,
    output wire [$clog2(SRB_FIFO_DEPTH)-1:0] debug_srb_fifo_rd_ptr,
    output wire [$clog2(SRB_FIFO_DEPTH)-1:0] debug_srb_fifo_wr_ptr,
    output wire debug_srb_valid_bit
);
    
    import windows_storage_pkg::*;
    
    // IO Queues (Submission Queues)
    typedef nvme_command_t queue_entry_t;
    queue_entry_t io_queues [0:NUM_IO_QUEUES-1][0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] queue_valid [0:NUM_IO_QUEUES-1];
    reg [4:0] queue_head [0:NUM_IO_QUEUES-1];
    reg [4:0] queue_tail [0:NUM_IO_QUEUES-1];
    reg [31:0] queue_counts [0:NUM_IO_QUEUES-1];
    
    // Command ID Management
    reg [15:0] cmd_id_to_irp_map [0:65535];
    reg [7:0] cmd_id_to_queue_map [0:65535];
    
    // PRP Pool
    reg [63:0] prp_pool [0:PRP_POOL_SIZE-1];
    reg [PRP_POOL_SIZE-1:0] prp_allocated;
    reg [8:0] prp_free_index;
    
    // Processing State Machine
    typedef enum logic [3:0] {
        NVME_IDLE,
        NVME_FETCH_SRB,
        NVME_PARSE_SRB,
        NVME_ALLOC_PRP,
        NVME_WAIT_PRP,
        NVME_BUILD_CMD,
        NVME_SELECT_QUEUE,
        NVME_SUBMIT_CMD,
        NVME_WAIT_COMPLETION
    } nvme_state_t;
    
    nvme_state_t current_state, next_state;
    
    // Current processing context
    srb_t current_srb;
    nvme_command_t current_nvme_cmd;
    reg [15:0] current_cmd_id;
    reg [7:0] current_queue_idx;
    reg [63:0] current_prp_addr;
    reg prp_alloc_pending;
    reg [31:0] wait_counter;
    
    // Statistics
    reg [63:0] cmd_issued_count;
    reg [63:0] cpl_received_count;
    reg [31:0] total_queue_util;
    
    // SRB FIFO – increased depth to avoid back‑pressure stall
    localparam SRB_PTR_W = $clog2(SRB_FIFO_DEPTH);
    reg [1023:0] srb_fifo [0:SRB_FIFO_DEPTH-1];
    reg [SRB_FIFO_DEPTH-1:0] srb_fifo_valid;
    reg [SRB_PTR_W-1:0] srb_fifo_rd_ptr;
    reg [SRB_PTR_W-1:0] srb_fifo_wr_ptr;
    reg [31:0] srb_fifo_cnt;
    
    // NEW:
    localparam CPL_PTR_W = $clog2(CPL_FIFO_DEPTH);
    reg [127:0] cpl_fifo [0:CPL_FIFO_DEPTH-1];
    reg [CPL_FIFO_DEPTH-1:0] cpl_fifo_valid;
    reg [CPL_PTR_W-1:0] cpl_fifo_rd_ptr;
    reg [CPL_PTR_W-1:0] cpl_fifo_wr_ptr;
    reg [31:0] cpl_fifo_cnt;
    
    // Command ID counter
    reg [15:0] command_id_counter;
    
    // DEBUG: Calculate sum of queue counts
    reg [31:0] queue_counts_sum;

    integer i;
    
    // =========================================================================
    // Sequential logic (reset & state updates)
    // =========================================================================
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= NVME_IDLE;
            command_id_counter <= 0;
            cmd_issued_count <= 0;
            cpl_received_count <= 0;
            prp_free_index <= 0;
            prp_allocated <= 0;
            prp_alloc_pending <= 0;
            srb_fifo_valid <= 0;
            cpl_fifo_valid <= 0;
            current_queue_idx <= 0;
            completion_valid <= 0;
            completion_irp_id <= 0;
            completion_status <= 0;
            prp_alloc_valid <= 0;
            prp_alloc_size <= 0;
            nvme_commands_issued <= 0;
            nvme_completions <= 0;
            queue_utilization <= 0;
            srb_fifo_cnt <= 0;
            cpl_fifo_cnt <= 0;
            queue_counts_sum <= 0;
            srb_fifo_rd_ptr <= 0;
            srb_fifo_wr_ptr <= 0;
            cpl_fifo_rd_ptr <= 0;
            cpl_fifo_wr_ptr <= 0;
            
            // Initialize arrays
            for (int i = 0; i < NUM_IO_QUEUES; i++) begin
                queue_head[i] <= 0;
                queue_tail[i] <= 0;
                queue_counts[i] <= 0;
                queue_valid[i] <= 0;
            end
            
            for (int i = 0; i < PRP_POOL_SIZE; i++) begin
                prp_pool[i] <= 64'h1000 + (i * 64'h1000);
            end
            
            for (int i = 0; i < 65536; i++) begin
                cmd_id_to_irp_map[i] <= 16'hFFFF;
                if (i < 256) cmd_id_to_queue_map[i] <= 0;
            end

            for (int i = 0; i < SRB_FIFO_DEPTH; i++) begin
                srb_fifo[i] <= 1024'b0;
            end
        end else begin
            current_state <= next_state;
            
            // ---------- SRB FIFO ----------
            if (srb_in_valid && srb_in_ready) begin
                srb_fifo[srb_fifo_wr_ptr] <= srb_in_data;
                srb_fifo_valid[srb_fifo_wr_ptr] <= 1'b1;
                srb_fifo_wr_ptr <= srb_fifo_wr_ptr + 1;
                srb_fifo_cnt <= srb_fifo_cnt + 1;
            end
            
            if (current_state == NVME_FETCH_SRB) begin
                if (srb_fifo_valid[srb_fifo_rd_ptr]) begin
                    srb_fifo_valid[srb_fifo_rd_ptr] <= 1'b0;
                    srb_fifo_rd_ptr <= srb_fifo_rd_ptr + 1;
                    srb_fifo_cnt <= srb_fifo_cnt - 1;
                end
            end
            
            // ---------- Completion FIFO ----------
            if (nvme_cpl_valid && nvme_cpl_ready) begin
                cpl_fifo[cpl_fifo_wr_ptr] <= nvme_cpl_data;
                cpl_fifo_valid[cpl_fifo_wr_ptr] <= 1'b1;
                cpl_fifo_wr_ptr <= cpl_fifo_wr_ptr + 1;
                cpl_fifo_cnt <= cpl_fifo_cnt + 1;
            end
            
            if (cpl_fifo_valid[cpl_fifo_rd_ptr]) begin
                nvme_completion_t cpl;
                cpl.command_specific = cpl_fifo[cpl_fifo_rd_ptr][31:0];
                cpl.reserved = cpl_fifo[cpl_fifo_rd_ptr][63:32];
                cpl.sq_head = cpl_fifo[cpl_fifo_rd_ptr][79:64];
                cpl.sq_id = cpl_fifo[cpl_fifo_rd_ptr][95:80];
                cpl.command_id = cpl_fifo[cpl_fifo_rd_ptr][111:96];
                cpl.status = cpl_fifo[cpl_fifo_rd_ptr][127:112];
                
                if (cmd_id_to_irp_map[cpl.command_id] != 16'hFFFF) begin
                    completion_irp_id <= cmd_id_to_irp_map[cpl.command_id];
                    completion_status <= (cpl.status == 0) ? STATUS_SUCCESS : STATUS_INVALID_PARAMETER;
                    completion_valid <= 1'b1;
                    cmd_id_to_irp_map[cpl.command_id] <= 16'hFFFF;
                    
                    if (cmd_id_to_queue_map[cpl.command_id] < NUM_IO_QUEUES) begin
                        queue_valid[cmd_id_to_queue_map[cpl.command_id]]
                                [queue_head[cmd_id_to_queue_map[cpl.command_id]]] <= 0;
                        queue_head[cmd_id_to_queue_map[cpl.command_id]] <= 
                            queue_head[cmd_id_to_queue_map[cpl.command_id]] + 1;
                        queue_counts[cmd_id_to_queue_map[cpl.command_id]] <= 
                            queue_counts[cmd_id_to_queue_map[cpl.command_id]] - 1;
                    end
                    cpl_received_count <= cpl_received_count + 1;
                    nvme_completions <= cpl_received_count + 1;
                end else begin
                    completion_irp_id <= 16'hFFFF;
                    completion_status <= STATUS_INVALID_PARAMETER;
                    completion_valid <= 1'b1;
                    $display("WARNING: NVMe Driver - No IRP mapping found for command %0d", cpl.command_id);
                end
                
                cpl_fifo_valid[cpl_fifo_rd_ptr] <= 1'b0;
                cpl_fifo_rd_ptr <= cpl_fifo_rd_ptr + 1;
                cpl_fifo_cnt <= cpl_fifo_cnt - 1;
            end else begin
                completion_valid <= 0;
            end
            
            // ---------- Queue management (submission) ----------
            if (current_state == NVME_SUBMIT_CMD && nvme_cmd_ready) begin
                io_queues[current_queue_idx][queue_tail[current_queue_idx]] <= current_nvme_cmd;
                queue_valid[current_queue_idx][queue_tail[current_queue_idx]] <= 1'b1;
                queue_tail[current_queue_idx] <= queue_tail[current_queue_idx] + 1;
                queue_counts[current_queue_idx] <= queue_counts[current_queue_idx] + 1;
                cmd_issued_count <= cmd_issued_count + 1;
                nvme_commands_issued <= cmd_issued_count + 1;
                

                queue_counts_sum = 0;
                for (i = 0; i < NUM_IO_QUEUES; i++) begin
                    queue_counts_sum = queue_counts_sum + queue_counts[i];
                end
            end
            
            // ---------- PRP allocation ----------
            if (prp_alloc_complete && prp_alloc_pending) begin
                prp_alloc_pending <= 0;
                current_prp_addr <= prp_physical_addr;
            end
            
            // ---------- Statistics ----------
            nvme_commands_issued <= cmd_issued_count;
        end
    end
    
    // =========================================================================
    // State machine combinational logic
    // =========================================================================
    always_comb begin
        next_state = current_state;
        case (current_state)
            NVME_IDLE: begin
                if (srb_fifo_cnt > 0) begin
                    next_state = NVME_FETCH_SRB;
                end
            end
            NVME_FETCH_SRB: begin
                next_state = NVME_PARSE_SRB;
            end
            NVME_PARSE_SRB: begin
                next_state = NVME_ALLOC_PRP;
            end
            NVME_ALLOC_PRP: begin
                if (prp_alloc_ready && !prp_alloc_pending) begin
                    next_state = NVME_WAIT_PRP;
                end
            end
            NVME_WAIT_PRP: begin
                if (prp_alloc_complete) begin
                    next_state = NVME_BUILD_CMD;
                end
            end
            NVME_BUILD_CMD: begin
                next_state = NVME_SELECT_QUEUE;
            end
            NVME_SELECT_QUEUE: begin
                next_state = NVME_SUBMIT_CMD;
            end
            NVME_SUBMIT_CMD: begin
                if (nvme_cmd_ready) begin
                    next_state = NVME_IDLE;
                end
            end
        endcase
    end
    
    // =========================================================================
    // Command building logic (sequential on clock)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (current_state == NVME_FETCH_SRB && srb_fifo_valid[srb_fifo_rd_ptr]) begin
            logic [391:0] srb_data;
            srb_data = srb_fifo[srb_fifo_rd_ptr][391:0];
            
            current_srb.length <= srb_data[31:0];
            current_srb.srb_function <= srb_data[39:32];
            current_srb.srb_status <= srb_data[47:40];
            current_srb.scsi_status <= srb_data[55:48];
            current_srb.data_transfer_length <= srb_data[87:56];
            current_srb.timeout_value <= srb_data[119:88];
            current_srb.cdb <= srb_data[247:120];
            current_srb.data_buffer_ptr <= srb_data[311:248];
            current_srb.original_irp_id <= srb_data[327:312];
            current_srb.lba <= srb_data[359:328];
            current_srb.sector_count <= srb_data[391:360];
        end
        
        if (current_state == NVME_BUILD_CMD) begin
            current_cmd_id <= command_id_counter;
            
            current_nvme_cmd.opcode <= (current_srb.cdb[7:0] == 8'h2A) ? 
                NVME_OPC_WRITE : NVME_OPC_READ;
            current_nvme_cmd.flags <= 0;
            current_nvme_cmd.command_id <= command_id_counter;
            current_nvme_cmd.namespace_id <= 1;
            current_nvme_cmd.dptr1 <= current_prp_addr;
            current_nvme_cmd.dptr2 <= 0;
            current_nvme_cmd.cdw10 <= current_srb.lba[31:0];
            current_nvme_cmd.cdw11 <= 0;
            current_nvme_cmd.cdw12 <= (current_srb.sector_count - 1);
            
            cmd_id_to_irp_map[command_id_counter] <= current_srb.original_irp_id;
            command_id_counter <= command_id_counter + 1;
        end
        
        if (current_state == NVME_SELECT_QUEUE) begin
            current_queue_idx <= current_queue_idx + 1;
            if (current_queue_idx == NUM_IO_QUEUES - 1)
                current_queue_idx <= 0;
            cmd_id_to_queue_map[current_cmd_id] <= current_queue_idx;
        end
    end
    
    // =========================================================================
    // Output assignments
    // =========================================================================
    assign srb_in_ready = (srb_fifo_cnt < SRB_FIFO_DEPTH);
    assign nvme_cmd_valid = (current_state == NVME_SUBMIT_CMD);
    assign nvme_cmd_data = {
        current_nvme_cmd.reserved,
        current_nvme_cmd.metadata_ptr,
        current_nvme_cmd.cdw15,
        current_nvme_cmd.cdw14,
        current_nvme_cmd.cdw13,
        current_nvme_cmd.cdw12,
        current_nvme_cmd.cdw11,
        current_nvme_cmd.cdw10,
        current_nvme_cmd.dptr2,
        current_nvme_cmd.dptr1,
        current_nvme_cmd.namespace_id,
        current_nvme_cmd.command_id,
        current_nvme_cmd.flags,
        current_nvme_cmd.opcode
    };
    assign nvme_cpl_ready = (cpl_fifo_cnt < CPL_FIFO_DEPTH);
    
    // DEBUG OUTPUTS
    assign debug_state = current_state;
    assign debug_srb_fifo_count = srb_fifo_cnt;
    assign debug_cpl_fifo_count = cpl_fifo_cnt;
    assign debug_queue_counts_sum = queue_counts_sum;
    assign debug_srb_fifo_full = (srb_fifo_cnt == SRB_FIFO_DEPTH);
    assign debug_srb_fifo_empty = (srb_fifo_cnt == 0);
    assign debug_srb_fifo_rd_ptr = srb_fifo_rd_ptr;
    assign debug_srb_fifo_wr_ptr = srb_fifo_wr_ptr;
    assign debug_srb_valid_bit = srb_fifo_valid[srb_fifo_rd_ptr];
    
endmodule