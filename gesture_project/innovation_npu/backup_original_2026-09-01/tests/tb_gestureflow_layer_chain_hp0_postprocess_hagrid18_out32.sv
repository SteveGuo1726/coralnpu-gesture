// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Top-level mode-4 regression for the HaGRID-18 postprocess path. The memory
// model returns a zero 12x12x64 tensor and checks that the shared layer-chain
// read mux forwards bursts from the postprocess loader, and that the 64-wide
// GAP + 18-class FC tail completes with correct done counts.
`timescale 1ns/1ps
module tb_gestureflow_layer_chain_hp0_postprocess_hagrid18_out32;
  localparam logic [31:0] CONTROL = 32'h008;
  localparam logic [31:0] LAYER_MODE = 32'h064;
  localparam logic [31:0] DMA_SOURCE = 32'h044;
  localparam logic [31:0] DMA_BYTES = 32'h048;
  localparam logic [31:0] DMA_PIXELS = 32'h04c;
  localparam logic [31:0] POST_GAP_MULT = 32'h080;
  localparam logic [31:0] POST_GAP_SHIFT = 32'h084;
  localparam logic [31:0] POST_QCFG = 32'h088;
  localparam logic [31:0] SOURCE_BASE = 32'h00001000;
  localparam int INPUT_BYTES = 144 * 64;
  localparam int INPUT_BEATS = INPUT_BYTES / 8;

  logic clk = 1'b0;
  logic aresetn = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] s_axi_awaddr = '0, s_axi_wdata = '0, s_axi_araddr = '0, s_axi_rdata;
  logic [2:0] s_axi_awprot = '0, s_axi_arprot = '0;
  logic [3:0] s_axi_wstrb = 4'hf;
  logic s_axi_awvalid = 1'b0, s_axi_awready, s_axi_wvalid = 1'b0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic s_axi_bvalid, s_axi_bready = 1'b0;
  logic s_axi_arvalid = 1'b0, s_axi_arready, s_axi_rvalid, s_axi_rready = 1'b0;

  logic [31:0] m_axi_araddr;
  logic [5:0] m_axi_arid, m_axi_rid = '0;
  logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot;
  logic [1:0] m_axi_arburst, m_axi_rresp = '0;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready;
  logic m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion;
  logic [63:0] m_axi_rdata = '0;
  logic [31:0] response_addr;
  logic [5:0] response_beats;
  logic response_active = 1'b0;
  logic [31:0] accepted_read_bursts = '0;

  logic [31:0] m_axi_awaddr;
  logic [63:0] m_axi_wdata;
  logic [5:0] m_axi_awid, m_axi_bid = '0;
  logic [7:0] m_axi_awlen, m_axi_wstrb;
  logic [2:0] m_axi_awsize, m_axi_awprot;
  logic [1:0] m_axi_awburst, m_axi_bresp = '0;
  logic m_axi_awlock, m_axi_awvalid, m_axi_awready;
  logic m_axi_wlast, m_axi_wvalid, m_axi_wready, m_axi_bvalid = 1'b0, m_axi_bready;
  logic [3:0] m_axi_awcache, m_axi_awqos, m_axi_awregion;

  assign m_axi_arready = !response_active;
  assign m_axi_awready = 1'b1;
  assign m_axi_wready = 1'b0;
  assign m_axi_bvalid = 1'b0;
  assign m_axi_rvalid = response_active;
  assign m_axi_rlast = response_beats == 1;

  gestureflow_layer_chain_hp0_axil #(
    .MAX_INPUT_CHANNELS(48),
    .OUT_LANES(32),
    .POOL_BANK_ADDR_W(12),
    .ENABLE_WIDE_MODES(1'b1),
    .ENABLE_POSTPROCESS(1'b1)
  ) dut (
    .aclk(clk), .aresetn(aresetn),
    .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .m_axi_araddr, .m_axi_arid, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
    .m_axi_arlock, .m_axi_arcache, .m_axi_arprot, .m_axi_arqos, .m_axi_arregion,
    .m_axi_arvalid, .m_axi_arready,
    .m_axi_rid, .m_axi_rdata, .m_axi_rresp, .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
    .m_axi_awaddr, .m_axi_awid, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
    .m_axi_awlock, .m_axi_awcache, .m_axi_awprot, .m_axi_awqos, .m_axi_awregion,
    .m_axi_awvalid, .m_axi_awready,
    .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
    .m_axi_bid, .m_axi_bresp, .m_axi_bvalid, .m_axi_bready
  );

  always_ff @(posedge clk) begin
    if (!aresetn) begin
      response_addr <= '0;
      response_beats <= '0;
      response_active <= 1'b0;
      accepted_read_bursts <= '0;
      m_axi_rdata <= '0;
    end else if (!response_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr < SOURCE_BASE || m_axi_araddr >= SOURCE_BASE + INPUT_BYTES ||
          m_axi_araddr[2:0] != 0 || m_axi_arsize != 3'd3 ||
          m_axi_arburst != 2'b01 || m_axi_arlen > 8'd15) begin
        $fatal(1, "invalid mode4 HP0 request addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      end
      response_addr <= m_axi_araddr;
      response_beats <= m_axi_arlen[5:0] + 1'b1;
      response_active <= 1'b1;
      accepted_read_bursts <= accepted_read_bursts + 1'b1;
      m_axi_rdata <= '0;
    end else if (response_active && m_axi_rvalid && m_axi_rready) begin
      if (response_beats == 1) begin
        response_active <= 1'b0;
        response_beats <= '0;
      end else begin
        response_addr <= response_addr + 8;
        response_beats <= response_beats - 1'b1;
        m_axi_rdata <= '0;
      end
    end
  end

  task automatic write32(input logic [31:0] address, input logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_awaddr = address;
      s_axi_wdata = value;
      s_axi_awvalid = 1'b1;
      s_axi_wvalid = 1'b1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
      s_axi_wvalid = 1'b0;
      while (!s_axi_bvalid) @(negedge clk);
      s_axi_bready = 1'b1;
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    aresetn = 1'b1;
    write32(CONTROL, 32'd1);
    write32(LAYER_MODE, 32'd4);
    write32(DMA_SOURCE, SOURCE_BASE);
    write32(DMA_BYTES, INPUT_BYTES);
    write32(DMA_PIXELS, 144);
    write32(POST_GAP_MULT, 0);
    write32(POST_GAP_SHIFT, 0);
    write32(POST_QCFG, 0);
    write32(CONTROL, 32'd2);

    for (int wait_cycle = 0; wait_cycle < 200000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "mode4 hagrid18 top fault progress=%08x", dut.post_gap_values_done);
      if (dut.done) begin
        if (accepted_read_bursts == 0 || dut.post_gap_values_done != 64 ||
            dut.post_fc_values_done != 18)
          $fatal(1, "mode4 hagrid18 completion invalid bursts=%0d gap=%0d fc=%0d class=%0d",
            accepted_read_bursts, dut.post_gap_values_done, dut.post_fc_values_done,
            dut.post_predicted_class);
        $display("GESTUREFLOW_LAYER_CHAIN_HP0_POSTPROCESS_HAGRID18_PASS bursts=%0d cycles=%0d gap=%0d fc=%0d class=%0d",
          accepted_read_bursts, dut.post_cycles, dut.post_gap_values_done,
          dut.post_fc_values_done, dut.post_predicted_class);
        $finish;
      end
    end
    $fatal(1, "mode4 hagrid18 top timeout bursts=%0d bytes=%0d",
      accepted_read_bursts, dut.dma_bytes_read);
  end
endmodule
