// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Bounded single-bitstream regression: real first layer writes tensor 18 to
// simulated DDR, then the same reusable IP reads that DDR buffer and runs the
// real second layer. The body golden is isolated in a child module so the two
// generated data headers keep their original names without being conflated.
`timescale 1ns/1ps
module gestureflow_layer_chain_body_golden;
  `include "generated_gestureflow_real_conv4x4_body2_layer.svh"
endmodule
module gestureflow_layer_chain_pool_golden;
  `include "generated_gestureflow_real_maxpool2d.svh"
endmodule
module gestureflow_layer_chain_conv2a_golden;
  `include "generated_gestureflow_real_conv4x4_conv2a_layer.svh"
endmodule

module tb_gestureflow_layer_chain_hp0_axil;
  `include "generated_gestureflow_real_conv4x4_full_layer.svh"
  gestureflow_layer_chain_body_golden body_golden();
  gestureflow_layer_chain_pool_golden pool_golden();
  gestureflow_layer_chain_conv2a_golden conv2a_golden();
  localparam logic [31:0] MAGIC=32'h000, VERSION=32'h004, CONTROL=32'h008,
    STATUS=32'h00c, QCFG=32'h010, WCTRL=32'h014, WDATA=32'h018,
    BIDX=32'h01c, BDATA=32'h020, RQIDX=32'h024, RQMULT=32'h028,
    RQSHIFT=32'h02c, CYCLES=32'h034, INPUT_PIXELS=32'h038,
    OUTPUT_VECTORS=32'h03c, OUTPUT_FNV1A=32'h040, DMA_SOURCE=32'h044,
    DMA_BYTES=32'h048, DMA_PIXELS=32'h04c, DMA_STATUS=32'h050,
    STORE_DESTINATION=32'h054, STORE_BYTES=32'h058, STORE_CONTROL=32'h05c,
    STORE_STATUS=32'h060, LAYER_MODE=32'h064, JOB_WIDTH=32'h068, JOB_HEIGHT=32'h06c,
    OUTPUT_LANE_MASK=32'h070, STORE_STRIDE=32'h074, STORE_VALID_BYTES=32'h078;
  localparam logic [31:0] RGB_BASE=32'h00001000, ACT1_BASE=32'h00010000, ACT2_BASE=32'h00040000, ACT3_BASE=32'h00070000, CONV2A_BASE=32'h00090000;
  localparam int RGB_BYTES=96*96*3, ACTIVATION_BYTES=96*96*16, POOL_BYTES=48*48*16, CONV2A_BYTES=48*48*40;
  localparam int DDR_BYTES=32'h000b0000, DDR_BEATS=DDR_BYTES/8;

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
  logic [63:0] ddr [0:DDR_BEATS-1]; logic ddr_active; logic [16:0] ddr_index; logic [4:0] ddr_beats_left;
  logic write_active; logic [16:0] write_index; logic [4:0] write_beats_left;
  logic [31:0] layer0_cycles, layer1_cycles, pool_cycles;

  always #5 clk=~clk;
  assign m_axi_arready = !ddr_active;
  assign m_axi_awready = !write_active;
  assign m_axi_wready = write_active;

  gestureflow_layer_chain_hp0_axil dut (
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
      m_axi_rresp<=0; m_axi_rlast<=0; m_axi_rvalid<=0;
    end else if (!ddr_active && m_axi_arvalid && m_axi_arready) begin
      if (m_axi_araddr[2:0] != 0 || m_axi_arsize != 3 || m_axi_arburst != 2'b01 || m_axi_arlen > 15 ||
          m_axi_araddr < RGB_BASE ||
          !((m_axi_araddr < ACT2_BASE + ACTIVATION_BYTES) ||
            (m_axi_araddr >= ACT3_BASE && m_axi_araddr < ACT3_BASE + POOL_BYTES)))
        $fatal(1, "invalid chain HP0 read addr=%08x len=%0d", m_axi_araddr, m_axi_arlen);
      ddr_active<=1; ddr_index<=17'(m_axi_araddr >> 3); ddr_beats_left<=m_axi_arlen[4:0]+1'b1; m_axi_rid<=m_axi_arid;
      m_axi_rdata<=ddr[m_axi_araddr>>3]; m_axi_rresp<=0; m_axi_rlast<=(m_axi_arlen==0); m_axi_rvalid<=1;
    end else if (ddr_active && m_axi_rvalid && m_axi_rready) begin
      if (ddr_beats_left==1) begin ddr_active<=0; m_axi_rvalid<=0; m_axi_rlast<=0; end
      else begin ddr_index<=ddr_index+1'b1; ddr_beats_left<=ddr_beats_left-1'b1; m_axi_rdata<=ddr[ddr_index+1'b1]; m_axi_rlast<=(ddr_beats_left==2); end
    end
  end

  always_ff @(posedge clk) begin
    if (!aresetn) begin write_active<=0; write_index<='0; write_beats_left<='0; m_axi_bvalid<=0; end
    else begin
      if (m_axi_bvalid && m_axi_bready) m_axi_bvalid<=0;
      if (!write_active && m_axi_awvalid && m_axi_awready) begin
        if (m_axi_awaddr[2:0] != 0 ||
            !((m_axi_awaddr >= ACT1_BASE && m_axi_awaddr < ACT1_BASE + ACTIVATION_BYTES) ||
              (m_axi_awaddr >= ACT2_BASE && m_axi_awaddr < ACT2_BASE + ACTIVATION_BYTES) ||
              (m_axi_awaddr >= ACT3_BASE && m_axi_awaddr < ACT3_BASE + POOL_BYTES) ||
              (m_axi_awaddr >= CONV2A_BASE && m_axi_awaddr < CONV2A_BASE + CONV2A_BYTES)) ||
            m_axi_awlen > 1 || m_axi_awsize != 3 || m_axi_awburst != 2'b01 || m_axi_awid != 0)
          $fatal(1,"invalid chain HP0 write addr=%08x len=%0d",m_axi_awaddr,m_axi_awlen);
        write_active<=1; write_index<=17'(m_axi_awaddr >> 3); write_beats_left<=m_axi_awlen[4:0]+1'b1;
      end
      if (write_active && m_axi_wvalid && m_axi_wready) begin
        if (m_axi_wstrb != 8'hff) $fatal(1,"partial chain activation strobe");
        ddr[write_index] <= m_axi_wdata;
        if (write_beats_left == 1) begin
          if (!m_axi_wlast) $fatal(1,"missing chain WLAST");
          write_active<=0; m_axi_bvalid<=1;
        end else begin
          if (m_axi_wlast) $fatal(1,"early chain WLAST");
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
  task automatic load_rgb_weights;
    logic [31:0] packed_weight;
    begin
      for (int oc=0; oc<16; oc++) begin
        write32(BIDX,oc); write32(BDATA,gf_full_folded_bias[oc]); write32(RQIDX,oc);
        write32(RQMULT,gf_full_multiplier[oc]); write32(RQSHIFT,{26'd0,gf_full_right_shift[oc]});
        for (int tap=0; tap<16; tap++) begin
          packed_weight={8'd0,gf_full_weights[oc*48+tap*3+2],gf_full_weights[oc*48+tap*3+1],gf_full_weights[oc*48+tap*3]};
          write32(WCTRL,oc|(tap<<4)); write32(WDATA,packed_weight);
        end
      end
    end
  endtask
  task automatic load_body_weights;
    logic [31:0] packed_weight;
    begin
      for (int oc=0; oc<16; oc++) begin
        write32(BIDX,oc); write32(BDATA,body_golden.gf_full_folded_bias[oc]); write32(RQIDX,oc);
        write32(RQMULT,body_golden.gf_full_multiplier[oc]); write32(RQSHIFT,{26'd0,body_golden.gf_full_right_shift[oc]});
        for (int tap=0; tap<16; tap++) for (int group=0; group<4; group++) begin
          packed_weight='0;
          for (int lane=0; lane<4; lane++) packed_weight[lane*8 +: 8] = body_golden.gf_full_weights[oc*256+tap*16+group*4+lane];
          write32(WCTRL,oc|(tap<<4)|(group<<8)); write32(WDATA,packed_weight);
        end
      end
    end
  endtask
  task automatic load_conv2a_tile(input int first_oc, input logic [15:0] lane_mask);
    logic [31:0] packed_weight;
    begin
      write32(OUTPUT_LANE_MASK,32'(lane_mask));
      for (int oc=0; oc<16; oc++) begin
        if (first_oc + oc >= 40) begin
          write32(BIDX,oc); write32(BDATA,0); write32(RQIDX,oc); write32(RQMULT,0); write32(RQSHIFT,0);
        end else begin
          write32(BIDX,oc); write32(BDATA,conv2a_golden.gf_conv2a_folded_bias[first_oc+oc]); write32(RQIDX,oc);
          write32(RQMULT,conv2a_golden.gf_conv2a_multiplier[first_oc+oc]); write32(RQSHIFT,{26'd0,conv2a_golden.gf_conv2a_right_shift[first_oc+oc]});
          for (int tap=0; tap<16; tap++) for (int group=0; group<4; group++) begin
            packed_weight = {conv2a_golden.gf_conv2a_weights[(first_oc+oc)*256+tap*16+group*4+3],conv2a_golden.gf_conv2a_weights[(first_oc+oc)*256+tap*16+group*4+2],conv2a_golden.gf_conv2a_weights[(first_oc+oc)*256+tap*16+group*4+1],conv2a_golden.gf_conv2a_weights[(first_oc+oc)*256+tap*16+group*4]};
            write32(WCTRL,oc|(tap<<4)|(group<<8)); write32(WDATA,packed_weight);
          end
        end
      end
    end
  endtask

  initial begin
    logic [31:0] value;
    for (int beat=0; beat<DDR_BEATS; beat++) ddr[beat]='0;
    for (int byte_index=0; byte_index<RGB_BYTES; byte_index++) ddr[(RGB_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] = gf_full_input_q[byte_index] ^ 8'h80;
    repeat(3) @(negedge clk); aresetn=1;
    read32(MAGIC,value); if(value!=32'h47464e50)$fatal(1,"bad chain magic %08x",value);
    read32(VERSION,value); if(value!=32'h00040002)$fatal(1,"bad chain version %08x",value);
    write32(CONTROL,1); write32(LAYER_MODE,0); write32(QCFG,32'h0003_8080); load_rgb_weights();
    write32(DMA_SOURCE,RGB_BASE); write32(DMA_BYTES,RGB_BYTES); write32(DMA_PIXELS,9216);
    write32(STORE_DESTINATION,ACT1_BASE); write32(STORE_BYTES,ACTIVATION_BYTES); write32(STORE_CONTROL,1); write32(CONTROL,2);
    for (int wait_cycle=0; wait_cycle<3_500_000; wait_cycle++) begin @(negedge clk); if(dut.fault)$fatal(1,"chain layer0 fault"); if(dut.done)break; if(wait_cycle==3_499_999)$fatal(1,"chain layer0 timeout"); end
    read32(OUTPUT_FNV1A,value); if(value!=GF_FULL_QUANT_FNV1A)$fatal(1,"chain layer0 hash %08x",value); layer0_cycles=dut.layer_cycles;
    for (int byte_index=0; byte_index<ACTIVATION_BYTES; byte_index++)
      if (ddr[(ACT1_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] !== body_golden.gf_full_input_q[byte_index])
        $fatal(1,"layer handoff tensor18 mismatch byte=%0d got=%02x expected=%02x",byte_index,
          ddr[(ACT1_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8], body_golden.gf_full_input_q[byte_index]);
    write32(CONTROL,1); write32(LAYER_MODE,1); write32(QCFG,32'h0003_8080); load_body_weights();
    write32(DMA_SOURCE,ACT1_BASE); write32(DMA_BYTES,ACTIVATION_BYTES); write32(DMA_PIXELS,9216);
    write32(STORE_DESTINATION,ACT2_BASE); write32(STORE_BYTES,ACTIVATION_BYTES); write32(STORE_CONTROL,1); write32(CONTROL,2);
    for (int wait_cycle=0; wait_cycle<4_000_000; wait_cycle++) begin @(negedge clk); if(dut.fault)$fatal(1,"chain layer1 fault"); if(dut.done)break; if(wait_cycle==3_999_999)$fatal(1,"chain layer1 timeout"); end
    read32(OUTPUT_FNV1A,value); if(value!=body_golden.GF_FULL_QUANT_FNV1A)$fatal(1,"chain layer1 hash %08x",value);
    read32(STORE_STATUS,value); if(value[2:0]!=3'b010 || value[31:3] != 29'(ACTIVATION_BYTES))$fatal(1,"chain store status %08x",value);
    layer1_cycles=dut.layer_cycles;
    write32(CONTROL,1); write32(LAYER_MODE,1); write32(QCFG,32'h0003_8080); load_body_weights();
    write32(DMA_SOURCE,ACT1_BASE); write32(DMA_BYTES,ACTIVATION_BYTES); write32(DMA_PIXELS,9216);
    write32(STORE_DESTINATION,ACT3_BASE); write32(STORE_BYTES,POOL_BYTES); write32(STORE_CONTROL,3); write32(CONTROL,2);
    for (int wait_cycle=0; wait_cycle<4_000_000; wait_cycle++) begin @(negedge clk); if(dut.fault)$fatal(1,"chain pool fault"); if(dut.done)break; if(wait_cycle==3_999_999)$fatal(1,"chain pool timeout"); end
    read32(OUTPUT_FNV1A,value); if(value!=body_golden.GF_FULL_QUANT_FNV1A)$fatal(1,"chain pooled conv hash %08x",value);
    read32(STORE_STATUS,value); if(value[2:0]!=3'b010 || value[31:3] != 29'(POOL_BYTES))$fatal(1,"chain pool store status %08x",value);
    for (int byte_index=0; byte_index<POOL_BYTES; byte_index++)
      if (ddr[(ACT3_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] !== pool_golden.gf_pool_output_q[byte_index])
        $fatal(1,"pool tensor mismatch byte=%0d got=%02x expected=%02x",byte_index,
          ddr[(ACT3_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8],pool_golden.gf_pool_output_q[byte_index]);
    pool_cycles=dut.layer_cycles;
    for (int byte_index=0; byte_index<POOL_BYTES; byte_index++)
      if (ddr[(ACT3_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] !== conv2a_golden.gf_conv2a_input_q[byte_index])
        $fatal(1,"conv2a input mismatch byte=%0d",byte_index);
    for (int tile=0; tile<3; tile++) begin
      write32(CONTROL,1); write32(LAYER_MODE,1); write32(QCFG,32'h0003_8080); write32(JOB_WIDTH,48); write32(JOB_HEIGHT,48);
      load_conv2a_tile(tile*16,tile==2 ? 16'h00ff : 16'hffff);
      write32(DMA_SOURCE,ACT3_BASE); write32(DMA_BYTES,POOL_BYTES); write32(DMA_PIXELS,2304);
      write32(STORE_DESTINATION,CONV2A_BASE+tile*16); write32(STORE_BYTES,tile==2 ? 18432 : 36864); write32(STORE_STRIDE,40); write32(STORE_VALID_BYTES,tile==2 ? 8 : 16); write32(STORE_CONTROL,1); write32(CONTROL,2);
      for (int wait_cycle=0; wait_cycle<2_000_000; wait_cycle++) begin @(negedge clk); if(dut.fault)$fatal(1,"conv2a tile%0d fault",tile); if(dut.done)break; if(wait_cycle==1_999_999)$fatal(1,"conv2a tile%0d timeout",tile); end
      read32(STORE_STATUS,value); if(value[2:0]!=3'b010 || value[31:3] != 29'(tile==2 ? 18432 : 36864))$fatal(1,"conv2a tile%0d store status %08x",tile,value);
    end
    for (int byte_index=0; byte_index<CONV2A_BYTES; byte_index++)
      if (ddr[(CONV2A_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8] !== conv2a_golden.gf_conv2a_output_q[byte_index])
        $fatal(1,"conv2a output mismatch byte=%0d got=%02x expected=%02x",byte_index,ddr[(CONV2A_BASE>>3)+(byte_index>>3)][(byte_index&7)*8 +: 8],conv2a_golden.gf_conv2a_output_q[byte_index]);
    $display("GESTUREFLOW_LAYER_CHAIN_HP0_CONV2A_AXIL_PASS layer0_cycles=%0d layer1_cycles=%0d pool_cycles=%0d conv2a=%08x",layer0_cycles,layer1_cycles,pool_cycles,conv2a_golden.GF_CONV2A_QUANT_FNV1A);
    $finish;
  end
endmodule
