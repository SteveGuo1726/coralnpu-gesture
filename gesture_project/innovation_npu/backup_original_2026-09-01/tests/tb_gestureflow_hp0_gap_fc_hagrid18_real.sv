// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Exact deterministic q27/q28/q29 regression for the HaGRID-18 distilled
// student (12x12x64 head, 64-wide GAP, 64->18 FC). Uses an AXI read
// responder, not an internal bypass, so the HP0 reader is covered too.
`timescale 1ns/1ps
module tb_gestureflow_hp0_gap_fc_hagrid18_real;
  localparam int CHANNELS = 64;
  localparam int CLASSES = 18;
  localparam int ELEMENTS = 144;

  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic [31:0] source_addr = 32'h1000, byte_count = 32'(ELEMENTS * CHANNELS);
  logic [13:0] pixel_count = 14'(ELEMENTS);
  logic signed [31:0] gap_multiplier = 32'sd1339606099;
  logic [5:0] gap_right_shift = 1;
  logic signed [7:0] gap_input_zero_point = -8'sd128, gap_output_zero_point = -8'sd128, fc_output_zero_point = -8'sd10;
  logic fc_weight_write_valid = 0; logic [$clog2(CLASSES)-1:0] fc_weight_write_class = 0; logic [$clog2(CHANNELS/4)-1:0] fc_weight_write_group = 0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [CLASSES-1:0][31:0] fc_bias, fc_multiplier; logic [CLASSES-1:0][5:0] fc_right_shift;
  logic busy, done, fault; logic [31:0] cycles, gap_fnv1a, fc_fnv1a;
  logic [$clog2(CLASSES)-1:0] predicted_class; logic [$clog2(CLASSES+1)-1:0] fc_values_done; logic [$clog2(CHANNELS+1)-1:0] gap_values_done;
  logic signed [31:0] debug_gap_sum0, debug_gap_sum6;
  logic signed [CLASSES-1:0][7:0] debug_fc_value;
  logic [31:0] araddr; logic [5:0] arid; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot; logic [3:0] arqos, arregion; logic arvalid, arready = 1;
  logic [5:0] rid = 0; logic [63:0] rdata; logic [1:0] rresp = 0; logic rlast, rvalid, rready;
  logic [5:0] response_left; logic [31:0] response_addr;
  logic [7:0] head_memory [0:ELEMENTS*CHANNELS-1]; logic [7:0] fc_memory [0:CLASSES*CHANNELS-1];
  logic first_loader_pixel_seen;
  logic signed [CHANNELS-1:0][7:0] first_loader_pixel;

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

  gestureflow_hp0_gap_fc #(.CHANNELS(CHANNELS), .CLASSES(CLASSES), .ELEMENTS(ELEMENTS), .FC_GROUPS(CHANNELS/4)) dut (.*,
    .m_axi_araddr(araddr), .m_axi_arid(arid), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  initial begin
    string head_path, fc_path;
    if (!$value$plusargs("HEAD_MEM=%s", head_path) || !$value$plusargs("FC_MEM=%s", fc_path)) $fatal(1, "HEAD_MEM and FC_MEM are required");
    $readmemh(head_path, head_memory); $readmemh(fc_path, fc_memory);
    // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
    // Assign element-by-element: a packed aggregate literal would reverse the
    // class order for a [17:0][31:0] packed array.
    fc_bias[0] = -32'sd259612; fc_bias[1] = -32'sd308318; fc_bias[2] = -32'sd307800; fc_bias[3] = -32'sd192215;
    fc_bias[4] = -32'sd246396; fc_bias[5] = -32'sd237285; fc_bias[6] = -32'sd231845; fc_bias[7] = -32'sd237584;
    fc_bias[8] = -32'sd231006; fc_bias[9] = -32'sd200666; fc_bias[10] = -32'sd222390; fc_bias[11] = -32'sd169312;
    fc_bias[12] = -32'sd208608; fc_bias[13] = -32'sd288502; fc_bias[14] = -32'sd223774; fc_bias[15] = -32'sd200223;
    fc_bias[16] = -32'sd153476; fc_bias[17] = -32'sd201918;
    fc_multiplier[0] = 32'sd1118501485; fc_multiplier[1] = 32'sd1993428563; fc_multiplier[2] = 32'sd1805385203; fc_multiplier[3] = 32'sd1095876951;
    fc_multiplier[4] = 32'sd2131823165; fc_multiplier[5] = 32'sd2032579994; fc_multiplier[6] = 32'sd1999131911; fc_multiplier[7] = 32'sd1340506307;
    fc_multiplier[8] = 32'sd1895092858; fc_multiplier[9] = 32'sd1095984626; fc_multiplier[10] = 32'sd2079881491; fc_multiplier[11] = 32'sd2024666747;
    fc_multiplier[12] = 32'sd1963017547; fc_multiplier[13] = 32'sd1717065443; fc_multiplier[14] = 32'sd2120724891; fc_multiplier[15] = 32'sd1960630339;
    fc_multiplier[16] = 32'sd1086290076; fc_multiplier[17] = 32'sd1261143672;
    fc_right_shift[0] = 6'd9; fc_right_shift[1] = 6'd10; fc_right_shift[2] = 6'd10; fc_right_shift[3] = 6'd9;
    fc_right_shift[4] = 6'd10; fc_right_shift[5] = 6'd10; fc_right_shift[6] = 6'd10; fc_right_shift[7] = 6'd9;
    fc_right_shift[8] = 6'd10; fc_right_shift[9] = 6'd9; fc_right_shift[10] = 6'd10; fc_right_shift[11] = 6'd10;
    fc_right_shift[12] = 6'd10; fc_right_shift[13] = 6'd10; fc_right_shift[14] = 6'd10; fc_right_shift[15] = 6'd10;
    fc_right_shift[16] = 6'd9; fc_right_shift[17] = 6'd9;
    repeat (4) @(posedge clk); rst_n = 1;
    for (int class_index = 0; class_index < CLASSES; class_index++) for (int group = 0; group < CHANNELS/4; group++) begin
      @(negedge clk); fc_weight_write_valid = 1; fc_weight_write_class = $clog2(CLASSES)'(class_index); fc_weight_write_group = $clog2(CHANNELS/4)'(group);
      for (int lane = 0; lane < 4; lane++) fc_weight_write_data[lane] = fc_memory[class_index * CHANNELS + group * 4 + lane];
    end
    @(negedge clk); fc_weight_write_valid = 0; start = 1;
    @(negedge clk); start = 0;
    repeat (7000) begin @(posedge clk); if (done || fault) break; end
    if (fault || !done) $fatal(1, "hagrid18 postprocess timeout/fault done=%0b fault=%0b cycles=%0d", done, fault, cycles);
    if (int'(gap_values_done) != CHANNELS || int'(fc_values_done) != CLASSES || predicted_class != 1) $fatal(1, "hagrid18 postprocess progress/class wrong gap=%0d fc=%0d class=%0d", gap_values_done, fc_values_done, predicted_class);
    if (!first_loader_pixel_seen) $fatal(1, "hagrid18 postprocess emitted no loader pixel");
    for (int channel = 0; channel < CHANNELS; channel++) begin
      if (first_loader_pixel[channel] != head_memory[channel])
        $fatal(1, "hagrid18 first loader vector mismatch channel=%0d observed=%0d expected=%0d", channel, first_loader_pixel[channel], head_memory[channel]);
    end
    if (debug_gap_sum0 != -18432 || debug_gap_sum6 != -18432) $fatal(1, "hagrid18 postprocess sums wrong sum0=%0d sum6=%0d", debug_gap_sum0, debug_gap_sum6);
    if (gap_fnv1a != 32'hF109A7AE || fc_fnv1a != 32'h22E52DDD) $fatal(1, "hagrid18 postprocess FNV wrong gap=%08x fc=%08x", gap_fnv1a, fc_fnv1a);
    $display("GESTUREFLOW_HP0_GAP_FC_HAGRID18_REAL_PASS cycles=%0d gap=%08x fc=%08x class=%0d", cycles, gap_fnv1a, fc_fnv1a, predicted_class);
    $finish;
  end
endmodule
