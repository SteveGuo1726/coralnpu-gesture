// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps
module tb_gestureflow_hp0_gap_fc;
  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic [31:0] source_addr = 32'h1000, byte_count = 32'(144 * 112);
  logic [13:0] pixel_count = 144;
  logic signed [31:0] gap_multiplier = 32'sh40000000;
  logic [5:0] gap_right_shift = 0;
  logic signed [7:0] gap_input_zero_point = -8'sd128, gap_output_zero_point = -8'sd128, fc_output_zero_point = 0;
  logic fc_weight_write_valid = 0;
  logic [2:0] fc_weight_write_class = 0;
  logic [4:0] fc_weight_write_group = 0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [5:0][31:0] fc_bias = '0, fc_multiplier = '0;
  logic [5:0][5:0] fc_right_shift = '0;
  logic busy, done, fault; logic [31:0] cycles, gap_fnv1a, fc_fnv1a; logic [2:0] predicted_class, fc_values_done; logic [6:0] gap_values_done;
  logic [31:0] araddr; logic [5:0] arid; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot; logic [3:0] arqos, arregion; logic arvalid, arready = 1;
  logic [5:0] rid = 0; logic [63:0] rdata = 64'h8080808080808080; logic [1:0] rresp = 0; logic rlast, rvalid, rready;
  logic [5:0] response_left;

  always #5 clk = ~clk;
  always_ff @(posedge clk) begin
    if (!rst_n) begin response_left <= 0; end
    else begin
      if (arvalid && arready) response_left <= 6'(arlen + 1'b1);
      else if (rvalid && rready) response_left <= response_left - 1'b1;
    end
  end
  assign rvalid = response_left != 0;
  assign rlast = response_left == 1;

  function automatic logic [31:0] fnv_repeat(input logic [7:0] byte_value, input int count);
    logic [31:0] value; begin value = 32'h811c9dc5; for (int index = 0; index < count; index++) value = (value ^ {24'd0, byte_value}) * 32'h01000193; fnv_repeat = value; end
  endfunction

  gestureflow_hp0_gap_fc dut (.*,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  initial begin
    repeat (4) @(posedge clk); rst_n = 1;
    @(posedge clk); start = 1;
    @(posedge clk); start = 0;
    repeat (6000) begin
      @(posedge clk);
      if (done || fault) break;
    end
    if (fault || !done) $fatal(1, "postprocess timeout/fault done=%0b fault=%0b cycles=%0d", done, fault, cycles);
    if (gap_values_done != 112 || fc_values_done != 6 || predicted_class != 0) $fatal(1, "postprocess progress/class wrong gap=%0d fc=%0d class=%0d", gap_values_done, fc_values_done, predicted_class);
    if (gap_fnv1a != fnv_repeat(8'h80, 112)) $fatal(1, "GAP FNV wrong %08x", gap_fnv1a);
    if (fc_fnv1a != fnv_repeat(8'h00, 6)) $fatal(1, "FC FNV wrong %08x", fc_fnv1a);
    $display("GESTUREFLOW_HP0_GAP_FC_PASS cycles=%0d gap=%08x fc=%08x", cycles, gap_fnv1a, fc_fnv1a);
    $finish;
  end
endmodule
