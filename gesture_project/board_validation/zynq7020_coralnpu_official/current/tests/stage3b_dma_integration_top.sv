// PROJECT_LOCAL_MOD: simulation-only composition of the real stage3b engine
// and its DDR burst mover.  It deliberately has no AXI-Lite or RVV wrapper so
// the regression can isolate complete tensor movement and arithmetic.
`timescale 1ns / 1ps

module stage3b_dma_integration_top (
    input wire clk, input wire rstn,
    input wire start_load, input wire start_engine, input wire start_store,
    input wire [31:0] input_base_addr, input wire [31:0] weight_base_addr,
    input wire [31:0] bias_base_addr, input wire [31:0] multiplier_base_addr,
    input wire [31:0] shift_base_addr, input wire [31:0] pool_base_addr,
    output wire dma_busy, output wire dma_done, output wire dma_fault,
    output wire engine_busy, output wire engine_done, output wire engine_fault,
    output wire m_axi_awvalid, input wire m_axi_awready, output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen, output wire [31:0] m_axi_wdata,
    output wire m_axi_wvalid, input wire m_axi_wready, output wire m_axi_wlast,
    output wire m_axi_bready, input wire m_axi_bvalid, input wire [1:0] m_axi_bresp,
    output wire m_axi_arvalid, input wire m_axi_arready, output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen, output wire m_axi_rready, input wire m_axi_rvalid,
    input wire [31:0] m_axi_rdata, input wire [1:0] m_axi_rresp, input wire m_axi_rlast
);
  wire dma_stage_we;
  wire [2:0] dma_stage_kind;
  wire [15:0] dma_stage_addr;
  wire [31:0] dma_stage_wdata;
  wire dma_pool_re;
  wire [10:0] dma_pool_addr;
  wire [63:0] dma_pool_rdata;
  wire unused_mem_rdata;

  coralnpu_stage3b_tensor_engine u_engine (
      .clk(clk), .rstn(rstn), .start(start_engine),
      .busy(engine_busy), .done(engine_done), .fault(engine_fault),
      .mem_we(1'b0), .mem_re(1'b0), .mem_kind(3'd0), .mem_addr(16'd0),
      .mem_wdata(32'd0), .mem_rdata(unused_mem_rdata),
      .dma_we(dma_stage_we), .dma_kind(dma_stage_kind),
      .dma_addr(dma_stage_addr), .dma_wdata(dma_stage_wdata),
      .dma_pool_re(dma_pool_re), .dma_pool_addr(dma_pool_addr),
      .dma_pool_rdata(dma_pool_rdata)
  );

  coralnpu_stage3b_axi_dma u_dma (
      .clk(clk), .rstn(rstn), .start_load(start_load), .start_store(start_store),
      .input_base_addr(input_base_addr), .weight_base_addr(weight_base_addr),
      .bias_base_addr(bias_base_addr), .multiplier_base_addr(multiplier_base_addr),
      .shift_base_addr(shift_base_addr), .pool_base_addr(pool_base_addr),
      .busy(dma_busy), .done(dma_done), .fault(dma_fault),
      .stage_we(dma_stage_we), .stage_kind(dma_stage_kind),
      .stage_addr(dma_stage_addr), .stage_wdata(dma_stage_wdata),
      .pool_re(dma_pool_re), .pool_addr(dma_pool_addr), .pool_rdata(dma_pool_rdata),
      .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_awaddr(m_axi_awaddr), .m_axi_awprot(), .m_axi_awid(),
      .m_axi_awlen(m_axi_awlen), .m_axi_awsize(), .m_axi_awburst(),
      .m_axi_awlock(), .m_axi_awcache(), .m_axi_awqos(), .m_axi_awregion(),
      .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(), .m_axi_wlast(m_axi_wlast),
      .m_axi_bready(m_axi_bready), .m_axi_bvalid(m_axi_bvalid), .m_axi_bid(6'd1), .m_axi_bresp(m_axi_bresp),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_araddr(m_axi_araddr), .m_axi_arprot(), .m_axi_arid(),
      .m_axi_arlen(m_axi_arlen), .m_axi_arsize(), .m_axi_arburst(),
      .m_axi_arlock(), .m_axi_arcache(), .m_axi_arqos(), .m_axi_arregion(),
      .m_axi_rready(m_axi_rready), .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rdata(m_axi_rdata), .m_axi_rid(6'd1), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast)
  );
endmodule
