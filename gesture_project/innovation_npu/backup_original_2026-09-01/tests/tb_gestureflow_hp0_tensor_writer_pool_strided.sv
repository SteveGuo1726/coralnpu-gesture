// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Checks the exact pool2 write shape: one physical 16-lane tile can write an
// 8-byte tail at a 40-byte NHWC stride after 2x2 local-bank pooling.
`timescale 1ns/1ps
module tb_gestureflow_hp0_tensor_writer_pool_strided;
  localparam int VECTOR_COUNT = 8;
  logic clk = 0, rst_n = 0, start = 0, clear = 0, pool_2x2 = 1;
  logic [31:0] destination_addr = 0, byte_count = 0;
  logic [13:0] vector_count = 14'(VECTOR_COUNT); logic [15:0] input_width = 2;
  logic [31:0] destination_stride_bytes = 40; logic [5:0] valid_vector_bytes = 8;
  logic busy, done, fault;
  logic [3:0] bank_read_addr; logic bank_read_enable; logic [127:0] bank_read_data;
  logic [31:0] awaddr; logic [5:0] awid; logic [7:0] awlen; logic [2:0] awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot; logic [3:0] awqos, awregion; logic awvalid, awready = 1;
  logic [63:0] wdata; logic [7:0] wstrb; logic wlast, wvalid, wready = 1;
  logic [5:0] bid = 0; logic [1:0] bresp = 0; logic bvalid = 0, bready;
  logic [127:0] source [0:VECTOR_COUNT-1];
  integer aw_count = 0, w_count = 0, b_count = 0;
  always #5 clk = ~clk;

  gestureflow_hp0_tensor_writer #(.VECTOR_COUNT(VECTOR_COUNT), .VECTOR_ADDR_W(4)) dut (
    .clk, .rst_n, .start, .clear, .pool_2x2, .destination_addr, .byte_count, .vector_count, .input_width, .destination_stride_bytes, .valid_vector_bytes, .busy, .done, .fault,
    .bank_read_addr, .bank_read_enable, .bank_read_data, .vectors_written(), .bytes_written(),
    .m_axi_awaddr(awaddr), .m_axi_awid(awid), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awregion(awregion), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
  );

  always_ff @(posedge clk) begin
    if (bank_read_enable) bank_read_data <= source[bank_read_addr[2:0]];
    bvalid <= 1'b0;
    if (awvalid && awready) begin
      if (awaddr != 32'h00100020 + aw_count * 40 || awid != 0 || awlen != 0 || awsize != 3 || awburst != 1)
        $fatal(1, "bad pooled-tail AW addr=%08x count=%0d", awaddr, aw_count);
      aw_count <= aw_count + 1;
    end
    if (wvalid && wready) begin
      if (wstrb != 8'hff || !wlast || wdata !== source[w_count == 0 ? 3 : 7][63:0])
        $fatal(1, "bad pooled-tail W count=%0d strb=%02x data=%016x", w_count, wstrb, wdata);
      w_count <= w_count + 1;
      bvalid <= 1'b1;
    end
    if (bvalid && bready) b_count <= b_count + 1;
  end

  initial begin
    for (int vector = 0; vector < VECTOR_COUNT; vector++)
      for (int lane = 0; lane < 16; lane++)
        source[vector][lane*8 +: 8] = 8'(vector * 16 + lane);
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);
    destination_addr = 32'h00100020; byte_count = 16; start = 1; @(posedge clk); start = 0;
    repeat (1000) begin
      @(posedge clk);
      if (done) begin
        if (fault || aw_count != 2 || w_count != 2 || b_count != 2) $fatal(1, "pooled-tail completion mismatch");
        $display("GESTUREFLOW_HP0_TENSOR_WRITER_POOL_STRIDED_PASS outputs=2 stride=40 tail_bytes=8");
        $finish;
      end
    end
    $fatal(1, "pooled-tail writer timeout");
  end
endmodule
