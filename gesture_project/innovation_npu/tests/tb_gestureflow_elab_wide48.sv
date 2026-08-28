// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Elaboration-only harness for the HaGRID-18 wide build: MAX_INPUT_CHANNELS=48
// with wide (32/48-channel) loaders and postprocess enabled. Verilator catches
// missing tie-offs / multiple drivers before a slow Vivado run.
`timescale 1ns/1ps
module tb_gestureflow_elab_wide48;
  logic clk = 0, aresetn = 0;
  logic [31:0] s_axi_awaddr = 0, s_axi_wdata = 0, s_axi_araddr = 0, s_axi_rdata;
  logic [2:0] s_axi_awprot = 0, s_axi_arprot = 0; logic [3:0] s_axi_wstrb = 4'hf;
  logic s_axi_awvalid = 0, s_axi_awready, s_axi_wvalid = 0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp; logic s_axi_bvalid, s_axi_bready = 0;
  logic s_axi_arvalid = 0, s_axi_arready, s_axi_rvalid, s_axi_rready = 0;
  logic [31:0] m_axi_araddr; logic [5:0] m_axi_arid, m_axi_rid = 0; logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot; logic [1:0] m_axi_arburst, m_axi_rresp = 0;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast = 0, m_axi_rvalid = 0, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion; logic [63:0] m_axi_rdata = 0;
  logic [31:0] m_axi_awaddr; logic [5:0] m_axi_awid, m_axi_bid = 0; logic [7:0] m_axi_awlen;
  logic [2:0] m_axi_awsize, m_axi_awprot; logic [1:0] m_axi_awburst, m_axi_bresp = 0;
  logic m_axi_awlock, m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic m_axi_bvalid = 0, m_axi_bready; logic [3:0] m_axi_awcache, m_axi_awqos, m_axi_awregion;
  logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb;

  always #5 clk = ~clk;

  gestureflow_layer_chain_hp0_axil #(
    .MAX_INPUT_CHANNELS(48), .ENABLE_WIDE_MODES(1'b1),
    .ENABLE_POSTPROCESS(1'b1), .ENABLE_RELAY(1'b0)
  ) dut (
    .aclk(clk), .aresetn(aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .m_axi_araddr(m_axi_araddr), .m_axi_arid(m_axi_arid), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
    .m_axi_arqos(m_axi_arqos), .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awid(m_axi_awid), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
    .m_axi_awqos(m_axi_awqos), .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  initial begin
    repeat (4) @(negedge clk);
    aresetn = 1;
    repeat (8) @(negedge clk);
    $display("GESTUREFLOW_ELAB_WIDE48_PASS");
    $finish;
  end
endmodule
