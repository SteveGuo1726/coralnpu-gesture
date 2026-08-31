// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Temporal summary accumulator for dynamic-gesture recognition.
//
// The dynamic model (algorithms/temporal_cnn/gesture_temporal_model.py) runs the
// same spatial Conv/GAP tail as the static model on every frame, then reduces
// the per-frame GAP embedding across a sequence with a zero-MAC summary:
//   summary = concat(mean, max, last - first)
//
// This engine accumulates exactly those reductions on-chip, so the spatial
// accelerator can emit one CHANNELS-wide embedding per frame and this block
// retires a complete sequence summary without any DSP and without going back
// through DDR. The division-by-sequence-length of the mean is intentionally
// NOT done here; it folds into the downstream temporal-fusion requant
// multiplier (the same trick already used by the static GAP mean), so the
// accumulator itself stays pure integer add/compare.
//
// INPUT_W selects the per-channel embedding width (8 for int8 GAP output).
// All accumulators are INT32 so a long sequence cannot overflow a sum.
`timescale 1ns/1ps
module gestureflow_temporal_accumulator #(
  parameter int CHANNELS = 96,
  parameter int INPUT_W = 8
) (
  input  logic clk,
  input  logic rst_n,

  input  logic start,
  input  logic clear,

  input  logic frame_valid,
  output logic frame_ready,
  input  logic signed [CHANNELS-1:0][INPUT_W-1:0] frame_data,
  input  logic frame_last,

  output logic busy,
  output logic done,
  output logic [15:0] frame_count,
  output logic signed [CHANNELS-1:0][31:0] out_sum,
  output logic signed [CHANNELS-1:0][INPUT_W-1:0] out_max,
  output logic signed [CHANNELS-1:0][31:0] out_delta
);
  logic active;
  logic signed [CHANNELS-1:0][31:0] accum_sum;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] accum_max;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] first_value;
  logic [15:0] count_q;

  // Next-state values computed combinationally so the final frame is included
  // in the retired summary on the same clock edge it is accepted.
  logic signed [CHANNELS-1:0][31:0] frame_extended;
  logic signed [CHANNELS-1:0][31:0] next_sum;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] next_max;
  logic signed [CHANNELS-1:0][INPUT_W-1:0] next_first;

  always_comb begin
    for (int ch = 0; ch < CHANNELS; ch++) begin
      frame_extended[ch] = {{(32 - INPUT_W){frame_data[ch][INPUT_W-1]}}, frame_data[ch]};
      next_sum[ch] = accum_sum[ch] + frame_extended[ch];
      if (count_q == 0) begin
        next_max[ch] = frame_data[ch];
        next_first[ch] = frame_data[ch];
      end else begin
        next_max[ch] = (frame_data[ch] > accum_max[ch]) ? frame_data[ch] : accum_max[ch];
        next_first[ch] = first_value[ch];
      end
    end
  end

  assign busy = active;
  assign frame_ready = active;
  assign frame_count = count_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 1'b0;
      accum_sum <= '0;
      accum_max <= '0;
      first_value <= '0;
      count_q <= '0;
      out_sum <= '0;
      out_max <= '0;
      out_delta <= '0;
      done <= 1'b0;
    end else if (clear) begin
      active <= 1'b0;
      accum_sum <= '0;
      accum_max <= '0;
      first_value <= '0;
      count_q <= '0;
      done <= 1'b0;
    end else begin
      if (done) done <= 1'b0;
      if (start && !active) begin
        active <= 1'b1;
        accum_sum <= '0;
        accum_max <= '0;
        first_value <= '0;
        count_q <= '0;
      end
      if (active && frame_valid && frame_ready) begin
        accum_sum <= next_sum;
        accum_max <= next_max;
        first_value <= next_first;
        count_q <= count_q + 1'b1;
        if (frame_last) begin
          active <= 1'b0;
          done <= 1'b1;
          out_sum <= next_sum;
          out_max <= next_max;
          for (int ch = 0; ch < CHANNELS; ch++) begin
            out_delta[ch] <=
              {{(32 - INPUT_W){frame_data[ch][INPUT_W-1]}}, frame_data[ch]} -
              {{(32 - INPUT_W){next_first[ch][INPUT_W-1]}}, next_first[ch]};
          end
        end
      end
    end
  end
endmodule
