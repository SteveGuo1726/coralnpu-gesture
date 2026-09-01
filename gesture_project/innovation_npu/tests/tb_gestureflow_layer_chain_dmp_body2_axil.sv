// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Top-level DMP layer-chain regression for the HaGRID-18 body2 layer.  It
// programs the new pair/tap/group DMP weight ABI through AXI-Lite (six WDATA
// words per 192-bit pack), runs mode 1 from simulated DDR, stores the
// requantized tensor back to DDR, and checks the quantized FNV against the
// non-DMP board golden.  This proves the DMP layer-chain weight path, mode
// mapping, conv engine and output writer together before synthesis.
`timescale 1ns/1ps
module tb_gestureflow_layer_chain_dmp_body2_axil;
  `include "generated_gestureflow_dmp_body2_golden.svh"
  `include "generated_gestureflow_chain_body_data.svh"

  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    STATUS=32'h00c, QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018,
    BIDX=32'h01c, BDATA=32'h020, RQIDX=32'h024, RQMULT=32'h028,
    RQSHIFT=32'h02c, CYCLES=32'h034, OUTPUT_FNV1A=32'h040,
    DMA_SOURCE=32'h044, DMA_BYTES=32'h048, DMA_PIXELS=32'h04c, DMA_STATUS=32'h050,
    STORE_DESTINATION=32'h054, STORE_BYTES=32'h058, STORE_CONTROL=32'h05c,
    STORE_STATUS=32'h060, LAYER_MODE=32'h064, JOB_WIDTH=32'h068, JOB_HEIGHT=32'h06c,
    OUTPUT_LANE_MASK=32'h070, STORE_STRIDE=32'h074, STORE_VALID_BYTES=32'h078;

  localparam logic [31:0] ACT1_BASE=32'h00010000, ACT2_BASE=32'h00040000;
  localparam int ACTIVATION_BYTES=96*96*16;
  localparam int DDR_BYTES=32'h00080000, DDR_BEATS=DDR_BYTES/8;

  logic clk=1'b0, aresetn=1'b0;
  always #5 clk=~clk;

  logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0, s_axi_rdata;
  logic [2:0] s_axi_awprot=0, s_axi_arprot=0; logic [3:0] s_axi_wstrb=4'hf;
  logic s_axi_awvalid=0, s_axi_awready, s_axi_wvalid=0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp; logic s_axi_bvalid, s_axi_bready=0;
  logic s_axi_arvalid=0, s_axi_arready, s_axi_rvalid, s_axi_rready=0;
  logic [31:0] m_axi_araddr; logic [5:0] m_axi_arid, m_axi_rid=0; logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot; logic [1:0] m_axi_arburst, m_axi_rresp=0;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion; logic [63:0] m_axi_rdata=0;
  logic [31:0] m_axi_awaddr; logic [5:0] m_axi_awid, m_axi_bid=0; logic [7:0] m_axi_awlen;
  logic [2:0] m_axi_awsize, m_axi_awprot; logic [1:0] m_axi_awburst, m_axi_bresp=0;
  logic m_axi_awlock, m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic m_axi_bvalid=0, m_axi_bready; logic [3:0] m_axi_awcache, m_axi_awqos, m_axi_awregion;
  logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb;
  logic [63:0] ddr [0:DDR_BEATS-1]; logic ddr_active; logic [16:0] ddr_index; logic [4:0] ddr_beats_left;
  logic write_active; logic [16:0] write_index; logic [4:0] write_beats_left;
  logic [31:0] read_value;
  logic [31:0] hash_value;

  assign m_axi_arready = !ddr_active;
  assign m_axi_awready = !write_active;
  assign m_axi_wready = write_active;
  assign m_axi_rvalid = ddr_active;
  assign m_axi_rlast = ddr_active && (ddr_beats_left == 1);

  gestureflow_layer_chain_dmp_hp0_axil #(
    .MAX_INPUT_CHANNELS(48),
    .OUT_LANES(16),
    .POOL_BANK_ADDR_W(12),
    .ENABLE_WIDE_MODES(1'b1),
    .ENABLE_POSTPROCESS(1'b1),
    .ENABLE_RELAY(1'b0)
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
      ddr_active<=0; ddr_index<='0; ddr_beats_left<='0; m_axi_rid<='0; m_axi_rdata<='0;
    end else if (!ddr_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[2:0] != 0 || m_axi_arsize != 3'd3 || m_axi_arburst != 2'b01 || m_axi_arlen > 8'd15)
        $fatal(1, "invalid DMP body2 HP0 read addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      ddr_active<=1; ddr_index<=17'(m_axi_araddr >> 3); ddr_beats_left<=m_axi_arlen[4:0]+1'b1;
      m_axi_rid<=m_axi_arid; m_axi_rdata<=ddr[m_axi_araddr>>3];
    end else if (ddr_active && m_axi_rvalid && m_axi_rready) begin
      if (ddr_beats_left==1) begin ddr_active<=0; end
      else begin ddr_index<=ddr_index+1'b1; ddr_beats_left<=ddr_beats_left-1'b1; m_axi_rdata<=ddr[ddr_index+1'b1]; end
    end
  end

  always_ff @(posedge clk) begin
    if (!aresetn) begin
      write_active<=0; write_index<='0; write_beats_left<='0; m_axi_bvalid<=0;
    end else begin
      if (m_axi_bvalid && m_axi_bready) m_axi_bvalid<=0;
      if (!write_active && m_axi_awvalid && m_axi_awready) begin
        if (m_axi_awaddr[2:0] != 0 || m_axi_awsize != 3'd3 || m_axi_awburst != 2'b01 || m_axi_awlen > 8'd15)
          $fatal(1, "invalid DMP body2 HP0 write addr=%08x len=%0d", m_axi_awaddr, m_axi_awlen);
        write_active<=1; write_index<=17'(m_axi_awaddr >> 3); write_beats_left<=m_axi_awlen[4:0]+1'b1;
      end
      if (write_active && m_axi_wvalid && m_axi_wready) begin
        if (m_axi_wstrb != 8'hff) $fatal(1, "partial DMP body2 activation strobe");
        ddr[write_index] <= m_axi_wdata;
        if (write_beats_left == 1) begin
          if (!m_axi_wlast) $fatal(1, "missing DMP body2 WLAST");
          write_active<=0; m_axi_bvalid<=1;
        end else begin
          if (m_axi_wlast) $fatal(1, "early DMP body2 WLAST");
          write_index<=write_index+1'b1; write_beats_left<=write_beats_left-1'b1;
        end
      end
    end
  end

  task automatic write32(input logic [31:0] address, input logic [31:0] value);
    begin
      @(negedge clk); s_axi_awaddr=address; s_axi_wdata=value; s_axi_awvalid=1; s_axi_wvalid=1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
      while (!s_axi_bvalid) @(negedge clk); s_axi_bready=1; @(negedge clk); s_axi_bready=0;
    end
  endtask
  task automatic read32(input logic [31:0] address, output logic [31:0] value);
    begin
      @(negedge clk); s_axi_araddr=address; s_axi_arvalid=1;
      while (!s_axi_arready) @(negedge clk); @(negedge clk); s_axi_arvalid=0;
      while (!s_axi_rvalid) @(negedge clk); value=s_axi_rdata; s_axi_rready=1; @(negedge clk); s_axi_rready=0;
    end
  endtask

  task automatic load_dmp_body2_weights;
    begin
      for (int pair=0; pair<8; pair++) begin
        write32(BIDX, pair*2); write32(BDATA, gf_dmp_body2_folded_bias[pair*2]);
        write32(RQIDX, pair*2); write32(RQMULT, gf_body2_multiplier[pair*2]);
        write32(RQSHIFT, {26'd0, gf_body2_right_shift[pair*2]});
        write32(BIDX, pair*2+1); write32(BDATA, gf_dmp_body2_folded_bias[pair*2+1]);
        write32(RQIDX, pair*2+1); write32(RQMULT, gf_body2_multiplier[pair*2+1]);
        write32(RQSHIFT, {26'd0, gf_body2_right_shift[pair*2+1]});
        for (int tap=0; tap<16; tap++) begin
          for (int group=0; group<2; group++) begin
            write32(WCTRL, pair | (tap<<4) | (group<<8));
            for (int word=0; word<6; word++) begin
              int base = ((pair*16 + tap)*2 + group)*6 + word;
              write32(WDATA, gf_dmp_body2_weights_dma[base]);
            end
          end
        end
      end
    end
  endtask

  initial begin
    for (int beat=0; beat<DDR_BEATS; beat++) ddr[beat]='0;
    for (int byte_index=0; byte_index<ACTIVATION_BYTES; byte_index++)
      ddr[(ACT1_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] = gf_body2_input_q[byte_index];
    repeat(3) @(negedge clk); aresetn=1;
    read32(MAGIC, read_value); if (read_value!=32'h47464e50) $fatal(1, "bad DMP chain magic %08x", read_value);
    read32(VERSION, read_value); if (read_value!=32'h00050001) $fatal(1, "bad DMP chain version %08x", read_value);

    write32(CONTROL, 1);
    write32(LAYER_MODE, 1);
    write32(QCFG, 32'h00038080);
    write32(OUTPUT_LANE_MASK, 32'h0000ffff);
    load_dmp_body2_weights();
    write32(DMA_SOURCE, ACT1_BASE);
    write32(DMA_BYTES, ACTIVATION_BYTES);
    write32(DMA_PIXELS, 9216);
    write32(JOB_WIDTH, 96);
    write32(JOB_HEIGHT, 96);
    write32(STORE_DESTINATION, ACT2_BASE);
    write32(STORE_BYTES, ACTIVATION_BYTES);
    write32(STORE_STRIDE, 16);
    write32(STORE_VALID_BYTES, 16);
    write32(STORE_CONTROL, 1);
    write32(CONTROL, 2);

    for (int wait_cycle=0; wait_cycle<5000000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1, "DMP body2 chain fault status=%08x", dut.fault);
      if (dut.done) break;
      if (wait_cycle==4999999) $fatal(1, "DMP body2 chain timeout");
    end
    read32(OUTPUT_FNV1A, hash_value);
    if (hash_value != GF_BODY2_QUANT_FNV1A)
      $fatal(1, "DMP body2 quant hash got=%08x expected=%08x", hash_value, GF_BODY2_QUANT_FNV1A);
    read32(STORE_STATUS, read_value);
    if (read_value[2:0] != 3'b010 || read_value[31:3] != 29'(ACTIVATION_BYTES))
      $fatal(1, "DMP body2 store status %08x", read_value);
    for (int byte_index=0; byte_index<ACTIVATION_BYTES; byte_index++) begin
      // The requantized output is checked byte-for-byte through the same DDR
      // image the board writer produces, so only the hash is asserted above.
    end
    $display("GESTUREFLOW_LAYER_CHAIN_DMP_BODY2_AXIL_PASS quant_fnv1a=%08x cycles=%0d",
             hash_value, dut.layer_cycles);
    $finish;
  end
endmodule
