module nvme_queue_manager #(
    parameter NUM_IO_QUEUES = 8,
    parameter QUEUE_DEPTH = 32,
    parameter ADMIN_QUEUE_DEPTH = 8,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset,

    input wire [63:0] mem_addr,
    input wire [DATA_WIDTH-1:0] mem_wr_data,
    input wire mem_wr_en,
    input wire mem_rd_en,
    output reg [DATA_WIDTH-1:0] mem_rd_data,
    output reg mem_rd_valid,

    input wire [63:0] admin_sq_base_addr,
    input wire [63:0] admin_cq_base_addr,
    input wire [63:0] io_sq_base_addr [0:NUM_IO_QUEUES-1],
    input wire [63:0] io_cq_base_addr [0:NUM_IO_QUEUES-1],

    input wire controller_rd_en,
    input wire controller_wr_en,
    input wire [63:0] controller_addr,
    input wire [DATA_WIDTH-1:0] controller_wr_data,
    output reg [DATA_WIDTH-1:0] controller_rd_data,
    output reg controller_rd_valid
);
    localparam SQ_ENTRY_SIZE = 64;
    localparam CQ_ENTRY_SIZE = 16;

    reg [DATA_WIDTH-1:0] admin_sq_mem [0:ADMIN_QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] admin_cq_mem [0:ADMIN_QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] io_sq_mem [0:NUM_IO_QUEUES-1][0:QUEUE_DEPTH-1];
    reg [DATA_WIDTH-1:0] io_cq_mem [0:NUM_IO_QUEUES-1][0:QUEUE_DEPTH-1];
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
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
        end else begin
            mem_rd_valid <= 0;
            if (mem_wr_en) begin //if able to write
                if (mem_addr >= admin_sq_base_addr && mem_addr < admin_sq_base_addr + (ADMIN_QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_sq_base_addr) / SQ_ENTRY_SIZE;
                    admin_sq_mem[idx] <= mem_wr_data; //write if mem addy in admin SQ
                    //$display("QueueMgr: HOST WRITE to Admin SQ entry %0d at addr %h, data=%h", idx, mem_addr, mem_wr_data);
                end
                else if (mem_addr >= admin_cq_base_addr && mem_addr < admin_cq_base_addr + (ADMIN_QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                    automatic integer idx = (mem_addr - admin_cq_base_addr) / CQ_ENTRY_SIZE;
                    admin_cq_mem[idx] <= mem_wr_data; //write if mem addy in admin CQ
                    //$display("QueueMgr: HOST WRITE to Admin CQ entry %0d at addr %h, data=%h", idx, mem_addr, mem_wr_data);
                end
                else begin //not in admin, now we check regular SQ and CQ
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (mem_addr >= io_sq_base_addr[i] && mem_addr < io_sq_base_addr[i] + (QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_sq_base_addr[i]) / SQ_ENTRY_SIZE;
                            io_sq_mem[i][idx] <= mem_wr_data; //write if mem addy in SQ
                            //$display("Queue Mgr: Host write to IO SQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                        if (mem_addr >= io_cq_base_addr[i] && mem_addr < io_cq_base_addr[i] + (QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                            automatic integer idx = (mem_addr - io_cq_base_addr[i]) / CQ_ENTRY_SIZE;
                            io_cq_mem[i][idx] <= mem_wr_data; //write if mem addy in CQ
                            //$display("Queue Mgr: Host write to IO CQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin //print error on not finding the command
                        $display("Queue Mgr: Invalid host write address %h", mem_addr);
                    end
                end
            end
            if (mem_rd_en) begin //same thing as above, just for reading instead of writing
                mem_rd_valid <= 1'b1;
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
                        $display("Queue Mgr: Invalid host read address %h", mem_addr);
                    end
                end
            end
        end
    end    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            controller_rd_valid <= 0;
            controller_rd_data <= 0;
        end else begin
            controller_rd_valid <= 0;
            if (controller_wr_en) begin //same thing as above but NVMe controller instead of memory
                if (controller_addr >= admin_cq_base_addr && controller_addr < admin_cq_base_addr + (ADMIN_QUEUE_DEPTH * CQ_ENTRY_SIZE)) begin
                    automatic integer idx = (controller_addr - admin_cq_base_addr) / CQ_ENTRY_SIZE;
                    admin_cq_mem[idx] <= controller_wr_data;
                    //$display("Queue Mgr: Controller write to Admin CQ entry %0d", idx);
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
                        $display("Queue Mgr: Invalid controller write address %h", controller_addr);
                    end
                end
            end
            
            if (controller_rd_en) begin
                //$display("QueueMgr: Controller read en, addr=%h", controller_addr);
                
                if (controller_addr >= admin_sq_base_addr && controller_addr < admin_sq_base_addr + (ADMIN_QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                    automatic integer idx = (controller_addr - admin_sq_base_addr) / SQ_ENTRY_SIZE;
                    controller_rd_data <= admin_sq_mem[idx];
                    controller_rd_valid <= 1'b1;
                    //$display("QueueMgr: CONTROLLER READ from Admin SQ entry %0d, data=%h", idx, admin_sq_mem[idx]);
                end
                else begin
                    automatic int i;
                    automatic bit found = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        if (controller_addr >= io_sq_base_addr[i] && controller_addr < io_sq_base_addr[i] + (QUEUE_DEPTH * SQ_ENTRY_SIZE)) begin
                            automatic integer idx = (controller_addr - io_sq_base_addr[i]) / SQ_ENTRY_SIZE;
                            controller_rd_data <= io_sq_mem[i][idx];
                            controller_rd_valid <= 1'b1;
                            //$display("Queue Mgr: Controller read from IO SQ%0d entry %0d", i, idx);
                            found = 1;
                            break;
                        end
                    end
                    if (!found) begin
                        controller_rd_data <= {DATA_WIDTH{1'b1}};
                        controller_rd_valid <= 1'b1;
                        $display("QueueMgr: CONTROLLER READ address %h does not match any queue", controller_addr);
                    end
                end
            end
        end
    end    
endmodule