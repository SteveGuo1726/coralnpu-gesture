// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_axil_microkernel;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [31:0] awaddr, wdata, araddr;
  logic [2:0] awprot, arprot;
  logic awvalid, wvalid, bready, arvalid, rready;
  logic [3:0] wstrb;
  logic awready, wready, bvalid, arready, rvalid;
  logic [1:0] bresp, rresp;
  logic [31:0] rdata;

  localparam [31:0] MAGIC = 32'h000, VERSION = 32'h004, CONTROL = 32'h008,
                    STATUS = 32'h00c, WCTRL = 32'h010, WDATA = 32'h014,
                    BIDX = 32'h018, BDATA = 32'h01c, ACTRL = 32'h020,
                    ADATA = 32'h024, RESULT_IDX = 32'h028,
                    RESULT_DATA = 32'h02c, CYCLES = 32'h030,
                    ACT_STAGE_ADDR = 32'h034, ACT_STAGE_DATA = 32'h038,
                    JOB_CFG = 32'h03c, RQIDX = 32'h040, RQMULT = 32'h044,
                    RQSHIFT = 32'h048, RQCTRL = 32'h04c,
                    OUT_STAGE_ADDR = 32'h050, OUT_READ_CTRL = 32'h054,
                    OUT_READ_DATA = 32'h058, QUANT_RESULT_IDX = 32'h05c,
                    QUANT_RESULT_DATA = 32'h060, DMA_SOURCE_ADDR = 32'h064,
                    DMA_WORD_COUNT = 32'h068, DMA_STAGE_ADDR = 32'h06c,
                    DMA_CONTROL = 32'h070, DMA_STATUS = 32'h074;

  logic [31:0] m_axi_araddr;
  logic [5:0] m_axi_arid, m_axi_rid;
  logic [7:0] m_axi_arlen;
  logic [2:0] m_axi_arsize;
  logic [1:0] m_axi_arburst, m_axi_rresp;
  logic m_axi_arlock, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [3:0] m_axi_arcache, m_axi_arqos, m_axi_arregion;
  logic [2:0] m_axi_arprot;
  logic [63:0] m_axi_rdata;
  logic [63:0] dma_memory [0:127];
  logic dma_read_active;
  logic [6:0] dma_memory_index;
  logic [4:0] dma_beats_left;

  always #5 clk = ~clk;

  gestureflow_axil_microkernel dut (
    .aclk(clk), .aresetn(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_axi_araddr(m_axi_araddr), .m_axi_arid(m_axi_arid), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos), .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  // Bounded AXI memory model: one read burst at a time, matching the HP0
  // loader's contract. Every 64-bit beat contains two activation words.
  assign m_axi_arready = !dma_read_active;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dma_read_active <= 1'b0;
      dma_memory_index <= '0;
      dma_beats_left <= '0;
      m_axi_rid <= '0;
      m_axi_rdata <= '0;
      m_axi_rresp <= 2'b00;
      m_axi_rlast <= 1'b0;
      m_axi_rvalid <= 1'b0;
    end else if (!dma_read_active && m_axi_arvalid && m_axi_arready) begin
      dma_read_active <= 1'b1;
      dma_memory_index <= m_axi_araddr[9:3];
      dma_beats_left <= m_axi_arlen[4:0] + 1'b1;
      m_axi_rid <= m_axi_arid;
      m_axi_rdata <= dma_memory[(m_axi_araddr - 32'h00001000) >> 3];
      m_axi_rresp <= 2'b00;
      m_axi_rlast <= (m_axi_arlen == 0);
      m_axi_rvalid <= 1'b1;
    end else if (dma_read_active && m_axi_rvalid && m_axi_rready) begin
      if (dma_beats_left == 5'd1) begin
        dma_read_active <= 1'b0;
        m_axi_rvalid <= 1'b0;
        m_axi_rlast <= 1'b0;
      end else begin
        dma_memory_index <= dma_memory_index + 1'b1;
        dma_beats_left <= dma_beats_left - 1'b1;
        m_axi_rdata <= dma_memory[dma_memory_index + 1'b1];
        m_axi_rlast <= (dma_beats_left == 5'd2);
      end
    end
  end

  task automatic axil_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      awaddr <= addr; awprot <= '0; awvalid <= 1'b1;
      wdata <= data; wstrb <= 4'hf; wvalid <= 1'b1;
      while (!(awready && wready)) @(negedge clk);
      @(negedge clk);
      awvalid <= 1'b0; wvalid <= 1'b0;
      bready <= 1'b1;
      while (!bvalid) @(negedge clk);
      @(negedge clk);
      bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr <= addr; arprot <= '0; arvalid <= 1'b1;
      while (!arready) @(negedge clk);
      @(negedge clk);
      arvalid <= 1'b0; rready <= 1'b1;
      while (!rvalid) @(negedge clk);
      data = rdata;
      @(negedge clk);
      rready <= 1'b0;
    end
  endtask

  logic [31:0] value;
  logic [31:0] full_cycles, dma_cycles, rgb_cycles, carry_cycles;
  integer signed real_accum [0:15] = '{12945,40101,-27709,-25992,-7799,-26966,21056,-11847,-5999,-20715,13808,-15449,-10414,13976,-4778,13263};
  integer signed real_multiplier [0:15] = '{1787846233,1122128448,1349594768,1412386588,2062591784,1790157864,1533299872,1443871989,1529114050,1120653286,2057570923,1596767263,1161961791,1968538391,2100971521,1438322766};
  logic [5:0] real_right_shift [0:15] = '{11,9,10,9,11,10,11,11,9,11,8,9,10,11,10,9};
  integer signed real_quantized [0:15] = '{-123,-87,-128,-128,-128,-128,-121,-128,-128,-128,-76,-128,-128,-122,-128,-111};
  integer oc;
  initial begin
    awaddr = '0; wdata = '0; araddr = '0; awprot = '0; arprot = '0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0; wstrb = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    axil_read(MAGIC, value); if (value != 32'h47464e50) $fatal(1, "bad magic %h", value);
    axil_read(VERSION, value); if (value != 32'h00010004) $fatal(1, "bad version %h", value);
    for (int beat = 0; beat < 128; beat++) dma_memory[beat] = 64'h0202020202020202;

    // Bias each output lane with its lane number. Load every 4x4 tap/group
    // with four ones. Feeding all-one activations produces 16 groups * 4 = 64.
    for (oc = 0; oc < 16; oc = oc + 1) begin
      axil_write(BIDX, oc);
      axil_write(BDATA, oc);
      for (int tap = 0; tap < 16; tap++) begin
        for (int group = 0; group < 16; group++) begin
          axil_write(WCTRL, oc | (tap << 4) | (group << 8));
          axil_write(WDATA, 32'h01010101);
        end
      end
    end

    for (int tap = 0; tap < 16; tap++) begin
      for (int group = 0; group < 16; group++) begin
        axil_write(ACT_STAGE_ADDR, (tap << 4) | group);
        axil_write(ACT_STAGE_DATA, 32'h01010101);
      end
    end
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);

    for (int wait_cycle = 0; wait_cycle < 100; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 99) $fatal(1, "transaction never completed status=%h", value);
    end
    axil_read(STATUS, value); if (value[4]) $fatal(1, "protocol fault status=%h", value);
    axil_read(CYCLES, value); if (value == 0) $fatal(1, "cycle counter did not run");
    full_cycles = value;
    for (oc = 0; oc < 16; oc++) begin
      axil_write(RESULT_IDX, oc);
      axil_read(RESULT_DATA, value);
      if ($signed(value) != (1024 + oc)) $fatal(1, "lane %0d result=%0d expected=%0d", oc, $signed(value), 1024 + oc);
    end
    axil_read(RESULT_IDX, value); if (value != 32'h0000ffff) $fatal(1, "bad result mask %h", value);
    if (dut.cycles >= 1000) $fatal(1, "staged execution did not remove host feed gap cycles=%0d", dut.cycles);

    // Replace AXI-Lite staging with HP0-style burst reads. The 256 words are
    // all +2, so the full tile result is 16*16*4*2 plus each lane's bias.
    axil_write(DMA_SOURCE_ADDR, 32'h00001000);
    axil_write(DMA_WORD_COUNT, 32'd256);
    axil_write(DMA_STAGE_ADDR, 32'd0);
    axil_write(DMA_CONTROL, 32'h1);
    for (int wait_cycle = 0; wait_cycle < 1000; wait_cycle++) begin
      axil_read(DMA_STATUS, value);
      if (value[1]) break;
      if (wait_cycle == 999) $fatal(1, "DMA never completed status=%h", value);
    end
    if (value != 32'h00000002) $fatal(1, "DMA fault or busy status=%h", value);
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);
    for (int wait_cycle = 0; wait_cycle < 200; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 199) $fatal(1, "DMA-staged transaction never completed status=%h", value);
    end
    axil_read(CYCLES, dma_cycles);
    for (oc = 0; oc < 16; oc++) begin
      axil_write(RESULT_IDX, oc);
      axil_read(RESULT_DATA, value);
      if ($signed(value) != (2048 + oc)) $fatal(1, "DMA lane %0d result=%0d expected=%0d", oc, $signed(value), 2048 + oc);
    end

    // Real RGB stem shape: 4x4 taps, one Cin group with only lanes 0..2.
    // The existing +1 weights/bias produce 16 * 3 + output-lane bias.
    axil_write(JOB_CFG, 32'hffff070f);
    for (int tap = 0; tap < 16; tap++) begin
      axil_write(ACT_STAGE_ADDR, tap);
      axil_write(ACT_STAGE_DATA, 32'h01010101);
    end
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);
    for (int wait_cycle = 0; wait_cycle < 100; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 99) $fatal(1, "RGB transaction never completed status=%h", value);
    end
    for (oc = 0; oc < 16; oc++) begin
      axil_write(RESULT_IDX, oc);
      axil_read(RESULT_DATA, value);
      if ($signed(value) != (48 + oc)) $fatal(1, "RGB lane %0d result=%0d expected=%0d", oc, $signed(value), 48 + oc);
    end
    if (dut.cycles >= 100) $fatal(1, "RGB staged execution took %0d cycles", dut.cycles);
    rgb_cycles = dut.cycles;

    // Exact first-layer TFLite requantization fixture. Raw accumulators are
    // real model values; Q31 multipliers, shifts, output zero point and fused
    // ReLU are exported by the project-local model probe generator.
    axil_write(JOB_CFG, 32'hffff0f00);
    axil_write(OUT_STAGE_ADDR, 0);
    for (oc = 0; oc < 16; oc++) begin
      axil_write(BIDX, oc); axil_write(BDATA, real_accum[oc]);
      axil_write(WCTRL, oc); axil_write(WDATA, 0);
      axil_write(RQIDX, oc); axil_write(RQMULT, real_multiplier[oc]);
      axil_write(RQSHIFT, {26'd0, real_right_shift[oc]});
    end
    axil_write(RQCTRL, 32'h00008003);
    axil_write(ACT_STAGE_ADDR, 0); axil_write(ACT_STAGE_DATA, 0);
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);
    for (int wait_cycle = 0; wait_cycle < 100; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 99) $fatal(1, "requant transaction never completed status=%h", value);
    end
    for (oc = 0; oc < 16; oc++) begin
      axil_write(RESULT_IDX, oc); axil_read(RESULT_DATA, value);
      if ($signed(value) != real_accum[oc]) $fatal(1, "requant raw lane %0d got=%0d expected=%0d", oc, $signed(value), real_accum[oc]);
      axil_write(QUANT_RESULT_IDX, oc); axil_read(QUANT_RESULT_DATA, value);
      if ($signed(value) != real_quantized[oc]) $fatal(1, "requant lane %0d got=%0d expected=%0d raw=%0d multiplier=%0d shift=%0d zero=%0d enabled=%0b", oc, $signed(value), real_quantized[oc], dut.result_psum[oc], dut.requant_multiplier[oc], dut.requant_right_shift[oc], dut.requant_zero_point, dut.requant_enable);
    end
    axil_write(OUT_READ_CTRL, 0);
    repeat (2) @(negedge clk);
    for (int word = 0; word < 4; word++) begin
      axil_write(OUT_READ_CTRL, word << 8);
      repeat (2) @(negedge clk);
      axil_read(OUT_READ_DATA, value);
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        if ($signed(value[byte_index*8 +: 8]) != real_quantized[word*4+byte_index]) $fatal(1, "output bank word=%0d byte=%0d got=%0d expected=%0d", word, byte_index, $signed(value[byte_index*8 +: 8]), real_quantized[word*4+byte_index]);
      end
    end

    // Regression for packed-array carry contamination. Lane 0 deliberately
    // wraps from INT32_MAX to INT32_MIN; lane 1 must remain exactly zero.
    // A whole-vector result_psum <= accum + sum would incorrectly carry the
    // lane-0 overflow into lane 1.
    axil_write(JOB_CFG, 32'h00030100);
    axil_write(BIDX, 0); axil_write(BDATA, 32'h7fffffff);
    axil_write(BIDX, 1); axil_write(BDATA, 32'h00000000);
    axil_write(WCTRL, 0); axil_write(WDATA, 32'h00000001);
    axil_write(WCTRL, 1); axil_write(WDATA, 32'h00000000);
    axil_write(ACT_STAGE_ADDR, 0); axil_write(ACT_STAGE_DATA, 32'h00000001);
    axil_write(CONTROL, 32'h2);
    axil_write(CONTROL, 32'h5);
    for (int wait_cycle = 0; wait_cycle < 100; wait_cycle++) begin
      axil_read(STATUS, value);
      if (value[3]) break;
      if (wait_cycle == 99) $fatal(1, "carry transaction never completed status=%h", value);
    end
    axil_write(RESULT_IDX, 0); axil_read(RESULT_DATA, value);
    if (value != 32'h80000000) $fatal(1, "lane 0 wrap result=%h", value);
    axil_write(RESULT_IDX, 1); axil_read(RESULT_DATA, value);
    if (value != 32'h00000000) $fatal(1, "cross-lane carry result=%h", value);
    carry_cycles = dut.cycles;
    $display("GESTUREFLOW_AXIL_MICROKERNEL_DMA_PASS full_cycles=%0d dma_cycles=%0d rgb_cycles=%0d carry_cycles=%0d lane0=%0d lane15=%0d", full_cycles, dma_cycles, rgb_cycles, carry_cycles, dut.result_psum[0], dut.result_psum[15]);
    $finish;
  end
endmodule
