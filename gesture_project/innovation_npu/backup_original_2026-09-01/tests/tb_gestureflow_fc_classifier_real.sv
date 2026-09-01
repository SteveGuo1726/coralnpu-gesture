// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Reusable 112->6 FC classifier verified against the deployed model golden.
// The 112 GAP values are the TFLite golden vector, FC weights are read from
// the export tool's fc.mem, and the expected FNV/class are
// fc=0xDDE32561 / class=0.
`timescale 1ns/1ps
module tb_gestureflow_fc_classifier_real;
  localparam int GAP_LANES = 112;
  localparam int CLASSES = 6;

  logic clk = 0, rst_n = 0, start = 0, clear = 0;
  logic gap_write_valid = 0;
  logic [6:0] gap_write_index = '0;
  logic signed [7:0] gap_write_data = '0;
  logic fc_weight_write_valid = 0;
  logic [2:0] fc_weight_write_class = '0;
  logic [4:0] fc_weight_write_group = '0;
  logic signed [3:0][7:0] fc_weight_write_data = '0;
  logic signed [CLASSES-1:0][31:0] fc_bias, fc_multiplier;
  logic [CLASSES-1:0][5:0] fc_right_shift;
  logic signed [7:0] fc_output_zero_point = -8'sd6;
  logic busy, done, fault;
  logic [31:0] fc_fnv1a;
  logic [2:0] predicted_class, fc_values_done;
  logic signed [CLASSES-1:0][7:0] fc_value;

  logic [7:0] fc_memory [0:671];
  logic signed [7:0] gap_golden [0:GAP_LANES-1];

  gestureflow_fc_classifier #(.GAP_LANES(GAP_LANES), .CLASSES(CLASSES), .FC_GROUPS(GAP_LANES/4)) dut (.*);

  always #5 clk = ~clk;

  initial begin
    string fc_path;
    if (!$value$plusargs("FC_MEM=%s", fc_path)) $fatal(1, "FC_MEM is required");
    $readmemh(fc_path, fc_memory);

    gap_golden = '{
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd127, -8'sd128, -8'sd128, -8'sd128, -8'sd124, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd124, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd126, -8'sd128, -8'sd116, -8'sd128, -8'sd128, -8'sd125, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd125, -8'sd123,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128,  8'sd127, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd74,  -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd27,  -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd110, -8'sd123, -8'sd126, -8'sd128, -8'sd128,
      -8'sd122, -8'sd128, -8'sd128, -8'sd123, -8'sd128, -8'sd128, -8'sd128, -8'sd95,  -8'sd72,  -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd95,  -8'sd128, -8'sd128,
      -8'sd128, -8'sd128, -8'sd113, -8'sd128, -8'sd123, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd128, -8'sd124, -8'sd128, -8'sd128, -8'sd128
    };

    fc_bias[0] = -57642; fc_bias[1] = -120742; fc_bias[2] = -38881; fc_bias[3] = -33497; fc_bias[4] = -84369; fc_bias[5] = -95573;
    fc_multiplier[0] = 1083681381; fc_multiplier[1] = 1391943058; fc_multiplier[2] = 1082184949; fc_multiplier[3] = 1720878833; fc_multiplier[4] = 1079290077; fc_multiplier[5] = 1807948028;
    fc_right_shift[0] = 10; fc_right_shift[1] = 10; fc_right_shift[2] = 10; fc_right_shift[3] = 11; fc_right_shift[4] = 10; fc_right_shift[5] = 11;

    repeat (4) @(posedge clk); rst_n = 1'b1;

    for (int i = 0; i < GAP_LANES; i++) begin
      @(negedge clk);
      gap_write_valid = 1'b1;
      gap_write_index = 7'(i);
      gap_write_data = gap_golden[i];
    end
    @(negedge clk);
    gap_write_valid = 1'b0;

    for (int class_index = 0; class_index < CLASSES; class_index++) begin
      for (int group = 0; group < GAP_LANES/4; group++) begin
        @(negedge clk);
        fc_weight_write_valid = 1'b1;
        fc_weight_write_class = 3'(class_index);
        fc_weight_write_group = 5'(group);
        for (int lane = 0; lane < 4; lane++) begin
          fc_weight_write_data[lane] = fc_memory[class_index * 112 + group * 4 + lane];
        end
      end
    end
    @(negedge clk);
    fc_weight_write_valid = 1'b0;

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    repeat (2000) begin @(posedge clk); if (done || fault) break; end
    if (fault || !done) $fatal(1, "fc classifier real timeout/fault done=%b fault=%b", done, fault);
    if (fc_values_done != 6 || predicted_class != 0) $fatal(1, "fc classifier real progress/class wrong values=%0d class=%0d", fc_values_done, predicted_class);
    if (fc_fnv1a != 32'hDDE32561) $fatal(1, "fc classifier real FNV wrong got=%08x expected=DDE32561", fc_fnv1a);
    $display("GESTUREFLOW_FC_CLASSIFIER_REAL_PASS fc=%08x class=%0d", fc_fnv1a, predicted_class);
    $finish;
  end
endmodule
