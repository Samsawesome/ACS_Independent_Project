// ============================================================================
// Windows Storage Stack Block Layer & NVMe Driver Core
// Hardware Implementation for IOPS Acceleration
// ============================================================================

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
// Module: IRP Manager
// ============================================================================
module irp_manager #(
    parameter MAX_IRPS = 256,
    parameter IRP_ID_WIDTH = 8
)(
    input wire clk,
    input wire reset_n,
    
    // Command Interface
    input wire command_valid,
    input wire [31:0] command_lba,
    input wire [31:0] command_size,
    input wire [63:0] command_data,
    input wire command_is_write,
    output wire command_ready,
    
    // IRP Interface to Block Layer
    output wire irp_valid,
    output wire [511:0] irp_data,
    input wire irp_ready,
    
    // Completion Interface
    input wire completion_valid,
    input wire [15:0] completion_irp_id,
    input wire [31:0] completion_status,
    input wire [31:0] completion_information,
    
    // Statistics
    output wire [63:0] total_irps_created,
    output wire [31:0] active_irp_count
);
    
    import windows_storage_pkg::*;
    
    // Internal registers
    reg [15:0] irp_id_counter = 0;
    reg [511:0] irp_fifo [0:MAX_IRPS-1];
    reg [MAX_IRPS-1:0] irp_valid_bits;
    reg [7:0] irp_read_ptr;
    reg [7:0] irp_write_ptr;
    reg [63:0] irp_creation_count;
    reg [31:0] active_irps;
    
    // IRP Creation State Machine
    typedef enum logic [2:0] {
        IRP_IDLE,
        IRP_ALLOCATE,
        IRP_BUILD,
        IRP_QUEUE,
        IRP_WAIT
    } irp_state_t;
    
    irp_state_t current_state, next_state;
    
    // Temporary IRP storage
    irp_t current_irp;
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= IRP_IDLE;
            irp_id_counter <= 0;
            irp_creation_count <= 0;
            active_irps <= 0;
            irp_read_ptr <= 0;
            irp_write_ptr <= 0;
            irp_valid_bits <= 0;
            for (int i = 0; i < MAX_IRPS; i = i + 1) begin
                irp_fifo[i] <= 512'b0;
            end
            $display("IRP_MGR: Reset complete");
        end else begin
            current_state <= next_state;
            
            // Completion tracking with IRP ID extraction
            if (completion_valid) begin
                //$display("DEBUG IRP_MGR: Completion for IRP %0d with status %h", 
                //        completion_irp_id, completion_status);
                
                // Search through all valid IRPs
                for (int i = 0; i < MAX_IRPS; i++) begin
                    if (irp_valid_bits[i]) begin
                        // Extract IRP ID from stored data (193-bit packed IRP)
                        logic [192:0] packed_irp;

                        // IRP ID is at bits [183:168] in packed_irp
                        automatic logic [15:0] stored_irp_id;
                        
                        // Get the packed IRP from FIFO first
                        packed_irp = irp_fifo[i][192:0];  // Get 193-bit packed IRP

                        stored_irp_id = packed_irp[183:168];
                        
                        //$display("DEBUG IRP_MGR: Checking FIFO slot %0d, stored IRP ID=%0d", 
                        //        i, stored_irp_id);
                        
                        if (stored_irp_id == completion_irp_id) begin
                            irp_valid_bits[i] <= 0;
                            if (active_irps > 0) active_irps <= active_irps - 1;
                            //$display("DEBUG IRP_MGR: IRP %0d completed and removed", completion_irp_id);
                            break;
                        end
                    end
                end
            end
            
            // Clear IRP from FIFO when consumed by block layer
            if (irp_valid && irp_ready) begin
                irp_valid_bits[irp_read_ptr] <= 0;
                irp_read_ptr <= irp_read_ptr + 1;
                //$display("DEBUG IRP_MGR: IRP consumed from FIFO position %0d", irp_read_ptr);
            end
        end
    end
    
    // State machine
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            IRP_IDLE: begin
                if (command_valid && active_irps < MAX_IRPS) begin
                    next_state = IRP_ALLOCATE;
                end
            end
            
            IRP_ALLOCATE: begin
                next_state = IRP_BUILD;
            end
            
            IRP_BUILD: begin
                next_state = IRP_QUEUE;
            end
            
            IRP_QUEUE: begin
                if (!irp_valid_bits[irp_write_ptr]) begin
                    next_state = IRP_IDLE;
                end else begin
                    next_state = IRP_WAIT;
                end
            end
            
            IRP_WAIT: begin
                if (!irp_valid_bits[irp_write_ptr]) begin
                    next_state = IRP_IDLE;
                end
            end
        endcase
    end
    
    // IRP Building Logic
    always_ff @(posedge clk) begin
        if (current_state == IRP_ALLOCATE) begin
            // Allocate new IRP ID
            current_irp.irp_id <= irp_id_counter;
            
            //$display("DEBUG IRP_MGR: Building IRP with ID %0d, is_write=%0d, LBA=%0d, Size=%0d",
            //        irp_id_counter, command_is_write, command_lba, command_size);
            
            // Build IRP with correct values
            current_irp.major_function <= command_is_write ? 
                irp_major_function_t'(IRP_MJ_WRITE) : irp_major_function_t'(IRP_MJ_READ);
            current_irp.minor_function <= 0;
            current_irp.status <= STATUS_PENDING;
            current_irp.information <= command_lba;  // Store LBA in information field
            current_irp.user_buffer_ptr <= command_data;
            current_irp.buffer_length <= command_size;
            current_irp.cancel <= 0;
            current_irp.stack_location <= 0;
            
            // Increment counter AFTER using current value
            irp_id_counter <= irp_id_counter + 1;
        end
        
        if (current_state == IRP_QUEUE) begin
            logic [192:0] packed_irp;  // 193 bits total

            // Clear the FIFO entry first
            irp_fifo[irp_write_ptr] <= 512'b0;
            
            // The irp_t struct is 193 bits:
            
            
            //   [192:185] stack_location   (8 bits)
            //   [184:169] irp_id           (16 bits)
            //   [168] cancel               (1 bit)
            //   [167:136] buffer_length    (32 bits)
            //   [135:72] user_buffer_ptr   (64 bits)
            //   [71:40] information (LBA)  (32 bits)
            //   [39:8]  status             (32 bits)
            //   [7:4]   minor_function     (4 bits)  
            //   [3:0]   major_function     (4 bits)
            
            // CORRECT PACKING ORDER:
            packed_irp = {
                current_irp.stack_location,    // [192:185] - 8 bits
                current_irp.irp_id,            // [184:169] - 16 bits
                current_irp.cancel,            // [168] - 1 bit
                current_irp.buffer_length,     // [167:136] - 32 bits
                current_irp.user_buffer_ptr,   // [135:72] - 64 bits
                current_irp.information,       // [71:40] - 32 bits (LBA)
                current_irp.status,            // [39:8] - 32 bits
                current_irp.minor_function,    // [7:4] - 4 bits
                current_irp.major_function     // [3:0] - 4 bits
            };
            
            // Store in lower 193 bits of 512-bit FIFO
            irp_fifo[irp_write_ptr][192:0] <= packed_irp;
            
            irp_valid_bits[irp_write_ptr] <= 1'b1;
            irp_write_ptr <= irp_write_ptr + 1;
            irp_creation_count <= irp_creation_count + 1;
            active_irps <= active_irps + 1;
            
            //$display("DEBUG IRP_MGR: IRP %0d queued, LBA=%0d, Size=%0d, Write=%0d, packed=%h",
            //        current_irp.irp_id, current_irp.information, 
            //        current_irp.buffer_length, current_irp.major_function == 4'h1,
            //        packed_irp);
        end
    end
    
    // Output assignments
    assign command_ready = (current_state == IRP_IDLE) && (active_irps < MAX_IRPS);
    assign irp_valid = irp_valid_bits[irp_read_ptr];
    assign irp_data = irp_fifo[irp_read_ptr];
    
    assign total_irps_created = irp_creation_count;
    assign active_irp_count = active_irps;
    
    // Debug: Monitor IRP FIFO state
    always @(posedge clk) begin
        if (irp_valid) begin
            // Extract IRP ID correctly from 193-bit packed IRP
            // The packed IRP is stored in irp_data[192:0]
            // IRP ID is at bits [184:169] in the packed structure
            
            logic [15:0] debug_irp_id;
            debug_irp_id = irp_data[184:169];  // CORRECT: Extract from bits [184:169]
            
            //$display("DEBUG IRP_MGR: FIFO output has IRP %0d at position %0d", 
            //        debug_irp_id, irp_read_ptr);
        end
    end
    
