// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// The first burst ends exactly at a 4 KB boundary; no AXI burst may cross it.
`timescale 1ns/1ps
module tb_gestureflow_hp0_tensor_writer_boundary;
  localparam int VECTOR_COUNT = 5;
  logic clk=0, rst_n=0, start=0, clear=0, pool_2x2=0;
  logic [31:0] destination_addr=32'h00100fe0, byte_count=VECTOR_COUNT*16;
  logic [13:0] vector_count=14'(VECTOR_COUNT); logic [15:0] input_width=96;
  logic [31:0] destination_stride_bytes=0; logic [4:0] valid_vector_bytes=0;
  logic busy, done, fault;
  logic [2:0] bank_read_addr; logic bank_read_enable; logic [127:0] bank_read_data;
  logic [31:0] awaddr; logic [5:0] awid; logic [7:0] awlen; logic [2:0] awsize; logic [1:0] awburst;
  logic awlock; logic [3:0] awcache; logic [2:0] awprot; logic [3:0] awqos, awregion; logic awvalid, awready=1;
  logic [63:0] wdata; logic [7:0] wstrb; logic wlast, wvalid, wready=1;
  logic [5:0] bid=0; logic [1:0] bresp=0; logic bvalid=0, bready;
  logic [127:0] expected [0:VECTOR_COUNT-1];
  integer aw_count=0, w_count=0, b_count=0, burst_beats_seen=0;
  always #5 clk=~clk;

  gestureflow_hp0_tensor_writer #(.VECTOR_COUNT(VECTOR_COUNT), .VECTOR_ADDR_W(3)) dut (
    .clk,.rst_n,.start,.clear,.pool_2x2,.destination_addr,.byte_count,.vector_count,.input_width,
    .destination_stride_bytes,.valid_vector_bytes,.busy,.done,.fault,.bank_read_addr,.bank_read_enable,
    .bank_read_data,.vectors_written(),.bytes_written(),.m_axi_awaddr(awaddr),.m_axi_awid(awid),
    .m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awlock(awlock),
    .m_axi_awcache(awcache),.m_axi_awprot(awprot),.m_axi_awqos(awqos),.m_axi_awregion(awregion),
    .m_axi_awvalid(awvalid),.m_axi_awready(awready),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bid(bid),.m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),.m_axi_bready(bready)
  );

  always_ff @(posedge clk) begin
    if (bank_read_enable) bank_read_data <= expected[bank_read_addr];
    bvalid <= 1'b0;
    if (awvalid && awready) begin
      if (aw_count == 0) begin
        if (awaddr != 32'h00100fe0 || awlen != 8'd3) $fatal(1,"bad boundary first burst addr=%08x len=%0d",awaddr,awlen);
      end else if (aw_count == 1) begin
        if (awaddr != 32'h00101000 || awlen != 8'd5) $fatal(1,"bad boundary second burst addr=%08x len=%0d",awaddr,awlen);
      end else $fatal(1,"unexpected third burst");
      aw_count <= aw_count + 1;
      burst_beats_seen <= 0;
    end
    if (wvalid && wready) begin
      if (wstrb != 8'hff || wdata !== (w_count[0] ? expected[w_count/2][127:64] : expected[w_count/2][63:0]) ||
          wlast != ((aw_count == 1 && burst_beats_seen == 3) || (aw_count == 2 && burst_beats_seen == 5)))
        $fatal(1,"bad boundary W beat=%0d burstbeat=%0d last=%0b",w_count,burst_beats_seen,wlast);
      w_count <= w_count + 1;
      if (wlast) begin bvalid <= 1'b1; burst_beats_seen <= 0; end
      else burst_beats_seen <= burst_beats_seen + 1;
    end
    if (bvalid && bready) b_count <= b_count + 1;
  end

  initial begin
    for (int i=0; i<VECTOR_COUNT; i++) expected[i] = {64'hB000_0000_0000_0000 + 64'(i),64'hA000_0000_0000_0000 + 64'(i)};
    repeat(3) @(posedge clk); rst_n=1; @(posedge clk); start=1; @(posedge clk); start=0;
    repeat(1000) begin
      @(posedge clk);
      if (done) begin
        if (fault || aw_count != 2 || w_count != VECTOR_COUNT*2 || b_count != 2) $fatal(1,"boundary summary mismatch");
        $display("GESTUREFLOW_HP0_TENSOR_WRITER_BOUNDARY_PASS bursts=%0d beats=%0d",aw_count,w_count);
        $finish;
      end
    end
    $fatal(1,"boundary writer timeout");
  end
endmodule
