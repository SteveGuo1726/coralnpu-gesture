// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Descriptor-level layer handoff regression.  This is deliberately small in
// spatial size, but not a zero-data smoke test: descriptor 0 uses parameter
// and weight context 0 to emit a nonzero 16-channel activation to emulated
// DDR; descriptor 1 reloads that exact activation through the 16-channel HP0
// reader and uses the independent context 1.  It catches accidental sharing
// of resident weights, bias/requant state, or the DDR handoff itself before a
// long 7020 implementation run.
`timescale 1ns/1ps
module tb_gestureflow_layer_chain_descriptor_axil;
  localparam logic [11:0] CONTROL=12'h008, WCTRL=12'h014, WDATA=12'h018,
    BIDX=12'h01c, BDATA=12'h020, RQIDX=12'h024, RQMULT=12'h028, RQSHIFT=12'h02c,
    DESC_SELECT=12'h100, DESC_MODE=12'h104, DESC_JOB_SHAPE=12'h108,
    DESC_DMA_SOURCE=12'h10c, DESC_DMA_BYTES=12'h110, DESC_DMA_PIXELS=12'h114,
    DESC_STORE_DESTINATION=12'h118, DESC_STORE_BYTES=12'h11c,
    DESC_STORE_CONTROL=12'h120, DESC_STORE_STRIDE=12'h124,
    DESC_STORE_VALID_BYTES=12'h128, DESC_QCFG=12'h12c,
    DESC_LANE_MASK=12'h130, DESC_COUNT=12'h134, DESC_CONTROL=12'h138,
    DESC_STATUS=12'h13c, DESC_ISSUED=12'h140, DESC_COMPLETED=12'h144,
    DESC_WEIGHT_BANK=12'h148, DESC_PARAM_BANK=12'h14c,
    PARAM_BANK_SELECT=12'h150, DESC_TASK_CYCLES=12'h154,
    WEIGHT_BANK_SELECT=12'h0fc;
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
  localparam logic [31:0] RGB_ADDR=32'h00001000, ACTIVATION_A_ADDR=32'h00002000,
    ACTIVATION_B_ADDR=32'h00003000;
  logic [7:0] ddr [0:16383];
  logic read_active=0, write_active=0; logic [4:0] read_left=0, write_left=0;
  logic [31:0] read_addr=0, write_addr=0;
  integer write_beats=0;

  function automatic logic [63:0] ddr_read64(input logic [31:0] address);
    logic [63:0] value;
    begin
      value = '0;
      for (int byte_index=0; byte_index<8; byte_index++) begin
        if (address + byte_index < 16384) value[byte_index*8 +: 8] = ddr[address + byte_index];
      end
      ddr_read64 = value;
    end
  endfunction

  gestureflow_layer_chain_hp0_axil #(.IMAGE_WIDTH(4),.IMAGE_HEIGHT(2),.OUTPUTS(8),.OUTPUT_ADDR_W(3)) dut (
    .aclk(clk), .aresetn,
    .s_axi_awaddr,.s_axi_awprot,.s_axi_awvalid,.s_axi_awready,.s_axi_wdata,.s_axi_wstrb,.s_axi_wvalid,.s_axi_wready,
    .s_axi_bresp,.s_axi_bvalid,.s_axi_bready,.s_axi_araddr,.s_axi_arprot,.s_axi_arvalid,.s_axi_arready,.s_axi_rdata,.s_axi_rresp,.s_axi_rvalid,.s_axi_rready,
    .m_axi_araddr,.m_axi_arid,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,.m_axi_arlock,.m_axi_arcache,.m_axi_arprot,.m_axi_arqos,.m_axi_arregion,.m_axi_arvalid,.m_axi_arready,
    .m_axi_rid,.m_axi_rdata,.m_axi_rresp,.m_axi_rlast,.m_axi_rvalid,.m_axi_rready,
    .m_axi_awaddr,.m_axi_awid,.m_axi_awlen,.m_axi_awsize,.m_axi_awburst,.m_axi_awlock,.m_axi_awcache,.m_axi_awprot,.m_axi_awqos,.m_axi_awregion,.m_axi_awvalid,.m_axi_awready,
    .m_axi_wdata,.m_axi_wstrb,.m_axi_wlast,.m_axi_wvalid,.m_axi_wready,.m_axi_bid,.m_axi_bresp,.m_axi_bvalid,.m_axi_bready
  );

  assign m_axi_arready = !read_active;
  assign m_axi_awready = !write_active;
  assign m_axi_wready = write_active;
  always_ff @(posedge clk) begin
    if (!aresetn) begin read_active<=0; m_axi_rvalid<=0; m_axi_rlast<=0; read_left<=0; end
    else begin
      if (!read_active && m_axi_arvalid && m_axi_arready) begin
        if (!((m_axi_araddr == RGB_ADDR) || (m_axi_araddr >= ACTIVATION_A_ADDR &&
              m_axi_araddr < ACTIVATION_A_ADDR + 128)) || m_axi_arsize != 3'd3 ||
            m_axi_arburst != 2'b01)
          $fatal(1,"unexpected descriptor read addr=%08x len=%0d",m_axi_araddr,m_axi_arlen);
        read_active<=1; read_addr<=m_axi_araddr; read_left<={1'b0,m_axi_arlen[3:0]}+1'b1;
        m_axi_rdata<=ddr_read64(m_axi_araddr); m_axi_rvalid<=1; m_axi_rlast<=(m_axi_arlen==0);
      end else if (read_active && m_axi_rvalid && m_axi_rready) begin
        if (read_left==1) begin read_active<=0; m_axi_rvalid<=0; m_axi_rlast<=0; end
        else begin
          read_addr<=read_addr+8; m_axi_rdata<=ddr_read64(read_addr+8);
          read_left<=read_left-1'b1; m_axi_rlast<=(read_left==2);
        end
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!aresetn) begin write_active<=0; write_left<=0; m_axi_bvalid<=0; write_beats<=0; end
    else begin
      if (m_axi_bvalid && m_axi_bready) m_axi_bvalid<=0;
      if (!write_active && m_axi_awvalid && m_axi_awready) begin
        if (!((m_axi_awaddr == ACTIVATION_A_ADDR) || (m_axi_awaddr == ACTIVATION_B_ADDR)) ||
            m_axi_awlen != 15 || m_axi_awsize != 3'd3 || m_axi_awburst != 2'b01)
          $fatal(1,"unexpected descriptor write addr=%08x len=%0d",m_axi_awaddr,m_axi_awlen);
        write_active<=1; write_addr<=m_axi_awaddr; write_left<={1'b0,m_axi_awlen[3:0]}+1'b1;
      end
      if (write_active && m_axi_wvalid && m_axi_wready) begin
        if (m_axi_wstrb != 8'hff) $fatal(1,"unexpected writer strobe %02x",m_axi_wstrb);
        for (int byte_index=0; byte_index<8; byte_index++) begin
          ddr[write_addr + byte_index] <= m_axi_wdata[byte_index*8 +: 8];
        end
        write_addr <= write_addr + 8;
        write_beats<=write_beats+1;
        if (write_left==1) begin
          if (!m_axi_wlast) $fatal(1,"missing descriptor WLAST");
          write_active<=0; m_axi_bvalid<=1;
        end else begin
          if (m_axi_wlast) $fatal(1,"early descriptor WLAST");
          write_left<=write_left-1'b1;
        end
      end
    end
  end

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
    integer byte_index;
    repeat(3) @(negedge clk); aresetn=1;
    write32(CONTROL,1);
    // All camera bytes are q=+1 after the RGB loader's u8->s8 conversion.
    // Context 0 ignores pixels and emits bias=5 in lane 0. Context 1 reloads
    // that tensor, multiplies its lane 0 by one over the 4x4 window and adds
    // bias=11. The two descriptors therefore cannot accidentally share either
    // parameter context or weight context and still pass.
    for (byte_index=0; byte_index<16384; byte_index++) ddr[byte_index] = 8'h00;
    for (byte_index=0; byte_index<24; byte_index++) ddr[RGB_ADDR + byte_index] = 8'h81;
    write32(WEIGHT_BANK_SELECT,0); write32(PARAM_BANK_SELECT,0);
    for (int oc=0; oc<16; oc++) begin
      write32(BIDX,oc); write32(BDATA,oc == 0 ? 5 : 0); write32(RQIDX,oc); write32(RQMULT,0); write32(RQSHIFT,0);
      for (int tap=0; tap<16; tap++) begin write32(WCTRL,oc|(tap<<4)); write32(WDATA,0); end
    end
    write32(WEIGHT_BANK_SELECT,1); write32(PARAM_BANK_SELECT,1);
    for (int oc=0; oc<16; oc++) begin
      write32(BIDX,oc); write32(BDATA,oc == 0 ? 11 : 0); write32(RQIDX,oc); write32(RQMULT,0); write32(RQSHIFT,0);
      for (int tap=0; tap<16; tap++) begin
        for (int group=0; group<4; group++) begin
          write32(WCTRL,oc|(tap<<4)|(group<<8));
          write32(WDATA,(oc == 0 && group == 0) ? 32'h00000001 : 0);
        end
      end
    end
    write32(DESC_SELECT,0); write32(DESC_MODE,0); write32(DESC_JOB_SHAPE,{16'd2,16'd4});
    write32(DESC_DMA_SOURCE,RGB_ADDR); write32(DESC_DMA_BYTES,24); write32(DESC_DMA_PIXELS,8);
    write32(DESC_STORE_DESTINATION,ACTIVATION_A_ADDR); write32(DESC_STORE_BYTES,128); write32(DESC_STORE_CONTROL,1);
    write32(DESC_STORE_STRIDE,16); write32(DESC_STORE_VALID_BYTES,16); write32(DESC_QCFG,0); write32(DESC_LANE_MASK,1);
    write32(DESC_WEIGHT_BANK,0); write32(DESC_PARAM_BANK,0);
    write32(DESC_SELECT,1); write32(DESC_MODE,1); write32(DESC_JOB_SHAPE,{16'd2,16'd4});
    write32(DESC_DMA_SOURCE,ACTIVATION_A_ADDR); write32(DESC_DMA_BYTES,128); write32(DESC_DMA_PIXELS,8);
    write32(DESC_STORE_DESTINATION,ACTIVATION_B_ADDR); write32(DESC_STORE_BYTES,128); write32(DESC_STORE_CONTROL,1);
    write32(DESC_STORE_STRIDE,16); write32(DESC_STORE_VALID_BYTES,16); write32(DESC_QCFG,0); write32(DESC_LANE_MASK,1);
    write32(DESC_WEIGHT_BANK,1); write32(DESC_PARAM_BANK,1);
    write32(DESC_COUNT,2); write32(DESC_CONTROL,2);
    for (int cycle=0; cycle<50000; cycle++) begin
      @(negedge clk);
      if (dut.fault) $fatal(1,"descriptor top fault status=%08x",dut.fault);
      if (dut.done) begin
        read32(DESC_ISSUED,value); if (value != 2) $fatal(1,"issued=%0d",value);
        read32(DESC_COMPLETED,value); if (value != 2) $fatal(1,"completed=%0d",value);
        read32(DESC_STATUS,value); if (value[3] || value[0]) $fatal(1,"bad descriptor status=%08x",value);
        if (write_beats != 32) $fatal(1,"writer beats=%0d",write_beats);
        // First layer is pure context-0 bias. The second layer must consume
        // that stored data and use context-1's distinct weights and bias.
        for (int pixel=0; pixel<8; pixel++) begin
          if (ddr[ACTIVATION_A_ADDR + pixel*16] != 8'd5)
            $fatal(1,"context-0 output pixel=%0d got=%0d expected=5",pixel,ddr[ACTIVATION_A_ADDR + pixel*16]);
          if ($signed(ddr[ACTIVATION_B_ADDR + pixel*16]) <= 8'sd11)
            $fatal(1,"context-1 output pixel=%0d got=%0d; bank/DDR handoff lost",pixel,$signed(ddr[ACTIVATION_B_ADDR + pixel*16]));
          for (int lane=1; lane<16; lane++) begin
            if (ddr[ACTIVATION_A_ADDR + pixel*16 + lane] != 0 || ddr[ACTIVATION_B_ADDR + pixel*16 + lane] != 0)
              $fatal(1,"inactive lane changed pixel=%0d lane=%0d",pixel,lane);
          end
        end
        write32(DESC_SELECT,0); read32(DESC_WEIGHT_BANK,value); if (value != 0) $fatal(1,"descriptor0 weight bank=%0d",value);
        read32(DESC_PARAM_BANK,value); if (value != 0) $fatal(1,"descriptor0 param bank=%0d",value);
        read32(DESC_TASK_CYCLES,value); if (value == 0) $fatal(1,"descriptor0 cycles missing");
        write32(DESC_SELECT,1); read32(DESC_WEIGHT_BANK,value); if (value != 1) $fatal(1,"descriptor1 weight bank=%0d",value);
        read32(DESC_PARAM_BANK,value); if (value != 1) $fatal(1,"descriptor1 param bank=%0d",value);
        read32(DESC_TASK_CYCLES,value); if (value == 0) $fatal(1,"descriptor1 cycles missing");
        $display("GESTUREFLOW_TOP_DESCRIPTOR_CONTEXT_PASS issued=2 completed=2 write_beats=%0d",write_beats);
        $finish;
      end
    end
    $fatal(1,"descriptor top timeout state=%0d active=%0d running=%0d",dut.desc_state,dut.descriptor_active,dut.running);
  end
endmodule
