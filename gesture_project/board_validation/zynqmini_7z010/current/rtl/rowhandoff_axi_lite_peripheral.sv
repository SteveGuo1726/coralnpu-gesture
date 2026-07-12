module RowhandoffAxiLitePeripheral #(
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 10
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN, FREQ_HZ 50000000" *)
  input  wire                                S_AXI_ACLK,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                                S_AXI_ARESETN,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 50000000, ADDR_WIDTH 10, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input  wire [2:0]                          S_AXI_AWPROT,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                                S_AXI_AWVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                                S_AXI_AWREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   S_AXI_WSTRB,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                                S_AXI_WVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                                S_AXI_WREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output wire [1:0]                          S_AXI_BRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output wire                                S_AXI_BVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                                S_AXI_BREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input  wire [2:0]                          S_AXI_ARPROT,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                                S_AXI_ARVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                                S_AXI_ARREADY,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output wire [1:0]                          S_AXI_RRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output wire                                S_AXI_RVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                                S_AXI_RREADY,
  output wire [3:0]                          led
);
  localparam [31:0] REG_MAGIC       = 32'h52484F57;
  localparam [31:0] REG_VERSION     = 32'h20260710;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_MAGIC      = 'h00;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_VERSION    = 'h04;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CONTROL    = 'h08;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CYCLE      = 'h0C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_HIT        = 'h10;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_MISS       = 'h14;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_INVALIDATE = 'h18;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_PRODUCE    = 'h1C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TAIL_HIT   = 'h20;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_INTERIOR   = 'h24;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_RIGHT_EDGE = 'h28;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROW_LAST   = 'h2C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TRACE_WORD = 'h30;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TRACE_AUX  = 'h34;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ROW_STATE  = 'h38;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TRACE_REPLAY = 'h3C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_EVENT_IN   = 'h40;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_EVENT_STATUS = 'h44;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RADDR = 'h80;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA0 = 'h84;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA1 = 'h88;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA2 = 'h8C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_RDATA3 = 'h90;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_STATUS = 'h94;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WADDR = 'h98;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA0 = 'h9C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA1 = 'hA0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA2 = 'hA4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WDATA3 = 'hA8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_WTRIG = 'hAC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CORECSR_EVENT_IN = 'hB0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_ADDR = 'hB4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_WDATA = 'hB8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_OP = 'hBC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_TRIG = 'hC0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_RDATA = 'hC4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_ROP = 'hC8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_STATUS = 'hCC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_CSR_INDEX = 'hD0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_MEM_ADDR = 'hD4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_MEM_DATA0 = 'hD8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_MEM_DATA1 = 'hDC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_MEM_STRB = 'hE0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DEBUG_FLAGS = 'hE4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_CTRL = 'h100;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_ACT0 = 'h104;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_ACT1 = 'h108;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_ACT2 = 'h10C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT0 = 'h110;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT1 = 'h114;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_WGT2 = 'h118;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_BIAS = 'h11C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_STATUS = 'h120;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_RESULT = 'h124;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_RELU8 = 'h128;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GESTURE_COUNT = 'h12C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_CTRL = 'h140;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_ROW0 = 'h144;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_ROW1 = 'h148;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_ROW2 = 'h14C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_STATUS = 'h150;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_RESULT0 = 'h154;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_RESULT1 = 'h158;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_RELU8 = 'h15C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN2_COUNT = 'h160;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_CTRL = 'h180;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW0_LO = 'h184;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW0_HI = 'h188;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW1_LO = 'h18C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW1_HI = 'h190;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW2_LO = 'h194;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_ROW2_HI = 'h198;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_STATUS = 'h19C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT0 = 'h1A0;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT1 = 'h1A4;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RESULT2 = 'h1A8;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_RELU8 = 'h1AC;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_WIN3_COUNT = 'h1B0;
  localparam [6:0]  TRACE_EVENT_COUNT = 7'd111;

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
  reg        soft_reset_pulse;
  reg        layer_start_sw_pulse;
  reg [31:0] cycle_count;
  reg [23:0] heartbeat;
  reg [7:0]  step;
  reg [5:0]  row_y;
  reg [6:0]  trace_index;
  reg        trace_done;
  reg [31:0] host_event_word;
  reg        host_event_write_pulse;
  reg [15:0] host_event_count;
  reg [31:0] corecsr_read_addr;
  reg [31:0] corecsr_write_addr;
  reg [127:0] corecsr_write_data;
  reg corecsr_write_pulse;
  reg [15:0] corecsr_event_count;
  reg [31:0] debug_req_addr;
  reg [31:0] debug_req_data;
  reg [1:0] debug_req_op;
  reg debug_req_pulse;
  reg [31:0] debug_last_rsp_data;
  reg [1:0] debug_last_rsp_op;
  reg debug_seen_rsp;
  reg [15:0] debug_req_count;
  reg [15:0] debug_rsp_count;
  reg [31:0] gesture_act0;
  reg [31:0] gesture_act1;
  reg [31:0] gesture_act2;
  reg [31:0] gesture_wgt0;
  reg [31:0] gesture_wgt1;
  reg [31:0] gesture_wgt2;
  reg [31:0] gesture_bias;
  reg        gesture_start_pulse;
  reg        gesture_clear_pulse;
  reg        gesture_auto_start;
  reg        gesture_autostart_pending;
  reg [31:0] win2_row0;
  reg [31:0] win2_row1;
  reg [31:0] win2_row2;
  reg        win2_start_pulse;
  reg        win2_clear_pulse;
  reg        win2_auto_start;
  reg        win2_autostart_pending;
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

  wire reset = ~S_AXI_ARESETN | soft_reset_pulse;
  wire generator_enable = control[0];
  wire trace_replay_mode = control[3];
  wire host_inject_mode = control[4];

  function [31:0] trace_event_word_at;
    input [6:0] idx;
    begin
      case (idx)
        7'd0: trace_event_word_at = 32'h00000001;
        7'd1: trace_event_word_at = 32'h00180040;
        7'd2: trace_event_word_at = 32'h00180008;
        7'd3: trace_event_word_at = 32'h00180080;
        7'd4: trace_event_word_at = 32'h00180120;
        7'd5: trace_event_word_at = 32'h00190040;
        7'd6: trace_event_word_at = 32'h00190002;
        7'd7: trace_event_word_at = 32'h00190004;
        7'd8: trace_event_word_at = 32'h00190080;
        7'd9: trace_event_word_at = 32'h00190120;
        7'd10: trace_event_word_at = 32'h001A0040;
        7'd11: trace_event_word_at = 32'h001A0002;
        7'd12: trace_event_word_at = 32'h001A0004;
        7'd13: trace_event_word_at = 32'h001A0080;
        7'd14: trace_event_word_at = 32'h001A0120;
        7'd15: trace_event_word_at = 32'h001B0040;
        7'd16: trace_event_word_at = 32'h001B0002;
        7'd17: trace_event_word_at = 32'h001B0004;
        7'd18: trace_event_word_at = 32'h001B0080;
        7'd19: trace_event_word_at = 32'h001B0120;
        7'd20: trace_event_word_at = 32'h001C0040;
        7'd21: trace_event_word_at = 32'h001C0002;
        7'd22: trace_event_word_at = 32'h001C0004;
        7'd23: trace_event_word_at = 32'h001C0080;
        7'd24: trace_event_word_at = 32'h001C0120;
        7'd25: trace_event_word_at = 32'h001D0040;
        7'd26: trace_event_word_at = 32'h001D0002;
        7'd27: trace_event_word_at = 32'h001D0004;
        7'd28: trace_event_word_at = 32'h001D0080;
        7'd29: trace_event_word_at = 32'h001D0120;
        7'd30: trace_event_word_at = 32'h001E0040;
        7'd31: trace_event_word_at = 32'h001E0002;
        7'd32: trace_event_word_at = 32'h001E0004;
        7'd33: trace_event_word_at = 32'h001E0080;
        7'd34: trace_event_word_at = 32'h001E0120;
        7'd35: trace_event_word_at = 32'h001F0040;
        7'd36: trace_event_word_at = 32'h001F0002;
        7'd37: trace_event_word_at = 32'h001F0004;
        7'd38: trace_event_word_at = 32'h001F0080;
        7'd39: trace_event_word_at = 32'h001F0120;
        7'd40: trace_event_word_at = 32'h00200040;
        7'd41: trace_event_word_at = 32'h00200002;
        7'd42: trace_event_word_at = 32'h00200004;
        7'd43: trace_event_word_at = 32'h00200080;
        7'd44: trace_event_word_at = 32'h00200120;
        7'd45: trace_event_word_at = 32'h00210040;
        7'd46: trace_event_word_at = 32'h00210002;
        7'd47: trace_event_word_at = 32'h00210004;
        7'd48: trace_event_word_at = 32'h00210080;
        7'd49: trace_event_word_at = 32'h00210120;
        7'd50: trace_event_word_at = 32'h00220040;
        7'd51: trace_event_word_at = 32'h00220002;
        7'd52: trace_event_word_at = 32'h00220004;
        7'd53: trace_event_word_at = 32'h00220080;
        7'd54: trace_event_word_at = 32'h00220120;
        7'd55: trace_event_word_at = 32'h00230040;
        7'd56: trace_event_word_at = 32'h00230002;
        7'd57: trace_event_word_at = 32'h00230004;
        7'd58: trace_event_word_at = 32'h00230080;
        7'd59: trace_event_word_at = 32'h00230120;
        7'd60: trace_event_word_at = 32'h00240040;
        7'd61: trace_event_word_at = 32'h00240002;
        7'd62: trace_event_word_at = 32'h00240004;
        7'd63: trace_event_word_at = 32'h00240080;
        7'd64: trace_event_word_at = 32'h00240120;
        7'd65: trace_event_word_at = 32'h00250040;
        7'd66: trace_event_word_at = 32'h00250002;
        7'd67: trace_event_word_at = 32'h00250004;
        7'd68: trace_event_word_at = 32'h00250080;
        7'd69: trace_event_word_at = 32'h00250120;
        7'd70: trace_event_word_at = 32'h00260040;
        7'd71: trace_event_word_at = 32'h00260002;
        7'd72: trace_event_word_at = 32'h00260004;
        7'd73: trace_event_word_at = 32'h00260080;
        7'd74: trace_event_word_at = 32'h00260120;
        7'd75: trace_event_word_at = 32'h00270040;
        7'd76: trace_event_word_at = 32'h00270002;
        7'd77: trace_event_word_at = 32'h00270004;
        7'd78: trace_event_word_at = 32'h00270080;
        7'd79: trace_event_word_at = 32'h00270120;
        7'd80: trace_event_word_at = 32'h00280040;
        7'd81: trace_event_word_at = 32'h00280002;
        7'd82: trace_event_word_at = 32'h00280004;
        7'd83: trace_event_word_at = 32'h00280080;
        7'd84: trace_event_word_at = 32'h00280120;
        7'd85: trace_event_word_at = 32'h00290040;
        7'd86: trace_event_word_at = 32'h00290002;
        7'd87: trace_event_word_at = 32'h00290004;
        7'd88: trace_event_word_at = 32'h00290080;
        7'd89: trace_event_word_at = 32'h00290120;
        7'd90: trace_event_word_at = 32'h002A0040;
        7'd91: trace_event_word_at = 32'h002A0002;
        7'd92: trace_event_word_at = 32'h002A0004;
        7'd93: trace_event_word_at = 32'h002A0080;
        7'd94: trace_event_word_at = 32'h002A0120;
        7'd95: trace_event_word_at = 32'h002B0040;
        7'd96: trace_event_word_at = 32'h002B0002;
        7'd97: trace_event_word_at = 32'h002B0004;
        7'd98: trace_event_word_at = 32'h002B0080;
        7'd99: trace_event_word_at = 32'h002B0120;
        7'd100: trace_event_word_at = 32'h002C0040;
        7'd101: trace_event_word_at = 32'h002C0002;
        7'd102: trace_event_word_at = 32'h002C0004;
        7'd103: trace_event_word_at = 32'h002C0080;
        7'd104: trace_event_word_at = 32'h002C0120;
        7'd105: trace_event_word_at = 32'h002D0040;
        7'd106: trace_event_word_at = 32'h002D0002;
        7'd107: trace_event_word_at = 32'h002D0004;
        7'd108: trace_event_word_at = 32'h002D0080;
        7'd109: trace_event_word_at = 32'h002D0120;
        7'd110: trace_event_word_at = 32'h002E0010;
        default: trace_event_word_at = 32'h00000000;
      endcase
    end
  endfunction

  wire        trace_valid = generator_enable & trace_replay_mode & ~host_inject_mode & ~trace_done;
  wire [31:0] trace_event_word = trace_event_word_at(trace_index);
  wire [5:0]  trace_row_y = trace_event_word[21:16];
  wire        trace_layer_start = trace_valid & trace_event_word[0];
  wire        trace_hit = trace_valid & trace_event_word[1];
  wire        trace_tail_hit = trace_valid & trace_event_word[2];
  wire        trace_miss = trace_valid & trace_event_word[3];
  wire        trace_invalidate = trace_valid & trace_event_word[4];
  wire        trace_produce = trace_valid & trace_event_word[5];
  wire        trace_interior = trace_valid & trace_event_word[6];
  wire        trace_right_edge = trace_valid & trace_event_word[7];
  wire        trace_row_write = trace_valid & trace_event_word[8];

  wire        host_valid = generator_enable & host_inject_mode & host_event_write_pulse;
  wire [5:0]  host_row_y = host_event_word[21:16];
  wire        host_layer_start = host_valid & host_event_word[0];
  wire        host_hit = host_valid & host_event_word[1];
  wire        host_tail_hit = host_valid & host_event_word[2];
  wire        host_miss = host_valid & host_event_word[3];
  wire        host_invalidate = host_valid & host_event_word[4];
  wire        host_produce = host_valid & host_event_word[5];
  wire        host_interior = host_valid & host_event_word[6];
  wire        host_right_edge = host_valid & host_event_word[7];
  wire        host_row_write = host_valid & host_event_word[8];

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
  wire debug_ext_req_ready;
  wire debug_ext_rsp_valid;
  wire [31:0] debug_ext_rsp_data;
  wire [1:0] debug_ext_rsp_op;
  wire debug_csr_valid;
  wire [11:0] debug_csr_index;
  wire debug_scalar_rd_valid;
  wire [4:0] debug_scalar_rd_addr;
  wire [31:0] debug_scalar_rd_data;
  wire [4:0] debug_scalar_rs_idx;
  wire debug_float_rd_valid;
  wire [4:0] debug_float_rd_addr;
  wire [22:0] debug_float_rd_data_mantissa;
  wire [7:0] debug_float_rd_data_exponent;
  wire debug_float_rd_data_sign;
  wire debug_float_rs_valid;
  wire [4:0] debug_float_rs_addr;
  wire debug_itcm_read_valid;
  wire [31:0] debug_itcm_read_addr;
  wire debug_itcm_write_valid;
  wire [31:0] debug_itcm_write_addr;
  wire [127:0] debug_itcm_write_data;
  wire [15:0] debug_itcm_write_strb;
  wire debug_dtcm_read_valid;
  wire [31:0] debug_dtcm_read_addr;
  wire debug_dtcm_write_valid;
  wire [31:0] debug_dtcm_write_addr;
  wire [127:0] debug_dtcm_write_data;
  wire [15:0] debug_dtcm_write_strb;
  wire debug_haltreq;
  wire debug_resumereq;
  wire debug_ndmreset;
  wire gesture_busy;
  wire gesture_valid;
  wire [31:0] gesture_result;
  wire [7:0] gesture_relu8;
  wire [31:0] gesture_op_count;
  reg gesture_done_latched;
  wire win2_busy;
  wire win2_valid;
  wire [31:0] win2_result0;
  wire [31:0] win2_result1;
  wire [7:0] win2_relu8_0;
  wire [7:0] win2_relu8_1;
  wire [31:0] win2_out_count;
  reg win2_done_latched;
  wire win3_busy;
  wire win3_valid;
  wire [31:0] win3_result0;
  wire [31:0] win3_result1;
  wire [31:0] win3_result2;
  wire [7:0] win3_relu8_0;
  wire [7:0] win3_relu8_1;
  wire [7:0] win3_relu8_2;
  wire [31:0] win3_out_count;
  reg win3_done_latched;
  wire gesture_ctrl_clear_write = slv_reg_wren && axi_awaddr == 10'h100 && S_AXI_WSTRB[0] && S_AXI_WDATA[1];
  wire win2_ctrl_clear_write = slv_reg_wren && axi_awaddr == 10'h140 && S_AXI_WSTRB[0] && S_AXI_WDATA[1];
  wire win3_ctrl_clear_write = slv_reg_wren && axi_awaddr == 10'h180 && S_AXI_WSTRB[0] && S_AXI_WDATA[1];
  wire debug_mux_req_valid = corecsr_debug_req_valid | debug_req_pulse;
  wire [31:0] debug_mux_req_addr = corecsr_debug_req_valid ? corecsr_debug_req_address : debug_req_addr;
  wire [31:0] debug_mux_req_data = corecsr_debug_req_valid ? corecsr_debug_req_data : debug_req_data;
  wire [1:0] debug_mux_req_op = corecsr_debug_req_valid ? corecsr_debug_req_op : debug_req_op;

  wire det_enable = generator_enable & ~trace_replay_mode & ~host_inject_mode;
  wire det_layer_start = det_enable & (step == 8'd1);
  wire det_row_write   = det_enable & (step[2:0] == 3'd2);
  wire det_produce     = det_enable & (step[2:0] == 3'd3);
  wire det_hit         = det_enable & (step[2:0] == 3'd4);
  wire det_tail_hit    = det_enable & (step[5:0] == 6'd31);
  wire det_miss        = det_enable & (step[5:0] == 6'd47);
  wire det_invalidate  = det_enable & (step[5:0] == 6'd55);
  wire det_interior    = det_enable & (step[2:0] == 3'd1);
  wire det_right_edge  = det_enable & (step[5:0] == 6'd63);

  wire [5:0] event_row_y = host_inject_mode ? host_row_y : trace_replay_mode ? trace_row_y : row_y;
  wire layer_start = layer_start_sw_pulse | host_layer_start | trace_layer_start | det_layer_start;
  wire row_write   = host_row_write | trace_row_write | det_row_write;
  wire produce     = host_produce | trace_produce | det_produce;
  wire hit         = host_hit | trace_hit | det_hit;
  wire tail_hit    = host_tail_hit | trace_tail_hit | det_tail_hit;
  wire miss        = host_miss | trace_miss | det_miss;
  wire invalidate  = host_invalidate | trace_invalidate | det_invalidate;
  wire interior    = host_interior | trace_interior | det_interior;
  wire right_edge  = host_right_edge | trace_right_edge | det_right_edge;

  wire [15:0] hit_count;
  wire [15:0] miss_count;
  wire [15:0] invalidate_count;
  wire [15:0] produce_count;
  wire [15:0] tail_hit_count;
  wire [15:0] interior_count;
  wire [15:0] right_edge_count;
  wire [5:0]  row_last;
  wire [31:0] state_trace_word;
  wire        row_gate_active;
  wire [5:0]  current_row;
  wire        valid_state;
  wire        consume_valid;
  wire        consume_hit;
  wire        tail_seen;
  wire [5:0]  last_produced_row;
  wire [5:0]  last_invalidated_row;
  wire        row_enter_pulse;
  wire        row_terminal_done_pulse;
  wire        row_advance_done_pulse;

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
      gesture_done_latched <= 1'b0;
      win2_done_latched <= 1'b0;
      win3_done_latched <= 1'b0;
    end else begin
      if (gesture_ctrl_clear_write) begin
        gesture_done_latched <= 1'b0;
      end else if (gesture_valid || (gesture_op_count != 32'd0)) begin
        gesture_done_latched <= 1'b1;
      end
      if (win2_ctrl_clear_write) begin
        win2_done_latched <= 1'b0;
      end else if (win2_valid || (win2_out_count != 32'd0)) begin
        win2_done_latched <= 1'b1;
      end
      if (win3_ctrl_clear_write) begin
        win3_done_latched <= 1'b0;
      end else if (win3_valid || (win3_out_count != 32'd0)) begin
        win3_done_latched <= 1'b1;
      end
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      control <= 32'h00000009;
      soft_reset_pulse <= 1'b0;
      layer_start_sw_pulse <= 1'b0;
      host_event_word <= 32'd0;
      host_event_write_pulse <= 1'b0;
      host_event_count <= 16'd0;
      corecsr_read_addr <= 32'h00000820;
      corecsr_write_addr <= 32'h00000840;
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
      gesture_act0 <= 32'd0;
      gesture_act1 <= 32'd0;
      gesture_act2 <= 32'd0;
      gesture_wgt0 <= 32'd0;
      gesture_wgt1 <= 32'd0;
      gesture_wgt2 <= 32'd0;
      gesture_bias <= 32'd0;
      gesture_start_pulse <= 1'b0;
      gesture_clear_pulse <= 1'b0;
      gesture_auto_start <= 1'b0;
      gesture_autostart_pending <= 1'b0;
      win2_row0 <= 32'd0;
      win2_row1 <= 32'd0;
      win2_row2 <= 32'd0;
      win2_start_pulse <= 1'b0;
      win2_clear_pulse <= 1'b0;
      win2_auto_start <= 1'b0;
      win2_autostart_pending <= 1'b0;
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
      soft_reset_pulse <= 1'b0;
      layer_start_sw_pulse <= 1'b0;
      host_event_write_pulse <= 1'b0;
      corecsr_write_pulse <= 1'b0;
      debug_req_pulse <= 1'b0;
      gesture_start_pulse <= gesture_autostart_pending & ~gesture_busy;
      gesture_clear_pulse <= 1'b0;
      gesture_autostart_pending <= gesture_autostart_pending & gesture_busy;
      win2_start_pulse <= win2_autostart_pending & ~win2_busy;
      win2_clear_pulse <= 1'b0;
      win2_autostart_pending <= win2_autostart_pending & win2_busy;
      win3_start_pulse <= win3_autostart_pending & ~win3_busy;
      win3_clear_pulse <= 1'b0;
      win3_autostart_pending <= win3_autostart_pending & win3_busy;
      if (soft_reset_pulse) begin
        host_event_word <= 32'd0;
        host_event_count <= 16'd0;
        corecsr_event_count <= 16'd0;
        debug_req_count <= 16'd0;
        debug_rsp_count <= 16'd0;
        debug_seen_rsp <= 1'b0;
        gesture_auto_start <= 1'b0;
        gesture_autostart_pending <= 1'b0;
        gesture_clear_pulse <= 1'b1;
        win2_auto_start <= 1'b0;
        win2_autostart_pending <= 1'b0;
        win2_clear_pulse <= 1'b1;
        win3_auto_start <= 1'b0;
        win3_autostart_pending <= 1'b0;
        win3_clear_pulse <= 1'b1;
      end
      if (debug_ext_rsp_valid) begin
        debug_last_rsp_data <= debug_ext_rsp_data;
        debug_last_rsp_op <= debug_ext_rsp_op;
        debug_seen_rsp <= 1'b1;
        debug_rsp_count <= debug_rsp_count + 16'd1;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CONTROL) begin
        if (S_AXI_WSTRB[0]) begin
          control[7:0] <= S_AXI_WDATA[7:0] & 8'h19;
          layer_start_sw_pulse <= S_AXI_WDATA[1];
          soft_reset_pulse <= S_AXI_WDATA[2];
        end
      end
      if (slv_reg_wren && axi_awaddr == ADDR_EVENT_IN) begin
        host_event_word <= S_AXI_WDATA;
        host_event_write_pulse <= 1'b1;
        host_event_count <= host_event_count + 16'd1;
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
      end
      if (slv_reg_wren && axi_awaddr == ADDR_CORECSR_EVENT_IN) begin
        host_event_word <= S_AXI_WDATA;
        host_event_write_pulse <= 1'b1;
        corecsr_event_count <= corecsr_event_count + 16'd1;
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
      if (slv_reg_wren && axi_awaddr == ADDR_DEBUG_TRIG && debug_ext_req_ready) begin
        debug_req_pulse <= 1'b1;
        debug_req_count <= debug_req_count + 16'd1;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_CTRL) begin
        gesture_start_pulse <= S_AXI_WDATA[0];
        gesture_clear_pulse <= S_AXI_WDATA[1];
        gesture_auto_start <= S_AXI_WDATA[2];
        gesture_autostart_pending <= 1'b0;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_ACT0) begin
        gesture_act0 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_ACT1) begin
        gesture_act1 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_GESTURE_ACT2) begin
        gesture_act2 <= S_AXI_WDATA;
        gesture_autostart_pending <= gesture_auto_start;
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
      if (slv_reg_wren && axi_awaddr == ADDR_WIN2_CTRL) begin
        win2_start_pulse <= S_AXI_WDATA[0];
        win2_clear_pulse <= S_AXI_WDATA[1];
        win2_auto_start <= S_AXI_WDATA[2];
        win2_autostart_pending <= 1'b0;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN2_ROW0) begin
        win2_row0 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN2_ROW1) begin
        win2_row1 <= S_AXI_WDATA;
      end
      if (slv_reg_wren && axi_awaddr == ADDR_WIN2_ROW2) begin
        win2_row2 <= S_AXI_WDATA;
        win2_autostart_pending <= win2_auto_start;
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

  always @(posedge S_AXI_ACLK) begin
    if (reset) begin
      cycle_count <= 32'd0;
      heartbeat <= 24'd0;
      step <= 8'd0;
      row_y <= 6'd0;
      trace_index <= 7'd0;
      trace_done <= 1'b0;
    end else begin
      heartbeat <= heartbeat + 24'd1;
      if (generator_enable) begin
        cycle_count <= cycle_count + 32'd1;
        if (trace_replay_mode && !host_inject_mode) begin
          if (!trace_done) begin
            if (trace_index == TRACE_EVENT_COUNT - 7'd1) begin
              trace_done <= 1'b1;
            end else begin
              trace_index <= trace_index + 7'd1;
            end
          end
        end else begin
          step <= step + 8'd1;
        end
        if (!trace_replay_mode && row_write) begin
          row_y <= row_y + 6'd1;
        end
      end
    end
  end

  always @(*) begin
    case (axi_araddr)
      ADDR_MAGIC:      axi_rdata = REG_MAGIC;
      ADDR_VERSION:    axi_rdata = REG_VERSION;
      ADDR_CONTROL:    axi_rdata = control;
      ADDR_CYCLE:      axi_rdata = cycle_count;
      ADDR_HIT:        axi_rdata = {16'd0, hit_count};
      ADDR_MISS:       axi_rdata = {16'd0, miss_count};
      ADDR_INVALIDATE: axi_rdata = {16'd0, invalidate_count};
      ADDR_PRODUCE:    axi_rdata = {16'd0, produce_count};
      ADDR_TAIL_HIT:   axi_rdata = {16'd0, tail_hit_count};
      ADDR_INTERIOR:   axi_rdata = {16'd0, interior_count};
      ADDR_RIGHT_EDGE: axi_rdata = {16'd0, right_edge_count};
      ADDR_ROW_LAST:   axi_rdata = {26'd0, row_last};
      ADDR_TRACE_WORD: axi_rdata = state_trace_word;
      ADDR_TRACE_AUX:  axi_rdata = {last_invalidated_row, last_produced_row, tail_seen, consume_hit, consume_valid, valid_state, row_gate_active, row_advance_done_pulse, row_terminal_done_pulse, row_enter_pulse, current_row, 6'd0};
      ADDR_ROW_STATE:  axi_rdata = {trace_done, trace_replay_mode, generator_enable, 5'd0, trace_index, 1'b0, event_row_y, 4'd0, current_row};
      ADDR_TRACE_REPLAY: axi_rdata = {8'd0, TRACE_EVENT_COUNT, trace_done, trace_replay_mode, 8'd0, trace_index};
      ADDR_EVENT_IN:   axi_rdata = host_event_word;
      ADDR_EVENT_STATUS: axi_rdata = {host_event_count, 11'd0, host_event_write_pulse, host_inject_mode, trace_replay_mode, generator_enable, 1'b0};
      ADDR_CORECSR_RADDR: axi_rdata = corecsr_read_addr;
      ADDR_CORECSR_RDATA0: axi_rdata = corecsr_read_data[31:0];
      ADDR_CORECSR_RDATA1: axi_rdata = corecsr_read_data[63:32];
      ADDR_CORECSR_RDATA2: axi_rdata = corecsr_read_data[95:64];
      ADDR_CORECSR_RDATA3: axi_rdata = corecsr_read_data[127:96];
      ADDR_CORECSR_STATUS: axi_rdata = {corecsr_event_count, 9'd0, corecsr_write_resp, corecsr_write_pulse, corecsr_read_valid, corecsr_reset_req, corecsr_cg_req, corecsr_debug_req_valid, 1'b0};
      ADDR_CORECSR_WADDR: axi_rdata = corecsr_write_addr;
      ADDR_CORECSR_WDATA0: axi_rdata = corecsr_write_data[31:0];
      ADDR_CORECSR_WDATA1: axi_rdata = corecsr_write_data[63:32];
      ADDR_CORECSR_WDATA2: axi_rdata = corecsr_write_data[95:64];
      ADDR_CORECSR_WDATA3: axi_rdata = corecsr_write_data[127:96];
      ADDR_CORECSR_EVENT_IN: axi_rdata = corecsr_write_data[31:0];
      ADDR_DEBUG_ADDR: axi_rdata = debug_req_addr;
      ADDR_DEBUG_WDATA: axi_rdata = debug_req_data;
      ADDR_DEBUG_OP: axi_rdata = {30'd0, debug_req_op};
      ADDR_DEBUG_RDATA: axi_rdata = debug_last_rsp_data;
      ADDR_DEBUG_ROP: axi_rdata = {30'd0, debug_last_rsp_op};
      ADDR_DEBUG_STATUS: axi_rdata = {debug_req_count[7:0], debug_rsp_count[7:0], debug_seen_rsp, debug_ext_rsp_valid, debug_ext_req_ready, debug_ndmreset, debug_resumereq, debug_haltreq, debug_req_pulse, debug_csr_valid, debug_scalar_rd_valid, debug_float_rd_valid, debug_itcm_read_valid, debug_itcm_write_valid, debug_dtcm_read_valid, debug_dtcm_write_valid, 2'd0};
      ADDR_DEBUG_CSR_INDEX: axi_rdata = {20'd0, debug_csr_index};
      ADDR_DEBUG_MEM_ADDR: axi_rdata = debug_dtcm_read_valid ? debug_dtcm_read_addr : debug_dtcm_write_valid ? debug_dtcm_write_addr : debug_itcm_read_valid ? debug_itcm_read_addr : debug_itcm_write_addr;
      ADDR_DEBUG_MEM_DATA0: axi_rdata = debug_itcm_write_data[31:0] | debug_dtcm_write_data[31:0];
      ADDR_DEBUG_MEM_DATA1: axi_rdata = debug_itcm_write_data[63:32] | debug_dtcm_write_data[63:32];
      ADDR_DEBUG_MEM_STRB: axi_rdata = {debug_itcm_write_strb, debug_dtcm_write_strb};
      ADDR_DEBUG_FLAGS: axi_rdata = {debug_scalar_rs_idx, debug_float_rs_addr, debug_float_rd_addr, debug_scalar_rd_addr, debug_float_rs_valid, debug_float_rd_valid, debug_scalar_rd_valid, debug_csr_valid, debug_ndmreset, debug_resumereq, debug_haltreq, debug_seen_rsp, debug_ext_rsp_valid, debug_ext_req_ready, 2'd0};
      ADDR_GESTURE_CTRL: axi_rdata = {29'd0, gesture_auto_start, gesture_clear_pulse, gesture_start_pulse};
      ADDR_GESTURE_ACT0: axi_rdata = gesture_act0;
      ADDR_GESTURE_ACT1: axi_rdata = gesture_act1;
      ADDR_GESTURE_ACT2: axi_rdata = gesture_act2;
      ADDR_GESTURE_WGT0: axi_rdata = gesture_wgt0;
      ADDR_GESTURE_WGT1: axi_rdata = gesture_wgt1;
      ADDR_GESTURE_WGT2: axi_rdata = gesture_wgt2;
      ADDR_GESTURE_BIAS: axi_rdata = gesture_bias;
      ADDR_GESTURE_STATUS: axi_rdata = {30'd0, gesture_done_latched, gesture_busy};
      ADDR_GESTURE_RESULT: axi_rdata = gesture_result;
      ADDR_GESTURE_RELU8: axi_rdata = {24'd0, gesture_relu8};
      ADDR_GESTURE_COUNT: axi_rdata = gesture_op_count;
      ADDR_WIN2_CTRL: axi_rdata = {29'd0, win2_auto_start, win2_clear_pulse, win2_start_pulse};
      ADDR_WIN2_ROW0: axi_rdata = win2_row0;
      ADDR_WIN2_ROW1: axi_rdata = win2_row1;
      ADDR_WIN2_ROW2: axi_rdata = win2_row2;
      ADDR_WIN2_STATUS: axi_rdata = {30'd0, win2_done_latched, win2_busy};
      ADDR_WIN2_RESULT0: axi_rdata = win2_result0;
      ADDR_WIN2_RESULT1: axi_rdata = win2_result1;
      ADDR_WIN2_RELU8: axi_rdata = {16'd0, win2_relu8_1, win2_relu8_0};
      ADDR_WIN2_COUNT: axi_rdata = win2_out_count;
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
      default:         axi_rdata = 32'd0;
    endcase
  end

  DebugModule official_debug_module (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .io_ext_req_ready(debug_ext_req_ready),
    .io_ext_req_valid(debug_mux_req_valid),
    .io_ext_req_bits_address(debug_mux_req_addr),
    .io_ext_req_bits_data(debug_mux_req_data),
    .io_ext_req_bits_op(debug_mux_req_op),
    .io_ext_rsp_ready(1'b1),
    .io_ext_rsp_valid(debug_ext_rsp_valid),
    .io_ext_rsp_bits_data(debug_ext_rsp_data),
    .io_ext_rsp_bits_op(debug_ext_rsp_op),
    .io_csr_valid(debug_csr_valid),
    .io_csr_bits_addr(),
    .io_csr_bits_index(debug_csr_index),
    .io_csr_bits_rs1(),
    .io_csr_bits_op(),
    .io_csr_rs1(),
    .io_csr_rd_valid(1'b1),
    .io_csr_rd_bits(32'hC5A0_0820),
    .io_scalar_rd_ready(1'b1),
    .io_scalar_rd_valid(debug_scalar_rd_valid),
    .io_scalar_rd_bits_addr(debug_scalar_rd_addr),
    .io_scalar_rd_bits_data(debug_scalar_rd_data),
    .io_scalar_rs_idx(debug_scalar_rs_idx),
    .io_scalar_rs_data({27'd0, debug_scalar_rs_idx}),
    .io_float_rd_valid(debug_float_rd_valid),
    .io_float_rd_addr(debug_float_rd_addr),
    .io_float_rd_data_mantissa(debug_float_rd_data_mantissa),
    .io_float_rd_data_exponent(debug_float_rd_data_exponent),
    .io_float_rd_data_sign(debug_float_rd_data_sign),
    .io_float_rs_valid(debug_float_rs_valid),
    .io_float_rs_addr(debug_float_rs_addr),
    .io_float_rs_data_mantissa({18'd0, debug_float_rs_addr}),
    .io_float_rs_data_exponent(8'h7F),
    .io_float_rs_data_sign(1'b0),
    .io_itcm_readDataAddr_valid(debug_itcm_read_valid),
    .io_itcm_readDataAddr_bits(debug_itcm_read_addr),
    .io_itcm_readData_valid(1'b1),
    .io_itcm_readData_bits(128'h11112222_33334444_55556666_77778888),
    .io_itcm_writeDataAddr_valid(debug_itcm_write_valid),
    .io_itcm_writeDataAddr_bits(debug_itcm_write_addr),
    .io_itcm_writeDataBits(debug_itcm_write_data),
    .io_itcm_writeDataStrb(debug_itcm_write_strb),
    .io_itcm_writeResp(1'b1),
    .io_dtcm_readDataAddr_valid(debug_dtcm_read_valid),
    .io_dtcm_readDataAddr_bits(debug_dtcm_read_addr),
    .io_dtcm_readData_valid(1'b1),
    .io_dtcm_readData_bits(128'h9999AAAA_BBBBCCCC_DDDD1111_22223333),
    .io_dtcm_writeDataAddr_valid(debug_dtcm_write_valid),
    .io_dtcm_writeDataAddr_bits(debug_dtcm_write_addr),
    .io_dtcm_writeDataBits(debug_dtcm_write_data),
    .io_dtcm_writeDataStrb(debug_dtcm_write_strb),
    .io_dtcm_writeResp(1'b1),
    .io_haltreq_0(debug_haltreq),
    .io_resumereq_0(debug_resumereq),
    .io_resumeack_0(1'b0),
    .io_ndmreset(debug_ndmreset),
    .io_halted_0(1'b1),
    .io_running_0(1'b0),
    .io_havereset_0(1'b0)
  );

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
    .io_bootAddr(32'h00100000),
    .io_halted(1'b0),
    .io_fault(1'b0),
    .io_coralnpu_csr_value_0(32'd0),
    .io_coralnpu_csr_value_1(32'd0),
    .io_coralnpu_csr_value_2(32'd0),
    .io_coralnpu_csr_value_3(32'd0),
    .io_coralnpu_csr_value_4(32'd0),
    .io_coralnpu_csr_value_5(32'd0),
    .io_coralnpu_csr_value_6(32'd0),
    .io_coralnpu_csr_value_7(32'd0),
    .io_coralnpu_csr_value_8(32'd0),
    .io_debug_req_ready(debug_ext_req_ready),
    .io_debug_req_valid(corecsr_debug_req_valid),
    .io_debug_req_bits_address(corecsr_debug_req_address),
    .io_debug_req_bits_data(corecsr_debug_req_data),
    .io_debug_req_bits_op(corecsr_debug_req_op),
    .io_debug_rsp_ready(corecsr_debug_rsp_ready),
    .io_debug_rsp_valid(debug_ext_rsp_valid),
    .io_debug_rsp_bits_data(debug_ext_rsp_data),
    .io_debug_rsp_bits_op(debug_ext_rsp_op)
  );

  GestureConv3x3MacLite gesture_conv3x3_mac_lite (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .start(gesture_start_pulse),
    .clear(gesture_clear_pulse),
    .act0(gesture_act0),
    .act1(gesture_act1),
    .act2(gesture_act2),
    .wgt0(gesture_wgt0),
    .wgt1(gesture_wgt1),
    .wgt2(gesture_wgt2),
    .bias(gesture_bias),
    .busy(gesture_busy),
    .valid(gesture_valid),
    .result(gesture_result),
    .relu8(gesture_relu8),
    .op_count(gesture_op_count)
  );

  GestureConv3x3Win2Lite gesture_conv3x3_win2_lite (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .start(win2_start_pulse),
    .clear(win2_clear_pulse),
    .row0(win2_row0),
    .row1(win2_row1),
    .row2(win2_row2),
    .wgt0(gesture_wgt0),
    .wgt1(gesture_wgt1),
    .wgt2(gesture_wgt2),
    .bias(gesture_bias),
    .busy(win2_busy),
    .valid(win2_valid),
    .result0(win2_result0),
    .result1(win2_result1),
    .relu8_0(win2_relu8_0),
    .relu8_1(win2_relu8_1),
    .out_count(win2_out_count)
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

  RowhandoffCounterBank rowhandoff_counter_bank (
    .clock(S_AXI_ACLK),
    .reset(reset),
    .io_layerStart(layer_start),
    .io_rowhandoffRowOutYIn(event_row_y),
    .io_rowhandoffRowOutYWritePulse(row_write),
    .io_rowhandoffHitPulse(hit),
    .io_rowhandoffTailHitPulse(tail_hit),
    .io_rowhandoffMissPulse(miss),
    .io_rowhandoffInvalidatePulse(invalidate),
    .io_rowhandoffProducePulse(produce),
    .io_interiorRowEnterPulse(interior),
    .io_rightEdgeDonePulse(right_edge),
    .io_csr_rowhandoff_hit_count(hit_count),
    .io_csr_rowhandoff_miss_count(miss_count),
    .io_csr_rowhandoff_invalidate_count(invalidate_count),
    .io_csr_rowhandoff_produce_count(produce_count),
    .io_csr_rowhandoff_tail_hit_count(tail_hit_count),
    .io_csr_interior_row_enter_count(interior_count),
    .io_csr_right_edge_done_count(right_edge_count),
    .io_csr_rowhandoff_row_out_y_last(row_last),
    .io_csr_rowhandoff_state_trace_word(state_trace_word),
    .io_trace_rowGateActive(row_gate_active),
    .io_trace_currentRowIndex(current_row),
    .io_trace_rowhandoffValidState(valid_state),
    .io_trace_consumeDecisionValid(consume_valid),
    .io_trace_consumeDecisionHit(consume_hit),
    .io_trace_tailHitSeen(tail_seen),
    .io_trace_lastProducedRow(last_produced_row),
    .io_trace_lastInvalidatedRow(last_invalidated_row),
    .io_trace_rowEnterPulse(row_enter_pulse),
    .io_trace_rowTerminalDonePulse(row_terminal_done_pulse),
    .io_trace_rowAdvanceDonePulse(row_advance_done_pulse)
  );

  assign led[0] = heartbeat[23];
  assign led[1] = hit_count[3];
  assign led[2] = row_gate_active ^ valid_state ^ consume_valid ^ consume_hit;
  assign led[3] = row_terminal_done_pulse ^ row_advance_done_pulse ^ tail_seen ^ gesture_valid ^ win2_valid ^ win3_valid;
endmodule
