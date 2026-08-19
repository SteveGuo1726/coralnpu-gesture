// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Real conv2_b needs 40 signed INT8 NHWC lanes per pixel. This verifies the
// HP0 reader preserves every byte and does not split a pixel at an AXI beat.
`timescale 1ns/1ps
module tb_gestureflow_hp0_tensor_loader_40;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, start = 0, clear = 0, pixel_ready = 1;
  logic [31:0] source_addr = 32'h00001000, byte_count = 120;
  logic [13:0] pixel_count = 3;
  logic busy, done, fault, frame_start, pixel_valid;
  logic signed [39:0][7:0] pixel_data;
  logic [13:0] pixels_emitted;
  logic [31:0] bytes_read;
  logic [31:0] araddr;
  logic [5:0] arid;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arlock;
  logic [3:0] arcache, arqos, arregion;
  logic [2:0] arprot;
  logic arvalid, arready;
  logic [5:0] rid = 0;
  logic [63:0] rdata;
  logic [1:0] rresp = 0;
  logic rlast, rvalid, rready;
  logic [31:0] response_addr;
  logic [5:0] response_beats;
  integer observed_pixels = 0;
  integer observed_frame_starts = 0;

  function automatic logic signed [7:0] source_byte(input integer offset);
    source_byte = 8'(offset - 60);
  endfunction

  function automatic logic [63:0] response_word(input logic [31:0] addr);
    logic [63:0] word;
    integer lane;
    begin
      word = '0;
      for (lane = 0; lane < 8; lane++) word[lane*8 +: 8] = source_byte(int'(addr) - 32'h1000 + lane);
      response_word = word;
    end
  endfunction

  assign arready = !rvalid;
  assign rlast = rvalid && (response_beats == 1);

  gestureflow_hp0_tensor_loader #(.CHANNELS(40)) dut (
    .clk, .rst_n, .start, .clear, .source_addr, .byte_count, .pixel_count,
    .busy, .done, .fault, .frame_start, .pixel_valid, .pixel_ready,
    .pixel_data, .pixels_emitted, .bytes_read,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
    .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arcache(arcache), .m_axi_arprot(arprot),
    .m_axi_arqos(arqos), .m_axi_arregion(arregion), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rvalid <= 0;
      rdata <= '0;
      response_addr <= '0;
      response_beats <= '0;
    end else begin
      if (arvalid && arready) begin
        rvalid <= 1;
        response_addr <= araddr;
        response_beats <= arlen[5:0] + 6'd1;
        rdata <= response_word(araddr);
      end else if (rvalid && rready) begin
        if (response_beats == 1) begin
          rvalid <= 0;
        end else begin
          response_addr <= response_addr + 8;
          response_beats <= response_beats - 1'b1;
          rdata <= response_word(response_addr + 8);
        end
      end
      if (frame_start) observed_frame_starts <= observed_frame_starts + 1;
      if (pixel_valid && pixel_ready) begin
        for (int channel = 0; channel < 40; channel++) begin
          if (pixel_data[channel] !== source_byte(observed_pixels * 40 + channel)) begin
            $fatal(1, "lane mismatch pixel=%0d channel=%0d expected=%0d got=%0d", observed_pixels, channel,
              source_byte(observed_pixels * 40 + channel), pixel_data[channel]);
          end
        end
        observed_pixels <= observed_pixels + 1;
      end
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk); start = 1;
    @(posedge clk); start = 0;
    repeat (600) begin
      @(posedge clk);
      if (done) begin
        if (fault || bytes_read != 120 || pixels_emitted != 3 || observed_pixels != 3 || observed_frame_starts != 1)
          $fatal(1, "loader summary fault=%0b bytes=%0d pixels=%0d observed=%0d frames=%0d", fault, bytes_read,
            pixels_emitted, observed_pixels, observed_frame_starts);
        $display("GESTUREFLOW_HP0_TENSOR_LOADER_40_PASS bytes=%0d pixels=%0d", bytes_read, pixels_emitted);
        $finish;
      end
    end
    $fatal(1, "40-channel loader timeout busy=%0b fault=%0b bytes=%0d pixels=%0d", busy, fault, bytes_read, pixels_emitted);
  end
endmodule
