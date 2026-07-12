module CoralNpuLiteCfg9AxiLitePeripheral #(
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 10
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN, FREQ_HZ 25000000" *)
  input  wire                              S_AXI_ACLK,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                              S_AXI_ARESETN,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 25000000, ADDR_WIDTH 10, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input  wire [2:0]                        S_AXI_AWPROT,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                              S_AXI_AWVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                              S_AXI_AWREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                              S_AXI_WVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                              S_AXI_WREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output wire [1:0]                        S_AXI_BRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output wire                              S_AXI_BVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                              S_AXI_BREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input  wire [2:0]                        S_AXI_ARPROT,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                              S_AXI_ARVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                              S_AXI_ARREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output wire [1:0]                        S_AXI_RRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output wire                              S_AXI_RVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                              S_AXI_RREADY,
  output wire [3:0]                        led
);
  localparam [31:0] REG_MAGIC = 32'h434E_5055;
  localparam [31:0] REG_VERSION = 32'h20260712;

  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_MAGIC          = 'h00;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_VERSION        = 'h04;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CONTROL        = 'h08;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS         = 'h0C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_HEARTBEAT      = 'h10;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_BOOT_ADDR      = 'h14;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_COUNT    = 'h18;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_LASTDATA = 'h1C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_LASTOP   = 'h20;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_HIT        = 'h24;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_MISS       = 'h28;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_INVALIDATE = 'h2C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_PRODUCE    = 'h30;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_TAIL_HIT   = 'h34;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_INTERIOR   = 'h38;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_RIGHT_EDGE = 'h3C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_ROW_LAST   = 'h40;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_TRACE_WORD = 'h44;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_TRACE_AUX  = 'h48;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_EVENT_STATUS = 'h4C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_LAST_EVENT = 'h50;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROWHANDOFF_TRACE_META = 'h54;

  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RADDR    = 'h80;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA0   = 'h84;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA1   = 'h88;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA2   = 'h8C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA3   = 'h90;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_STATUS   = 'h94;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WADDR    = 'h98;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA0   = 'h9C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA1   = 'hA0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA2   = 'hA4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA3   = 'hA8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WTRIG    = 'hAC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_EVENT_IN = 'hB0;

  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_ADDR       = 'hB4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_WDATA      = 'hB8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_OP         = 'hBC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_TRIG       = 'hC0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_RDATA      = 'hC4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_ROP        = 'hC8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_STATUS     = 'hCC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT0     = 'h110;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT1     = 'h114;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT2     = 'h118;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_BIAS     = 'h11C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_CTRL        = 'h180;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW0_LO     = 'h184;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW0_HI     = 'h188;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW1_LO     = 'h18C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW1_HI     = 'h190;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW2_LO     = 'h194;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW2_HI     = 'h198;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_STATUS      = 'h19C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT0     = 'h1A0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT1     = 'h1A4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT2     = 'h1A8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RELU8       = 'h1AC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_COUNT       = 'h1B0;

  reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
  reg                          axi_awready;
  reg                          axi_wready;
  reg [1:0]                    axi_bresp;
  reg                          axi_bvalid;
  reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
  reg                          axi_arready;
  reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
  reg [1:0]                    axi_rresp;
  reg                          axi_rvalid;
  reg                          aw_en;

  reg [31:0] control;
  reg [31:0] heartbeat;
  reg [31:0] boot_addr;
  reg        soft_reset_pulse;

  reg [31:0] corecsr_read_addr;
  reg [31:0] corecsr_write_addr;
  reg [127:0] corecsr_write_data;
  reg corecsr_write_pulse;
  reg [15:0] corecsr_event_count;

  reg [31:0] debug_req_addr;
  reg [31:0] debug_req_data;
  reg [1:0]  debug_req_op;
  reg        debug_req_pulse;
  reg [31:0] debug_last_rsp_data;
  reg [1:0]  debug_last_rsp_op;
  reg        debug_seen_rsp;
  reg [15:0] debug_req_count;
  reg [15:0] debug_rsp_count;
  reg [31:0] rowhandoff_last_event_word;
  reg [15:0] rowhandoff_trace_event_count;
  reg        rowhandoff_last_event_valid;
  reg [31:0] gesture_wgt0;
  reg [31:0] gesture_wgt1;
  reg [31:0] gesture_wgt2;
  reg [31:0] gesture_bias;
  reg [31:0] win3_row0_lo;
  reg [31:0] win3_row0_hi;
  reg [31:0] win3_row1_lo;
  reg [31:0] win3_row1_hi;
  reg [31:0] win3_row2_lo;
  reg [31:0] win3_row2_hi;
  reg        win3_start_pulse;
  reg        win3_clear_pulse;
  reg        win3_auto_start;
  reg        win3_autostart_pending;
  reg [31:0] win3_control_snapshot;
  reg        win3_done_latched;

  wire reset = ~S_AXI_ARESETN | soft_reset_pulse;

  wire corecsr_read_valid;
  wire [127:0] corecsr_read_data;
  wire corecsr_write_resp;
  wire corecsr_reset_req;
  wire corecsr_cg_req;
  wire [31:0] corecsr_pc_start;
  wire corecsr_debug_req_valid;
  wire [31:0] corecsr_debug_req_address;
  wire [31:0] corecsr_debug_req_data;
  wire [1:0] corecsr_debug_req_op;
  wire corecsr_debug_rsp_ready;
  wire rowhandoff_event_layer_start;
  wire [5:0] rowhandoff_event_row_out_y_in;
  wire rowhandoff_event_row_out_y_write_pulse;
  wire rowhandoff_event_hit_pulse;
  wire rowhandoff_event_tail_hit_pulse;
  wire rowhandoff_event_miss_pulse;
  wire rowhandoff_event_invalidate_pulse;
  wire rowhandoff_event_produce_pulse;
  wire rowhandoff_event_interior_enter_pulse;
  wire rowhandoff_event_right_edge_done_pulse;

  wire [15:0] rowhandoff_hit_count;
  wire [15:0] rowhandoff_miss_count;
  wire [15:0] rowhandoff_invalidate_count;
  wire [15:0] rowhandoff_produce_count;
  wire [15:0] rowhandoff_tail_hit_count;
  wire [15:0] rowhandoff_interior_count;
  wire [15:0] rowhandoff_right_edge_count;
  wire [5:0] rowhandoff_row_last;
  wire [31:0] rowhandoff_state_trace_word;
  wire rowhandoff_row_gate_active;
  wire [5:0] rowhandoff_current_row;
  wire rowhandoff_valid_state;
  wire rowhandoff_consume_valid;
  wire rowhandoff_consume_hit;
  wire rowhandoff_tail_seen;
  wire [5:0] rowhandoff_last_produced_row;
  wire [5:0] rowhandoff_last_invalidated_row;
  wire rowhandoff_row_enter_pulse;
  wire rowhandoff_row_terminal_done_pulse;
  wire rowhandoff_row_advance_done_pulse;
  wire win3_busy;
  wire win3_valid;
  wire [31:0] win3_result0;
  wire [31:0] win3_result1;
  wire [31:0] win3_result2;
  wire [7:0] win3_relu8_0;
  wire [7:0] win3_relu8_1;
  wire [7:0] win3_relu8_2;
  wire [31:0] win3_out_count;

  wire core_halted;
  wire core_fault;
  wire core_wfi;

  wire core_dm_req_ready;
  wire core_dm_rsp_valid;
  wire [31:0] core_dm_rsp_data;
  wire [1:0] core_dm_rsp_op;

  wire debug_mux_req_valid = corecsr_debug_req_valid | debug_req_pulse;
  wire [31:0] debug_mux_req_addr = corecsr_debug_req_valid ? corecsr_debug_req_address : debug_req_addr;
  wire [31:0] debug_mux_req_data = corecsr_debug_req_valid ? corecsr_debug_req_data : debug_req_data;
  wire [1:0] debug_mux_req_op = corecsr_debug_req_valid ? corecsr_debug_req_op : debug_req_op;

  assign S_AXI_AWREADY = axi_awready;
  assign S_AXI_WREADY  = axi_wready;
  assign S_AXI_BRESP   = axi_bresp;
  assign S_AXI_BVALID  = axi_bvalid;
  assign S_AXI_ARREADY = axi_arready;
  assign S_AXI_RDATA   = axi_rdata;
  assign S_AXI_RRESP   = axi_rresp;
  assign S_AXI_RVALID  = axi_rvalid;

  wire slv_reg_wren = axi_wready & S_AXI_WVALID & axi_awready & S_AXI_AWVALID;
  wire slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_awready <= 1'b0;
      aw_en <= 1'b1;
    end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
      axi_awready <= 1'b1;
      aw_en <= 1'b0;
    end else if (S_AXI_BREADY && axi_bvalid) begin
      axi_awready <= 1'b0;
      aw_en <= 1'b1;
    end else begin
      axi_awready <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_awaddr <= {C_S_AXI_ADDR_WIDTH{1'b0}};
    end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
      axi_awaddr <= S_AXI_AWADDR;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_wready <= 1'b0;
    end else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) begin
      axi_wready <= 1'b1;
    end else begin
      axi_wready <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_bvalid <= 1'b0;
      axi_bresp <= 2'b00;
    end else if (slv_reg_wren && ~axi_bvalid) begin
      axi_bvalid <= 1'b1;
      axi_bresp <= 2'b00;
    end else if (S_AXI_BREADY && axi_bvalid) begin
      axi_bvalid <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_arready <= 1'b0;
      axi_araddr <= {C_S_AXI_ADDR_WIDTH{1'b0}};
    end else if (~axi_arready && S_AXI_ARVALID) begin
      axi_arready <= 1'b1;
      axi_araddr <= S_AXI_ARADDR;
    end else begin
      axi_arready <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      axi_rvalid <= 1'b0;
      axi_rresp <= 2'b00;
    end else if (slv_reg_rden) begin
      axi_rvalid <= 1'b1;
      axi_rresp <= 2'b00;
    end else if (axi_rvalid && S_AXI_RREADY) begin
      axi_rvalid <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (reset) begin
      win3_done_latched <= 1'b0;
    end else begin
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_CTRL && S_AXI_WSTRB[0] && S_AXI_WDATA[1]) begin
        win3_done_latched <= 1'b0;
      end else if (win3_valid || (win3_out_count != 32'd0)) begin
        win3_done_latched <= 1'b1;
      end
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      control <= 32'h00000001;
      heartbeat <= 32'd0;
      boot_addr <= 32'h00000000;
      soft_reset_pulse <= 1'b0;
      corecsr_read_addr <= 32'h00000000;
      corecsr_write_addr <= 32'h00000000;
      corecsr_write_data <= 128'd0;
      corecsr_write_pulse <= 1'b0;
      corecsr_event_count <= 16'd0;
      debug_req_addr <= 32'd0;
      debug_req_data <= 32'd0;
      debug_req_op <= 2'd1;
      debug_req_pulse <= 1'b0;
      debug_last_rsp_data <= 32'd0;
      debug_last_rsp_op <= 2'd0;
      debug_seen_rsp <= 1'b0;
      debug_req_count <= 16'd0;
      debug_rsp_count <= 16'd0;
      rowhandoff_last_event_word <= 32'd0;
      rowhandoff_trace_event_count <= 16'd0;
      rowhandoff_last_event_valid <= 1'b0;
      gesture_wgt0 <= 32'd0;
      gesture_wgt1 <= 32'd0;
      gesture_wgt2 <= 32'd0;
      gesture_bias <= 32'd0;
      win3_row0_lo <= 32'd0;
      win3_row0_hi <= 32'd0;
      win3_row1_lo <= 32'd0;
      win3_row1_hi <= 32'd0;
      win3_row2_lo <= 32'd0;
      win3_row2_hi <= 32'd0;
      win3_start_pulse <= 1'b0;
      win3_clear_pulse <= 1'b0;
      win3_auto_start <= 1'b0;
      win3_autostart_pending <= 1'b0;
      win3_control_snapshot <= 32'd0;
    end else begin
      heartbeat <= heartbeat + 32'd1;
      soft_reset_pulse <= 1'b0;
      corecsr_write_pulse <= 1'b0;
      debug_req_pulse <= 1'b0;
      win3_start_pulse <= win3_autostart_pending & ~win3_busy;
      win3_clear_pulse <= 1'b0;
      win3_autostart_pending <= win3_autostart_pending & win3_busy;

      if (core_dm_rsp_valid) begin
        debug_last_rsp_data <= core_dm_rsp_data;
        debug_last_rsp_op <= core_dm_rsp_op;
        debug_seen_rsp <= 1'b1;
        debug_rsp_count <= debug_rsp_count + 16'd1;
      end

      if (slv_reg_wren && axi_awaddr == ADDR_CONTROL) begin
        if (S_AXI_WSTRB[0]) begin
          control[7:0] <= S_AXI_WDATA[7:0];
          soft_reset_pulse <= S_AXI_WDATA[2];
          if (S_AXI_WDATA[3]) begin
            debug_seen_rsp <= 1'b0;
          end
          if (S_AXI_WDATA[2]) begin
            rowhandoff_last_event_word <= 32'd0;
            rowhandoff_trace_event_count <= 16'd0;
            rowhandoff_last_event_valid <= 1'b0;
            win3_auto_start <= 1'b0;
            win3_autostart_pending <= 1'b0;
            win3_clear_pulse <= 1'b1;
          end
        end
      end
      if (slv_reg_wren && axi_awaddr == ADDR_BOOT_ADDR) begin
        boot_addr <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_RADDR) begin
        corecsr_read_addr <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WADDR) begin
        corecsr_write_addr <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WDATA0) begin
        corecsr_write_data[31:0] <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WDATA1) begin
        corecsr_write_data[63:32] <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WDATA2) begin
        corecsr_write_data[95:64] <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WDATA3) begin
        corecsr_write_data[127:96] <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_WTRIG) begin
        corecsr_write_pulse <= 1'b1;
        corecsr_event_count <= corecsr_event_count + 16'd1;
        if (corecsr_write_addr == 32'h00000840) begin
          rowhandoff_last_event_word <= corecsr_write_data[31:0];
          rowhandoff_trace_event_count <= rowhandoff_trace_event_count + 16'd1;
          rowhandoff_last_event_valid <= 1'b1;
        end
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_EVENT_IN) begin
        corecsr_write_addr <= 32'h00000840;
        corecsr_write_data <= {96'd0, S_AXI_WDATA};
        corecsr_write_pulse <= 1'b1;
        corecsr_event_count <= corecsr_event_count + 16'd1;
        rowhandoff_last_event_word <= S_AXI_WDATA;
        rowhandoff_trace_event_count <= rowhandoff_trace_event_count + 16'd1;
        rowhandoff_last_event_valid <= 1'b1;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_DEBUG_ADDR) begin
        debug_req_addr <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_DEBUG_WDATA) begin
        debug_req_data <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_DEBUG_OP) begin
        debug_req_op <= S_AXI_WDATA[1:0];
      end
      if (slv_reg_wren && axi_awaddr == ADDR_DEBUG_TRIG && core_dm_req_ready && !corecsr_debug_req_valid) begin
        debug_req_pulse <= 1'b1;
        debug_req_count <= debug_req_count + 16'd1;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_WGT0) begin
        gesture_wgt0 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_WGT1) begin
        gesture_wgt1 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_WGT2) begin
        gesture_wgt2 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_BIAS) begin
        gesture_bias <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_CTRL) begin
        win3_start_pulse <= S_AXI_WDATA[0];
        win3_clear_pulse <= S_AXI_WDATA[1];
        win3_auto_start <= S_AXI_WDATA[2];
        win3_autostart_pending <= 1'b0;
        win3_control_snapshot <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW0_LO) begin
        win3_row0_lo <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW0_HI) begin
        win3_row0_hi <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW1_LO) begin
        win3_row1_lo <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW1_HI) begin
        win3_row1_hi <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW2_LO) begin
        win3_row2_lo <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN3_ROW2_HI) begin
        win3_row2_hi <= S_AXI_WDATA;
        win3_autostart_pending <= win3_auto_start;
      end
    end
  end

  always @(*) begin
    axi_rdata = 32'd0;
    case (axi_araddr)
      ADDR_MAGIC: axi_rdata = REG_MAGIC;
      ADDR_VERSION: axi_rdata = REG_VERSION;
      ADDR_CONTROL: axi_rdata = control;
      ADDR_STATUS: axi_rdata = {24'd0, corecsr_cg_req, corecsr_reset_req, debug_seen_rsp, core_dm_rsp_valid, core_dm_req_ready, core_wfi, core_fault, core_halted};
      ADDR_HEARTBEAT: axi_rdata = heartbeat;
      ADDR_BOOT_ADDR: axi_rdata = boot_addr;
      ADDR_DEBUG_COUNT: axi_rdata = {debug_req_count, debug_rsp_count};
      ADDR_DEBUG_LASTDATA: axi_rdata = debug_last_rsp_data;
      ADDR_DEBUG_LASTOP: axi_rdata = {30'd0, debug_last_rsp_op};
      ADDR_ROWHANDOFF_HIT: axi_rdata = {16'd0, rowhandoff_hit_count};
      ADDR_ROWHANDOFF_MISS: axi_rdata = {16'd0, rowhandoff_miss_count};
      ADDR_ROWHANDOFF_INVALIDATE: axi_rdata = {16'd0, rowhandoff_invalidate_count};
      ADDR_ROWHANDOFF_PRODUCE: axi_rdata = {16'd0, rowhandoff_produce_count};
      ADDR_ROWHANDOFF_TAIL_HIT: axi_rdata = {16'd0, rowhandoff_tail_hit_count};
      ADDR_ROWHANDOFF_INTERIOR: axi_rdata = {16'd0, rowhandoff_interior_count};
      ADDR_ROWHANDOFF_RIGHT_EDGE: axi_rdata = {16'd0, rowhandoff_right_edge_count};
      ADDR_ROWHANDOFF_ROW_LAST: axi_rdata = {26'd0, rowhandoff_row_last};
      ADDR_ROWHANDOFF_TRACE_WORD: axi_rdata = rowhandoff_state_trace_word;
      ADDR_ROWHANDOFF_TRACE_AUX: axi_rdata = {rowhandoff_last_invalidated_row, rowhandoff_last_produced_row, rowhandoff_tail_seen, rowhandoff_consume_hit, rowhandoff_consume_valid, rowhandoff_valid_state, rowhandoff_row_gate_active, rowhandoff_row_advance_done_pulse, rowhandoff_row_terminal_done_pulse, rowhandoff_row_enter_pulse, rowhandoff_current_row, 6'd0};
      ADDR_ROWHANDOFF_EVENT_STATUS: axi_rdata = {rowhandoff_trace_event_count, 12'd0, rowhandoff_last_event_valid, rowhandoff_event_right_edge_done_pulse, rowhandoff_event_interior_enter_pulse, rowhandoff_event_produce_pulse};
      ADDR_ROWHANDOFF_LAST_EVENT: axi_rdata = rowhandoff_last_event_word;
      ADDR_ROWHANDOFF_TRACE_META: axi_rdata = {4'd0, 12'h840, rowhandoff_trace_event_count};
      ADDR_CORECSR_RADDR: axi_rdata = corecsr_read_addr;
      ADDR_CORECSR_RDATA0: axi_rdata = corecsr_read_data[31:0];
      ADDR_CORECSR_RDATA1: axi_rdata = corecsr_read_data[63:32];
      ADDR_CORECSR_RDATA2: axi_rdata = corecsr_read_data[95:64];
      ADDR_CORECSR_RDATA3: axi_rdata = corecsr_read_data[127:96];
      ADDR_CORECSR_STATUS: axi_rdata = {corecsr_event_count, 11'd0, corecsr_write_resp, corecsr_read_valid, corecsr_debug_req_valid, corecsr_debug_rsp_ready, corecsr_cg_req, corecsr_reset_req};
      ADDR_CORECSR_WADDR: axi_rdata = corecsr_write_addr;
      ADDR_CORECSR_WDATA0: axi_rdata = corecsr_write_data[31:0];
      ADDR_CORECSR_WDATA1: axi_rdata = corecsr_write_data[63:32];
      ADDR_CORECSR_WDATA2: axi_rdata = corecsr_write_data[95:64];
      ADDR_CORECSR_WDATA3: axi_rdata = corecsr_write_data[127:96];
      ADDR_CORECSR_EVENT_IN: axi_rdata = rowhandoff_last_event_word;
      ADDR_DEBUG_ADDR: axi_rdata = debug_req_addr;
      ADDR_DEBUG_WDATA: axi_rdata = debug_req_data;
      ADDR_DEBUG_OP: axi_rdata = {30'd0, debug_req_op};
      ADDR_DEBUG_RDATA: axi_rdata = debug_last_rsp_data;
      ADDR_DEBUG_ROP: axi_rdata = {30'd0, debug_last_rsp_op};
      ADDR_DEBUG_STATUS: axi_rdata = {debug_req_count[7:0], debug_rsp_count[7:0], debug_seen_rsp, core_dm_rsp_valid, core_dm_req_ready, corecsr_debug_req_valid, 13'd0};
      ADDR_GESTURE_WGT0: axi_rdata = gesture_wgt0;
      ADDR_GESTURE_WGT1: axi_rdata = gesture_wgt1;
      ADDR_GESTURE_WGT2: axi_rdata = gesture_wgt2;
      ADDR_GESTURE_BIAS: axi_rdata = gesture_bias;
      ADDR_WIN3_CTRL: axi_rdata = {29'd0, win3_auto_start, win3_clear_pulse, win3_start_pulse};
      ADDR_WIN3_ROW0_LO: axi_rdata = win3_row0_lo;
      ADDR_WIN3_ROW0_HI: axi_rdata = win3_row0_hi;
      ADDR_WIN3_ROW1_LO: axi_rdata = win3_row1_lo;
      ADDR_WIN3_ROW1_HI: axi_rdata = win3_row1_hi;
      ADDR_WIN3_ROW2_LO: axi_rdata = win3_row2_lo;
      ADDR_WIN3_ROW2_HI: axi_rdata = win3_row2_hi;
      ADDR_WIN3_STATUS: axi_rdata = {30'd0, win3_done_latched, win3_busy};
      ADDR_WIN3_RESULT0: axi_rdata = win3_result0;
      ADDR_WIN3_RESULT1: axi_rdata = win3_result1;
      ADDR_WIN3_RESULT2: axi_rdata = win3_result2;
      ADDR_WIN3_RELU8: axi_rdata = {24'd0, win3_relu8_2, win3_relu8_1, win3_relu8_0};
      ADDR_WIN3_COUNT: axi_rdata = win3_out_count;
      default: axi_rdata = 32'hDEADBEEF;
    endcase
  end

  CoreCSR official_corecsr (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .io_fabric_readDataAddr_bits(corecsr_read_addr),
    .io_fabric_readData_valid(corecsr_read_valid),
    .io_fabric_readData_bits(corecsr_read_data),
    .io_fabric_writeDataAddr_valid(corecsr_write_pulse),
    .io_fabric_writeDataAddr_bits(corecsr_write_addr),
    .io_fabric_writeDataBits(corecsr_write_data),
    .io_fabric_writeResp(corecsr_write_resp),
    .io_reset(corecsr_reset_req),
    .io_cg(corecsr_cg_req),
    .io_pcStart(corecsr_pc_start),
    .io_bootAddr(boot_addr),
    .io_halted(core_halted),
    .io_fault(core_fault),
    .io_coralnpu_csr_value_0(32'd0),
    .io_coralnpu_csr_value_1(32'd0),
    .io_coralnpu_csr_value_2(32'd0),
    .io_coralnpu_csr_value_3(32'd0),
    .io_coralnpu_csr_value_4(32'd0),
    .io_coralnpu_csr_value_5(32'd0),
    .io_coralnpu_csr_value_6(32'd0),
    .io_coralnpu_csr_value_7(32'd0),
    .io_coralnpu_csr_value_8(32'd0),
    .io_rowhandoff_rowhandoff_hit_count(rowhandoff_hit_count),
    .io_rowhandoff_rowhandoff_miss_count(rowhandoff_miss_count),
    .io_rowhandoff_rowhandoff_invalidate_count(rowhandoff_invalidate_count),
    .io_rowhandoff_rowhandoff_produce_count(rowhandoff_produce_count),
    .io_rowhandoff_rowhandoff_tail_hit_count(rowhandoff_tail_hit_count),
    .io_rowhandoff_interior_row_enter_count(rowhandoff_interior_count),
    .io_rowhandoff_right_edge_done_count(rowhandoff_right_edge_count),
    .io_rowhandoff_rowhandoff_row_out_y_last(rowhandoff_row_last),
    .io_rowhandoff_rowhandoff_state_trace_word(rowhandoff_state_trace_word),
    .io_rowhandoffEvent_layerStart(rowhandoff_event_layer_start),
    .io_rowhandoffEvent_rowhandoffRowOutYIn(rowhandoff_event_row_out_y_in),
    .io_rowhandoffEvent_rowhandoffRowOutYWritePulse(rowhandoff_event_row_out_y_write_pulse),
    .io_rowhandoffEvent_rowhandoffHitPulse(rowhandoff_event_hit_pulse),
    .io_rowhandoffEvent_rowhandoffTailHitPulse(rowhandoff_event_tail_hit_pulse),
    .io_rowhandoffEvent_rowhandoffMissPulse(rowhandoff_event_miss_pulse),
    .io_rowhandoffEvent_rowhandoffInvalidatePulse(rowhandoff_event_invalidate_pulse),
    .io_rowhandoffEvent_rowhandoffProducePulse(rowhandoff_event_produce_pulse),
    .io_rowhandoffEvent_interiorRowEnterPulse(rowhandoff_event_interior_enter_pulse),
    .io_rowhandoffEvent_rightEdgeDonePulse(rowhandoff_event_right_edge_done_pulse),
    .io_debug_req_ready(core_dm_req_ready),
    .io_debug_req_valid(corecsr_debug_req_valid),
    .io_debug_req_bits_address(corecsr_debug_req_address),
    .io_debug_req_bits_data(corecsr_debug_req_data),
    .io_debug_req_bits_op(corecsr_debug_req_op),
    .io_debug_rsp_ready(corecsr_debug_rsp_ready),
    .io_debug_rsp_valid(core_dm_rsp_valid),
    .io_debug_rsp_bits_data(core_dm_rsp_data),
    .io_debug_rsp_bits_op(core_dm_rsp_op)
  );

  RowhandoffCounterBankProject rowhandoff_counter_bank (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .io_layerStart(rowhandoff_event_layer_start),
    .io_rowhandoffRowOutYIn(rowhandoff_event_row_out_y_in),
    .io_rowhandoffRowOutYWritePulse(rowhandoff_event_row_out_y_write_pulse),
    .io_rowhandoffHitPulse(rowhandoff_event_hit_pulse),
    .io_rowhandoffTailHitPulse(rowhandoff_event_tail_hit_pulse),
    .io_rowhandoffMissPulse(rowhandoff_event_miss_pulse),
    .io_rowhandoffInvalidatePulse(rowhandoff_event_invalidate_pulse),
    .io_rowhandoffProducePulse(rowhandoff_event_produce_pulse),
    .io_interiorRowEnterPulse(rowhandoff_event_interior_enter_pulse),
    .io_rightEdgeDonePulse(rowhandoff_event_right_edge_done_pulse),
    .io_csr_rowhandoff_hit_count(rowhandoff_hit_count),
    .io_csr_rowhandoff_miss_count(rowhandoff_miss_count),
    .io_csr_rowhandoff_invalidate_count(rowhandoff_invalidate_count),
    .io_csr_rowhandoff_produce_count(rowhandoff_produce_count),
    .io_csr_rowhandoff_tail_hit_count(rowhandoff_tail_hit_count),
    .io_csr_interior_row_enter_count(rowhandoff_interior_count),
    .io_csr_right_edge_done_count(rowhandoff_right_edge_count),
    .io_csr_rowhandoff_row_out_y_last(rowhandoff_row_last),
    .io_csr_rowhandoff_state_trace_word(rowhandoff_state_trace_word),
    .io_trace_rowGateActive(rowhandoff_row_gate_active),
    .io_trace_currentRowIndex(rowhandoff_current_row),
    .io_trace_rowhandoffValidState(rowhandoff_valid_state),
    .io_trace_consumeDecisionValid(rowhandoff_consume_valid),
    .io_trace_consumeDecisionHit(rowhandoff_consume_hit),
    .io_trace_tailHitSeen(rowhandoff_tail_seen),
    .io_trace_lastProducedRow(rowhandoff_last_produced_row),
    .io_trace_lastInvalidatedRow(rowhandoff_last_invalidated_row),
    .io_trace_rowEnterPulse(rowhandoff_row_enter_pulse),
    .io_trace_rowTerminalDonePulse(rowhandoff_row_terminal_done_pulse),
    .io_trace_rowAdvanceDonePulse(rowhandoff_row_advance_done_pulse)
  );

  GestureConv3x3Win3Lite gesture_conv3x3_win3_lite (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .start(win3_start_pulse),
    .clear(win3_clear_pulse),
    .row0_lo(win3_row0_lo),
    .row0_hi(win3_row0_hi),
    .row1_lo(win3_row1_lo),
    .row1_hi(win3_row1_hi),
    .row2_lo(win3_row2_lo),
    .row2_hi(win3_row2_hi),
    .wgt0(gesture_wgt0),
    .wgt1(gesture_wgt1),
    .wgt2(gesture_wgt2),
    .bias(gesture_bias),
    .busy(win3_busy),
    .valid(win3_valid),
    .result0(win3_result0),
    .result1(win3_result1),
    .result2(win3_result2),
    .relu8_0(win3_relu8_0),
    .relu8_1(win3_relu8_1),
    .relu8_2(win3_relu8_2),
    .out_count(win3_out_count)
  );

  CoreLite7z010Cfg9Axi coral_cfg9 (
    .io_aclk(S_AXI_ACLK),
    .io_aresetn(~(reset | corecsr_reset_req)),
    .io_axi_slave_write_addr_ready(),
    .io_axi_slave_write_addr_valid(1'b0),
    .io_axi_slave_write_addr_bits_addr(32'd0),
    .io_axi_slave_write_addr_bits_prot(3'd0),
    .io_axi_slave_write_addr_bits_id(6'd0),
    .io_axi_slave_write_addr_bits_len(8'd0),
    .io_axi_slave_write_addr_bits_size(3'd0),
    .io_axi_slave_write_addr_bits_burst(2'd0),
    .io_axi_slave_write_addr_bits_lock(1'b0),
    .io_axi_slave_write_addr_bits_cache(4'd0),
    .io_axi_slave_write_addr_bits_qos(4'd0),
    .io_axi_slave_write_addr_bits_region(4'd0),
    .io_axi_slave_write_data_ready(),
    .io_axi_slave_write_data_valid(1'b0),
    .io_axi_slave_write_data_bits_data(128'd0),
    .io_axi_slave_write_data_bits_last(1'b0),
    .io_axi_slave_write_data_bits_strb(16'd0),
    .io_axi_slave_write_resp_ready(1'b1),
    .io_axi_slave_write_resp_valid(),
    .io_axi_slave_write_resp_bits_id(),
    .io_axi_slave_write_resp_bits_resp(),
    .io_axi_slave_read_addr_ready(),
    .io_axi_slave_read_addr_valid(1'b0),
    .io_axi_slave_read_addr_bits_addr(32'd0),
    .io_axi_slave_read_addr_bits_prot(3'd0),
    .io_axi_slave_read_addr_bits_id(6'd0),
    .io_axi_slave_read_addr_bits_len(8'd0),
    .io_axi_slave_read_addr_bits_size(3'd0),
    .io_axi_slave_read_addr_bits_burst(2'd0),
    .io_axi_slave_read_addr_bits_lock(1'b0),
    .io_axi_slave_read_addr_bits_cache(4'd0),
    .io_axi_slave_read_addr_bits_qos(4'd0),
    .io_axi_slave_read_addr_bits_region(4'd0),
    .io_axi_slave_read_data_ready(1'b1),
    .io_axi_slave_read_data_valid(),
    .io_axi_slave_read_data_bits_data(),
    .io_axi_slave_read_data_bits_id(),
    .io_axi_slave_read_data_bits_resp(),
    .io_axi_slave_read_data_bits_last(),
    .io_axi_master_write_addr_ready(1'b0),
    .io_axi_master_write_addr_valid(),
    .io_axi_master_write_addr_bits_addr(),
    .io_axi_master_write_addr_bits_prot(),
    .io_axi_master_write_addr_bits_id(),
    .io_axi_master_write_addr_bits_len(),
    .io_axi_master_write_addr_bits_size(),
    .io_axi_master_write_addr_bits_burst(),
    .io_axi_master_write_addr_bits_lock(),
    .io_axi_master_write_addr_bits_cache(),
    .io_axi_master_write_addr_bits_qos(),
    .io_axi_master_write_addr_bits_region(),
    .io_axi_master_write_data_ready(1'b0),
    .io_axi_master_write_data_valid(),
    .io_axi_master_write_data_bits_data(),
    .io_axi_master_write_data_bits_last(),
    .io_axi_master_write_data_bits_strb(),
    .io_axi_master_write_resp_ready(),
    .io_axi_master_write_resp_valid(1'b0),
    .io_axi_master_write_resp_bits_id(6'd0),
    .io_axi_master_write_resp_bits_resp(2'd0),
    .io_axi_master_read_addr_ready(1'b0),
    .io_axi_master_read_addr_valid(),
    .io_axi_master_read_addr_bits_addr(),
    .io_axi_master_read_addr_bits_prot(),
    .io_axi_master_read_addr_bits_id(),
    .io_axi_master_read_addr_bits_len(),
    .io_axi_master_read_addr_bits_size(),
    .io_axi_master_read_addr_bits_burst(),
    .io_axi_master_read_addr_bits_lock(),
    .io_axi_master_read_addr_bits_cache(),
    .io_axi_master_read_addr_bits_qos(),
    .io_axi_master_read_addr_bits_region(),
    .io_axi_master_read_data_ready(),
    .io_axi_master_read_data_valid(1'b0),
    .io_axi_master_read_data_bits_data(128'd0),
    .io_axi_master_read_data_bits_id(6'd0),
    .io_axi_master_read_data_bits_resp(2'd0),
    .io_axi_master_read_data_bits_last(1'b0),
    .io_halted(core_halted),
    .io_fault(core_fault),
    .io_wfi(core_wfi),
    .io_irq(1'b0),
    .io_boot_addr(corecsr_pc_start),
    .io_timer_irq(1'b0),
    .io_software_irq(1'b0),
    .io_debug_en(),
    .io_debug_addr_0(),
    .io_debug_inst_0(),
    .io_debug_cycles(),
    .io_debug_dbus_valid(),
    .io_debug_dbus_bits_addr(),
    .io_debug_dbus_bits_wdata(),
    .io_debug_dbus_bits_write(),
    .io_debug_dispatch_0_instFire(),
    .io_debug_dispatch_0_instAddr(),
    .io_debug_dispatch_0_instInst(),
    .io_debug_regfile_writeAddr_0_valid(),
    .io_debug_regfile_writeAddr_0_bits(),
    .io_debug_regfile_writeData_0_valid(),
    .io_debug_regfile_writeData_0_bits_addr(),
    .io_debug_regfile_writeData_0_bits_data(),
    .io_debug_regfile_writeData_1_valid(),
    .io_debug_regfile_writeData_1_bits_addr(),
    .io_debug_regfile_writeData_1_bits_data(),
    .io_debug_regfile_writeData_2_valid(),
    .io_debug_regfile_writeData_2_bits_addr(),
    .io_debug_regfile_writeData_2_bits_data(),
    .io_debug_rb_inst_0_valid(),
    .io_debug_rb_inst_0_bits_pc(),
    .io_debug_rb_inst_0_bits_inst(),
    .io_debug_rb_inst_0_bits_idx(),
    .io_debug_rb_inst_0_bits_data(),
    .io_debug_rb_inst_0_bits_trap(),
    .io_debug_rb_inst_1_valid(),
    .io_debug_rb_inst_1_bits_pc(),
    .io_debug_rb_inst_1_bits_inst(),
    .io_debug_rb_inst_1_bits_idx(),
    .io_debug_rb_inst_1_bits_data(),
    .io_debug_rb_inst_1_bits_trap(),
    .io_debug_rb_inst_2_valid(),
    .io_debug_rb_inst_2_bits_pc(),
    .io_debug_rb_inst_2_bits_inst(),
    .io_debug_rb_inst_2_bits_idx(),
    .io_debug_rb_inst_2_bits_data(),
    .io_debug_rb_inst_2_bits_trap(),
    .io_debug_rb_inst_3_valid(),
    .io_debug_rb_inst_3_bits_pc(),
    .io_debug_rb_inst_3_bits_inst(),
    .io_debug_rb_inst_3_bits_idx(),
    .io_debug_rb_inst_3_bits_data(),
    .io_debug_rb_inst_3_bits_trap(),
    .io_dm_req_ready(core_dm_req_ready),
    .io_dm_req_valid(debug_mux_req_valid),
    .io_dm_req_bits_address(debug_mux_req_addr),
    .io_dm_req_bits_data(debug_mux_req_data),
    .io_dm_req_bits_op(debug_mux_req_op),
    .io_dm_rsp_ready(1'b1),
    .io_dm_rsp_valid(core_dm_rsp_valid),
    .io_dm_rsp_bits_data(core_dm_rsp_data),
    .io_dm_rsp_bits_op(core_dm_rsp_op),
    .io_te(1'b1),
    .io_rowhandoffTrace_valid(),
    .io_rowhandoffTrace_addr(),
    .io_rowhandoffTrace_data(),
    .io_rowhandoffStateTrace_rowGateActive(),
    .io_rowhandoffStateTrace_currentRowIndex(),
    .io_rowhandoffStateTrace_rowhandoffValidState(),
    .io_rowhandoffStateTrace_consumeDecisionValid(),
    .io_rowhandoffStateTrace_consumeDecisionHit(),
    .io_rowhandoffStateTrace_tailHitSeen(),
    .io_rowhandoffStateTrace_lastProducedRow(),
    .io_rowhandoffStateTrace_lastInvalidatedRow(),
    .io_rowhandoffStateTrace_rowEnterPulse(),
    .io_rowhandoffStateTrace_rowTerminalDonePulse(),
    .io_rowhandoffStateTrace_rowAdvanceDonePulse()
  );

  assign led[0] = heartbeat[23];
  assign led[1] = core_halted;
  assign led[2] = core_fault;
  assign led[3] = core_wfi ^ debug_seen_rsp;
endmodule
