module pcie_config_space #(
    parameter VENDOR_ID = 16'h8086,
    parameter DEVICE_ID = 16'h0953,
    parameter SUBSYSTEM_VENDOR_ID = 16'h8086,
    parameter SUBSYSTEM_ID = 16'h0001,
    parameter CLASS_CODE = 24'h010802,
    parameter REVISION_ID = 8'h02
)(
    input wire clk,
    input wire reset,

    input wire [7:0] cfg_addr,
    input wire [31:0] cfg_wr_data,
    input wire cfg_wr_en,

    output reg [63:0] bar0_base_addr,

    output reg msi_enabled,
    output reg [31:0] msi_address,
    output reg [15:0] msi_data
);

    typedef struct packed {
        logic [15:0] vendor_id;
        logic [15:0] device_id;
        logic [15:0] command;
        logic [15:0] status;
        logic [7:0] revision_id;
        logic [23:0] class_code;
        logic [7:0] cache_line_size;
        logic [7:0] latency_timer;
        logic [7:0] header_type;
        logic [7:0] bist;
        logic [31:0] bar0;
        logic [31:0] bar1;
        logic [31:0] bar2;
        logic [31:0] bar3;
        logic [31:0] bar4;
        logic [31:0] bar5;
        logic [31:0] cardbus_cis_ptr;
        logic [15:0] subsystem_vendor_id;
        logic [15:0] subsystem_id;
        logic [31:0] expansion_rom_base;
        logic [7:0] capabilities_ptr;
        logic [7:0] reserved1;
        logic [15:0] reserved2;
        logic [31:0] reserved3;
        logic [7:0] interrupt_line;
        logic [7:0] interrupt_pin;
        logic [7:0] min_grant;
        logic [7:0] max_latency;
    } pcie_config_header_t;

    typedef struct packed {
        logic [7:0] capability_id;
        logic [7:0] next_capability_ptr;
        logic [15:0] message_control;
        logic [31:0] message_address;
        logic [31:0] message_upper_address;
        logic [15:0] message_data;
        logic [31:0] mask_bits;
        logic [31:0] pending_bits;
    } msi_capability_t;

    pcie_config_header_t config_header;
    msi_capability_t msi_cap;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            config_header.vendor_id <= VENDOR_ID;
            config_header.device_id <= DEVICE_ID;
            config_header.command <= 16'h0000;
            config_header.status <= 16'h0010;
            config_header.revision_id <= REVISION_ID;
            config_header.class_code <= CLASS_CODE;
            config_header.cache_line_size <= 8'h00;
            config_header.latency_timer <= 8'h00;
            config_header.header_type <= 8'h00;
            config_header.bist <= 8'h00;
            config_header.bar0 <= 32'hFFFF0004;
            config_header.bar1 <= 32'h00000000;
            config_header.bar2 <= 32'h00000000;
            config_header.bar3 <= 32'h00000000;
            config_header.bar4 <= 32'h00000000;
            config_header.bar5 <= 32'h00000000;
            config_header.subsystem_vendor_id <= SUBSYSTEM_VENDOR_ID;
            config_header.subsystem_id <= SUBSYSTEM_ID;
            config_header.expansion_rom_base <= 32'h00000000;
            config_header.capabilities_ptr <= 8'h40;
            config_header.interrupt_line <= 8'h00;
            config_header.interrupt_pin <= 8'h01;
            config_header.min_grant <= 8'h00;
            config_header.max_latency <= 8'h00;

            msi_cap.capability_id <= 8'h05;
            msi_cap.next_capability_ptr <= 8'h00;
            msi_cap.message_control <= 16'h0080;
            msi_cap.message_address <= 32'hFEE00000;
            msi_cap.message_upper_address <= 32'h00000000;
            msi_cap.message_data <= 16'h0000;
            msi_cap.mask_bits <= 32'h00000000;
            msi_cap.pending_bits <= 32'h00000000;

            bar0_base_addr <= 64'h0;
            msi_enabled <= 0;
            msi_address <= 0;
            msi_data <= 0;
        end else begin
            if (cfg_wr_en) begin //if write, based on address do a specific write
                case (cfg_addr)
                    8'h04: begin //register update
                        config_header.command <= cfg_wr_data[15:0];
                        //$display("PCIe Config: Command register updated: %h", cfg_wr_data[15:0]);
                    end
                    8'h10: begin //bar0 update
                        config_header.bar0 <= cfg_wr_data;
                        bar0_base_addr[31:0] <= cfg_wr_data & 32'hFFFFFFF0;
                        //$display("PCIe Config: BAR0 updated: %h", cfg_wr_data);
                    end
                    8'h14: begin //bar1 update
                        config_header.bar1 <= cfg_wr_data;
                        bar0_base_addr[63:32] <= cfg_wr_data;
                        //$display("PCIe Config: BAR1 (BAR0 upper) updated: %h", cfg_wr_data);
                    end
                    8'h42: begin //MSI message control update
                        msi_cap.message_control <= cfg_wr_data[15:0];
                        msi_enabled <= cfg_wr_data[0];
                        //$display("PCIe Config: MSI Message Control updated: %h", cfg_wr_data[15:0]);
                    end
                    8'h44: begin //MSI message addy update
                        msi_cap.message_address <= cfg_wr_data;
                        msi_address <= cfg_wr_data;
                        //$display("PCIe Config: MSI Message Address updated: %h", cfg_wr_data);
                    end
                    8'h4C: begin //MSI message data update
                        msi_cap.message_data <= cfg_wr_data[15:0];
                        msi_data <= cfg_wr_data[15:0];
                        //$display("PCIe Config: MSI Message Data updated: %h", cfg_wr_data[15:0]);
                    end
                    8'h44: begin //not implemented, but this would be power management
                        //$display("PCIe Config: Power Management Control updated: %h", cfg_wr_data);
                    end
                    default: ;//do nothing
                endcase
            end
        end
    end
endmodule