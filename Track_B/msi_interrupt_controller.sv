// ============================================================================
// New: MSI/MSI-X Interrupt Controller
// ============================================================================
module msi_interrupt_controller #(
    parameter NUM_VECTORS = 32,
    parameter NUM_QUEUES = 8
)(
    input wire clk,
    input wire reset_n,
    
    // MSI Configuration
    input wire [31:0] msi_address,
    input wire [15:0] msi_data_base,
    input wire msi_enabled,
    input wire [2:0] msi_capability,
    
    // Interrupt Requests from Queues
    input wire [NUM_QUEUES:0] interrupt_request,  // +1 for admin queue
    input wire [5:0] interrupt_vector [0:NUM_QUEUES],
    
    // PCIe Memory Write Interface (for MSI)
    output reg msi_mem_wr_en,
    output reg [63:0] msi_mem_addr,
    output reg [31:0] msi_mem_data,
    output reg [3:0] msi_mem_be,
    input wire msi_mem_ready,
    
    // Interrupt Status
    output reg [31:0] interrupt_status,
    output reg [31:0] interrupt_mask,
    output reg [31:0] interrupt_pending,
    
    // Statistics
    output reg [31:0] msi_sent_count,
    output reg [31:0] interrupt_count [0:NUM_QUEUES]
);

    // MSI Message Control States
    typedef enum logic [1:0] {
        MSI_IDLE,
        MSI_SENDING,     // assert msi_mem_wr_en for one cycle
        MSI_COMPLETE     // move back to IDLE after clearing pending
    } msi_state_t;
    
    msi_state_t current_state, next_state;
    
    // Interrupt registers
    reg [31:0] int_status_reg;
    reg [31:0] int_mask_reg;
    reg [31:0] int_pending_reg;
    
    // MSI generation
    reg [31:0] msi_data_reg;
    reg [63:0] msi_addr_reg;
    reg [5:0] current_vector;
    
    // Per-vector pending bits
    reg [NUM_VECTORS-1:0] vector_pending;
    reg [NUM_VECTORS-1:0] vector_masked;
    
    // Arbitration
    reg [4:0] arbitration_pointer;
    
    // Vector selection logic
    logic found_vector;
    logic [5:0] selected_vector;
    
    // Vector selection combinational logic
    always_comb begin
        found_vector = 1'b0;
        selected_vector = 6'b0;
        
        if (|(vector_pending & ~vector_masked) && msi_enabled) begin
            // Find highest priority pending interrupt (round-robin)
            for (int i = 0; i < NUM_VECTORS; i = i + 1) begin
                automatic logic [5:0] idx = (arbitration_pointer + i) % NUM_VECTORS;
                if (vector_pending[idx] && ~vector_masked[idx]) begin
                    selected_vector = idx;
                    found_vector = 1'b1;
                    break;
                end
            end
        end
    end
    
    // State machine – combinational next state
    always_comb begin
        next_state = current_state;
        case (current_state)
            MSI_IDLE:     if (found_vector) next_state = MSI_SENDING;
            MSI_SENDING:  next_state = MSI_COMPLETE;   // pulse one cycle, then done
            MSI_COMPLETE: next_state = MSI_IDLE;
        endcase
    end
    
    integer i;
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= MSI_IDLE;
            int_status_reg <= 0;
            int_mask_reg <= 0;
            int_pending_reg <= 0;
            vector_pending <= 0;
            vector_masked <= 0;
            
            // Defaults
            msi_mem_wr_en <= 0;
            msi_mem_addr <= 0;
            msi_mem_data <= 0;
            msi_mem_be <= 4'b1111;
            
            msi_sent_count <= 0;
            for (i = 0; i <= NUM_QUEUES; i = i + 1) begin
                interrupt_count[i] <= 0;
            end
            
            arbitration_pointer <= 0;
            current_vector <= 0;
        end else begin
            // Defaults
            msi_mem_wr_en <= 0;
            
            current_state <= next_state;
            
            // Capture interrupt requests
            for (i = 0; i <= NUM_QUEUES; i = i + 1) begin
                if (interrupt_request[i]) begin
                    automatic logic [5:0] vec = interrupt_vector[i];
                    if (vec < NUM_VECTORS) begin
                        vector_pending[vec] <= 1'b1;
                        interrupt_count[i] <= interrupt_count[i] + 1;
                        $display("MSI: Interrupt requested for queue %0d -> vector %0d", i, vec);
                    end
                end
            end
            
            // Update status registers
            int_status_reg <= vector_pending;
            int_pending_reg <= vector_pending & ~vector_masked;
            
            case (current_state)
                MSI_IDLE: begin
                    if (found_vector) begin
                        // Capture selected vector and advance arbitration
                        current_vector <= selected_vector;
                        arbitration_pointer <= (selected_vector + 1) % NUM_VECTORS;
                        
                        // Prepare MSI message
                        msi_addr_reg <= msi_address;
                        msi_data_reg <= {16'h0, msi_data_base + selected_vector};
                    end
                end
                
                MSI_SENDING: begin
                    // Assert write enable for exactly one cycle
                    msi_mem_wr_en <= 1'b1;
                    msi_mem_addr <= msi_addr_reg;
                    msi_mem_data <= msi_data_reg;
                    $display("MSI: Asserting msi_mem_wr_en for vector %0d", current_vector);
                end
                
                MSI_COMPLETE: begin
                    // Clear the pending bit and increment sent count
                    vector_pending[current_vector] <= 0;
                    msi_sent_count <= msi_sent_count + 1;
                    $display("MSI: Sent MSI for vector %0d, address=%h, data=%h",
                            current_vector, msi_addr_reg, msi_data_reg);
                end
            endcase
            
            // Handle mask (via configuration)
            if (int_mask_reg != 0)
                vector_masked <= int_mask_reg[NUM_VECTORS-1:0];
        end
    end
    
    // Map outputs
    assign interrupt_status = int_status_reg;
    assign interrupt_mask   = int_mask_reg;
    assign interrupt_pending = int_pending_reg;
    
endmodule