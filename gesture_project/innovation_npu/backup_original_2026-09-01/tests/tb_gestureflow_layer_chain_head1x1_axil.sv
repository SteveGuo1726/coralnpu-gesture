// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Bounded top-level regression for the real static-network head_1x1 tile.
// The HP0 loader reads the true pool3 tensor, the shared MAC backend runs the
// new pointwise mode, and the writer stores lane0..15 into a 112-byte NHWC
// stride so board software can use the same ABI.
`timescale 1ns/1ps
module tb_gestureflow_layer_chain_head1x1_axil;
  `include "generated_gestureflow_real_conv4x4_head1x1_layer.svh"

  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    STATUS=32'h00c, QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018,
    BIDX=32'h01c, BDATA=32'h020, RQIDX=32'h024, RQMULT=32'h028,
    RQSHIFT=32'h02c, OUTPUT_FNV1A=32'h040, DMA_SOURCE=32'h044,
    DMA_BYTES=32'h048, DMA_PIXELS=32'h04c, STORE_DESTINATION=32'h054,
    STORE_BYTES=32'h058, STORE_CONTROL=32'h05c, STORE_STATUS=32'h060,
    LAYER_MODE=32'h064, JOB_WIDTH=32'h068, JOB_HEIGHT=32'h06c,
    OUTPUT_LANE_MASK=32'h070, STORE_STRIDE=32'h074, STORE_VALID_BYTES=32'h078;
  localparam logic [31:0] INPUT_BASE=32'h00001000, OUTPUT_BASE=32'h00010000;
  localparam int GF_HEAD1X1_EMBEDDED_CENTER_TAP = 5;
  localparam int INPUT_BYTES = GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT * GF_HEAD1X1_INPUT_CHANNELS;
  localparam int TILE_OUTPUT_BYTES = GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT * 16;
  localparam int FULL_OUTPUT_BYTES = GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT * GF_HEAD1X1_LANES;
  localparam int DDR_BYTES = 32'h00018000;
  localparam int DDR_BEATS = DDR_BYTES / 8;

  logic clk = 0, aresetn = 0;
  logic [31:0] s_axi_awaddr = 0, s_axi_wdata = 0, s_axi_araddr = 0, s_axi_rdata;
  logic [2:0] s_axi_awprot = 0, s_axi_arprot = 0; logic [3:0] s_axi_wstrb = 4'hf;
  logic s_axi_awvalid = 0, s_axi_awready, s_axi_wvalid = 0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp; logic s_axi_bvalid, s_axi_bready = 0;
  logic s_axi_arvalid = 0, s_axi_arready, s_axi_rvalid, s_axi_rready = 0;
  logic [31:0] m_axi_araddr; logic [5:0] m_axi_arid, m_axi_rid; logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot; logic [1:0] m_axi_arburst, m_axi_rresp;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion; logic [63:0] m_axi_rdata;
  logic [31:0] m_axi_awaddr; logic [5:0] m_axi_awid, m_axi_bid = 0; logic [7:0] m_axi_awlen;
  logic [2:0] m_axi_awsize, m_axi_awprot; logic [1:0] m_axi_awburst, m_axi_bresp = 0;
  logic m_axi_awlock, m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic m_axi_bvalid = 0, m_axi_bready; logic [3:0] m_axi_awcache, m_axi_awqos, m_axi_awregion;
  logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb;
  logic [63:0] ddr [0:DDR_BEATS-1];
  logic ddr_active; logic [13:0] ddr_index; logic [4:0] ddr_beats_left;
  logic write_active; logic [13:0] write_index; logic [4:0] write_beats_left;

  function automatic logic [31:0] fnv_step(input logic [31:0] current, input logic [7:0] byte_value);
    fnv_step = (current ^ {24'd0, byte_value}) * 32'h01000193;
  endfunction

  always #5 clk = ~clk;
  assign m_axi_arready = !ddr_active;
  assign m_axi_awready = !write_active;
  assign m_axi_wready = write_active;

  gestureflow_layer_chain_hp0_axil #(
    .IMAGE_WIDTH(12), .IMAGE_HEIGHT(12), .OUTPUTS(144),
    .OUTPUT_ADDR_W(14), .MAX_INPUT_CHANNELS(80),
    .ENABLE_WIDE_MODES(1'b1), .ENABLE_POSTPROCESS(1'b0)
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

  always_ff @(posedge clk) begin
    if (!aresetn) begin
      ddr_active <= 1'b0; ddr_index <= '0; ddr_beats_left <= '0; m_axi_rid <= '0; m_axi_rdata <= '0;
      m_axi_rresp <= 0; m_axi_rlast <= 1'b0; m_axi_rvalid <= 1'b0;
    end else if (!ddr_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[2:0] != 0 || m_axi_arsize != 3 || m_axi_arburst != 2'b01 || m_axi_arlen > 15 ||
          m_axi_araddr < INPUT_BASE || m_axi_araddr >= INPUT_BASE + INPUT_BYTES)
        $fatal(1, "invalid head1x1 HP0 read addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      ddr_active <= 1'b1;
      ddr_index <= 14'(m_axi_araddr >> 3);
      ddr_beats_left <= m_axi_arlen[4:0] + 1'b1;
      m_axi_rid <= m_axi_arid;
      m_axi_rdata <= ddr[m_axi_araddr >> 3];
      m_axi_rresp <= 0;
      m_axi_rlast <= (m_axi_arlen == 0);
      m_axi_rvalid <= 1'b1;
    end else if (ddr_active && m_axi_rvalid && m_axi_rready) begin
      if (ddr_beats_left == 1) begin
        ddr_active <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
      end else begin
        ddr_index <= ddr_index + 1'b1;
        ddr_beats_left <= ddr_beats_left - 1'b1;
        m_axi_rdata <= ddr[ddr_index + 1'b1];
        m_axi_rlast <= (ddr_beats_left == 2);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!aresetn) begin
      write_active <= 1'b0; write_index <= '0; write_beats_left <= '0; m_axi_bvalid <= 1'b0;
    end else begin
      if (m_axi_bvalid && m_axi_bready) m_axi_bvalid <= 1'b0;
      if (!write_active && m_axi_awvalid && m_axi_awready) begin
        if (m_axi_awaddr[2:0] != 0 || m_axi_awsize != 3 || m_axi_awburst != 2'b01 || m_axi_awlen > 1 ||
            m_axi_awaddr < OUTPUT_BASE || m_axi_awaddr >= OUTPUT_BASE + FULL_OUTPUT_BYTES || m_axi_awid != 0)
          $fatal(1, "invalid head1x1 HP0 write addr=%08x len=%0d", m_axi_awaddr, m_axi_awlen);
        write_active <= 1'b1;
        write_index <= 14'(m_axi_awaddr >> 3);
        write_beats_left <= m_axi_awlen[4:0] + 1'b1;
      end
      if (write_active && m_axi_wvalid && m_axi_wready) begin
        for (int byte_index = 0; byte_index < 8; byte_index++) begin
          if (m_axi_wstrb[byte_index]) ddr[write_index][byte_index*8 +: 8] <= m_axi_wdata[byte_index*8 +: 8];
        end
        if (write_beats_left == 1) begin
          if (!m_axi_wlast) $fatal(1, "missing head1x1 WLAST");
          write_active <= 1'b0;
          m_axi_bvalid <= 1'b1;
        end else begin
          if (m_axi_wlast) $fatal(1, "early head1x1 WLAST");
          write_index <= write_index + 1'b1;
          write_beats_left <= write_beats_left - 1'b1;
        end
      end
    end
  end

  task automatic write32(input logic [31:0] address, input logic [31:0] value);
    begin
      @(negedge clk); s_axi_awaddr = address; s_axi_wdata = value; s_axi_awvalid = 1'b1; s_axi_wvalid = 1'b1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk); s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
      while (!s_axi_bvalid) @(negedge clk);
      s_axi_bready = 1'b1; @(negedge clk); s_axi_bready = 1'b0;
    end
  endtask

  task automatic read32(input logic [31:0] address, output logic [31:0] value);
    begin
      @(negedge clk); s_axi_araddr = address; s_axi_arvalid = 1'b1;
      while (!s_axi_arready) @(negedge clk);
      @(negedge clk); s_axi_arvalid = 1'b0;
      while (!s_axi_rvalid) @(negedge clk);
      value = s_axi_rdata; s_axi_rready = 1'b1; @(negedge clk); s_axi_rready = 1'b0;
    end
  endtask

  task automatic load_head1x1_tile0_weights;
    logic [31:0] packed_weight;
    begin
      write32(OUTPUT_LANE_MASK, 32'h0000ffff);
      for (int oc = 0; oc < 16; oc++) begin
        write32(BIDX, oc);
        write32(BDATA, gf_head1x1_folded_bias[oc]);
        write32(RQIDX, oc);
        write32(RQMULT, gf_head1x1_multiplier[oc]);
        write32(RQSHIFT, {26'd0, gf_head1x1_right_shift[oc]});
        for (int group = 0; group < GF_HEAD1X1_INPUT_CHANNELS / 4; group++) begin
          packed_weight = '0;
          for (int lane = 0; lane < 4; lane++) begin
            packed_weight[lane*8 +: 8] = gf_head1x1_weights[
              (oc * 16 * GF_HEAD1X1_INPUT_CHANNELS) +
              (GF_HEAD1X1_EMBEDDED_CENTER_TAP * GF_HEAD1X1_INPUT_CHANNELS) +
              (group * 4) + lane
            ];
          end
          write32(WCTRL, oc | (group << 8));
          write32(WDATA, packed_weight);
        end
      end
    end
  endtask

  initial begin
    logic [31:0] value;
    logic [31:0] expected_tile_hash;
    expected_tile_hash = 32'h811c9dc5;
    for (int beat = 0; beat < DDR_BEATS; beat++) ddr[beat] = '0;
    for (int byte_index = 0; byte_index < INPUT_BYTES; byte_index++) begin
      ddr[(INPUT_BASE >> 3) + (byte_index >> 3)][(byte_index & 7) * 8 +: 8] = gf_head1x1_input_q[byte_index];
    end
    for (int pixel = 0; pixel < GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT; pixel++) begin
      for (int lane = 0; lane < 16; lane++) begin
        expected_tile_hash = fnv_step(expected_tile_hash, gf_head1x1_output_q[pixel * GF_HEAD1X1_LANES + lane]);
      end
    end
    repeat (3) @(negedge clk);
    aresetn = 1'b1;

    read32(MAGIC, value); if (value != 32'h47464e50) $fatal(1, "bad head1x1 magic %08x", value);
    read32(VERSION, value); if (value != 32'h00040004) $fatal(1, "bad head1x1 version %08x", value);

    write32(CONTROL, 1);
    write32(LAYER_MODE, 5);
    write32(JOB_WIDTH, GF_HEAD1X1_WIDTH);
    write32(JOB_HEIGHT, GF_HEAD1X1_HEIGHT);
    write32(QCFG, 32'h0003_8080);
    load_head1x1_tile0_weights();
    write32(DMA_SOURCE, INPUT_BASE);
    write32(DMA_BYTES, INPUT_BYTES);
    write32(DMA_PIXELS, GF_HEAD1X1_WIDTH * GF_HEAD1X1_HEIGHT);
    write32(STORE_DESTINATION, OUTPUT_BASE);
    write32(STORE_BYTES, TILE_OUTPUT_BYTES);
    write32(STORE_CONTROL, 1);
    write32(STORE_STRIDE, GF_HEAD1X1_LANES);
    write32(STORE_VALID_BYTES, 16);
    write32(CONTROL, 2);

    for (int wait_cycle = 0; wait_cycle < 500000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "head1x1 top fault");
      if (dut.done) break;
      if (wait_cycle == 499999) $fatal(1, "head1x1 top timeout");
    end

    read32(OUTPUT_FNV1A, value);
    if (value != expected_tile_hash) $fatal(1, "head1x1 tile hash mismatch got=%08x expected=%08x", value, expected_tile_hash);
    read32(STORE_STATUS, value);
    if (value[2:0] != 3'b010 || value[31:3] != 29'(TILE_OUTPUT_BYTES))
      $fatal(1, "head1x1 store status mismatch %08x", value);

    for (int row = 0; row < GF_HEAD1X1_HEIGHT; row++) begin
      for (int column = 0; column < GF_HEAD1X1_WIDTH; column++) begin
        int pixel_index;
        int base_byte;
        pixel_index = row * GF_HEAD1X1_WIDTH + column;
        base_byte = int'(OUTPUT_BASE) + pixel_index * GF_HEAD1X1_LANES;
        for (int lane = 0; lane < 16; lane++) begin
          logic signed [7:0] got;
          got = ddr[(base_byte >> 3) + (lane >> 3)][((lane & 7) * 8) +: 8];
          if (got !== gf_head1x1_output_q[pixel_index * GF_HEAD1X1_LANES + lane]) begin
            $fatal(1, "head1x1 top mismatch y=%0d x=%0d lane=%0d got=%0d expected=%0d",
              row, column, lane, got, gf_head1x1_output_q[pixel_index * GF_HEAD1X1_LANES + lane]);
          end
        end
        for (int lane = 16; lane < GF_HEAD1X1_LANES; lane++) begin
          logic [7:0] untouched;
          untouched = ddr[(base_byte >> 3) + (lane >> 3)][((lane & 7) * 8) +: 8];
          if (untouched !== 8'd0) begin
            $fatal(1, "head1x1 sparse stride overwrite y=%0d x=%0d lane=%0d value=%0d",
              row, column, lane, untouched);
          end
        end
      end
    end

    $display("GESTUREFLOW_LAYER_CHAIN_HEAD1X1_AXIL_PASS hash=%08x tile_bytes=%0d full_stride=%0d",
      value, TILE_OUTPUT_BYTES, GF_HEAD1X1_LANES);
    $finish;
  end
endmodule
