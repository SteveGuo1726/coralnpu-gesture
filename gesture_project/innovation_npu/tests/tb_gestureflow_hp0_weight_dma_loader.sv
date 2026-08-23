// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_hp0_weight_dma_loader;
  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  always #5 clk = ~clk;
  logic [31:0] source_addr = 32'h00001000, byte_count = 32'd512;
  logic [4:0] taps = 5'd2, groups = 5'd4;
  logic busy, done, fault;
  logic [31:0] bytes_read, write_count;
  logic weight_write_valid;
  logic [3:0] weight_write_oc, weight_write_tap;
  logic [4:0] weight_write_ic_group;
  logic signed [3:0][7:0] weight_write_data;
  logic [31:0] araddr; logic [5:0] arid; logic [7:0] arlen;
  logic [2:0] arsize; logic [1:0] arburst; logic arlock;
  logic [3:0] arcache, arqos, arregion; logic [2:0] arprot;
  logic arvalid, arready, rvalid, rready, rlast;
  logic [5:0] rid; logic [63:0] rdata; logic [1:0] rresp;
  logic response_active; logic [5:0] response_left; logic [31:0] response_beat;
  integer expected_word = 0;
  integer expected_writes = 0;

  assign arready = !response_active;
  assign rvalid = response_active;
  assign rid = 0;
  assign rresp = 0;
  assign rlast = response_left == 1;
  assign rdata = {32'hA0000000 + (response_beat * 2) + 1,
                  32'hA0000000 + (response_beat * 2)};

  gestureflow_hp0_weight_dma_loader #(.FIFO_BEATS(16)) dut (
    .clk, .rst_n, .start, .clear, .source_addr, .byte_count,
    .taps_per_output(taps), .groups_per_tap(groups), .busy, .done, .fault,
    .bytes_read, .write_count, .weight_write_valid, .weight_write_oc,
    .weight_write_tap, .weight_write_ic_group, .weight_write_data,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen),
    .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
    .m_axi_arregion(arregion), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
    .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      response_active <= 0; response_left <= 0; response_beat <= 0;
    end else begin
      if (arvalid && arready) begin
        response_active <= 1;
        response_left <= arlen[5:0] + 6'd1;
        response_beat <= (araddr - source_addr) >> 3;
      end
      if (rvalid && rready) begin
        if (response_left == 1) response_active <= 0;
        else begin response_left <= response_left - 1'b1; response_beat <= response_beat + 1'b1; end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && weight_write_valid) begin
      if (weight_write_data !== (32'hA0000000 + expected_word))
        $fatal(1, "bad weight word=%0d got=%08x", expected_word, weight_write_data);
      if ({28'd0, weight_write_oc} !== (expected_word / 8) ||
          {28'd0, weight_write_tap} !== ((expected_word / 4) % 2) ||
          {27'd0, weight_write_ic_group} !== (expected_word % 4))
        $fatal(1, "bad coordinate word=%0d oc=%0d tap=%0d group=%0d", expected_word,
               weight_write_oc, weight_write_tap, weight_write_ic_group);
      expected_word = expected_word + 1;
      expected_writes = expected_writes + 1;
    end
  end

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); start = 1;
    @(posedge clk); start = 0;
    for (integer cycle = 0; cycle < 2000; cycle = cycle + 1) begin
      @(posedge clk);
      if (fault) $fatal(1, "weight DMA fault bytes=%0d writes=%0d", bytes_read, write_count);
      if (done) begin
        if (expected_writes != 128 || bytes_read != 512 || write_count != 128)
          $fatal(1, "bad completion writes=%0d bytes=%0d count=%0d", expected_writes, bytes_read, write_count);
        $display("GESTUREFLOW_WEIGHT_DMA_LOADER_PASS writes=%0d bytes=%0d", expected_writes, bytes_read);
        $finish;
      end
    end
    $fatal(1, "weight DMA timeout word=%0d bytes=%0d", expected_word, bytes_read);
  end
endmodule
