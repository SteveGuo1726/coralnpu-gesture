// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Full real-layer test through the PS-facing AXI-Lite PIO contract.
`timescale 1ns/1ps
module tb_gestureflow_full_layer_pio_axil;
  `include "generated_gestureflow_real_conv4x4_full_layer.svh"
  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    STATUS=32'h00c, QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018,
    BIDX=32'h01c, BDATA=32'h020, RQIDX=32'h024, RQMULT=32'h028,
    RQSHIFT=32'h02c, PIXEL_DATA=32'h030, CYCLES=32'h034,
    INPUT_PIXELS=32'h038, OUTPUT_VECTORS=32'h03c, OUTPUT_FNV1A=32'h040;
  logic clk=0, aresetn=0;
  logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0, s_axi_rdata;
  logic [2:0] s_axi_awprot=0, s_axi_arprot=0;
  logic [3:0] s_axi_wstrb=4'hf;
  logic s_axi_awvalid=0, s_axi_awready, s_axi_wvalid=0, s_axi_wready;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic s_axi_bvalid, s_axi_bready=0, s_axi_arvalid=0, s_axi_arready, s_axi_rvalid, s_axi_rready=0;

  gestureflow_full_layer_pio_axil dut (.aclk(clk), .*);
  always #5 clk=~clk;

  task automatic write32(input logic [31:0] address, input logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_awaddr = address; s_axi_wdata = value; s_axi_awvalid = 1; s_axi_wvalid = 1;
      while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
      @(negedge clk);
      s_axi_awvalid = 0; s_axi_wvalid = 0;
      while (!s_axi_bvalid) @(negedge clk);
      s_axi_bready = 1;
      @(negedge clk);
      s_axi_bready = 0;
    end
  endtask

  task automatic read32(input logic [31:0] address, output logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_araddr = address; s_axi_arvalid = 1;
      while (!s_axi_arready) @(negedge clk);
      @(negedge clk);
      s_axi_arvalid = 0;
      while (!s_axi_rvalid) @(negedge clk);
      value = s_axi_rdata;
      s_axi_rready = 1;
      @(negedge clk);
      s_axi_rready = 0;
    end
  endtask

  initial begin
    logic [31:0] value, packed_word;
    repeat(3) @(negedge clk);
    aresetn = 1;
    read32(MAGIC, value);
    if (value != 32'h47464e50) $fatal(1,"bad magic %08x",value);
    read32(VERSION, value);
    if (value != 32'h00020000) $fatal(1,"bad version %08x",value);
    write32(CONTROL, 1);
    write32(QCFG, 32'h0003_8080);
    for (int lane=0; lane<16; lane++) begin
      write32(BIDX, lane); write32(BDATA, gf_full_folded_bias[lane]);
      write32(RQIDX, lane); write32(RQMULT, gf_full_multiplier[lane]);
      write32(RQSHIFT, {26'd0, gf_full_right_shift[lane]});
      for (int tap=0; tap<16; tap++) begin
        packed_word = {8'd0, gf_full_weights[lane*48+tap*3+2], gf_full_weights[lane*48+tap*3+1], gf_full_weights[lane*48+tap*3]};
        write32(WCTRL, (lane << 0) | (tap << 4)); write32(WDATA, packed_word);
      end
    end
    write32(CONTROL, 2);
    for (int row=0; row<GF_FULL_HEIGHT; row++) begin
      for (int column=0; column<GF_FULL_WIDTH; column++) begin
        do read32(STATUS,value); while ((value & 32'h8)==0);
        packed_word = {8'd0,
          (gf_full_input_q[(row*GF_FULL_WIDTH+column)*3+2] ^ 8'h80),
          (gf_full_input_q[(row*GF_FULL_WIDTH+column)*3+1] ^ 8'h80),
          (gf_full_input_q[(row*GF_FULL_WIDTH+column)*3] ^ 8'h80)};
        write32(PIXEL_DATA, packed_word);
      end
    end
    for (int poll=0; poll<100000; poll++) begin
      read32(STATUS,value);
      if ((value & 32'h2) != 0) break;
      if ((value & 32'h4) != 0) $fatal(1,"controller fault status=%08x",value);
    end
    read32(STATUS,value); if ((value & 32'h2)==0 || (value & 32'h4)!=0) $fatal(1,"not done status=%08x",value);
    read32(INPUT_PIXELS,value); if (value != 9216) $fatal(1,"RGB pixel count %0d",value);
    read32(OUTPUT_VECTORS,value); if (value != 9216) $fatal(1,"output count %0d",value);
    read32(OUTPUT_FNV1A,value); if (value != GF_FULL_QUANT_FNV1A) $fatal(1,"hash %08x expected %08x",value,GF_FULL_QUANT_FNV1A);
    read32(CYCLES,value); if (value == 0) $fatal(1,"zero cycle count");
    $display("GESTUREFLOW_FULL_LAYER_PIO_AXIL_PASS cycles=%0d hash=%08x",value,GF_FULL_QUANT_FNV1A);
    $finish;
  end
endmodule
