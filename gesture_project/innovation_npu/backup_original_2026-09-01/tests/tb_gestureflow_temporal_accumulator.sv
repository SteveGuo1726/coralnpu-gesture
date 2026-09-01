// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
`timescale 1ns/1ps

module tb_gestureflow_temporal_accumulator;
  localparam int CHANNELS = 4;
  localparam int INPUT_W = 8;
  localparam int FRAMES = 4;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic start = 1'b0;
  logic clear = 1'b0;
  logic frame_valid = 1'b0;
  logic frame_ready;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] frame_data = '0;
  logic frame_last = 1'b0;
  logic busy;
  logic done;
  logic [15:0] frame_count;
  logic signed [CHANNELS-1:0][31:0] out_sum;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] out_max;
  logic signed [CHANNELS-1:0][31:0] out_delta;

  logic signed [FRAMES-1:0][CHANNELS-1:0][INPUT_W-1:0] seq;
  logic signed [CHANNELS-1:0][31:0] exp_sum;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] exp_max;
  logic signed [CHANNELS-1:0][31:0] exp_delta;

  gestureflow_temporal_accumulator #(.CHANNELS(CHANNELS), .INPUT_W(INPUT_W)) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .clear(clear),
    .frame_valid(frame_valid), .frame_ready(frame_ready), .frame_data(frame_data),
    .frame_last(frame_last), .busy(busy), .done(done), .frame_count(frame_count),
    .out_sum(out_sum), .out_max(out_max), .out_delta(out_delta)
  );

  always #5 clk = ~clk;

  int errors = 0;
  int timeout = 0;

  task automatic check(string name, int got, int want);
    if (got !== want) begin
      $display("FAIL %s: got=%0d want=%0d", name, got, want);
      errors++;
    end
  endtask

  initial begin
    seq[0] = '{8'sd1, -8'sd2, 8'sd5, 8'sd10};
    seq[1] = '{8'sd3, 8'sd4, -8'sd1, 8'sd20};
    seq[2] = '{-8'sd5, 8'sd6, 8'sd7, 8'sd0};
    seq[3] = '{8'sd2, 8'sd8, 8'sd3, -8'sd10};

    exp_sum   = '{32'sd1, 32'sd16, 32'sd14, 32'sd20};
    exp_max   = '{8'sd3, 8'sd8, 8'sd7, 8'sd20};
    exp_delta = '{32'sd1, 32'sd10, -32'sd2, -32'sd20};

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Start a new sequence; active asserts on the following clock edge.
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    @(posedge clk);

    // Drive one frame per cycle, holding frame_valid for exactly one cycle.
    for (int i = 0; i < FRAMES; i++) begin
      frame_valid = 1'b1;
      frame_data = seq[i];
      frame_last = (i == FRAMES - 1);
      @(posedge clk);
      frame_valid = 1'b0;
    end

    // done asserts for one cycle; capture the retired outputs before it clears.
    timeout = 0;
    while (!done && timeout < 100) begin
      @(posedge clk);
      timeout++;
    end
    if (!done) begin
      $display("FAIL timeout waiting for done");
      errors++;
    end else begin
      check("frame_count", int'(frame_count), FRAMES);
      for (int ch = 0; ch < CHANNELS; ch++) begin
        check($sformatf("sum[%0d]", ch), int'(out_sum[ch]), int'(exp_sum[ch]));
        check($sformatf("max[%0d]", ch), int'(out_max[ch]), int'(exp_max[ch]));
        check($sformatf("delta[%0d]", ch), int'(out_delta[ch]), int'(exp_delta[ch]));
      end
    end

    if (errors == 0) $display("TEMPORAL_ACCUMULATOR_PASS frames=%0d", frame_count);
    else $display("TEMPORAL_ACCUMULATOR_FAIL errors=%0d", errors);
    $finish;
  end
endmodule
