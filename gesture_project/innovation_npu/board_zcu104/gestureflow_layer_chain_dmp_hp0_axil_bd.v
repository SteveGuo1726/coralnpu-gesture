// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Plain-Verilog module-reference wrapper for the SystemVerilog GestureFlow top.
//
// WHY THIS FILE EXISTS
// --------------------
// IP Integrator's Module Reference flow (UG898) accepts only a Verilog or VHDL
// top file.  Pointing it straight at the SystemVerilog top fails with:
//     [filemgmt 56-195] Reference 'gestureflow_layer_chain_dmp_hp0_axil'
//     contains top file '...gestureflow_layer_chain_dmp_hp0_axil.sv' of type
//     SystemVerilog. This type is not allowed as the top file in the reference.
// Packaging the RTL as an IP instead is not an option here either: on this
// machine the packaged user IP deterministically breaks synthesis's scratch
// cleanup, so the design uses a module reference (see the build TCL header).
//
// Therefore the block design instantiates THIS thin Verilog wrapper, which
// passes every port and parameter straight through to the real SystemVerilog
// module.  The AXI attributes below are copies of the ones already carried by
// the SystemVerilog ports, so IP Integrator infers aclk / aresetn / S_AXI /
// M_AXI exactly as it did for the packaged IP.
//
// Written in non-ANSI Verilog-2001 style on purpose: attributes on port
// declarations are plain Verilog there, whereas ANSI-style port attributes are
// a SystemVerilog extension.

