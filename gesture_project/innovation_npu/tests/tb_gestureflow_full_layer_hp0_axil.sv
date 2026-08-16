// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Real exported 96x96 RGB layer through AXI-Lite configuration and a bounded
// 64-bit AXI4 HP0 memory model. This is the numerical gate before board use.
`timescale 1ns/1ps
module tb_gestureflow_full_layer_hp0_axil;
  `include "generated_gestureflow_real_conv4x4_full_layer.svh"
  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    STATUS=32'h00c, QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018,
    BIDX=32'h01c, BDATA=32'h020, RQIDX=32'h024, RQMULT=32'h028,
    RQSHIFT=32'h02c, CYCLES=32'h034, INPUT_PIXELS=32'h038,
    OUTPUT_VECTORS=32'h03c, OUTPUT_FNV1A=32'h040, DMA_SOURCE=32'h044,
    DMA_BYTES=32'h048, DMA_PIXELS=32'h04c, DMA_STATUS=32'h050;
  localparam logic [31:0] INPUT_BASE=32'h00001000;
  localparam int INPUT_BYTES=96*96*3, INPUT_BEATS=INPUT_BYTES/8;

  logic clk=0, aresetn=0;
  logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0, s_axi_rdata;
  logic [2:0] s_axi_awprot=0, s_axi_arprot=0;
  logic [3:0] s_axi_wstrb=4'hf;
  logic s_axi_awvalid=0, s_axi_awready, s_axi_wvalid=0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic s_axi_bvalid, s_axi_bready=0, s_axi_arvalid=0, s_axi_arready;
  logic s_axi_rvalid, s_axi_rready=0;
  logic [31:0] m_axi_araddr;
  logic [5:0] m_axi_arid, m_axi_rid;
  logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize, m_axi_arprot;
  logic [1:0] m_axi_arburst, m_axi_rresp;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion;
  logic [63:0] m_axi_rdata;
  logic [63:0] ddr [0:INPUT_BEATS-1];
  logic ddr_active;
  logic [11:0] ddr_index;
  logic [4:0] ddr_beats_left;

  always #5 clk=~clk;

  gestureflow_full_layer_hp0_axil dut (
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
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  // One outstanding burst is exactly the loader's HP0 contract. Addresses
  // are byte addresses and each word is little-endian camera RGB bytes.
  assign m_axi_arready = !ddr_active;
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      ddr_active<=0; ddr_index<='0; ddr_beats_left<='0; m_axi_rid<='0;
      m_axi_rdata<='0; m_axi_rresp<=0; m_axi_rlast<=0; m_axi_rvalid<=0;
    end else if (!ddr_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr < INPUT_BASE || m_axi_araddr[2:0] != 0 ||
          m_axi_arsize != 3 || m_axi_arburst != 2'b01 || m_axi_arlen > 15)
        $fatal(1, "invalid HP0 request addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      ddr_active<=1; ddr_index<=m_axi_araddr[14:3]-INPUT_BASE[14:3];
      ddr_beats_left<=m_axi_arlen[4:0]+1'b1; m_axi_rid<=m_axi_arid;
      m_axi_rdata<=ddr[(m_axi_araddr-INPUT_BASE)>>3]; m_axi_rresp<=0;
      m_axi_rlast<=(m_axi_arlen==0); m_axi_rvalid<=1;
    end else if (ddr_active && m_axi_rvalid && m_axi_rready) begin
      if (ddr_beats_left==1) begin
        ddr_active<=0; m_axi_rvalid<=0; m_axi_rlast<=0;
      end else begin
        ddr_index<=ddr_index+1'b1; ddr_beats_left<=ddr_beats_left-1'b1;
        m_axi_rdata<=ddr[ddr_index+1'b1]; m_axi_rlast<=(ddr_beats_left==2);
      end
    end
  end

  task automatic write32(input logic [31:0] address, input logic [31:0] value);
    begin
      @(negedge clk); s_axi_awaddr=address; s_axi_wdata=value; s_axi_awvalid=1; s_axi_wvalid=1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
      while (!s_axi_bvalid) @(negedge clk);
      s_axi_bready=1; @(negedge clk); s_axi_bready=0;
    end
  endtask

  task automatic read32(input logic [31:0] address, output logic [31:0] value);
    begin
      @(negedge clk); s_axi_araddr=address; s_axi_arvalid=1;
      while (!s_axi_arready) @(negedge clk);
      @(negedge clk); s_axi_arvalid=0;
      while (!s_axi_rvalid) @(negedge clk);
      value=s_axi_rdata; s_axi_rready=1; @(negedge clk); s_axi_rready=0;
    end
  endtask

  initial begin
    logic [31:0] value, packed_weight;
    for (int beat=0; beat<INPUT_BEATS; beat++) ddr[beat]='0;
    for (int byte_index=0; byte_index<INPUT_BYTES; byte_index++)
      ddr[byte_index>>3][(byte_index&7)*8 +: 8] = gf_full_input_q[byte_index] ^ 8'h80;
    repeat(3) @(negedge clk); aresetn=1;
    read32(MAGIC,value); if (value!=32'h47464e50) $fatal(1,"bad magic %08x",value);
    read32(VERSION,value); if (value!=32'h00030000) $fatal(1,"bad version %08x",value);
    write32(CONTROL,1); write32(QCFG,32'h0003_8080);
    for (int lane=0; lane<16; lane++) begin
      write32(BIDX,lane); write32(BDATA,gf_full_folded_bias[lane]);
      write32(RQIDX,lane); write32(RQMULT,gf_full_multiplier[lane]);
      write32(RQSHIFT,{26'd0,gf_full_right_shift[lane]});
      for (int tap=0; tap<16; tap++) begin
        packed_weight={8'd0,gf_full_weights[lane*48+tap*3+2],gf_full_weights[lane*48+tap*3+1],gf_full_weights[lane*48+tap*3]};
        write32(WCTRL,lane|(tap<<4)); write32(WDATA,packed_weight);
      end
    end
    write32(DMA_SOURCE,INPUT_BASE); write32(DMA_BYTES,INPUT_BYTES); write32(DMA_PIXELS,96*96);
    write32(CONTROL,2);
    for (int wait_cycle=0; wait_cycle<3_500_000; wait_cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1,"HP0 layer fault status=%08x dma=%08x", dut.fault, dut.dma_fault);
      if (dut.done) break;
      if (wait_cycle==3_499_999) $fatal(1,"HP0 full-layer timed out input=%0d output=%0d",dut.input_pixels,dut.output_vectors);
    end
    read32(STATUS,value); if ((value&32'h6)!=32'h2) $fatal(1,"bad status %08x",value);
    read32(INPUT_PIXELS,value); if (value!=9216) $fatal(1,"input pixels %0d",value);
    read32(OUTPUT_VECTORS,value); if (value!=9216) $fatal(1,"output vectors %0d",value);
    read32(OUTPUT_FNV1A,value); if (value!=GF_FULL_QUANT_FNV1A) $fatal(1,"hash %08x expected %08x",value,GF_FULL_QUANT_FNV1A);
    read32(DMA_STATUS,value); if (value[2:0]!=3'b010 || value[18:3]!=16'(INPUT_BYTES)) $fatal(1,"DMA status %08x",value);
    read32(CYCLES,value); if (value==0) $fatal(1,"zero cycle count");
    $display("GESTUREFLOW_FULL_LAYER_HP0_AXIL_PASS cycles=%0d hash=%08x bytes=%0d",value,GF_FULL_QUANT_FNV1A,INPUT_BYTES);
    $finish;
  end
endmodule
