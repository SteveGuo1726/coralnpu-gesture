// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Quantized postprocess engine for the deployed GestureFlow static CNN.
// It fetches a 12x12xCHANNELS head tensor from DDR through HP0, retains all
// CHANNELS INT32 GAP sums locally, follows LiteRT's integer Mean scaling
// exactly, then executes the CHANNELS->CLASSES classifier with CLASSES x
// four INT8 MAC lanes. No GAP or FC partial result is written to DDR and ARM
// only loads descriptors. CHANNELS/CLASSES are parameters so one module
// serves both the 112->6 mainline and the 64->18 HaGRID student.
`timescale 1ns/1ps
module gestureflow_hp0_gap_fc #(
  parameter int CHANNELS = 112,
  parameter int CLASSES = 6,
  parameter int ELEMENTS = 144,
  parameter int FC_GROUPS = CHANNELS / 4
) (
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
  input logic [$clog2(CLASSES)-1:0] fc_weight_write_class,
  input logic [$clog2(FC_GROUPS)-1:0] fc_weight_write_group,
  input logic signed [3:0][7:0] fc_weight_write_data,
  input logic signed [CLASSES-1:0][31:0] fc_bias,
  input logic signed [CLASSES-1:0][31:0] fc_multiplier,
  input logic [CLASSES-1:0][5:0] fc_right_shift,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [31:0] cycles,
  output logic [31:0] gap_fnv1a,
  output logic [31:0] fc_fnv1a,
  output logic [$clog2(CLASSES)-1:0] predicted_class,
  output logic [$clog2(CHANNELS+1)-1:0] gap_values_done,
  output logic [$clog2(CLASSES+1)-1:0] fc_values_done,
  output logic signed [31:0] debug_gap_sum0,
  output logic signed [31:0] debug_gap_sum6,
  output logic signed [CLASSES-1:0][7:0] debug_fc_value,

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
  localparam logic signed [31:0] GAP_ELEMENTS = ELEMENTS;
  localparam logic [31:0] FNV_OFFSET = 32'h811c9dc5;
  localparam logic [31:0] FNV_PRIME = 32'h01000193;

  typedef enum logic [4:0] {
    IDLE, LOAD, GAP_ADJ, GAP_MUL, GAP_MUL2, GAP_QUANT, GAP_QUANT2, GAP_HASH, FC_INIT, FC_ACC_T0, FC_ACC_A0, FC_ACC_T1, FC_ACC_A1, FC_ACC_T2, FC_ACC_A2, FC_ACC_T3, FC_ACC_A3, FC_MUL, FC_MUL2, FC_MUL3, FC_QUANT, FC_QUANT2, FC_HASH,
    ARGMAX_PAIR, ARGMAX_TREE1, ARGMAX_TREE2, ARGMAX_TREE3, ARGMAX_FINAL
  } state_t;
  state_t state;
  logic loader_start, loader_clear, loader_busy, loader_done, loader_fault;
  logic loader_frame_start, loader_pixel_valid, loader_pixel_ready;
  logic signed [CHANNELS-1:0][7:0] loader_pixel;
  logic [13:0] loader_pixels_emitted;
  logic [31:0] loader_bytes_read;
  logic signed [CHANNELS-1:0][31:0] gap_sum;
  logic signed [CHANNELS-1:0][7:0] gap_value;
  logic signed [31:0] gap_adjusted;
  logic signed [31:0] gap_mul_result;
  logic signed [31:0] gap_rounded;
  logic signed [7:0] gap_saturated_comb;
  logic signed [63:0] gap_product;
  logic gap_product_special;
  logic signed [CLASSES-1:0][31:0] fc_sum;
  logic signed [31:0] fc_term;
  logic signed [CLASSES-1:0][31:0] fc_mul_result;
  logic signed [63:0] fc_product;
  logic fc_product_special;
  logic signed [31:0] fc_sel_a;
  logic signed [31:0] fc_sel_b;
  logic signed [CLASSES-1:0][31:0] fc_rounded;
  logic signed [7:0] fc_saturated_comb;
  logic signed [CLASSES-1:0][7:0] fc_value;
  logic signed [7:0] fc_weight [0:CLASSES-1][0:FC_GROUPS-1][0:3];
  logic [$clog2(CHANNELS)-1:0] gap_index;
  logic [$clog2(FC_GROUPS)-1:0] fc_group;
  logic [$clog2(CLASSES)-1:0] fc_class;
  logic [$clog2(CLASSES)-1:0] fc_index;
  logic [31:0] gap_hash_work, fc_hash_work;
  logic signed [7:0] gap_quantized_pending;
  logic signed [7:0] gap_requant_value;
  logic signed [7:0] fc_requant_value;
  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // The old argmax function formed a linear 18-class comparator chain. These
  // registered tree levels keep each comparison stage short and remove the
  // classifier result path from the critical timing path on Zynq-7020.
  localparam int ARGMAX_L0 = (CLASSES + 1) / 2;
  localparam int ARGMAX_L1 = (ARGMAX_L0 + 1) / 2;
  localparam int ARGMAX_L2 = (ARGMAX_L1 + 1) / 2;
  localparam int ARGMAX_L3 = (ARGMAX_L2 + 1) / 2;
  // Keep one spare slot at each level so the constant-folded final compare
  // remains a legal selection for one-node levels such as a six-class tree.
  localparam int ARGMAX_S0 = (ARGMAX_L0 < 2) ? 2 : ARGMAX_L0;
  localparam int ARGMAX_S1 = (ARGMAX_L1 < 2) ? 2 : ARGMAX_L1;
  localparam int ARGMAX_S2 = (ARGMAX_L2 < 2) ? 2 : ARGMAX_L2;
  localparam int ARGMAX_S3 = (ARGMAX_L3 < 2) ? 2 : ARGMAX_L3;
  logic signed [7:0] argmax_value0 [0:ARGMAX_S0-1];
  logic signed [7:0] argmax_value1 [0:ARGMAX_S1-1];
  logic signed [7:0] argmax_value2 [0:ARGMAX_S2-1];
  logic signed [7:0] argmax_value3 [0:ARGMAX_S3-1];
  logic [$clog2(CLASSES)-1:0] argmax_index0 [0:ARGMAX_S0-1];
  logic [$clog2(CLASSES)-1:0] argmax_index1 [0:ARGMAX_S1-1];
  logic [$clog2(CLASSES)-1:0] argmax_index2 [0:ARGMAX_S2-1];
  logic [$clog2(CLASSES)-1:0] argmax_index3 [0:ARGMAX_S3-1];

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

  function automatic logic signed [31:0] high_mul_from_product(
    input logic signed [63:0] product
  );
    logic signed [63:0] nudge;
    begin
      nudge = product >= 0 ? 64'sh0000000040000000 : -64'sh000000003fffffff;
      high_mul_from_product = trunc_shift31(product + nudge);
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

  function automatic logic signed [7:0] saturate_after_shift(
    input logic signed [31:0] shifted,
    input logic signed [7:0] zero_point
  );
    logic signed [31:0] zero_extended, with_zero_point;
    begin
      zero_extended = {{24{zero_point[7]}}, zero_point};
      with_zero_point = shifted + zero_extended;
      if (with_zero_point > 127) saturate_after_shift = 8'sh7f;
      else if (with_zero_point < -128) saturate_after_shift = -8'sh80;
      else saturate_after_shift = with_zero_point[7:0];
    end
  endfunction

  function automatic logic signed [31:0] sign_extend_int8(input logic signed [7:0] value);
    sign_extend_int8 = {{24{value[7]}}, value};
  endfunction

  // PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
  // Parameterized argmax keeps the lowest class index on ties, matching the
  // software classifier and the previously board-validated postprocess path.
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

  assign loader_pixel_ready = (state == LOAD);
  assign busy = (state != IDLE);
  assign debug_gap_sum0 = gap_sum[0];
  assign debug_gap_sum6 = gap_sum[6];
  assign debug_fc_value = fc_value;
  assign gap_requant_value = requantize_after_mul(gap_mul_result, gap_right_shift, gap_output_zero_point);
  assign gap_saturated_comb = saturate_after_shift(gap_rounded, gap_output_zero_point);
  assign fc_requant_value = requantize_after_mul(
    fc_mul_result[fc_index], fc_right_shift[fc_index], fc_output_zero_point
  );
  assign fc_saturated_comb = saturate_after_shift(fc_rounded[fc_index], fc_output_zero_point);

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
      gap_sum <= '0; gap_value <= '0; gap_adjusted <= '0; gap_mul_result <= '0; gap_rounded <= '0; gap_product <= '0; gap_product_special <= 1'b0; fc_sum <= '0; fc_term <= '0; fc_mul_result <= '0; fc_product <= '0; fc_product_special <= 1'b0; fc_sel_a <= '0; fc_sel_b <= '0; fc_rounded <= '0; fc_value <= '0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
      gap_quantized_pending <= '0;
      gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
      predicted_class <= 0; gap_values_done <= 0; fc_values_done <= 0;
      for (int i = 0; i < ARGMAX_L0; i++) begin argmax_value0[i] <= '0; argmax_index0[i] <= '0; end
      for (int i = 0; i < ARGMAX_L1; i++) begin argmax_value1[i] <= '0; argmax_index1[i] <= '0; end
      for (int i = 0; i < ARGMAX_L2; i++) begin argmax_value2[i] <= '0; argmax_index2[i] <= '0; end
      for (int i = 0; i < ARGMAX_L3; i++) begin argmax_value3[i] <= '0; argmax_index3[i] <= '0; end
    end else begin
      loader_start <= 0; loader_clear <= 0;
      if (fc_weight_write_valid && (int'(fc_weight_write_class) < CLASSES) && (int'(fc_weight_write_group) < FC_GROUPS)) begin
        for (int lane = 0; lane < 4; lane++) fc_weight[fc_weight_write_class][fc_weight_write_group][lane] <= fc_weight_write_data[lane];
      end
      if (clear) begin
        state <= IDLE; loader_clear <= 1; done <= 0; fault <= 0; cycles <= 0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
        gap_adjusted <= '0; gap_mul_result <= '0; gap_rounded <= '0; gap_product <= '0; gap_product_special <= 1'b0; gap_quantized_pending <= '0; fc_term <= '0; fc_mul_result <= '0; fc_product <= '0; fc_product_special <= 1'b0; fc_rounded <= '0;
        gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
        predicted_class <= 0; gap_values_done <= 0; fc_values_done <= 0;
        for (int i = 0; i < ARGMAX_L0; i++) begin argmax_value0[i] <= '0; argmax_index0[i] <= '0; end
        for (int i = 0; i < ARGMAX_L1; i++) begin argmax_value1[i] <= '0; argmax_index1[i] <= '0; end
        for (int i = 0; i < ARGMAX_L2; i++) begin argmax_value2[i] <= '0; argmax_index2[i] <= '0; end
        for (int i = 0; i < ARGMAX_L3; i++) begin argmax_value3[i] <= '0; argmax_index3[i] <= '0; end
      end else begin
        if (busy) cycles <= cycles + 1'b1;
        case (state)
          IDLE: if (start) begin
            done <= 0; fault <= 0; cycles <= 0; gap_sum <= '0; gap_index <= 0; fc_group <= 0; fc_class <= 0; fc_index <= 0;
            gap_adjusted <= '0; gap_mul_result <= '0; gap_rounded <= '0; gap_product <= '0; gap_product_special <= 1'b0; gap_quantized_pending <= '0; fc_term <= '0; fc_mul_result <= '0; fc_product <= '0; fc_product_special <= 1'b0; fc_rounded <= '0;
            gap_hash_work <= FNV_OFFSET; fc_hash_work <= FNV_OFFSET; gap_fnv1a <= FNV_OFFSET; fc_fnv1a <= FNV_OFFSET;
            gap_values_done <= 0; fc_values_done <= 0; loader_start <= 1; state <= LOAD;
          end
          LOAD: begin
            if (loader_fault) begin fault <= 1; state <= IDLE; end
            else if (loader_pixel_valid && loader_pixel_ready) begin
              for (int channel = 0; channel < CHANNELS; channel++) begin
                gap_sum[channel] <= gap_sum[channel] + {{24{loader_pixel[channel][7]}}, loader_pixel[channel]};
              end
              if (loader_pixels_emitted == 14'(ELEMENTS - 1)) begin gap_index <= 0; state <= GAP_ADJ; end
            end
          end
          GAP_ADJ: begin
            // Split the zero-point subtraction from the DSP48 high_mul so the
            // 32-bit subtract chain is not on the multiply cascade.
            gap_adjusted <= gap_sum[gap_index] - sign_extend_int8(gap_input_zero_point) * GAP_ELEMENTS;
            state <= GAP_MUL;
          end
          GAP_MUL: begin
            if ((gap_adjusted == 32'sh80000000) && (gap_multiplier == 32'sh80000000)) begin
              gap_product_special <= 1'b1;
              gap_product <= '0;
            end else begin
              gap_product_special <= 1'b0;
              gap_product <= $signed(gap_adjusted) * $signed(gap_multiplier);
            end
            state <= GAP_MUL2;
          end
          GAP_MUL2: begin
            if (gap_product_special) gap_mul_result <= 32'sh7fffffff;
            else gap_mul_result <= high_mul_from_product(gap_product);
            state <= GAP_QUANT;
          end
          GAP_QUANT: begin
            gap_rounded <= round_div_pot(gap_mul_result, gap_right_shift);
            state <= GAP_QUANT2;
          end
          GAP_QUANT2: begin
            gap_quantized_pending <= gap_saturated_comb;
            gap_value[gap_index] <= gap_saturated_comb;
            gap_values_done <= gap_index + 1'b1;
            state <= GAP_HASH;
          end
          GAP_HASH: begin
            gap_hash_work <= fnv_step(gap_hash_work, gap_quantized_pending);
            if (gap_index == $clog2(CHANNELS)'(CHANNELS - 1)) begin
              gap_fnv1a <= fnv_step(gap_hash_work, gap_quantized_pending);
              state <= FC_INIT;
            end else begin
              gap_index <= gap_index + 1'b1;
              state <= GAP_ADJ;
            end
          end
          FC_INIT: begin fc_sum <= fc_bias; fc_group <= 0; fc_class <= 0; fc_term <= '0; state <= FC_ACC_T0; end
          FC_ACC_T0: begin
            fc_term <= int8_product($signed(gap_value[fc_group*4]), $signed(fc_weight[fc_class][fc_group][0]));
            state <= FC_ACC_A0;
          end
          FC_ACC_A0: begin
            fc_sum[fc_class] <= $signed(fc_sum[fc_class]) + fc_term;
            state <= FC_ACC_T1;
          end
          FC_ACC_T1: begin
            fc_term <= int8_product($signed(gap_value[fc_group*4+1]), $signed(fc_weight[fc_class][fc_group][1]));
            state <= FC_ACC_A1;
          end
          FC_ACC_A1: begin
            fc_sum[fc_class] <= $signed(fc_sum[fc_class]) + fc_term;
            state <= FC_ACC_T2;
          end
          FC_ACC_T2: begin
            fc_term <= int8_product($signed(gap_value[fc_group*4+2]), $signed(fc_weight[fc_class][fc_group][2]));
            state <= FC_ACC_A2;
          end
          FC_ACC_A2: begin
            fc_sum[fc_class] <= $signed(fc_sum[fc_class]) + fc_term;
            state <= FC_ACC_T3;
          end
          FC_ACC_T3: begin
            fc_term <= int8_product($signed(gap_value[fc_group*4+3]), $signed(fc_weight[fc_class][fc_group][3]));
            state <= FC_ACC_A3;
          end
          FC_ACC_A3: begin
            fc_sum[fc_class] <= $signed(fc_sum[fc_class]) + fc_term;
            if (fc_group == $clog2(FC_GROUPS)'(FC_GROUPS - 1)) begin
              if (fc_class == $clog2(CLASSES)'(CLASSES - 1)) begin fc_index <= 0; state <= FC_MUL; end
              else begin fc_class <= fc_class + 1'b1; fc_group <= 0; state <= FC_ACC_T0; end
            end else begin fc_group <= fc_group + 1'b1; state <= FC_ACC_T0; end
          end
          FC_MUL: begin
            // Register the selected operands so the fc_index mux is not in
            // front of the 32x32 DSP multiply, shortening the routed path.
            fc_sel_a <= $signed(fc_sum[fc_index]);
            fc_sel_b <= $signed(fc_multiplier[fc_index]);
            fc_product_special <= (fc_sum[fc_index] == 32'sh80000000) &&
                                  (fc_multiplier[fc_index] == 32'sh80000000);
            state <= FC_MUL2;
          end
          FC_MUL2: begin
            if (fc_product_special) fc_product <= '0;
            else fc_product <= fc_sel_a * fc_sel_b;
            state <= FC_MUL3;
          end
          FC_MUL3: begin
            if (fc_product_special) fc_mul_result[fc_index] <= 32'sh7fffffff;
            else fc_mul_result[fc_index] <= high_mul_from_product(fc_product);
            state <= FC_QUANT;
          end
          FC_QUANT: begin
            fc_rounded[fc_index] <= round_div_pot(fc_mul_result[fc_index], fc_right_shift[fc_index]);
            state <= FC_QUANT2;
          end
          FC_QUANT2: begin
            fc_value[fc_index] <= fc_saturated_comb;
            if (fc_index == $clog2(CLASSES)'(CLASSES - 1)) begin
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
            if (fc_index == $clog2(CLASSES)'(CLASSES - 1)) begin
              fc_fnv1a <= fnv_step(fc_hash_work, fc_value[fc_index]);
              state <= ARGMAX_PAIR;
            end else begin
              fc_index <= fc_index + 1'b1;
            end
          end
          ARGMAX_PAIR: begin
            // Pair comparisons cover all classes; an odd final class is copied.
            for (int i = 0; i < ARGMAX_L0; i++) begin
              if ((2*i + 1) < CLASSES && $signed(fc_value[2*i+1]) > $signed(fc_value[2*i])) begin
                argmax_value0[i] <= fc_value[2*i+1];
                argmax_index0[i] <= $clog2(CLASSES)'(2*i+1);
              end else begin
                argmax_value0[i] <= fc_value[2*i];
                argmax_index0[i] <= $clog2(CLASSES)'(2*i);
              end
            end
            state <= ARGMAX_TREE1;
          end
          ARGMAX_TREE1: begin
            for (int i = 0; i < ARGMAX_L1; i++) begin
              if ((2*i + 1) < ARGMAX_L0 && $signed(argmax_value0[2*i+1]) > $signed(argmax_value0[2*i])) begin
                argmax_value1[i] <= argmax_value0[2*i+1];
                argmax_index1[i] <= argmax_index0[2*i+1];
              end else begin
                argmax_value1[i] <= argmax_value0[2*i];
                argmax_index1[i] <= argmax_index0[2*i];
              end
            end
            state <= ARGMAX_TREE2;
          end
          ARGMAX_TREE2: begin
            for (int i = 0; i < ARGMAX_L2; i++) begin
              if ((2*i + 1) < ARGMAX_L1 && $signed(argmax_value1[2*i+1]) > $signed(argmax_value1[2*i])) begin
                argmax_value2[i] <= argmax_value1[2*i+1];
                argmax_index2[i] <= argmax_index1[2*i+1];
              end else begin
                argmax_value2[i] <= argmax_value1[2*i];
                argmax_index2[i] <= argmax_index1[2*i];
              end
            end
            state <= ARGMAX_TREE3;
          end
          ARGMAX_TREE3: begin
            for (int i = 0; i < ARGMAX_L3; i++) begin
              if ((2*i + 1) < ARGMAX_L2 && $signed(argmax_value2[2*i+1]) > $signed(argmax_value2[2*i])) begin
                argmax_value3[i] <= argmax_value2[2*i+1];
                argmax_index3[i] <= argmax_index2[2*i+1];
              end else begin
                argmax_value3[i] <= argmax_value2[2*i];
                argmax_index3[i] <= argmax_index2[2*i];
              end
            end
            state <= ARGMAX_FINAL;
          end
          ARGMAX_FINAL: begin
            if (ARGMAX_L3 > 1 && $signed(argmax_value3[1]) > $signed(argmax_value3[0]))
              predicted_class <= argmax_index3[1];
            else
              predicted_class <= argmax_index3[0];
            done <= 1;
            state <= IDLE;
          end
          default: begin fault <= 1; state <= IDLE; end
        endcase
      end
    end
  end
endmodule
