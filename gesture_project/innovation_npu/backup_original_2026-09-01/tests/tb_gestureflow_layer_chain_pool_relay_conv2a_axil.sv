// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Real three-stage bounded regression:
// 1. conv1 writes bank0 only
// 2. body reads bank0 and writes bank1 without DDR traffic
// 3. conv2a tile0 reads a pooled 48x48 tensor directly from bank1, so the
//    input side of this stage must not issue any HP0 read traffic.
`timescale 1ns/1ps
module gestureflow_layer_chain_pool_relay_body_golden;
  `include "generated_gestureflow_real_conv4x4_body2_layer.svh"
endmodule
module gestureflow_layer_chain_pool_relay_conv2a_golden;
  `include "generated_gestureflow_real_conv4x4_conv2a_layer.svh"
endmodule

module tb_gestureflow_layer_chain_pool_relay_conv2a_axil;
  `include "generated_gestureflow_real_conv4x4_full_layer.svh"

  gestureflow_layer_chain_pool_relay_body_golden body_golden();
  gestureflow_layer_chain_pool_relay_conv2a_golden conv2a_golden();

  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018, BIDX=32'h01c, BDATA=32'h020,
    RQIDX=32'h024, RQMULT=32'h028, RQSHIFT=32'h02c, OUTPUT_FNV1A=32'h040,
    DMA_SOURCE=32'h044, DMA_BYTES=32'h048, DMA_PIXELS=32'h04c,
    STORE_DESTINATION=32'h054, STORE_BYTES=32'h058, STORE_CONTROL=32'h05c,
    STORE_STATUS=32'h060, LAYER_MODE=32'h064, JOB_WIDTH=32'h068,
    JOB_HEIGHT=32'h06c, OUTPUT_LANE_MASK=32'h070, STORE_STRIDE=32'h074,
    STORE_VALID_BYTES=32'h078, RELAY_CONTROL=32'h07c;
  localparam logic [31:0] RGB_BASE=32'h00001000, CONV2A_TILE0_BASE=32'h00040000;
  localparam int RGB_BYTES=96*96*3;
  localparam int CONV2A_TILE0_BYTES=48*48*16;
  localparam int DDR_BYTES=32'h00050000;
  localparam int DDR_BEATS=DDR_BYTES/8;

  logic clk=0, aresetn=0;
  logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0, s_axi_rdata;
  logic [2:0] s_axi_awprot=0, s_axi_arprot=0; logic [3:0] s_axi_wstrb=4'hf;
  logic s_axi_awvalid=0, s_axi_awready, s_axi_wvalid=0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp; logic s_axi_bvalid, s_axi_bready=0;
  logic s_axi_arvalid=0, s_axi_arready, s_axi_rvalid, s_axi_rready=0;
  logic [31:0] m_axi_araddr; logic [5:0] m_axi_arid, m_axi_rid; logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot; logic [1:0] m_axi_arburst, m_axi_rresp;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion; logic [63:0] m_axi_rdata;
  logic [31:0] m_axi_awaddr; logic [5:0] m_axi_awid, m_axi_bid=0; logic [7:0] m_axi_awlen;
  logic [2:0] m_axi_awsize, m_axi_awprot; logic [1:0] m_axi_awburst, m_axi_bresp=0;
  logic m_axi_awlock, m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic m_axi_bvalid=0, m_axi_bready; logic [3:0] m_axi_awcache, m_axi_awqos, m_axi_awregion;
  logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb;
  logic [63:0] ddr [0:DDR_BEATS-1];
  logic ddr_active; logic [15:0] ddr_index; logic [4:0] ddr_beats_left;
  logic write_active; logic [15:0] write_index; logic [4:0] write_beats_left;
  logic conv2a_read_seen;

  function automatic logic [31:0] fnv_step(input logic [31:0] current, input logic [7:0] byte_value);
    fnv_step = (current ^ {24'd0, byte_value}) * 32'h01000193;
  endfunction

  always #5 clk = ~clk;
  assign m_axi_arready = !ddr_active;
  assign m_axi_awready = !write_active;
  assign m_axi_wready = write_active;

  gestureflow_layer_chain_hp0_axil #(
    .MAX_INPUT_CHANNELS(40),
    .ENABLE_WIDE_MODES(1'b1)
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
      m_axi_rresp <= 0; m_axi_rlast <= 1'b0; m_axi_rvalid <= 1'b0; conv2a_read_seen <= 1'b0;
    end else if (!ddr_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[2:0] != 0 || m_axi_arsize != 3 || m_axi_arburst != 2'b01 || m_axi_arlen > 15 ||
          m_axi_araddr < RGB_BASE || m_axi_araddr >= RGB_BASE + RGB_BYTES)
        $fatal(1, "unexpected pooled-relay HP0 read addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      if ((dut.layer_mode == 3'd1) && dut.relay_enable && dut.relay_pool_2x2) conv2a_read_seen <= 1'b1;
      ddr_active <= 1'b1;
      ddr_index <= 16'(m_axi_araddr >> 3);
      ddr_beats_left <= m_axi_arlen[4:0] + 1'b1;
      m_axi_rid <= m_axi_arid;
      m_axi_rdata <= ddr[m_axi_araddr >> 3];
      m_axi_rresp <= 0;
      m_axi_rlast <= (m_axi_arlen == 0);
      m_axi_rvalid <= 1'b1;
    end else if (ddr_active && m_axi_rvalid && m_axi_rready) begin
      if ((dut.layer_mode == 3'd1) && dut.relay_enable && dut.relay_pool_2x2) conv2a_read_seen <= 1'b1;
      if (ddr_beats_left == 1) begin
        ddr_active <= 1'b0;
        m_axi_rvalid <= 1'b0;
        m_axi_rlast <= 1'b0;
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
        if (m_axi_awaddr[2:0] != 0 || m_axi_awsize != 3 || m_axi_awburst != 2'b01 || m_axi_awlen > 15 ||
            m_axi_awaddr < CONV2A_TILE0_BASE || m_axi_awaddr >= CONV2A_TILE0_BASE + CONV2A_TILE0_BYTES || m_axi_awid != 0)
          $fatal(1, "invalid pooled-relay write addr=%08x len=%0d", m_axi_awaddr, m_axi_awlen);
        write_active <= 1'b1;
        write_index <= 16'(m_axi_awaddr >> 3);
        write_beats_left <= m_axi_awlen[4:0] + 1'b1;
      end
      if (write_active && m_axi_wvalid && m_axi_wready) begin
        if (m_axi_wstrb != 8'hff) $fatal(1, "unexpected pooled-relay partial strobe");
        ddr[write_index] <= m_axi_wdata;
        if (write_beats_left == 1) begin
          if (!m_axi_wlast) $fatal(1, "missing pooled-relay WLAST");
          write_active <= 1'b0;
          m_axi_bvalid <= 1'b1;
        end else begin
          if (m_axi_wlast) $fatal(1, "early pooled-relay WLAST");
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

  task automatic load_rgb_weights;
    logic [31:0] packed_weight;
    begin
      write32(OUTPUT_LANE_MASK, 32'h0000ffff);
      for (int oc = 0; oc < 16; oc++) begin
        write32(BIDX, oc);
        write32(BDATA, gf_full_folded_bias[oc]);
        write32(RQIDX, oc);
        write32(RQMULT, gf_full_multiplier[oc]);
        write32(RQSHIFT, {26'd0, gf_full_right_shift[oc]});
        for (int tap = 0; tap < 16; tap++) begin
          packed_weight = {8'd0,
            gf_full_weights[oc*48 + tap*3 + 2],
            gf_full_weights[oc*48 + tap*3 + 1],
            gf_full_weights[oc*48 + tap*3 + 0]};
          write32(WCTRL, oc | (tap << 4));
          write32(WDATA, packed_weight);
        end
      end
    end
  endtask

  task automatic load_body_weights;
    logic [31:0] packed_weight;
    begin
      write32(OUTPUT_LANE_MASK, 32'h0000ffff);
      for (int oc = 0; oc < 16; oc++) begin
        write32(BIDX, oc);
        write32(BDATA, body_golden.gf_full_folded_bias[oc]);
        write32(RQIDX, oc);
        write32(RQMULT, body_golden.gf_full_multiplier[oc]);
        write32(RQSHIFT, {26'd0, body_golden.gf_full_right_shift[oc]});
        for (int tap = 0; tap < 16; tap++) begin
          for (int group = 0; group < 4; group++) begin
            packed_weight = '0;
            for (int lane = 0; lane < 4; lane++) begin
              packed_weight[lane*8 +: 8] =
                body_golden.gf_full_weights[oc*256 + tap*16 + group*4 + lane];
            end
            write32(WCTRL, oc | (tap << 4) | (group << 8));
            write32(WDATA, packed_weight);
          end
        end
      end
    end
  endtask

  task automatic load_conv2a_tile0_weights;
    logic [31:0] packed_weight;
    begin
      write32(OUTPUT_LANE_MASK, 32'h0000ffff);
      for (int oc = 0; oc < 16; oc++) begin
        write32(BIDX, oc);
        write32(BDATA, conv2a_golden.gf_conv2a_folded_bias[oc]);
        write32(RQIDX, oc);
        write32(RQMULT, conv2a_golden.gf_conv2a_multiplier[oc]);
        write32(RQSHIFT, {26'd0, conv2a_golden.gf_conv2a_right_shift[oc]});
        for (int tap = 0; tap < 16; tap++) begin
          for (int group = 0; group < 4; group++) begin
            packed_weight = {
              conv2a_golden.gf_conv2a_weights[oc*256 + tap*16 + group*4 + 3],
              conv2a_golden.gf_conv2a_weights[oc*256 + tap*16 + group*4 + 2],
              conv2a_golden.gf_conv2a_weights[oc*256 + tap*16 + group*4 + 1],
              conv2a_golden.gf_conv2a_weights[oc*256 + tap*16 + group*4 + 0]
            };
            write32(WCTRL, oc | (tap << 4) | (group << 8));
            write32(WDATA, packed_weight);
          end
        end
      end
    end
  endtask

  initial begin
    logic [31:0] value;
    logic [31:0] expected_tile_hash;
    expected_tile_hash = 32'h811c9dc5;

    for (int beat = 0; beat < DDR_BEATS; beat++) ddr[beat] = '0;
    for (int byte_index = 0; byte_index < RGB_BYTES; byte_index++) begin
      ddr[(RGB_BASE >> 3) + (byte_index >> 3)][(byte_index & 7) * 8 +: 8] = gf_full_input_q[byte_index] ^ 8'h80;
    end
    for (int pixel = 0; pixel < 48*48; pixel++) begin
      for (int lane = 0; lane < 16; lane++) begin
        expected_tile_hash = fnv_step(expected_tile_hash, conv2a_golden.gf_conv2a_output_q[pixel * 40 + lane]);
      end
    end

    repeat (3) @(negedge clk);
    aresetn = 1'b1;

    read32(MAGIC, value); if (value != 32'h47464e50) $fatal(1, "bad pooled-relay magic %08x", value);
    read32(VERSION, value); if (value != 32'h00040004) $fatal(1, "bad pooled-relay version %08x", value);

    write32(CONTROL, 32'd1);
    write32(RELAY_CONTROL, 32'd0);
    write32(LAYER_MODE, 32'd0);
    write32(JOB_WIDTH, 32'd96);
    write32(JOB_HEIGHT, 32'd96);
    write32(QCFG, 32'h0003_8080);
    load_rgb_weights();
    write32(DMA_SOURCE, RGB_BASE);
    write32(DMA_BYTES, RGB_BYTES);
    write32(DMA_PIXELS, 32'd9216);
    write32(STORE_CONTROL, 32'd0);
    write32(CONTROL, 32'd2);
    for (int wait_cycle = 0; wait_cycle < 2_500_000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "pooled-relay layer0 fault");
      if (dut.done) break;
      if (wait_cycle == 2_499_999) $fatal(1, "pooled-relay layer0 timeout");
    end
    read32(OUTPUT_FNV1A, value); if (value != GF_FULL_QUANT_FNV1A) $fatal(1, "pooled-relay layer0 hash %08x", value);

    write32(CONTROL, 32'd1);
    write32(RELAY_CONTROL, 32'd5);
    write32(LAYER_MODE, 32'd1);
    write32(JOB_WIDTH, 32'd96);
    write32(JOB_HEIGHT, 32'd96);
    write32(QCFG, 32'h0003_8080);
    load_body_weights();
    write32(DMA_PIXELS, 32'd9216);
    write32(STORE_CONTROL, 32'd0);
    write32(CONTROL, 32'd2);
    for (int wait_cycle = 0; wait_cycle < 4_000_000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "pooled-relay body fault");
      if (dut.done) break;
      if (wait_cycle == 3_999_999) $fatal(1, "pooled-relay body timeout");
    end
    read32(OUTPUT_FNV1A, value); if (value != body_golden.GF_FULL_QUANT_FNV1A) $fatal(1, "pooled-relay body hash %08x", value);

    write32(CONTROL, 32'd1);
    write32(RELAY_CONTROL, 32'd11);
    write32(LAYER_MODE, 32'd1);
    write32(JOB_WIDTH, 32'd48);
    write32(JOB_HEIGHT, 32'd48);
    write32(QCFG, 32'h0003_8080);
    load_conv2a_tile0_weights();
    write32(DMA_PIXELS, 32'd2304);
    write32(STORE_DESTINATION, CONV2A_TILE0_BASE);
    write32(STORE_BYTES, CONV2A_TILE0_BYTES);
    write32(STORE_CONTROL, 32'd1);
    write32(STORE_STRIDE, 32'd16);
    write32(STORE_VALID_BYTES, 32'd16);
    conv2a_read_seen = 1'b0;
    write32(CONTROL, 32'd2);
    for (int wait_cycle = 0; wait_cycle < 3_500_000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "pooled-relay conv2a fault");
      if (conv2a_read_seen) $fatal(1, "pooled-relay conv2a leaked HP0 read traffic");
      if (dut.done) break;
      if (wait_cycle == 3_499_999) $fatal(1, "pooled-relay conv2a timeout");
    end

    read32(OUTPUT_FNV1A, value);
    if (value != expected_tile_hash) $fatal(1, "pooled-relay conv2a hash %08x expected %08x", value, expected_tile_hash);
    read32(STORE_STATUS, value);
    if (value[2:0] != 3'b010 || value[31:3] != 29'(CONV2A_TILE0_BYTES))
      $fatal(1, "pooled-relay conv2a store status %08x", value);
    for (int pixel = 0; pixel < 48*48; pixel++) begin
      int base_byte;
      base_byte = int'(CONV2A_TILE0_BASE) + pixel * 16;
      for (int lane = 0; lane < 16; lane++) begin
        logic signed [7:0] got;
        got = ddr[(base_byte >> 3) + (lane >> 3)][((lane & 7) * 8) +: 8];
        if (got !== conv2a_golden.gf_conv2a_output_q[pixel * 40 + lane]) begin
          $fatal(1, "pooled-relay conv2a mismatch pixel=%0d lane=%0d got=%0d expected=%0d",
            pixel, lane, got, conv2a_golden.gf_conv2a_output_q[pixel * 40 + lane]);
        end
      end
    end

    $display("GESTUREFLOW_LAYER_CHAIN_POOL_RELAY_CONV2A_AXIL_PASS body=%08x conv2a_tile0=%08x pixels=%0d",
      body_golden.GF_FULL_QUANT_FNV1A, expected_tile_hash, 48*48);
    $finish;
  end
endmodule
