// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Exact deterministic q27 / q28 / q29 regression exported from the current
// deployment model. The test uses an AXI read responder, not an internal
// bypass, so the postprocess HP0 reader is covered too.
`timescale 1ns/1ps
module tb_gestureflow_hp0_gap_fc_real;
  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic [31:0] source_addr = 32'h1000, byte_count = 32'(144 * 112);
  logic [13:0] pixel_count = 144;
  logic signed [31:0] gap_multiplier = 32'sd1161448398;
  logic [5:0] gap_right_shift = 1;
  logic signed [7:0] gap_input_zero_point = -8'sd128, gap_output_zero_point = -8'sd128, fc_output_zero_point = -8'sd6;
  logic fc_weight_write_valid = 0; logic [2:0] fc_weight_write_class = 0; logic [4:0] fc_weight_write_group = 0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [5:0][31:0] fc_bias, fc_multiplier; logic [5:0][5:0] fc_right_shift;
  logic busy, done, fault; logic [31:0] cycles, gap_fnv1a, fc_fnv1a; logic [2:0] predicted_class, fc_values_done; logic [6:0] gap_values_done;
  logic signed [31:0] debug_gap_sum0, debug_gap_sum6;
  logic signed [5:0][7:0] debug_fc_value;
  logic [31:0] araddr; logic [5:0] arid; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot; logic [3:0] arqos, arregion; logic arvalid, arready = 1;
  logic [5:0] rid = 0; logic [63:0] rdata; logic [1:0] rresp = 0; logic rlast, rvalid, rready;
  logic [5:0] response_left; logic [31:0] response_addr;
  logic [7:0] head_memory [0:16127]; logic [7:0] fc_memory [0:671];
  logic first_loader_pixel_seen;
  logic signed [111:0][7:0] first_loader_pixel;

  always #5 clk = ~clk;
  always_ff @(posedge clk) begin
    if (!rst_n) begin response_left <= 0; response_addr <= 0; end
    else if (arvalid && arready) begin response_left <= 6'(arlen + 1'b1); response_addr <= araddr; end
    else if (rvalid && rready) begin response_left <= response_left - 1'b1; response_addr <= response_addr + 8; end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) first_loader_pixel_seen <= 0;
    else if (!first_loader_pixel_seen && dut.loader_pixel_valid && dut.loader_pixel_ready) begin
      first_loader_pixel_seen <= 1;
      first_loader_pixel <= dut.loader_pixel;
    end
  end
  always_comb for (int byte_index = 0; byte_index < 8; byte_index++) rdata[byte_index*8 +: 8] = head_memory[response_addr - source_addr + byte_index];
  assign rvalid = response_left != 0;
  assign rlast = response_left == 1;

  gestureflow_hp0_gap_fc dut (.*,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  initial begin
    string head_path, fc_path;
    if (!$value$plusargs("HEAD_MEM=%s", head_path) || !$value$plusargs("FC_MEM=%s", fc_path)) $fatal(1, "HEAD_MEM and FC_MEM are required");
    $readmemh(head_path, head_memory); $readmemh(fc_path, fc_memory);
    fc_bias[0] = -57642; fc_bias[1] = -120742; fc_bias[2] = -38881; fc_bias[3] = -33497; fc_bias[4] = -84369; fc_bias[5] = -95573;
    fc_multiplier[0] = 1083681381; fc_multiplier[1] = 1391943058; fc_multiplier[2] = 1082184949; fc_multiplier[3] = 1720878833; fc_multiplier[4] = 1079290077; fc_multiplier[5] = 1807948028;
    fc_right_shift[0] = 10; fc_right_shift[1] = 10; fc_right_shift[2] = 10; fc_right_shift[3] = 11; fc_right_shift[4] = 10; fc_right_shift[5] = 11;
    repeat (4) @(posedge clk); rst_n = 1;
    for (int class_index = 0; class_index < 6; class_index++) for (int group = 0; group < 28; group++) begin
      @(negedge clk); fc_weight_write_valid = 1; fc_weight_write_class = class_index; fc_weight_write_group = group;
      for (int lane = 0; lane < 4; lane++) fc_weight_write_data[lane] = fc_memory[class_index * 112 + group * 4 + lane];
    end
    @(negedge clk); fc_weight_write_valid = 0; start = 1;
    @(negedge clk); start = 0;
    repeat (7000) begin @(posedge clk); if (done || fault) break; end
    if (fault || !done) $fatal(1, "real postprocess timeout/fault done=%0b fault=%0b cycles=%0d", done, fault, cycles);
    if (gap_values_done != 112 || fc_values_done != 6 || predicted_class != 0) $fatal(1, "real postprocess progress/class wrong gap=%0d fc=%0d class=%0d", gap_values_done, fc_values_done, predicted_class);
    if (!first_loader_pixel_seen) $fatal(1, "real postprocess emitted no loader pixel");
    for (int channel = 0; channel < 112; channel++) begin
      if (first_loader_pixel[channel] != head_memory[channel])
        $fatal(1, "first loader vector mismatch channel=%0d observed=%0d expected=%0d", channel, first_loader_pixel[channel], head_memory[channel]);
    end
    if (debug_gap_sum0 != -18432 || debug_gap_sum6 != -18429) $fatal(1, "real postprocess sums wrong sum0=%0d sum6=%0d", debug_gap_sum0, debug_gap_sum6);
    if (gap_fnv1a != 32'hABBC5831 || fc_fnv1a != 32'hDDE32561) $fatal(1, "real postprocess FNV wrong gap=%08x fc=%08x", gap_fnv1a, fc_fnv1a);
    $display("GESTUREFLOW_HP0_GAP_FC_REAL_PASS cycles=%0d gap=%08x fc=%08x class=%0d", cycles, gap_fnv1a, fc_fnv1a, predicted_class);
    $finish;
  end
endmodule
