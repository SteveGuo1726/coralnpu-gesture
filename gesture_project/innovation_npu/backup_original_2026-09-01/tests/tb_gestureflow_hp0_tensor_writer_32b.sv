// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// The 32-byte regression proves that an OUT_LANES=32 tile is written in four
// 64-bit AXI beats without silently dropping lanes 16..31.
`timescale 1ns/1ps
module tb_gestureflow_hp0_tensor_writer_32b;
  localparam int VECTOR_COUNT = 3;
  localparam int MAX_BURST_VECTORS = 4;
  localparam int BEATS = 4;
  logic clk = 0, rst_n = 0, start = 0, clear = 0, pool_2x2 = 0;
  logic [31:0] destination_addr = 32'h00200000, byte_count = VECTOR_COUNT * 32;
  logic [13:0] vector_count = 14'(VECTOR_COUNT);
  logic [15:0] input_width = 96;
  logic [31:0] destination_stride_bytes = 0;
  logic [5:0] valid_vector_bytes = 6'd32;
  logic busy, done, fault;
  logic [2:0] bank_read_addr;
  logic bank_read_enable;
  logic [255:0] bank_read_data;
  logic [31:0] awaddr;
  logic [7:0] awlen;
  logic awvalid, awready = 1;
  logic [63:0] wdata;
  logic [7:0] wstrb;
  logic wlast, wvalid, wready = 1;
  logic [1:0] bresp = 0;
  logic bvalid = 0, bready;
  logic [255:0] expected [0:VECTOR_COUNT-1];
  integer aw_count = 0, w_count = 0, b_count = 0;
  integer burst_beats = 0;

  always #5 clk = ~clk;

  gestureflow_hp0_tensor_writer #(
    .VECTOR_COUNT(VECTOR_COUNT), .VECTOR_ADDR_W(3), .VECTOR_BYTES(32),
    .MAX_BURST_VECTORS(MAX_BURST_VECTORS)
  ) dut (
    .clk, .rst_n, .start, .clear, .pool_2x2, .destination_addr, .byte_count,
    .vector_count, .input_width, .destination_stride_bytes, .valid_vector_bytes,
    .busy, .done, .fault, .bank_read_addr, .bank_read_enable, .bank_read_data,
    .vectors_written(), .bytes_written(), .m_axi_awaddr(awaddr), .m_axi_awid(),
    .m_axi_awlen(awlen), .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(),
    .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(), .m_axi_awregion(),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
    .m_axi_wready(wready), .m_axi_bid('0), .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid), .m_axi_bready(bready)
  );

  always_ff @(posedge clk) begin
    if (bank_read_enable) bank_read_data <= expected[bank_read_addr[1:0]];
    bvalid <= 1'b0;
    if (awvalid && awready) begin
      if (awaddr != destination_addr || awlen != 8'(VECTOR_COUNT * BEATS - 1))
        $fatal(1, "bad 32-byte burst addr=%08x len=%0d", awaddr, awlen);
      aw_count <= aw_count + 1;
    end
    if (wvalid && wready) begin
      if (wstrb != 8'hff || wdata !== expected[w_count / BEATS][(w_count % BEATS) * 64 +: 64] ||
          wlast != (w_count == VECTOR_COUNT * BEATS - 1))
        $fatal(1, "bad 32-byte beat=%0d last=%0b data=%016x", w_count, wlast, wdata);
      w_count <= w_count + 1;
      burst_beats <= burst_beats + 1;
      if (wlast) bvalid <= 1'b1;
    end
    if (bvalid && bready) b_count <= b_count + 1;
  end

  initial begin
    for (int i = 0; i < VECTOR_COUNT; i++) begin
      expected[i] = '0;
      for (int lane = 0; lane < 32; lane++) expected[i][lane*8 +: 8] = 8'(i * 32 + lane);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    start = 1;
    @(posedge clk);
    start = 0;
    repeat (500) begin
      @(posedge clk);
      if (done) begin
        if (fault || aw_count != 1 || w_count != VECTOR_COUNT * BEATS || b_count != 1)
          $fatal(1, "32-byte writer completion mismatch aw=%0d w=%0d b=%0d", aw_count, w_count, b_count);
        $display("GESTUREFLOW_HP0_TENSOR_WRITER_32B_PASS vectors=%0d beats=%0d", VECTOR_COUNT, burst_beats);
        $finish;
      end
    end
    $fatal(1, "32-byte writer timeout");
  end
endmodule