endmodule

// ============================================================================
// Module: Block Layer Processor
// ============================================================================
module block_layer_processor #(
    parameter QUEUE_DEPTH = 64,
    parameter DATA_WIDTH = 512
)(
    input wire clk,
    input wire reset_n,
    
    // IRP Input Interface
    input wire irp_in_valid,
    input wire [511:0] irp_in_data,
    output wire irp_in_ready,
    
    // SRB Output Interface (to Port Driver)
    output wire srb_out_valid,
    output wire [1023:0] srb_out_data,
    input wire srb_out_ready,
    
    // MDL Interface
    output reg mdl_request_valid,
    output reg [63:0] mdl_buffer_addr,
    output reg [31:0] mdl_buffer_size,
    input wire mdl_request_ready,
    input wire mdl_complete_valid,
    input wire [63:0] mdl_physical_addr,
    
    // Statistics
    output wire [31:0] block_layer_cycles,
    output wire [31:0] irps_processed,
    
    // DEBUG OUTPUTS
    output wire [3:0] debug_state,
    output wire [31:0] debug_fifo_count,
    output wire [31:0] debug_srb_fifo_count,
    output wire [15:0] debug_current_irp_id
);
    
    import windows_storage_pkg::*;
    
    // Internal FIFOs
    reg [511:0] irp_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] irp_fifo_valid;
    reg [5:0] irp_fifo_rd_ptr;
    reg [5:0] irp_fifo_wr_ptr;
    reg [31:0] fifo_count;
    
    // SRB FIFO
    reg [1023:0] srb_fifo [0:QUEUE_DEPTH-1];
    reg [QUEUE_DEPTH-1:0] srb_fifo_valid;
    reg [5:0] srb_fifo_rd_ptr;
    reg [5:0] srb_fifo_wr_ptr;
    reg [31:0] srb_fifo_count;
    
    // Processing State Machine
    typedef enum logic [3:0] {
        BL_IDLE,
        BL_FETCH_IRP,
        BL_PARSE_IRP,
        BL_BUILD_MDL,
        BL_WAIT_MDL,
        BL_BUILD_SRB,
        BL_QUEUE_SRB,
        BL_COMPLETE
    } bl_state_t;
    
    bl_state_t current_state, next_state;
    
    // Current processing context
    irp_t current_irp;
    srb_t current_srb;
    reg [31:0] current_lba;
    reg [31:0] current_size;
    reg is_write_op;
    reg [15:0] current_irp_id;
    reg [63:0] current_physical_addr;
    reg [31:0] sector_count;
    reg [31:0] cycles_counter;
    reg [31:0] irp_processed_count;
    
    // MDL State
    reg mdl_in_progress;
    reg [31:0] mdl_wait_cycles;
    
    // Debug tracking
    reg [15:0] last_irp_id_processed;
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= BL_IDLE;
            irp_fifo_valid <= 0;
            srb_fifo_valid <= 0;
            irp_fifo_rd_ptr <= 0;
            irp_fifo_wr_ptr <= 0;
            srb_fifo_rd_ptr <= 0;
            srb_fifo_wr_ptr <= 0;
            fifo_count <= 0;
            srb_fifo_count <= 0;
            cycles_counter <= 0;
            irp_processed_count <= 0;
            mdl_in_progress <= 0;
            mdl_wait_cycles <= 0;
            mdl_request_valid <= 0;
            mdl_buffer_addr <= 0;
            mdl_buffer_size <= 0;
            current_irp_id <= 0;
            last_irp_id_processed <= 0;
            sector_count <= 0;


            for (int i = 0; i < QUEUE_DEPTH; i = i + 1) begin
                srb_fifo[i] <= 1024'b0;
                srb_fifo_valid[i] <= 1'b0;
            end
            
        end else begin
            current_state <= next_state;
            
            // Update FIFO pointers
            if (irp_in_valid && irp_in_ready) begin
                irp_fifo[irp_fifo_wr_ptr] <= irp_in_data;
                irp_fifo_valid[irp_fifo_wr_ptr] <= 1'b1;
                irp_fifo_wr_ptr <= irp_fifo_wr_ptr + 1;
                fifo_count <= fifo_count + 1;
            end
            
            if (irp_fifo_valid[irp_fifo_rd_ptr] && current_state == BL_FETCH_IRP) begin
                irp_fifo_valid[irp_fifo_rd_ptr] <= 1'b0;
                irp_fifo_rd_ptr <= irp_fifo_rd_ptr + 1;
                fifo_count <= fifo_count - 1;
            end
            
             // Write SRB to FIFO in BUILD_SRB state with valid bit
            if (current_state == BL_BUILD_SRB) begin
                
                // Pack SRB in the correct order
                srb_fifo[srb_fifo_wr_ptr][391:0] <= {
                    current_srb.sector_count,        // [391:360] - 32 bits
                    current_srb.lba,                 // [359:328] - 32 bits
                    current_srb.original_irp_id,     // [327:312] - 16 bits
                    current_srb.data_buffer_ptr,     // [311:248] - 64 bits
                    current_srb.cdb,                 // [247:120] - 128 bits
                    current_srb.timeout_value,       // [119:88]  - 32 bits
                    current_srb.data_transfer_length,// [87:56]   - 32 bits
                    current_srb.scsi_status,         // [55:48]   - 8 bits
                    current_srb.srb_status,          // [47:40]   - 8 bits
                    current_srb.srb_function,        // [39:32]   - 8 bits
                    current_srb.length               // [31:0]    - 32 bits
                };
                
                //$display("DEBUG BLOCK: Stored SRB for IRP %0d at FIFO position %0d, LBA=%0d, Sector Count=%0d",
                //        current_srb.original_irp_id, srb_fifo_wr_ptr, current_srb.lba, current_srb.sector_count);
            end
            
            // Set valid bit
            if (current_state == BL_BUILD_SRB) begin
                srb_fifo_valid[srb_fifo_wr_ptr] <= 1'b1;
                srb_fifo_wr_ptr <= srb_fifo_wr_ptr + 1;
                srb_fifo_count <= srb_fifo_count + 1;
                //$display("DEBUG BLOCK: SRB valid bit set for position %0d, new count=%0d",
                //        srb_fifo_wr_ptr, srb_fifo_count + 1);
            end
            
            // Clear valid bit when SRB is consumed
            if (srb_out_valid && srb_out_ready) begin
                srb_fifo_valid[srb_fifo_rd_ptr] <= 1'b0;
                srb_fifo_rd_ptr <= srb_fifo_rd_ptr + 1;
                srb_fifo_count <= srb_fifo_count - 1;
                //$display("DEBUG BLOCK: SRB consumed from position %0d", srb_fifo_rd_ptr);
            end
            
            // Update statistics
            if (current_state != BL_IDLE) begin
                cycles_counter <= cycles_counter + 1;
            end
            
            // In the always_ff block, add this update:
            if (current_state == BL_COMPLETE) begin
                last_irp_id_processed <= current_irp_id;  // Update with the current IRP ID
                irp_processed_count <= irp_processed_count + 1;
            end
            
            // MDL tracking
            if (mdl_request_valid && mdl_request_ready) begin
                mdl_in_progress <= 1'b1;
                mdl_wait_cycles <= 0;
            end
            
            if (mdl_in_progress) begin
                mdl_wait_cycles <= mdl_wait_cycles + 1;
                if (mdl_complete_valid) begin
                    mdl_in_progress <= 1'b0;
                end
            end
            
            // Handle MDL output signals
            if (current_state == BL_BUILD_MDL) begin
                mdl_request_valid <= 1'b1;
                mdl_buffer_addr <= current_irp.user_buffer_ptr;
                mdl_buffer_size <= current_irp.buffer_length;
            end else begin
                mdl_request_valid <= 1'b0;
            end
        end
    end
    
    // State machine
    always_comb begin
    next_state = current_state;
    
    case (current_state)
        BL_IDLE: begin
            if (fifo_count > 0) begin
                next_state = BL_FETCH_IRP;
            end
        end
        
        BL_FETCH_IRP: begin
            next_state = BL_PARSE_IRP;
        end
        
        BL_PARSE_IRP: begin
            // Parse IRP and calculate sector count (512-byte sectors)
            // This is combinatorial, move to next state
            next_state = BL_BUILD_MDL;
        end
        
        BL_BUILD_MDL: begin
            // MDL request is made, wait for it to be accepted
            if (mdl_request_ready || !mdl_in_progress) begin
                next_state = BL_WAIT_MDL;
            end
        end
        
        BL_WAIT_MDL: begin
            if (mdl_complete_valid) begin
                next_state = BL_BUILD_SRB;
            end
        end
        
        BL_BUILD_SRB: begin
            // SRB is built in this state, then move to queue
            next_state = BL_QUEUE_SRB;
        end
        
        BL_QUEUE_SRB: begin
            // Move to COMPLETE immediately after queuing
            next_state = BL_COMPLETE;
        end
        
        BL_COMPLETE: begin
            next_state = BL_IDLE;
        end
    endcase
