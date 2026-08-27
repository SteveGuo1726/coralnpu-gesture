// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Quantized postprocess engine for the deployed GestureFlow static CNN.
// It fetches the 12x12x112 head tensor from DDR through HP0, retains all
// 112 INT32 GAP sums locally, follows LiteRT's integer Mean scaling exactly,
// then executes the 112x6 classifier with six x four INT8 MAC lanes. No GAP
// or FC partial result is written to DDR and ARM only loads descriptors.
`timescale 1ns/1ps
module gestureflow_hp0_gap_fc (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic [31:0] source_addr,
  input logic [31:0] byte_count,
  input logic [13:0] pixel_count,
  input logic signed [31:0] gap_multiplier,
  input logic [5:0] gap_right_shift,
  input logic signed [7:0] gap_input_zero_point,
  input logic signed [7:0] gap_output_zero_point,
  input logic signed [7:0] fc_output_zero_point,
  input logic fc_weight_write_valid,
  input logic [2:0] fc_weight_write_class,
  input logic [4:0] fc_weight_write_group,
  input logic signed [3:0][7:0] fc_weight_write_data,
  input logic signed [5:0][31:0] fc_bias,
  input logic signed [5:0][31:0] fc_multiplier,
  input logic [5:0][5:0] fc_right_shift,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [31:0] cycles,
  output logic [31:0] gap_fnv1a,
  output logic [31:0] fc_fnv1a,
  output logic [2:0] predicted_class,
  output logic [6:0] gap_values_done,
  output logic [2:0] fc_values_done,
  output logic signed [31:0] debug_gap_sum0,
  output logic signed [31:0] debug_gap_sum6,
  output logic signed [5:0][7:0] debug_fc_value,

  output logic [31:0] m_axi_araddr,
  output logic [5:0] m_axi_arid,
  output logic [7:0] m_axi_arlen,
  output logic [2:0] m_axi_arsize,
  output logic [1:0] m_axi_arburst,
  output logic m_axi_arlock,
  output logic [3:0] m_axi_arcache,
  output logic [2:0] m_axi_arprot,
  output logic [3:0] m_axi_arqos,
  output logic [3:0] m_axi_arregion,
  output logic m_axi_arvalid,
  input wire m_axi_arready,
  input wire [5:0] m_axi_rid,
  input wire [63:0] m_axi_rdata,
  input wire [1:0] m_axi_rresp,
  input wire m_axi_rlast,
  input wire m_axi_rvalid,
  output logic m_axi_rready
);
  localparam int CHANNELS = 112;
  localparam int ELEMENTS = 144;
  localparam logic signed [31:0] GAP_ELEMENTS = 32'sd144;
  localparam logic [31:0] FNV_OFFSET = 32'h811c9dc5;
  localparam logic [31:0] FNV_PRIME = 32'h01000193;

  typedef enum logic [3:0] {
    IDLE, LOAD, GAP_MUL, GAP_QUANT, GAP_HASH, FC_INIT, FC_ACC, FC_MUL, FC_QUANT, FC_HASH
  } state_t;
  state_t state;
  logic loader_start, loader_clear, loader_busy, loader_done, loader_fault;
  logic loader_frame_start, loader_pixel_valid, loader_pixel_ready;
  logic signed [CHANNELS-1:0][7:0] loader_pixel;
  logic [13:0] loader_pixels_emitted;
  logic [31:0] loader_bytes_read;
  logic signed [CHANNELS-1:0][31:0] gap_sum;
  logic signed [CHANNELS-1:0][7:0] gap_value;
  logic signed [31:0] gap_mul_result;
  logic signed [5:0][31:0] fc_sum;
  logic signed [5:0][31:0] fc_mul_result;
  logic signed [5:0][7:0] fc_value;
  logic signed [7:0] fc_weight [0:5][0:27][0:3];
  logic [6:0] gap_index;
  logic [4:0] fc_group;
  logic [2:0] fc_class;
  logic [2:0] fc_index;
  logic [31:0] gap_hash_work, fc_hash_work;
  logic signed [7:0] gap_quantized_pending;
  logic signed [7:0] gap_requant_value;
  logic signed [7:0] fc_requant_value;

  function automatic logic [31:0] fnv_step(
    input logic [31:0] current,
    input logic [7:0] byte_value
  );
    fnv_step = (current ^ {24'd0, byte_value}) * FNV_PRIME;
  endfunction

  function automatic logic signed [31:0] trunc_shift31(input logic signed [63:0] value);
    logic signed [63:0] magnitude;
    begin
      if (value < 0) begin magnitude = -value; trunc_shift31 = -$signed(magnitude[62:31]); end
      else trunc_shift31 = $signed(value[62:31]);
    end
  endfunction

  function automatic logic signed [31:0] high_mul(
    input logic signed [31:0] left,
    input logic signed [31:0] right
  );
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

  function automatic logic signed [31:0] round_div_pot(
    input logic signed [31:0] value,
    input logic [5:0] shift
  );
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

  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Second half of the GAP requantizer, applied after high_mul is registered.
  // Keeping round_div_pot/saturate in a separate pipeline stage cuts the
  // 32-bit ripple-carry chain off the DSP48 high_mul cascade and removes it
  // from the top routed setup path.
  function automatic logic signed [7:0] requantize_after_mul(
    input logic signed [31:0] mul_result,
    input logic [5:0] right_shift,
    input logic signed [7:0] zero_point
  );
    logic signed [31:0] result, with_zero_point;
    begin
      result = round_div_pot(mul_result, right_shift);
      with_zero_point = result + {{24{zero_point[7]}}, zero_point};
      if (with_zero_point > 127) requantize_after_mul = 8'sh7f;
      else if (with_zero_point < -128) requantize_after_mul = -8'sh80;
      else requantize_after_mul = with_zero_point[7:0];
    end
  endfunction

  function automatic logic signed [31:0] sign_extend_int8(input logic signed [7:0] value);
    sign_extend_int8 = {{24{value[7]}}, value};
  endfunction

  // Keep the FC MAC product width and signedness explicit. This avoids
  // tool-dependent sizing of a packed-array element multiplication before it
  // joins the INT32 accumulator expression.
  function automatic logic signed [31:0] int8_product(
    input logic signed [7:0] left,
    input logic signed [7:0] right
  );
    logic signed [15:0] product;
    begin
      product = left * right;
      int8_product = {{16{product[15]}}, product};
    end
  endfunction

  function automatic logic [2:0] argmax6(input logic signed [5:0][7:0] values);
    logic signed [7:0] best_value;
    logic [2:0] best_index;
    begin
      // Keep the comparison explicitly signed and use strict greater-than so
      // ties retain the lowest class index, matching software argmax.
      best_value = $signed(values[0]); best_index = 3'd0;
      if ($signed(values[1]) > best_value) begin best_value = $signed(values[1]); best_index = 3'd1; end
      if ($signed(values[2]) > best_value) begin best_value = $signed(values[2]); best_index = 3'd2; end
      if ($signed(values[3]) > best_value) begin best_value = $signed(values[3]); best_index = 3'd3; end
      if ($signed(values[4]) > best_value) begin best_value = $signed(values[4]); best_index = 3'd4; end
      if ($signed(values[5]) > best_value) begin best_value = $signed(values[5]); best_index = 3'd5; end
      argmax6 = best_index;
    end
  endfunction

  assign loader_pixel_ready = (state == LOAD);
  assign busy = (state != IDLE);
  assign debug_gap_sum0 = gap_sum[0];
  assign debug_gap_sum6 = gap_sum[6];
  assign debug_fc_value = fc_value;
  assign gap_requant_value = requantize_after_mul(gap_mul_result, gap_right_shift, gap_output_zero_point);
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // The FC requantizer is split into high_mul (registered in FC_MUL) and
  // round_div_pot/saturate (FC_QUANT), mirroring the GAP_MUL/GAP_QUANT split.
  // This removes the long 32-bit ripple-carry chain from the DSP48 high_mul
  // cascade and takes it off the top routed setup path.
  assign fc_requant_value = requantize_after_mul(
    fc_mul_result[fc_index], fc_right_shift[fc_index], fc_output_zero_point
  );

  gestureflow_hp0_tensor_loader #(.CHANNELS(CHANNELS)) loader (
    .clk(clk), .rst_n(rst_n), .start(loader_start), .clear(loader_clear),
    .source_addr(source_addr), .byte_count(byte_count), .pixel_count(pixel_count),
    .busy(loader_busy), .done(loader_done), .fault(loader_fault), .frame_start(loader_frame_start),
    .pixel_valid(loader_pixel_valid), .pixel_ready(loader_pixel_ready), .pixel_data(loader_pixel),
    .pixels_emitted(loader_pixels_emitted), .bytes_read(loader_bytes_read),
    .m_axi_araddr(m_axi_araddr), .m_axi_arid(m_axi_arid), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
    .m_axi_arqos(m_axi_arqos), .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE; loader_start <= 0; loader_clear <= 0; done <= 0; fault <= 0; cycles <= 0;
      gap_sum <= '0; gap_value <= '0; gap_mul_result <= '0; fc_sum <= '0; fc_mul_result <= '0; fc_value <= '0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
      gap_quantized_pending <= '0;
      gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
      predicted_class <= 0; gap_values_done <= 0; fc_values_done <= 0;
    end else begin
      loader_start <= 0; loader_clear <= 0;
      if (fc_weight_write_valid && (fc_weight_write_class < 6) && (fc_weight_write_group < 28)) begin
        for (int lane = 0; lane < 4; lane++) fc_weight[fc_weight_write_class][fc_weight_write_group][lane] <= fc_weight_write_data[lane];
      end
      if (clear) begin
        state <= IDLE; loader_clear <= 1; done <= 0; fault <= 0; cycles <= 0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
        gap_mul_result <= '0; gap_quantized_pending <= '0; fc_mul_result <= '0;
        gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
        predicted_class <= 0; gap_values_done <= 0; fc_values_done <= 0;
      end else begin
        if (busy) cycles <= cycles + 1'b1;
        case (state)
          IDLE: if (start) begin
            done <= 0; fault <= 0; cycles <= 0; gap_sum <= '0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
            gap_mul_result <= '0; gap_quantized_pending <= '0; fc_mul_result <= '0;
            gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
            gap_values_done <= 0; fc_values_done <= 0; loader_start <= 1; state <= LOAD;
          end
          LOAD: begin
            if (loader_fault) begin fault <= 1; state <= IDLE; end
            else if (loader_pixel_valid && loader_pixel_ready) begin
              for (int channel = 0; channel < CHANNELS; channel++) begin
                gap_sum[channel] <= gap_sum[channel] + {{24{loader_pixel[channel][7]}}, loader_pixel[channel]};
              end
              if (loader_pixels_emitted == 14'(ELEMENTS - 1)) begin gap_index <= 0; state <= GAP_MUL; end
            end
          end
          GAP_MUL: begin
            gap_mul_result <= high_mul(
              gap_sum[gap_index] - sign_extend_int8(gap_input_zero_point) * GAP_ELEMENTS,
              gap_multiplier
            );
            state <= GAP_QUANT;
          end
          GAP_QUANT: begin
            // Split requantization and FNV hashing into separate cycles. The
            // previous version chained requantize()->fnv_step() in one state
            // and became the top routed setup path on 7020.
            gap_quantized_pending <= gap_requant_value;
            gap_value[gap_index] <= gap_requant_value;
            gap_values_done <= gap_index + 1'b1;
            state <= GAP_HASH;
          end
          GAP_HASH: begin
            gap_hash_work <= fnv_step(gap_hash_work, gap_quantized_pending);
            if (gap_index == 7'(CHANNELS - 1)) begin
              gap_fnv1a <= fnv_step(gap_hash_work, gap_quantized_pending);
              state <= FC_INIT;
            end else begin
              gap_index <= gap_index + 1'b1;
              state <= GAP_MUL;
            end
          end
          FC_INIT: begin fc_sum <= fc_bias; fc_group <= 0; fc_class <= 0; state <= FC_ACC; end
          FC_ACC: begin
            // One four-lane MAC is time-shared across six outputs. It adds
            // only 168 cycles after the DDR/GAP tail, while retaining DSP
            // margin required for reliable XC7Z020 implementation.
            fc_sum[fc_class] <= $signed(fc_sum[fc_class])
              + int8_product($signed(gap_value[fc_group*4]),   $signed(fc_weight[fc_class][fc_group][0]))
              + int8_product($signed(gap_value[fc_group*4+1]), $signed(fc_weight[fc_class][fc_group][1]))
              + int8_product($signed(gap_value[fc_group*4+2]), $signed(fc_weight[fc_class][fc_group][2]))
              + int8_product($signed(gap_value[fc_group*4+3]), $signed(fc_weight[fc_class][fc_group][3]));
            if (fc_group == 27) begin
              if (fc_class == 5) begin fc_index <= 0; state <= FC_MUL; end
              else begin fc_class <= fc_class + 1'b1; fc_group <= 0; end
            end else fc_group <= fc_group + 1'b1;
          end
          FC_MUL: begin
            fc_mul_result[fc_index] <= high_mul(fc_sum[fc_index], fc_multiplier[fc_index]);
            state <= FC_QUANT;
          end
          FC_QUANT: begin
            fc_value[fc_index] <= fc_requant_value;
            if (fc_index == 5) begin
              fc_index <= 0;
              fc_hash_work <= FNV_OFFSET;
              state <= FC_HASH;
            end else begin
              fc_index <= fc_index + 1'b1;
              state <= FC_MUL;
            end
          end
          FC_HASH: begin
            fc_hash_work <= fnv_step(fc_hash_work, fc_value[fc_index]);
            fc_values_done <= fc_index + 1'b1;
            if (fc_index == 5) begin
              fc_fnv1a <= fnv_step(fc_hash_work, fc_value[fc_index]);
              predicted_class <= argmax6(fc_value);
              done <= 1;
              state <= IDLE;
            end else begin
              fc_index <= fc_index + 1'b1;
            end
          end
          default: begin fault <= 1; state <= IDLE; end
        endcase
      end
    end
  end
endmodule