module gestureflow_layer_chain_dmp_hp0_axil_bd #(
  parameter integer IMAGE_WIDTH            = 96,
  parameter integer IMAGE_HEIGHT           = 96,
  parameter integer OUT_LANES              = 16,
  parameter integer REQUANT_PARALLEL_LANES = 4,
  parameter integer OUTPUT_ADDR_W          = 14,
  parameter integer POOL_BANK_ADDR_W       = 12,
  parameter integer MAX_INPUT_CHANNELS     = 48,
  parameter integer ENABLE_WIDE_MODES      = 1,
  parameter integer ENABLE_POSTPROCESS     = 1,
  parameter integer ENABLE_RELAY           = 0,
  parameter integer ENABLE_STREAM_STORE    = 0
) (
  aclk,
  aresetn,
  s_axi_awaddr, s_axi_awprot, s_axi_awvalid, s_axi_awready,
  s_axi_wdata, s_axi_wstrb, s_axi_wvalid, s_axi_wready,
  s_axi_bresp, s_axi_bvalid, s_axi_bready,
  s_axi_araddr, s_axi_arprot, s_axi_arvalid, s_axi_arready,
  s_axi_rdata, s_axi_rresp, s_axi_rvalid, s_axi_rready,
  m_axi_araddr, m_axi_arid, m_axi_arlen, m_axi_arsize, m_axi_arburst,
  m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos, m_axi_arregion,
  m_axi_arvalid, m_axi_arready,
  m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, m_axi_rready,
  m_axi_awaddr, m_axi_awid, m_axi_awlen, m_axi_awsize, m_axi_awburst,
  m_axi_awlock, m_axi_awcache, m_axi_awprot, m_axi_awqos, m_axi_awregion,
  m_axi_awvalid, m_axi_awready,
  m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wvalid, m_axi_wready,
  m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_bready
);

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
  input  wire        aclk;
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW" *)
  input  wire        aresetn;

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 32, DATA_WIDTH 32, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2, MAX_BURST_LENGTH 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR"  *) input  wire [31:0] s_axi_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT"  *) input  wire [2:0]  s_axi_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input  wire        s_axi_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire        s_axi_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA"   *) input  wire [31:0] s_axi_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB"   *) input  wire [3:0]  s_axi_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID"  *) input  wire        s_axi_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY"  *) output wire        s_axi_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP"   *) output wire [1:0]  s_axi_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID"  *) output wire        s_axi_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY"  *) input  wire        s_axi_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR"  *) input  wire [31:0] s_axi_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT"  *) input  wire [2:0]  s_axi_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input  wire        s_axi_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire        s_axi_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA"   *) output wire [31:0] s_axi_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP"   *) output wire [1:0]  s_axi_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID"  *) output wire        s_axi_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY"  *) input  wire        s_axi_rready;

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR"   *) output wire [31:0] m_axi_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID"     *) output wire [5:0]  m_axi_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN"    *) output wire [7:0]  m_axi_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE"   *) output wire [2:0]  m_axi_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST"  *) output wire [1:0]  m_axi_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK"   *) output wire        m_axi_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE"  *) output wire [3:0]  m_axi_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT"   *) output wire [2:0]  m_axi_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS"    *) output wire [3:0]  m_axi_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREGION" *) output wire [3:0]  m_axi_arregion;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID"  *) output wire        m_axi_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY"  *) input  wire        m_axi_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID"      *) input  wire [5:0]  m_axi_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA"    *) input  wire [63:0] m_axi_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP"    *) input  wire [1:0]  m_axi_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST"    *) input  wire        m_axi_rlast;
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BRESP 1, HAS_RRESP 1, HAS_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 16" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID"   *) input  wire        m_axi_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY"   *) output wire        m_axi_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR"   *) output wire [31:0] m_axi_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID"     *) output wire [5:0]  m_axi_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN"    *) output wire [7:0]  m_axi_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE"   *) output wire [2:0]  m_axi_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST"  *) output wire [1:0]  m_axi_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK"   *) output wire        m_axi_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE"  *) output wire [3:0]  m_axi_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT"   *) output wire [2:0]  m_axi_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS"    *) output wire [3:0]  m_axi_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREGION" *) output wire [3:0]  m_axi_awregion;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID"  *) output wire        m_axi_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY"  *) input  wire        m_axi_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA"    *) output wire [63:0] m_axi_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB"    *) output wire [7:0]  m_axi_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST"    *) output wire        m_axi_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID"   *) output wire        m_axi_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY"   *) input  wire        m_axi_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID"      *) input  wire [5:0]  m_axi_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP"    *) input  wire [1:0]  m_axi_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID"   *) input  wire        m_axi_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY"   *) output wire        m_axi_bready;

  gestureflow_layer_chain_dmp_hp0_axil #(
    .IMAGE_WIDTH            (IMAGE_WIDTH),
    .IMAGE_HEIGHT           (IMAGE_HEIGHT),
    .OUT_LANES              (OUT_LANES),
    .REQUANT_PARALLEL_LANES (REQUANT_PARALLEL_LANES),
    .OUTPUT_ADDR_W          (OUTPUT_ADDR_W),
    .POOL_BANK_ADDR_W       (POOL_BANK_ADDR_W),
    .MAX_INPUT_CHANNELS     (MAX_INPUT_CHANNELS),
    .ENABLE_WIDE_MODES      (ENABLE_WIDE_MODES[0]),
    .ENABLE_POSTPROCESS     (ENABLE_POSTPROCESS[0]),
    .ENABLE_RELAY           (ENABLE_RELAY[0]),
    .ENABLE_STREAM_STORE    (ENABLE_STREAM_STORE[0])
  ) u_gestureflow (
    .aclk             (aclk),
    .aresetn          (aresetn),
    .s_axi_awaddr     (s_axi_awaddr),
    .s_axi_awprot     (s_axi_awprot),
    .s_axi_awvalid    (s_axi_awvalid),
    .s_axi_awready    (s_axi_awready),
    .s_axi_wdata      (s_axi_wdata),
    .s_axi_wstrb      (s_axi_wstrb),
    .s_axi_wvalid     (s_axi_wvalid),
    .s_axi_wready     (s_axi_wready),
    .s_axi_bresp      (s_axi_bresp),
    .s_axi_bvalid     (s_axi_bvalid),
    .s_axi_bready     (s_axi_bready),
    .s_axi_araddr     (s_axi_araddr),
    .s_axi_arprot     (s_axi_arprot),
    .s_axi_arvalid    (s_axi_arvalid),
    .s_axi_arready    (s_axi_arready),
    .s_axi_rdata      (s_axi_rdata),
    .s_axi_rresp      (s_axi_rresp),
    .s_axi_rvalid     (s_axi_rvalid),
    .s_axi_rready     (s_axi_rready),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arid       (m_axi_arid),
    .m_axi_arlen      (m_axi_arlen),
    .m_axi_arsize     (m_axi_arsize),
    .m_axi_arburst    (m_axi_arburst),
    .m_axi_arlock     (m_axi_arlock),
    .m_axi_arcache    (m_axi_arcache),
    .m_axi_arprot     (m_axi_arprot),
    .m_axi_arqos      (m_axi_arqos),
    .m_axi_arregion   (m_axi_arregion),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_rid        (m_axi_rid),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rlast      (m_axi_rlast),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready),
    .m_axi_awaddr     (m_axi_awaddr),
    .m_axi_awid       (m_axi_awid),
    .m_axi_awlen      (m_axi_awlen),
    .m_axi_awsize     (m_axi_awsize),
    .m_axi_awburst    (m_axi_awburst),
    .m_axi_awlock     (m_axi_awlock),
    .m_axi_awcache    (m_axi_awcache),
    .m_axi_awprot     (m_axi_awprot),
    .m_axi_awqos      (m_axi_awqos),
    .m_axi_awregion   (m_axi_awregion),
    .m_axi_awvalid    (m_axi_awvalid),
    .m_axi_awready    (m_axi_awready),
    .m_axi_wdata      (m_axi_wdata),
    .m_axi_wstrb      (m_axi_wstrb),
    .m_axi_wlast      (m_axi_wlast),
    .m_axi_wvalid     (m_axi_wvalid),
    .m_axi_wready     (m_axi_wready),
    .m_axi_bid        (m_axi_bid),
    .m_axi_bresp      (m_axi_bresp),
    .m_axi_bvalid     (m_axi_bvalid),
    .m_axi_bready     (m_axi_bready)
  );

endmodule