end
    
    // IRP Parsing
    always_ff @(posedge clk) begin
        if (current_state == BL_FETCH_IRP) begin
            // Extract correct 193-bit packed IRP
            logic [192:0] packed_irp;
            packed_irp = irp_fifo[irp_fifo_rd_ptr][192:0];
            
            // Debug the raw packed IRP
            //$display("DEBUG BLOCK: Raw packed_irp=%h (193 bits)", packed_irp);
            
            // FIXED: CORRECT UNPACKING (reverse of packing)
            // packed_irp structure:
            //   [192:185] = stack_location (8 bits)
            //   [184:169] = irp_id (16 bits)
            //   [168] = cancel (1 bit)
            //   [167:136] = buffer_length (32 bits)
            //   [135:72] = user_buffer_ptr (64 bits)
            //   [71:40] = information/LBA (32 bits)
            //   [39:8] = status (32 bits)
            //   [7:4] = minor_function (4 bits)
            //   [3:0] = major_function (4 bits)
            
            current_irp.stack_location <= packed_irp[192:185];
            current_irp.irp_id <= packed_irp[184:169];
            current_irp.cancel <= packed_irp[168];
            current_irp.buffer_length <= packed_irp[167:136];
            current_irp.user_buffer_ptr <= packed_irp[135:72];
            current_irp.information <= packed_irp[71:40];  // LBA
            current_irp.status <= packed_irp[39:8];
            current_irp.minor_function <= packed_irp[7:4];
            current_irp.major_function <= packed_irp[3:0];
            
            is_write_op = (packed_irp[3:0] == 4'h1);
            current_irp_id = packed_irp[184:169];
            
            // Extract LBA and size
            current_lba = packed_irp[71:40];
            current_size = packed_irp[167:136];
            
            // Calculate sector count (512-byte sectors)
            sector_count = (current_size + 511) / 512;
            
            //$display("DEBUG BLOCK: Extracted IRP %0d, LBA=%0d (0x%h), Size=%0d, is_write=%0d, Sectors=%0d",
            //        current_irp_id, current_lba, current_lba, current_size, is_write_op, sector_count);
            

            current_srb.length <= 64;
            current_srb.srb_function <= is_write_op ? 8'h2A : 8'h28;  // SCSIOP_WRITE or SCSIOP_READ
            current_srb.srb_status <= 8'h04;  // SRB_STATUS_PENDING
            current_srb.scsi_status <= 8'h00;
            current_srb.data_transfer_length <= current_size;
            current_srb.timeout_value <= 32'd1000;  // 1 second timeout
            current_srb.cdb <= is_write_op ? 
                {8'h2A, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0} :  // Write(10) CDB
                {8'h28, 8'h00, current_lba[31:0], 8'h00, sector_count[15:0], 8'h00, 104'h0};   // Read(10) CDB
            current_srb.data_buffer_ptr <= current_irp.user_buffer_ptr;
            current_srb.original_irp_id <= current_irp_id;
            current_srb.lba <= current_lba;
            current_srb.sector_count <= sector_count;
            
            //$display("DEBUG BLOCK: Built SRB for IRP %0d, LBA=%0d, Sector Count=%0d, is_write=%0d",
            //        current_irp_id, current_lba, sector_count, is_write_op);
        end
    end
    
    // Output assignments
    assign irp_in_ready = (fifo_count < QUEUE_DEPTH);
    assign srb_out_valid = srb_fifo_valid[srb_fifo_rd_ptr];
    assign srb_out_data = srb_fifo[srb_fifo_rd_ptr];
    
    assign block_layer_cycles = cycles_counter;
    assign irps_processed = irp_processed_count;
    
    // DEBUG OUTPUTS
    assign debug_state = current_state;
    assign debug_fifo_count = fifo_count;
    assign debug_srb_fifo_count = srb_fifo_count;
    assign debug_current_irp_id = last_irp_id_processed;
    
endmodule

// ============================================================================
// Module: NVMe Driver Core with Enhanced Debug
// ============================================================================
module nvme_driver_core #(
    parameter NUM_IO_QUEUES = 8,
    parameter QUEUE_DEPTH = 32,
    parameter PRP_POOL_SIZE = 256
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
    output wire [2:0] debug_srb_fifo_rd_ptr,
    output wire [2:0] debug_srb_fifo_wr_ptr,
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
    
    // SRB FIFO
    reg [1023:0] srb_fifo [0:15];
    reg [15:0] srb_fifo_valid;
    reg [3:0] srb_fifo_rd_ptr;
    reg [3:0] srb_fifo_wr_ptr;
    reg [31:0] srb_fifo_cnt;
    
    // Completion FIFO
    reg [127:0] cpl_fifo [0:7];
    reg [7:0] cpl_fifo_valid;
    reg [2:0] cpl_fifo_rd_ptr;
    reg [2:0] cpl_fifo_wr_ptr;
    reg [31:0] cpl_fifo_cnt;
    
    // Command ID counter
    reg [15:0] command_id_counter;
    
    // DEBUG: Calculate sum of queue counts
    reg [31:0] queue_counts_sum;
    
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
            for (int i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                queue_head[i] <= 0;
                queue_tail[i] <= 0;
                queue_counts[i] <= 0;
                queue_valid[i] <= 0;
            end
            
            for (int i = 0; i < PRP_POOL_SIZE; i = i + 1) begin
                prp_pool[i] <= 64'h1000 + (i * 64'h1000);
            end
            
            // Initialize command ID mapping arrays
            for (int i = 0; i < 65536; i = i + 1) begin
                cmd_id_to_irp_map[i] <= 0;
                if (i < 256) cmd_id_to_queue_map[i] <= 0;
            end

            for (int i = 0; i < 16; i = i + 1) begin
                srb_fifo[i] <= 1024'b0;  // Clear FIFO data
            end

            for (int i = 0; i < 65536; i = i + 1) begin
                cmd_id_to_irp_map[i] <= 16'hFFFF;  // Use 0xFFFF for invalid, not 0
            end
            
            for (int i = 0; i < 256; i = i + 1) begin  // Only need 256 for queue mapping
                cmd_id_to_queue_map[i] <= 0;
            end
        end else begin
            current_state <= next_state;
            
            // SRB FIFO management - handle incoming SRBs
            if (srb_in_valid && srb_in_ready) begin
                srb_fifo[srb_fifo_wr_ptr] <= srb_in_data;
                srb_fifo_valid[srb_fifo_wr_ptr] <= 1'b1;
                srb_fifo_wr_ptr <= srb_fifo_wr_ptr + 1;
                srb_fifo_cnt <= srb_fifo_cnt + 1;
                //$display("DEBUG: NVMe Driver - SRB written to FIFO at index %0d, count=%0d", 
                //         srb_fifo_wr_ptr, srb_fifo_cnt + 1);
            end
            
            // Clear valid bit when SRB is fetched
            if (current_state == NVME_FETCH_SRB) begin
                if (srb_fifo_valid[srb_fifo_rd_ptr]) begin
                    srb_fifo_valid[srb_fifo_rd_ptr] <= 1'b0;
                    srb_fifo_rd_ptr <= srb_fifo_rd_ptr + 1;
                    srb_fifo_cnt <= srb_fifo_cnt - 1;
                    //$display("DEBUG: NVMe Driver - SRB fetched from index %0d, new count=%0d", 
                    //         srb_fifo_rd_ptr, srb_fifo_cnt - 1);
                end
            end
            
            // Completion FIFO management
            if (nvme_cpl_valid && nvme_cpl_ready) begin
                cpl_fifo[cpl_fifo_wr_ptr] <= nvme_cpl_data;
                cpl_fifo_valid[cpl_fifo_wr_ptr] <= 1'b1;
                cpl_fifo_wr_ptr <= cpl_fifo_wr_ptr + 1;
                cpl_fifo_cnt <= cpl_fifo_cnt + 1;
            end
            
            // Process completions when they arrive in the FIFO
            if (cpl_fifo_valid[cpl_fifo_rd_ptr]) begin
                // Parse completion
                nvme_completion_t cpl;
                cpl.command_specific = cpl_fifo[cpl_fifo_rd_ptr][31:0];
                cpl.reserved = cpl_fifo[cpl_fifo_rd_ptr][63:32];
                cpl.sq_head = cpl_fifo[cpl_fifo_rd_ptr][79:64];
                cpl.sq_id = cpl_fifo[cpl_fifo_rd_ptr][95:80];
                cpl.command_id = cpl_fifo[cpl_fifo_rd_ptr][111:96];
                cpl.status = cpl_fifo[cpl_fifo_rd_ptr][127:112];
                
                // Look up IRP ID from command ID - check if mapping exists
                if (cmd_id_to_irp_map[cpl.command_id] != 16'hFFFF) begin
                    completion_irp_id <= cmd_id_to_irp_map[cpl.command_id];
                    completion_status <= (cpl.status == 0) ? STATUS_SUCCESS : STATUS_INVALID_PARAMETER;
                    completion_valid <= 1'b1;
                    
                    //$display("DEBUG NVMe: Completion for command %0d -> IRP %0d, status=%s", 
                    //        cpl.command_id, cmd_id_to_irp_map[cpl.command_id],
                    //        (cpl.status == 0) ? "SUCCESS" : "ERROR");
                    
                    // Clear the mapping after use to prevent reuse
                    cmd_id_to_irp_map[cpl.command_id] <= 16'hFFFF;
                    
                    // Free queue entry if we can find which queue it's in
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
                    // No mapping found
                    completion_irp_id <= 16'hFFFF;
                    completion_status <= STATUS_INVALID_PARAMETER;
                    completion_valid <= 1'b1;
                    $display("WARNING: NVMe Driver - No IRP mapping found for command %0d", 
                            cpl.command_id);
                end
                
                // Clear the completion FIFO entry
                cpl_fifo_valid[cpl_fifo_rd_ptr] <= 1'b0;
                cpl_fifo_rd_ptr <= cpl_fifo_rd_ptr + 1;
                cpl_fifo_cnt <= cpl_fifo_cnt - 1;
            end else begin
                completion_valid <= 0;
            end
            
            // Queue management
            if (current_state == NVME_SUBMIT_CMD && nvme_cmd_ready) begin
                // Store command in queue
                io_queues[current_queue_idx][queue_tail[current_queue_idx]] <= current_nvme_cmd;
                queue_valid[current_queue_idx][queue_tail[current_queue_idx]] <= 1'b1;
                queue_tail[current_queue_idx] <= queue_tail[current_queue_idx] + 1;
                queue_counts[current_queue_idx] <= queue_counts[current_queue_idx] + 1;
                cmd_issued_count <= cmd_issued_count + 1;
                nvme_commands_issued <= cmd_issued_count + 1;
                
                //$display("DEBUG: Queue %0d now has %0d entries, command_id=%0d for IRP=%0d", 
                //        current_queue_idx, queue_counts[current_queue_idx], 
                //        current_cmd_id, current_srb.original_irp_id);
                
                // Update queue counts sum
                begin
                    integer i;
                    queue_counts_sum = 0;
                    for (i = 0; i < NUM_IO_QUEUES; i = i + 1) begin
                        queue_counts_sum = queue_counts_sum + queue_counts[i];
                    end
                end
            end
                        
            // PRP allocation
            if (prp_alloc_complete && prp_alloc_pending) begin
                prp_alloc_pending <= 0;
                current_prp_addr <= prp_physical_addr;
            end
            
            // Completion processing
            if (current_state == NVME_WAIT_COMPLETION && cpl_fifo_valid[cpl_fifo_rd_ptr]) begin
                // Parse completion
                nvme_completion_t cpl;
                cpl.command_specific = cpl_fifo[cpl_fifo_rd_ptr][31:0];
                cpl.reserved = cpl_fifo[cpl_fifo_rd_ptr][63:32];
                cpl.sq_head = cpl_fifo[cpl_fifo_rd_ptr][79:64];
                cpl.sq_id = cpl_fifo[cpl_fifo_rd_ptr][95:80];
                cpl.command_id = cpl_fifo[cpl_fifo_rd_ptr][111:96];
                cpl.status = cpl_fifo[cpl_fifo_rd_ptr][127:112];
                
                // Look up IRP ID from command ID
                completion_irp_id <= cmd_id_to_irp_map[cpl.command_id];
                completion_status <= (cpl.status == 0) ? 32'h00000000 : 32'hC000000D;
                completion_valid <= 1'b1;
                
                // Free queue entry
                queue_valid[cmd_id_to_queue_map[cpl.command_id]][queue_head[cmd_id_to_queue_map[cpl.command_id]]] <= 0;
                queue_head[cmd_id_to_queue_map[cpl.command_id]] <= queue_head[cmd_id_to_queue_map[cpl.command_id]] + 1;
                queue_counts[cmd_id_to_queue_map[cpl.command_id]] <= queue_counts[cmd_id_to_queue_map[cpl.command_id]] - 1;
                
                cpl_received_count <= cpl_received_count + 1;
                nvme_completions <= cpl_received_count + 1;
            end else begin
                completion_valid <= 0;
            end
            
            // Update statistics
            nvme_commands_issued <= cmd_issued_count;
        end
    end
    
    // State machine
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            NVME_IDLE: begin
                if (srb_fifo_cnt > 0) begin
                    next_state = NVME_FETCH_SRB;
                end else if (cpl_fifo_cnt > 0) begin
                    // Stay in IDLE but completion will be processed
                    next_state = NVME_IDLE;
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
                    //$display("DEBUG: NVMe Command submitted for IRP %0d, command_id=%0d", 
                    //        current_srb.original_irp_id, current_cmd_id);
                    next_state = NVME_IDLE;
                end else begin
                    next_state = NVME_SUBMIT_CMD;
                end
            end
        endcase
    end
    
    // Command building logic
    always_ff @(posedge clk) begin
        if (current_state == NVME_FETCH_SRB && srb_fifo_valid[srb_fifo_rd_ptr]) begin
            logic [391:0] srb_data;
            srb_data = srb_fifo[srb_fifo_rd_ptr][391:0];
            
            // Debug the raw data
            //$display("DEBUG NVMe: SRB data at index %0d:", srb_fifo_rd_ptr);
            //$display("  sector_count[391:360]=%h", srb_data[391:360]);
            //$display("  lba[359:328]=%h", srb_data[359:328]);
            //$display("  irp_id[327:312]=%h", srb_data[327:312]);
            //$display("  data_ptr[311:248]=%h", srb_data[311:248]);
            //$display("  cdb[247:120]=%h", srb_data[247:120]);
            //$display("  First CDB byte[127:120]=%h (opcode)", srb_data[127:120]);
            
            // Extract fields
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
            
            //$display("DEBUG NVMe: Parsed SRB - IRP=%0d, LBA=%0d, Sectors=%0d, Opcode=%s",
            //        srb_data[327:312], 
            //        srb_data[359:328],
            //        srb_data[391:360],
            //        (srb_data[127:120] == 8'h2A) ? "WRITE" : "READ");
        end
        
        if (current_state == NVME_BUILD_CMD) begin
            // Build NVMe command
            current_cmd_id <= command_id_counter;
            
            current_nvme_cmd.opcode <= (current_srb.cdb[7:0] == 8'h2A) ? 
                NVME_OPC_WRITE : NVME_OPC_READ;
            current_nvme_cmd.flags <= 0;
            current_nvme_cmd.command_id <= command_id_counter;
            current_nvme_cmd.namespace_id <= 1;
            current_nvme_cmd.dptr1 <= current_prp_addr;
            current_nvme_cmd.dptr2 <= 0;
            
            // Set LBA and sector count
            current_nvme_cmd.cdw10 <= current_srb.lba[31:0];
            current_nvme_cmd.cdw11 <= 0;
            current_nvme_cmd.cdw12 <= (current_srb.sector_count - 1);
            
            // Map command ID to IRP ID
            cmd_id_to_irp_map[command_id_counter] <= current_srb.original_irp_id;
            
            //$display("DEBUG NVMe: Building command for IRP %0d -> Command ID=%0d, Opcode=%s, LBA=%0d",
            //        current_srb.original_irp_id, command_id_counter,
            //        (current_srb.cdb[7:0] == 8'h2A) ? "WRITE" : "READ",
            //        current_srb.lba);
            
            // Increment for next command
            command_id_counter <= command_id_counter + 1;
        end
        
        if (current_state == NVME_SELECT_QUEUE) begin
            // Round-robin queue selection
            current_queue_idx <= current_queue_idx + 1;
            if (current_queue_idx == NUM_IO_QUEUES - 1)
                current_queue_idx <= 0;
            cmd_id_to_queue_map[current_cmd_id] <= current_queue_idx;
            //$display("DEBUG: Selected queue %0d for command %0d (IRP %0d)", 
            //        current_queue_idx, current_cmd_id, current_srb.original_irp_id);
        end
    end
    
    // Output assignments
    assign srb_in_ready = (srb_fifo_cnt < 16);
    
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
    
    assign nvme_cpl_ready = (cpl_fifo_cnt < 8);
    
    // DEBUG OUTPUTS
    assign debug_state = current_state;
    assign debug_srb_fifo_count = srb_fifo_cnt;
    assign debug_cpl_fifo_count = cpl_fifo_cnt;
    assign debug_queue_counts_sum = queue_counts_sum;
    assign debug_srb_fifo_full = (srb_fifo_cnt == 16);
    assign debug_srb_fifo_empty = (srb_fifo_cnt == 0);
    assign debug_srb_fifo_rd_ptr = srb_fifo_rd_ptr;
    assign debug_srb_fifo_wr_ptr = srb_fifo_wr_ptr;
    assign debug_srb_valid_bit = srb_fifo_valid[srb_fifo_rd_ptr];
    
endmodule

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
    
    // Latency tracking (for p95/p99)
    input wire [15:0] command_id_received,      // Command ID when received
    input wire [15:0] command_id_completed,     // Command ID when completed
    input wire latency_track_enable,            // Enable latency tracking for this command
    
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
    output reg [31:0] commands_with_latency
);
    
    // Cycle counter
    reg [CYCLE_COUNTER_WIDTH-1:0] cycle_counter;
    
    // Queue depth tracking
    reg [31:0] current_depth;
    
    // Latency tracking structures
    reg [63:0] command_start_time [0:MAX_COMMANDS-1];
    reg [63:0] command_end_time [0:MAX_COMMANDS-1];
    reg [31:0] command_latencies [0:LATENCY_HISTORY_DEPTH-1];
    reg [9:0] latency_write_ptr;
    reg [9:0] latency_read_ptr;
    reg latency_tracking_active;
    
    // Temporary storage for latency calculation
    reg [31:0] sorted_latencies [0:MAX_COMMANDS-1];
    reg [31:0] temp_latency;
    reg [9:0] i, j;
    
    // Internal registers for percentile calculation
    reg [31:0] p95_index, p99_index;
    reg [31:0] latency_count;
    
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
            latency_tracking_active <= 0;
            latency_count <= 0;
            
            // Initialize arrays
            for (int i = 0; i < MAX_COMMANDS; i = i + 1) begin
                command_start_time[i] <= 0;
                command_end_time[i] <= 0;
            end
            
            for (int i = 0; i < LATENCY_HISTORY_DEPTH; i = i + 1) begin
                command_latencies[i] <= 0;
            end
            
            for (int i = 0; i < MAX_COMMANDS; i = i + 1) begin
                sorted_latencies[i] <= 0;
            end
            
        end else begin
            // Count cycles
            cycle_counter <= cycle_counter + 1;
            total_cycles <= cycle_counter;
            
            // Track commands
            if (command_received) begin
                total_commands <= total_commands + 1;
                total_bytes <= total_bytes + command_size_bytes;
                if (command_is_write) begin
                    write_commands <= write_commands + 1;
                end else begin
                    read_commands <= read_commands + 1;
                end
                
                // Record start time for latency tracking
                if (latency_track_enable && command_id_received < MAX_COMMANDS) begin
                    command_start_time[command_id_received] <= cycle_counter;
                    $display("STATS: Recorded start time for command %0d at cycle %0d", 
                            command_id_received, cycle_counter);
                end
            end
            
            // Track pipeline stages
            if (irp_created) irps_created_count <= irps_created_count + 1;
            if (srb_created) srbs_created_count <= srbs_created_count + 1;
            if (nvme_cmd_issued) nvme_cmds_issued_count <= nvme_cmds_issued_count + 1;
            
            // Track completions and calculate latency
            if (nvme_cpl_received && latency_track_enable && command_id_completed < MAX_COMMANDS) begin
                nvme_cpls_received_count <= nvme_cpls_received_count + 1;
                
                // Calculate latency if we have a start time
                if (command_start_time[command_id_completed] > 0) begin
                    automatic reg [63:0] start_time = command_start_time[command_id_completed];
                    automatic reg [63:0] end_time = cycle_counter;
                    automatic reg [31:0] latency;
                    
                    // Calculate latency in cycles
                    if (end_time >= start_time) begin
                        latency = end_time - start_time;
                    end else begin
                        // Handle counter wrap-around
                        latency = (64'hFFFFFFFFFFFFFFFF - start_time) + end_time + 1;
                    end
                    
                    // Store latency in history
                    if (latency_write_ptr < LATENCY_HISTORY_DEPTH) begin
                        command_latencies[latency_write_ptr] <= latency;
                        latency_write_ptr <= latency_write_ptr + 1;
                        latency_count <= latency_count + 1;
                        
                        // Update min/max
                        if (latency < min_latency_cycles) min_latency_cycles <= latency;
                        if (latency > max_latency_cycles) max_latency_cycles <= latency;
                        
                        // Update total for average
                        total_latency_cycles <= total_latency_cycles + latency;
                        
                        // Update average
                        if (latency_count > 0) begin
                            average_latency_cycles <= total_latency_cycles / latency_count;
                        end
                        
                        commands_with_latency <= latency_count;
                        
                        $display("STATS: Command %0d latency = %0d cycles (min=%0d, max=%0d, avg=%0d)", 
                                command_id_completed, latency, min_latency_cycles, 
                                max_latency_cycles, average_latency_cycles);
                    end
                    
                    // Clear the start time
                    command_start_time[command_id_completed] <= 0;
                end
            end
            
            // Track queue depth
            current_depth <= current_queue_depth;
            if (current_depth > max_queue_depth) begin
                max_queue_depth <= current_depth;
            end
            
            // Calculate percentiles periodically (every 64 completions or when requested)
            if (latency_count >= 10 && (latency_count % 64 == 0 || nvme_cpl_received)) begin
                calculate_percentiles();
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
            for (i = 0; i < latency_write_ptr; i = i + 1) begin
                if (command_latencies[i] > 0) begin
                    sorted_latencies[sorted_count] = command_latencies[i];
                    sorted_count = sorted_count + 1;
                end
            end
            
            if (sorted_count > 0) begin
                // Simple bubble sort (for moderate number of samples)
                for (i = 0; i < sorted_count - 1; i = i + 1) begin
                    for (j = 0; j < sorted_count - i - 1; j = j + 1) begin
                        if (sorted_latencies[j] > sorted_latencies[j + 1]) begin
                            temp_latency = sorted_latencies[j];
                            sorted_latencies[j] = sorted_latencies[j + 1];
                            sorted_latencies[j + 1] = temp_latency;
                        end
                    end
                end
                
                // Calculate percentile indices
                p95_pos = (sorted_count * 95 + 99) / 100; // Round up
                p99_pos = (sorted_count * 99 + 99) / 100; // Round up
                
                // Ensure indices are within bounds
                if (p95_pos >= sorted_count) p95_pos = sorted_count - 1;
                if (p99_pos >= sorted_count) p99_pos = sorted_count - 1;
                
                // Set percentile values
                p95_latency_cycles <= sorted_latencies[p95_pos];
                p99_latency_cycles <= sorted_latencies[p99_pos];
                
                $display("STATS: Percentiles calculated - p95=%0d, p99=%0d (based on %0d samples)", 
                        sorted_latencies[p95_pos], sorted_latencies[p99_pos], sorted_count);
            end
        end
    endtask
    
endmodule

// ============================================================================
// Updated Top Module with Debug Outputs and Latency Tracking
// ============================================================================
module windows_storage_stack_core_fixed #(
    parameter CMD_FIFO_DEPTH = 64,
    parameter NUM_IO_QUEUES = 8,
    parameter PRP_POOL_SIZE = 256
)(
    input wire clk,
    input wire reset_n,
    
    // Command Input Interface
    input wire cmd_in_valid,
    input wire [127:0] cmd_in_data,
    output wire cmd_in_ready,
    
    // Completion Output Interface
    output wire completion_out_valid,
    output wire [31:0] completion_status,
    output wire [31:0] completion_info,
    
    // NVMe Physical Interface
    output wire nvme_cmd_valid,
    output wire [511:0] nvme_cmd_data,
    input wire nvme_cmd_ready,
    input wire nvme_cpl_valid,
    input wire [127:0] nvme_cpl_data,
    output wire nvme_cpl_ready,
    
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
    
    // Latency Statistics
    output wire [31:0] stat_min_latency,
    output wire [31:0] stat_max_latency,
    output wire [31:0] stat_avg_latency,
    output wire [31:0] stat_p95_latency,
    output wire [31:0] stat_p99_latency,
    output wire [31:0] stat_commands_with_latency,
    
    // DEBUG OUTPUTS
    output wire [3:0] debug_blk_state,
    output wire [31:0] debug_blk_fifo_count,
    output wire [31:0] debug_blk_srb_fifo_count,
    output wire [15:0] debug_blk_current_irp_id,
    output wire [3:0] debug_nvme_state,
    output wire [31:0] debug_nvme_srb_fifo_count,
    output wire [31:0] debug_nvme_cpl_fifo_count,
    output wire [31:0] debug_nvme_queue_counts_sum,
    output wire [15:0] completion_irp_id_out
);
    
    // Internal interfaces
    wire [127:0] parsed_cmd_data;
    wire parsed_cmd_valid;
    wire parsed_cmd_ready;
    
    wire [511:0] irp_data;
    wire irp_valid;
    wire irp_ready;
    
    wire [1023:0] srb_data;
    wire srb_valid;
    wire srb_ready;
    
    wire [15:0] completion_irp_id;
    wire completion_int_valid;
    wire [31:0] completion_int_status;
    wire [31:0] completion_int_info;
    
    wire [31:0] block_layer_cycles;
    wire [31:0] irps_processed;
    
    wire [63:0] nvme_cmds_issued;
    wire [63:0] nvme_cpls_received;
    wire [31:0] nvme_queue_util;
    
    wire [63:0] total_irps_created;
    wire [31:0] active_irp_count;
    
    // Statistics tracking signals
    wire command_received;
    wire command_is_write;
    wire [31:0] command_size_bytes;
    wire irp_created;
    wire srb_created;
    wire nvme_cmd_issued;
    wire nvme_cpl_received;
    
    // Latency tracking signals
    reg [15:0] command_id_counter;
    wire [15:0] current_command_id;
    wire latency_track_enable;
    
    // Simplified command parser
    assign parsed_cmd_valid = cmd_in_valid;
    assign parsed_cmd_data = cmd_in_data;
    assign cmd_in_ready = parsed_cmd_ready;
    
    // Command ID assignment
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            command_id_counter <= 0;
        end else if (cmd_in_valid && cmd_in_ready) begin
            command_id_counter <= command_id_counter + 1;
        end
    end
    
    assign current_command_id = command_id_counter;
    assign latency_track_enable = 1'b1; // Always track latency for all commands
    
    // Statistics event tracking
    assign command_received = parsed_cmd_valid && parsed_cmd_ready;
    assign command_is_write = parsed_cmd_data[0];
    assign command_size_bytes = parsed_cmd_data[95:64];
    assign irp_created = irp_valid && irp_ready;
    assign srb_created = srb_valid && srb_ready;
    assign nvme_cmd_issued = nvme_cmd_valid && nvme_cmd_ready;
    assign nvme_cpl_received = nvme_cpl_valid && nvme_cpl_ready;

    assign completion_irp_id_out = completion_irp_id;
    
    // Instantiate modules
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
    
    // Enhanced Performance statistics collector with latency tracking
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
        .total_latency_cycles(), // Internal only
        .average_latency_cycles(stat_avg_latency),
        .p95_latency_cycles(stat_p95_latency),
        .p99_latency_cycles(stat_p99_latency),
        .commands_with_latency(stat_commands_with_latency)
    );
    
    // Map completion output
    assign completion_out_valid = completion_int_valid;
    assign completion_status = completion_int_status;
    assign completion_info = completion_int_info;
    
endmodule

// ============================================================================
// Testbench Debug Ports with Enhanced Latency Statistics
// ============================================================================
module tb_windows_storage_stack;
    
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
    
endmodule