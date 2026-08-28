// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// 64->18 INT8 FC classifier verified against the HaGRID-18 distilled student
// golden. GAP values and FC metadata are the TFLite golden vector exported by
// export_real_gap_fc.py; FC weights are read from fc.mem. Expected
// fc=0x22E52DDD / class=1.
`timescale 1ns/1ps
module tb_gestureflow_fc_classifier_hagrid18_real;
  localparam int GAP_LANES = 64;
  localparam int CLASSES = 18;

  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic gap_write_valid = 0;
  logic [$clog2(GAP_LANES)-1:0] gap_write_index = '0;
  logic signed [7:0] gap_write_data = '0;
  logic fc_weight_write_valid = 0;
  logic [$clog2(CLASSES)-1:0] fc_weight_write_class = '0;
  logic [$clog2(GAP_LANES/4)-1:0] fc_weight_write_group = '0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [CLASSES-1:0][31:0] fc_bias, fc_multiplier;
  logic [CLASSES-1:0][5:0] fc_right_shift;
  logic signed [7:0] fc_output_zero_point = -8'sd10;
  logic busy, done, fault;
  logic [31:0] fc_fnv1a;
  logic [$clog2(CLASSES)-1:0] predicted_class, fc_values_done;
  logic signed [CLASSES-1:0][7:0] fc_value;

  logic [7:0] fc_memory [0:CLASSES*GAP_LANES-1];
  logic signed [7:0] gap_golden [0:GAP_LANES-1];

  gestureflow_fc_classifier #(.GAP_LANES(GAP_LANES), .CLASSES(CLASSES), .FC_GROUPS(GAP_LANES/4)) dut (.*);

  always #5 clk = ~clk;

  initial begin
    string fc_path;
    if (!$value$plusargs("FC_MEM=%s", fc_path)) $fatal(1, "FC_MEM is required");
    $readmemh(fc_path, fc_memory);

    gap_golden = '{
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd118, -8'sd128, -8'sd128, -8'sd11,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd125, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd122, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd115, -8'sd128, -8'sd128
    };

    // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
    // Assign element-by-element, not as one packed aggregate. An aggregate
    // literal assigns its first element to the highest packed index, which
    // silently reverses the class order for a [17:0][31:0] packed array.
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

    repeat (4) @(posedge clk); rst_n = 1'b1;

    for (int i = 0; i < GAP_LANES; i++) begin
      @(negedge clk);
      gap_write_valid = 1'b1;
      gap_write_index = $clog2(GAP_LANES)'(i);
      gap_write_data = gap_golden[i];
    end
    @(negedge clk);
    gap_write_valid = 1'b0;

    for (int class_index = 0; class_index < CLASSES; class_index++) begin
      for (int group = 0; group < GAP_LANES/4; group++) begin
        @(negedge clk);
        fc_weight_write_valid = 1'b1;
        fc_weight_write_class = $clog2(CLASSES)'(class_index);
        fc_weight_write_group = $clog2(GAP_LANES/4)'(group);
        for (int lane = 0; lane < 4; lane++) begin
          fc_weight_write_data[lane] = fc_memory[class_index * GAP_LANES + group * 4 + lane];
        end
      end
    end
    @(negedge clk);
    fc_weight_write_valid = 1'b0;

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    repeat (4000) begin @(posedge clk); if (done || fault) break; end
    if (fault || !done) $fatal(1, "hagrid18 fc timeout/fault done=%b fault=%b", done, fault);
    if (int'(fc_values_done) != CLASSES || predicted_class != 1) $fatal(1, "hagrid18 fc progress/class wrong values=%0d class=%0d", fc_values_done, predicted_class);
    if (fc_fnv1a != 32'h22E52DDD) $fatal(1, "hagrid18 fc FNV wrong got=%08x expected=22E52DDD", fc_fnv1a);
    $display("GESTUREFLOW_FC_CLASSIFIER_HAGRID18_REAL_PASS fc=%08x class=%0d", fc_fnv1a, predicted_class);
    $finish;
  end
endmodule
