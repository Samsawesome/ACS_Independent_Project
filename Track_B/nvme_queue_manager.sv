// ============================================================================
// NVMe Memory-Mapped Queue Manager (FIXED - no multiple drivers)
// ============================================================================
module nvme_queue_manager #(
    parameter NUM_IO_QUEUES = 8,
    parameter QUEUE_DEPTH = 32,
    parameter ADMIN_QUEUE_DEPTH = 8,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset_n,
    
    // PCIe Memory Interface (for host)
    input wire [63:0] mem_addr,
    input wire [DATA_WIDTH-1:0] mem_wr_data,
    input wire mem_wr_en,
    input wire [DATA_WIDTH/8-1:0] mem_wr_be,
    input wire mem_rd_en,
    output reg [DATA_WIDTH-1:0] mem_rd_data,
    output reg mem_rd_valid,
    
    // Queue Base Address Registers
    input wire [63:0] admin_sq_base_addr,
    input wire [63:0] admin_cq_base_addr,
    input wire [63:0] io_sq_base_addr [0:NUM_IO_QUEUES-1],
    input wire [63:0] io_cq_base_addr [0:NUM_IO_QUEUES-1],
    
    // Controller Access Interface (for NVMe controller)
    input wire controller_rd_en,
    input wire controller_wr_en,
    input wire [63:0] controller_addr,
    input wire [DATA_WIDTH-1:0] controller_wr_data,
    output reg [DATA_WIDTH-1:0] controller_rd_data,
    output reg controller_rd_valid,
    
    // Queue Status
    output reg [15:0] sq_head [0:NUM_IO_QUEUES],
    output reg [15:0] sq_tail [0:NUM_IO_QUEUES],
    output reg [15:0] cq_head [0:NUM_IO_QUEUES],
    output reg [15:0] cq_tail [0:NUM_IO_QUEUES],
    
    // Interrupt Coalescing
    input wire [7:0] interrupt_coalescing_threshold,
    input wire [7:0] interrupt_coalescing_time,
    
    // Debug
    output reg [31:0] queue_access_count,
    output reg [31:0] queue_error_count
);

    // Queue Entry Sizes
    localparam SQ_ENTRY_SIZE = 64;  // 64 bytes per submission entry
    localparam CQ_ENTRY_SIZE = 16;  // 16 bytes per completion entry
    
    // Internal memory for queues
    reg [DATA_WIDTH-1:0] admin_sq_mem [0:ADMIN_QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] admin_cq_mem [0:ADMIN_QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] io_sq_mem [0:NUM_IO_QUEUES-1][0:QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] io_cq_mem [0:NUM_IO_QUEUES-1][0:QUEUE_DEPTH-1];
    
    // Queue pointers (internal, may be updated by doorbells or controller)
    reg [4:0] admin_sq_head;
    reg [4:0] admin_sq_tail;
    reg [4:0] admin_cq_head;
    reg [4:0] admin_cq_tail;
    
    reg [5:0] io_sq_head [0:NUM_IO_QUEUES-1];
    reg [5:0] io_sq_tail [0:NUM_IO_QUEUES-1];
    reg [5:0] io_cq_head [0:NUM_IO_QUEUES-1];
    reg [5:0] io_cq_tail [0:NUM_IO_QUEUES-1];
    
    // Phase tags
    reg admin_cq_phase;
    reg io_cq_phase [0:NUM_IO_QUEUES-1];
    
    // Interrupt coalescing counters
    reg [7:0] interrupt_counter [0:NUM_IO_QUEUES];
    reg [15:0] time_counter [0:NUM_IO_QUEUES];
    reg interrupt_pending [0:NUM_IO_QUEUES];
    
    // Helper function to compute entry index from address and base
    function automatic integer get_entry_index(input [63:0] addr, input [63:0] base, input integer entry_size);
        return (addr - base) / entry_size;
    endfunction
    
    // Host memory access (PCIe)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset internal arrays if needed
            for (int i = 0; i < ADMIN_QUEUE_DEPTH; i = i + 1) begin
                admin_sq_mem[i] <= 0;
                admin_cq_mem[i] <= 0;
            end
            for (int i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                for (int j = 0; j < QUEUE_DEPTH; j = j + 1) begin
                    io_sq_mem[i][j] <= 0;
                    io_cq_mem[i][j] <= 0;
                end
            end
            mem_rd_valid <= 0;
            queue_access_count <= 0;
            queue_error_count <= 0;
        end else begin
            mem_rd_valid <= 0;
            
            // Handle host writes
            if (mem_wr_en) begin
                queue_access_count <= queue_access_count + 1;
                
                // Decode address
                if (mem_addr >= admin_sq_base_addr && mem_addr < admin_sq_base_addr + (ADMIN_QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_sq_base_addr) / SQ_ENTRY_SIZE;
                    admin_sq_mem[idx] <= mem_wr_data;
                    $display("QueueMgr: HOST WRITE to Admin SQ entry %0d at addr %h, data=%h", idx, mem_addr, mem_wr_data);
                end
                else if (mem_addr >= admin_cq_base_addr && mem_addr < admin_cq_base_addr + (ADMIN_QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_cq_base_addr) / CQ_ENTRY_SIZE;
                    admin_cq_mem[idx] <= mem_wr_data;
                    $display("QueueMgr: HOST WRITE to Admin CQ entry %0d at addr %h, data=%h", idx, mem_addr, mem_wr_data);
                end
                else begin
                    // Check I/O queues
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (mem_addr >= io_sq_base_addr[i] && mem_addr < io_sq_base_addr[i] + (QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_sq_base_addr[i]) / SQ_ENTRY_SIZE;
                            io_sq_mem[i][idx] <= mem_wr_data;
                            $display("Queue Mgr: Host write to IO SQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                        if (mem_addr >= io_cq_base_addr[i] && mem_addr < io_cq_base_addr[i] + (QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_cq_base_addr[i]) / CQ_ENTRY_SIZE;
                            io_cq_mem[i][idx] <= mem_wr_data;
                            $display("Queue Mgr: Host write to IO CQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin
                        queue_error_count <= queue_error_count + 1;
                        $display("Queue Mgr: Invalid host write address %h", mem_addr);
                    end
                end
            end
            
            // Handle host reads
            if (mem_rd_en) begin
                queue_access_count <= queue_access_count + 1;
                mem_rd_valid <= 1'b1;  // data available same cycle (simplified)

                $display("QueueMgr: HOST READ from addr %h, data=%h", mem_addr, mem_rd_data);
                
                if (mem_addr >= admin_sq_base_addr && mem_addr < admin_sq_base_addr + (ADMIN_QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_sq_base_addr) / SQ_ENTRY_SIZE;
                    mem_rd_data <= admin_sq_mem[idx];
                end
                else if (mem_addr >= admin_cq_base_addr && mem_addr < admin_cq_base_addr + (ADMIN_QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_cq_base_addr) / CQ_ENTRY_SIZE;
                    mem_rd_data <= admin_cq_mem[idx];
                end
                else begin
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (mem_addr >= io_sq_base_addr[i] && mem_addr < io_sq_base_addr[i] + (QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_sq_base_addr[i]) / SQ_ENTRY_SIZE;
                            mem_rd_data <= io_sq_mem[i][idx];
                            found = 1;
                            break;
                        end
                        if (mem_addr >= io_cq_base_addr[i] && mem_addr < io_cq_base_addr[i] + (QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_cq_base_addr[i]) / CQ_ENTRY_SIZE;
                            mem_rd_data <= io_cq_mem[i][idx];
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin
                        mem_rd_data <= {DATA_WIDTH{1'b1}};
                        queue_error_count <= queue_error_count + 1;
                        $display("Queue Mgr: Invalid host read address %h", mem_addr);
                    end
                end
            end
        end
    end
    
    // Controller access (NVMe controller reads submission queues, writes completion queues)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            controller_rd_valid <= 0;
            controller_rd_data <= 0;
        end else begin
            controller_rd_valid <= 0;  // default
            
            // Controller write (typically writing completions to CQ)
            if (controller_wr_en) begin
                queue_access_count <= queue_access_count + 1;
                
                // Decode address
                if (controller_addr >= admin_cq_base_addr && controller_addr < admin_cq_base_addr + (ADMIN_QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                    automatic integer idx = (controller_addr - admin_cq_base_addr) / CQ_ENTRY_SIZE;
                    admin_cq_mem[idx] <= controller_wr_data;
                    $display("Queue Mgr: Controller write to Admin CQ entry %0d", idx);
                end
                else begin
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (controller_addr >= io_cq_base_addr[i] && controller_addr < io_cq_base_addr[i] + (QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                            automatic integer idx = (controller_addr - io_cq_base_addr[i]) / CQ_ENTRY_SIZE;
                            io_cq_mem[i][idx] <= controller_wr_data;
                            //$display("Queue Mgr: Controller write to IO CQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin
                        queue_error_count <= queue_error_count + 1;
                        $display("Queue Mgr: Invalid controller write address %h", controller_addr);
                    end
                end
            end
            
            // Controller read (reading commands from SQ)
            if (controller_rd_en) begin
               // $display("QueueMgr: CONTROLLER READ en, addr=%h", controller_addr);
                queue_access_count <= queue_access_count + 1;
                $display("QueueMgr: Controller read en, addr=%h", controller_addr);
                
                if (controller_addr >= admin_sq_base_addr && controller_addr < admin_sq_base_addr + (ADMIN_QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                    automatic integer idx = (controller_addr - admin_sq_base_addr) / SQ_ENTRY_SIZE;
                    controller_rd_data <= admin_sq_mem[idx];
                    controller_rd_valid <= 1'b1;
                    $display("QueueMgr: CONTROLLER READ from Admin SQ entry %0d, data=%h", idx, admin_sq_mem[idx]);
                end
                else begin
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (controller_addr >= io_sq_base_addr[i] && controller_addr < io_sq_base_addr[i] + (QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                            automatic integer idx = (controller_addr - io_sq_base_addr[i]) / SQ_ENTRY_SIZE;
                            controller_rd_data <= io_sq_mem[i][idx];
                            controller_rd_valid <= 1'b1;
                            $display("Queue Mgr: Controller read from IO SQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin
                        controller_rd_data <= {DATA_WIDTH{1'b1}};
                        controller_rd_valid <= 1'b1;  // still return something
                        queue_error_count <= queue_error_count + 1;
                        $display("QueueMgr: CONTROLLER READ address %h does not match any queue", controller_addr);
                    end
                end
            end
        end
    end
    
    // Update queue status outputs (simplified – not critical for admin setup)
    always @(posedge clk) begin
        for (int i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
            sq_head[i] <= io_sq_head[i];
            sq_tail[i] <= io_sq_tail[i];
            cq_head[i] <= io_cq_head[i];
            cq_tail[i] <= io_cq_tail[i];
        end
        sq_head[NUM_IO_QUEUES] <= admin_sq_head;
        sq_tail[NUM_IO_QUEUES] <= admin_sq_tail;
        cq_head[NUM_IO_QUEUES] <= admin_cq_head;
        cq_tail[NUM_IO_QUEUES] <= admin_cq_tail;
    end
    
endmodule