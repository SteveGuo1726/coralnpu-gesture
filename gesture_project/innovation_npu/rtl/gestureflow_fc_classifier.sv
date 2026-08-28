// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Reusable GAP_LANES->CLASSES INT8 fully-connected classifier. It mirrors the FC portion
// of gestureflow_hp0_gap_fc exactly (folded bias + four-lane time-shared MAC
// + LiteRT requantization + FNV hash + argmax), but takes the 112 GAP values
// through a small write port instead of a DDR loader. This is the classifier
// half of the reduce/classify backend used by the on-chip head1x1->GAP->FC
// tail.
`timescale 1ns/1ps
module gestureflow_fc_classifier #(
  parameter int GAP_LANES = 112,
  parameter int CLASSES = 6,
  parameter int FC_GROUPS = GAP_LANES / 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear,
  input  logic gap_write_valid,
  input  logic [$clog2(GAP_LANES)-1:0] gap_write_index,
  input  logic signed [7:0] gap_write_data,
  input  logic fc_weight_write_valid,
  input  logic [$clog2(CLASSES)-1:0] fc_weight_write_class,
  input  logic [$clog2(FC_GROUPS)-1:0] fc_weight_write_group,
  input  logic signed [3:0][7:0] fc_weight_write_data,
  input  logic signed [CLASSES-1:0][31:0] fc_bias,
  input  logic signed [CLASSES-1:0][31:0] fc_multiplier,
  input  logic [CLASSES-1:0][5:0] fc_right_shift,
  input  logic signed [7:0] fc_output_zero_point,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [31:0] fc_fnv1a,
  output logic [$clog2(CLASSES)-1:0] predicted_class,
  output logic signed [CLASSES-1:0][7:0] fc_value,
  output logic [$clog2(CLASSES+1)-1:0] fc_values_done
);
  localparam logic [31:0] FNV_OFFSET = 32'h811c9dc5;
  localparam logic [31:0] FNV_PRIME = 32'h01000193;

  typedef enum logic [2:0] {IDLE, FC_INIT, FC_ACC, FC_QUANT, FC_HASH} state_t;
  state_t state;
  logic signed [7:0] gap_value [0:GAP_LANES-1];
  logic signed [7:0] fc_weight [0:CLASSES-1][0:FC_GROUPS-1][0:3];
  logic signed [CLASSES-1:0][31:0] fc_sum;
  logic signed [CLASSES-1:0][7:0] fc_value_reg;
  logic [$clog2(FC_GROUPS)-1:0] fc_group;
  logic [$clog2(CLASSES)-1:0] fc_class;
  logic [$clog2(CLASSES)-1:0] fc_index;
  logic [31:0] fc_hash_work;
  logic signed [7:0] fc_requant_value;

  function automatic logic [31:0] fnv_step(input logic [31:0] current, input logic [7:0] byte_value);
    fnv_step = (current ^ {24'd0, byte_value}) * FNV_PRIME;
  endfunction

  function automatic logic signed [31:0] trunc_shift31(input logic signed [63:0] value);
    logic signed [63:0] magnitude;
    begin
      if (value < 0) begin magnitude = -value; trunc_shift31 = -$signed(magnitude[62:31]); end
      else trunc_shift31 = $signed(value[62:31]);
    end
  endfunction

  function automatic logic signed [31:0] high_mul(input logic signed [31:0] left, input logic signed [31:0] right);
    logic signed [63:0] product, nudge;
    begin
      if ((left == 32'sh80000000) && (right == 32'sh80000000)) high_mul = 32'sh7fffffff;
      else begin
        product = left * right;
        nudge = product >= 0 ? 64'sh0000000040000000 : -64'sh000000003fffffff;
        high_mul = trunc_shift31(product + nudge);
      end
    end
  endfunction

  function automatic logic signed [31:0] round_div_pot(input logic signed [31:0] value, input logic [5:0] shift);
    logic [31:0] mask, remainder, threshold;
    logic signed [31:0] base;
    begin
      if (shift == 0) round_div_pot = value;
      else begin
        mask = (32'h1 << shift) - 1'b1;
        remainder = value & mask;
        threshold = (mask >> 1) + (value < 0 ? 1 : 0);
        base = value >>> shift;
        round_div_pot = remainder > threshold ? base + 1 : base;
      end
    end
  endfunction

  function automatic logic signed [7:0] requantize(
    input logic signed [31:0] accumulator,
    input logic signed [31:0] multiplier,
    input logic [5:0] right_shift,
    input logic signed [7:0] zero_point
  );
    logic signed [31:0] result, with_zero_point;
    begin
      result = round_div_pot(high_mul(accumulator, multiplier), right_shift);
      with_zero_point = result + {{24{zero_point[7]}}, zero_point};
      if (with_zero_point > 127) requantize = 8'sh7f;
      else if (with_zero_point < -128) requantize = -8'sh80;
      else requantize = with_zero_point[7:0];
    end
  endfunction

  function automatic logic signed [31:0] int8_product(input logic signed [7:0] left, input logic signed [7:0] right);
    logic signed [15:0] product;
    begin
      product = left * right;
      int8_product = {{16{product[15]}}, product};
    end
  endfunction

  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Parameterized argmax so CLASSES is no longer pinned to six. The strict
  // greater-than keeps the lowest index on ties, matching the software argmax.
  function automatic logic [$clog2(CLASSES)-1:0] argmax_n(
    input logic signed [CLASSES-1:0][7:0] values
  );
    logic signed [7:0] best_value;
    logic [$clog2(CLASSES)-1:0] best_index;
    begin
      best_value = $signed(values[0]);
      best_index = '0;
      for (int index = 1; index < CLASSES; index++) begin
        if ($signed(values[index]) > best_value) begin
          best_value = $signed(values[index]);
          best_index = index[$clog2(CLASSES)-1:0];
        end
      end
      argmax_n = best_index;
    end
  endfunction

  assign busy = (state != IDLE);
  assign fc_value = fc_value_reg;
  assign fc_requant_value = requantize(fc_sum[fc_index], fc_multiplier[fc_index], fc_right_shift[fc_index], fc_output_zero_point);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE; done <= 1'b0; fault <= 1'b0;
      fc_sum <= '0; fc_value_reg <= '0; fc_group <= '0; fc_class <= '0; fc_index <= '0;
      fc_hash_work <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET; predicted_class <= '0; fc_values_done <= '0;
    end else begin
      done <= 1'b0;
      if (gap_write_valid && (int'(gap_write_index) < GAP_LANES)) begin
        gap_value[gap_write_index] <= gap_write_data;
      end
      if (fc_weight_write_valid && (int'(fc_weight_write_class) < CLASSES) && (int'(fc_weight_write_group) < FC_GROUPS)) begin
        for (int lane = 0; lane < 4; lane++) fc_weight[fc_weight_write_class][fc_weight_write_group][lane] <= fc_weight_write_data[lane];
      end
      if (clear) begin
        state <= IDLE; done <= 1'b0; fault <= 1'b0;
        fc_sum <= '0; fc_value_reg <= '0; fc_group <= '0; fc_class <= '0; fc_index <= '0;
        fc_hash_work <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET; predicted_class <= '0; fc_values_done <= '0;
      end else begin
        case (state)
          IDLE: if (start) begin
            done <= 1'b0; fault <= 1'b0; fc_sum <= fc_bias; fc_group <= '0; fc_class <= '0; fc_index <= '0;
            fc_hash_work <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET; predicted_class <= '0; fc_values_done <= '0;
            state <= FC_ACC;
          end
          FC_ACC: begin
            fc_sum[fc_class] <= $signed(fc_sum[fc_class])
              + int8_product($signed(gap_value[fc_group*4]),   $signed(fc_weight[fc_class][fc_group][0]))
              + int8_product($signed(gap_value[fc_group*4+1]), $signed(fc_weight[fc_class][fc_group][1]))
              + int8_product($signed(gap_value[fc_group*4+2]), $signed(fc_weight[fc_class][fc_group][2]))
              + int8_product($signed(gap_value[fc_group*4+3]), $signed(fc_weight[fc_class][fc_group][3]));
            if (fc_group == $clog2(FC_GROUPS)'(FC_GROUPS-1)) begin
              if (fc_class == $clog2(CLASSES)'(CLASSES-1)) begin fc_index <= '0; state <= FC_QUANT; end
              else begin fc_class <= fc_class + 1'b1; fc_group <= '0; end
            end else fc_group <= fc_group + 1'b1;
          end
          FC_QUANT: begin
            fc_value_reg[fc_index] <= fc_requant_value;
            if (fc_index == $clog2(CLASSES)'(CLASSES-1)) begin
              fc_index <= '0;
              fc_hash_work <= FNV_OFFSET;
              state <= FC_HASH;
            end else fc_index <= fc_index + 1'b1;
          end
          FC_HASH: begin
            fc_hash_work <= fnv_step(fc_hash_work, fc_value_reg[fc_index]);
            fc_values_done <= fc_index + 1'b1;
            if (fc_index == $clog2(CLASSES)'(CLASSES-1)) begin
              fc_fnv1a <= fnv_step(fc_hash_work, fc_value_reg[fc_index]);
              predicted_class <= argmax_n(fc_value_reg);
              done <= 1'b1;
              state <= IDLE;
            end else fc_index <= fc_index + 1'b1;
          end
          default: begin fault <= 1'b1; state <= IDLE; end
        endcase
      end
    end
  end
endmodule
