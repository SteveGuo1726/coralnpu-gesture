// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_hp0_stream_writer;
  localparam int N = 10;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, start = 0, clear = 0;
  logic [31:0] destination_addr = 32'h1000_0000, byte_count = N * 32;
  logic [31:0] destination_stride_bytes = 32;
  logic [13:0] vector_count = 14'(N);
  logic [5:0] valid_vector_bytes = 32;
  logic vector_valid = 0, vector_ready, vector_last;
  logic [255:0] vector_data;
  logic busy, done, fault;
  logic [13:0] vectors_written;
  logic [31:0] bytes_written;
  logic [31:0] awaddr;
  logic [5:0] awid;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awlock;
  logic [3:0] awcache;
  logic [2:0] awprot;
  logic [3:0] awqos, awregion;
  logic awvalid, awready = 1;
  logic [63:0] wdata;
  logic [7:0] wstrb;
  logic wlast, wvalid, wready = 1;
  logic [5:0] bid = 0;
  logic [1:0] bresp = 0;
  logic bvalid = 0, bready;
  int sent = 0;
  int burst_count = 0;
  int burst_beats = 0;
  int expected_beat = 0;
  logic [31:0] expected_address = 32'h1000_0000;

  gestureflow_hp0_stream_writer #(.VECTOR_BYTES(32), .MAX_BURST_VECTORS(4), .COUNT_W(14)) dut (
    .clk, .rst_n, .start, .clear, .destination_addr, .byte_count, .vector_count,
    .destination_stride_bytes, .valid_vector_bytes, .vector_valid, .vector_ready, .vector_data, .vector_last,
    .busy, .done, .fault, .vectors_written, .bytes_written,
    .m_axi_awaddr(awaddr), .m_axi_awid(awid), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
    .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
    .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awregion(awregion),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
  );

  always @(posedge clk) begin
    bvalid <= 0;
    if (awvalid && awready) begin
      if (awaddr != expected_address || awsize != 3 || awburst != 2'b01)
        $fatal(1, "bad AW addr=%08x expected=%08x size=%0d burst=%0d", awaddr, expected_address, awsize, awburst);
      if ((int'(awlen) + 1) != ((sent - burst_count * 4 >= 4) ? 16 : (N - burst_count * 4) * 4))
        $fatal(1, "bad AWLEN=%0d burst=%0d sent=%0d", awlen, burst_count, sent);
      burst_beats = int'(awlen) + 1;
      expected_beat = 0;
      burst_count++;
    end
    if (wvalid && wready) begin
      if (wstrb != 8'hff) $fatal(1, "unexpected WSTRB=%02x", wstrb);
      expected_beat++;
      if (wlast) begin
        if (expected_beat != burst_beats) $fatal(1, "WLAST beat=%0d expected=%0d", expected_beat, burst_beats);
        bvalid <= 1;
        expected_address <= expected_address + burst_beats * 8;
      end else if (expected_beat >= burst_beats) begin
        $fatal(1, "missing WLAST");
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n && vector_valid && vector_ready) begin
      if (vector_data[7:0] != sent[7:0]) $fatal(1, "data order mismatch index=%0d data=%02x", sent, vector_data[7:0]);
      if (vector_last != (sent == N - 1)) $fatal(1, "last mismatch index=%0d", sent);
      sent++;
    end
  end

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); start = 1;
    @(posedge clk); start = 0;
    while (!done && !fault && sent < N) begin
      @(posedge clk);
      vector_valid = vector_ready;
      vector_last = (sent == N - 1);
      vector_data = '0;
      vector_data[7:0] = 8'(sent);
      for (int lane = 1; lane < 32; lane++) vector_data[lane*8 +: 8] = 8'(sent + lane);
    end
    vector_valid = 0;
    repeat (20) @(posedge clk);
    if (fault || !done) $fatal(1, "writer failed done=%0d fault=%0d", done, fault);
    if (int'(vectors_written) != N || bytes_written != N * 32) $fatal(1, "bad counters vectors=%0d bytes=%0d", vectors_written, bytes_written);
    if (burst_count != 3) $fatal(1, "expected 3 bursts, got %0d", burst_count);
    $display("GESTUREFLOW_HP0_STREAM_WRITER_PASS vectors=%0d bursts=%0d bytes=%0d", vectors_written, burst_count, bytes_written);
    $finish;
  end
endmodule
