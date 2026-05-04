module msi_interrupt_controller #(
    parameter NUM_VECTORS = 32,
    parameter NUM_QUEUES = 8
)(
    input wire clk,
    input wire reset,

    input wire [31:0] msi_address,
    input wire [15:0] msi_data_base,
    input wire msi_enabled,

    input wire [NUM_QUEUES:0] interrupt_request,
    input wire [5:0] interrupt_vector [0:NUM_QUEUES],

    output reg msi_mem_wr_en
);

    typedef enum logic [1:0] {
        MSI_IDLE,
        MSI_SENDING,
        MSI_COMPLETE
    } msi_state_t;
    msi_state_t current_state, next_state;

    reg [31:0] msi_data_reg;
    reg [63:0] msi_addr_reg;
    reg [5:0] current_vector;

    reg [NUM_VECTORS-1:0] vector_pending;
    reg [NUM_VECTORS-1:0] vector_masked;
    reg [4:0] arbitration_pointer;

    logic found_vector;
    logic [5:0] selected_vector;

    integer i;

    //vector selection
    always_comb begin
        found_vector = 1'b0;
        selected_vector = 6'b0;
        if ((vector_pending & ~vector_masked) && msi_enabled) begin //check that a vector that is both pending and not masked exists
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

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= MSI_IDLE;
            vector_pending <= 0;
            vector_masked <= 0;
            msi_mem_wr_en <= 0;
            arbitration_pointer <= 0;
            current_vector <= 0;
        end else begin
            msi_mem_wr_en <= 0;
            current_state <= next_state;

            for (i = 0; i <= NUM_QUEUES; i = i + 1) begin
                if (interrupt_request[i]) begin //if interrupt
                    if (interrupt_vector[i] < NUM_VECTORS) begin //if room
                        vector_pending[interrupt_vector[i]] <= 1'b1; //start pending
                        //$display("MSI: Interrupt requested for queue %0d -> vector %0d", i, vec);
                    end
                end
            end

            case (current_state)
                MSI_IDLE: begin
                    if (found_vector) begin //idle until found valid vec (goes to sending next)
                        current_vector <= selected_vector;
                        arbitration_pointer <= (selected_vector + 1) % NUM_VECTORS;
                        msi_addr_reg <= msi_address;
                        msi_data_reg <= {16'h0, msi_data_base + selected_vector};
                    end
                end

                MSI_SENDING: begin
                    msi_mem_wr_en <= 1'b1; //enable the mem write
                    //$display("MSI: Asserting msi_mem_wr_en for vector %0d", current_vector);
                end

                MSI_COMPLETE: begin
                    vector_pending[current_vector] <= 0; //no longer pending since done
                    //$display("MSI: Sent MSI for vector %0d, address=%h, data=%h", current_vector, msi_addr_reg, msi_data_reg);
                end
            endcase
        end
    end

    always_comb begin
        next_state = current_state;
        case (current_state)
            MSI_IDLE: if (found_vector) next_state = MSI_SENDING;
            MSI_SENDING: next_state = MSI_COMPLETE;
            MSI_COMPLETE: next_state = MSI_IDLE;
            default: next_state = MSI_IDLE;
        endcase
    end
endmodule