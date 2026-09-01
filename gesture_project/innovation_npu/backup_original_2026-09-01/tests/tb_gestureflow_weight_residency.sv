// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Weight-residency protocol regression. It proves the B1 hardware gate:
// a model key is committed once, a second write of the same key is a hit
// (hit_count increments, miss_count stays put, resident_valid stays set), and
// any AXI-Lite weight/data write after a hit is rejected with a fault so the
// per-frame weight reload cannot silently re-enter the data path.
`timescale 1ns/1ps
module tb_gestureflow_weight_residency;
  localparam logic [11:0] CONTROL=12'h008, STATUS=12'h00c, WDATA=12'h018,
    WEIGHT_KEY=12'h0c0, WEIGHT_RESIDENT_KEY=12'h0c4,
    WEIGHT_WRITE_COUNT=12'h0c8, WEIGHT_HIT_COUNT=12'h0cc,
    WEIGHT_BYTES=12'h0d0, WEIGHT_STATUS=12'h0d4,
    WEIGHT_COMMIT=12'h0d8, WEIGHT_MISS_COUNT=12'h0dc;
  localparam logic [31:0] MODEL_KEY = 32'hCAFE1234;

  logic clk=0, aresetn=0; always #5 clk=~clk;
  logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0, s_axi_rdata;
  logic [2:0] s_axi_awprot=0, s_axi_arprot=0;
  logic [3:0] s_axi_wstrb=4'hf;
  logic s_axi_awvalid=0,s_axi_awready,s_axi_wvalid=0,s_axi_wready,s_axi_bvalid,s_axi_bready=1;
  logic [1:0] s_axi_bresp,s_axi_rresp;
  logic s_axi_arvalid=0,s_axi_arready,s_axi_rvalid,s_axi_rready=1;
  logic [31:0] m_axi_araddr,m_axi_awaddr; logic [5:0] m_axi_arid,m_axi_awid,m_axi_rid=0,m_axi_bid=0;
  logic [7:0] m_axi_arlen,m_axi_awlen; logic [2:0] m_axi_arsize,m_axi_awsize;
  logic [1:0] m_axi_arburst,m_axi_awburst,m_axi_rresp=0,m_axi_bresp=0;
  logic m_axi_arlock,m_axi_arvalid,m_axi_arready,m_axi_rlast,m_axi_rvalid=0,m_axi_rready;
  logic [3:0] m_axi_arcache,m_axi_arqos,m_axi_arregion,m_axi_awcache,m_axi_awqos,m_axi_awregion;
  logic [2:0] m_axi_arprot,m_axi_awprot;
  logic m_axi_awlock,m_axi_awvalid,m_axi_awready,m_axi_wvalid,m_axi_wready,m_axi_wlast,m_axi_bvalid=0,m_axi_bready;
  logic [63:0] m_axi_rdata=0,m_axi_wdata; logic [7:0] m_axi_wstrb;

  gestureflow_layer_chain_hp0_axil #(.IMAGE_WIDTH(4),.IMAGE_HEIGHT(2),.OUTPUTS(8),.OUTPUT_ADDR_W(3)) dut (
    .aclk(clk), .aresetn,
    .s_axi_awaddr,.s_axi_awprot,.s_axi_awvalid,.s_axi_awready,.s_axi_wdata,.s_axi_wstrb,.s_axi_wvalid,.s_axi_wready,
    .s_axi_bresp,.s_axi_bvalid,.s_axi_bready,.s_axi_araddr,.s_axi_arprot,.s_axi_arvalid,.s_axi_arready,.s_axi_rdata,.s_axi_rresp,.s_axi_rvalid,.s_axi_rready,
    .m_axi_araddr,.m_axi_arid,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,.m_axi_arlock,.m_axi_arcache,.m_axi_arprot,.m_axi_arqos,.m_axi_arregion,.m_axi_arvalid,.m_axi_arready,
    .m_axi_rid,.m_axi_rdata,.m_axi_rresp,.m_axi_rlast,.m_axi_rvalid,.m_axi_rready,
    .m_axi_awaddr,.m_axi_awid,.m_axi_awlen,.m_axi_awsize,.m_axi_awburst,.m_axi_awlock,.m_axi_awcache,.m_axi_awprot,.m_axi_awqos,.m_axi_awregion,.m_axi_awvalid,.m_axi_awready,
    .m_axi_wdata,.m_axi_wstrb,.m_axi_wlast,.m_axi_wvalid,.m_axi_wready,.m_axi_bid,.m_axi_bresp,.m_axi_bvalid,.m_axi_bready
  );

  assign m_axi_arready = 1'b1;
  assign m_axi_awready = 1'b1;
  assign m_axi_wready = 1'b1;

  task automatic write32(input logic [11:0] address, input logic [31:0] value);
    begin
      @(negedge clk); s_axi_awaddr={20'd0,address}; s_axi_wdata=value; s_axi_awvalid=1; s_axi_wvalid=1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
      while (!s_axi_bvalid) @(negedge clk);
    end
  endtask
  task automatic read32(input logic [11:0] address, output logic [31:0] value);
    begin
      @(negedge clk); s_axi_araddr={20'd0,address}; s_axi_arvalid=1;
      while (!s_axi_arready) @(negedge clk);
      @(negedge clk); s_axi_arvalid=0;
      while (!s_axi_rvalid) @(negedge clk);
      value=s_axi_rdata;
    end
  endtask

  initial begin
    logic [31:0] value;
    repeat(3) @(negedge clk); aresetn=1;
    write32(CONTROL,1);

    // Cold miss.
    write32(WEIGHT_KEY, MODEL_KEY);
    read32(WEIGHT_MISS_COUNT, value); if (value != 1) $fatal(1, "cold miss_count=%0d", value);
    read32(WEIGHT_HIT_COUNT, value); if (value != 0) $fatal(1, "cold hit_count=%0d", value);
    read32(WEIGHT_STATUS, value);
    if (!value[3] || value[4] || value[2]) $fatal(1, "cold weight_status=%08x", value);

    // Commit makes the key resident.
    write32(WEIGHT_COMMIT, 1);
    read32(WEIGHT_RESIDENT_KEY, value); if (value != MODEL_KEY) $fatal(1, "resident key=%08x", value);
    read32(WEIGHT_STATUS, value);
    if (!value[2] || !value[1]) $fatal(1, "committed weight_status=%08x", value);

    // Same key again is a hit and must not count a second miss.
    write32(WEIGHT_KEY, MODEL_KEY);
    read32(WEIGHT_HIT_COUNT, value); if (value != 1) $fatal(1, "warm hit_count=%0d", value);
    read32(WEIGHT_MISS_COUNT, value); if (value != 1) $fatal(1, "warm miss_count=%0d", value);
    read32(WEIGHT_STATUS, value);
    if (!value[4] || !value[3] || !value[2]) $fatal(1, "warm weight_status=%08x", value);

    // A weight-data write after a hit must be rejected.
    write32(WDATA, 32'h00000001);
    read32(STATUS, value);
    if (!value[2]) $fatal(1, "post-hit WDATA was not rejected status=%08x", value);

    $display("GESTUREFLOW_WEIGHT_RESIDENCY_PASS miss=1 hit=1 resident=%08x", MODEL_KEY);
    $finish;
  end
endmodule
