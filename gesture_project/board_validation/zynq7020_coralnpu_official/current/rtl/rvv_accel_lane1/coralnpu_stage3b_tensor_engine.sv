// PROJECT_LOCAL_MOD: fixed-shape tensor engine for the real model's
// conv3_3x3_b layer (24x24x64, SAME, int8 -> int8).  It is deliberately
// separate from the proven RVV instruction path so the existing postprocess
// regression remains a rollback baseline.
`timescale 1ns / 1ps

module coralnpu_stage3b_tensor_engine (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    output wire        busy,
    output reg         done,
    output reg         fault,

    // PS-side staging port. mem_kind: 0=input, 1=weights, 2=bias,
    // 3=multiplier, 4=shift. Input/weight addresses index packed 32-bit words.
    input  wire        mem_we,
    input  wire        mem_re,
    input  wire [2:0]  mem_kind,
    input  wire [15:0] mem_addr,
    input  wire [31:0] mem_wdata,
    output reg  [31:0] mem_rdata
);
  localparam [3:0] ST_IDLE  = 4'd0;
  localparam [3:0] ST_INIT  = 4'd1;
  localparam [3:0] ST_FETCH = 4'd2;
  localparam [3:0] ST_MAC   = 4'd3;
  localparam [3:0] ST_WRITE = 4'd4;
  // PROJECT_LOCAL_MOD: maxpool is part of the tensor data path, not a PS
  // post-processing loop.  Keeping it after all convolution writes leaves
  // output_mem readable for full tensor25 regression while producing pool3.
  localparam [3:0] ST_POOL_ISSUE   = 4'd5;
  localparam [3:0] ST_POOL_WAIT    = 4'd6;
  localparam [3:0] ST_POOL_CAPTURE = 4'd7;
  localparam [3:0] ST_POOL_WRITE   = 4'd8;
  localparam [3:0] ST_DONE  = 4'd9;

  // PROJECT_LOCAL_MOD: tensor memories are deliberately outside the
  // asynchronous-reset controller. This is Vivado's supported 7-series BRAM
  // pattern, rather than dissolving 36 KiB tensors into LUT registers.
  (* ram_style = "block" *) reg [63:0] input_mem [0:4607];
  (* ram_style = "block" *) reg [63:0] weight_mem0 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem1 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem2 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem3 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem4 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem5 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem6 [0:575];
  (* ram_style = "block" *) reg [63:0] weight_mem7 [0:575];
  reg signed [31:0] bias_mem [0:63];
  reg signed [31:0] multiplier_mem [0:63];
  reg signed [31:0] shift_mem [0:63];
  (* ram_style = "block" *) reg [63:0] output_mem [0:4607];
  (* ram_style = "block" *) reg [63:0] pool_mem [0:1151];

  reg [3:0] state;
  reg [4:0] out_y;
  reg [4:0] out_x;
  reg [2:0] out_group;
  reg [3:0] kernel_index;
  reg [2:0] cin_group;
  reg [3:0] pool_y;
  reg [3:0] pool_x;
  reg [2:0] pool_group;
  reg [1:0] pool_phase;
  reg signed [31:0] acc0, acc1, acc2, acc3, acc4, acc5, acc6, acc7;
  reg signed [31:0] final0, final1, final2, final3, final4, final5, final6, final7;
  reg [63:0] input_q;
  reg [63:0] weight_q0, weight_q1, weight_q2, weight_q3;
  reg [63:0] weight_q4, weight_q5, weight_q6, weight_q7;
  // PROJECT_LOCAL_MOD: decouple asynchronous-reset AXI-Lite registers from
  // BRAM address/enable pins. These controller registers use synchronous
  // reset only, which keeps reset assertion out of the RAM control cone.
  reg        stage_we_q;
  reg [2:0]  stage_kind_q;
  reg [15:0] stage_addr_q;
  reg [31:0] stage_wdata_q;
  reg [63:0] pool_q00, pool_q01, pool_q10, pool_q11;
  // PROJECT_LOCAL_MOD: a single full-width synchronous port is used for each
  // tensor RAM.  Partial-width and multi-read access made Vivado dissolve the
  // original output tensor into LUTRAM, so read requests now return through a
  // registered 64-bit path and only then select the requested 32-bit half.
  reg        output_rd_en_q;
  reg [12:0] output_rd_addr_q;
  reg [63:0] output_rd_data_q;
  reg        pool_rd_en_q;
  reg [10:0] pool_rd_addr_q;
  reg [63:0] pool_rd_data_q;
  reg        mem_rsp_pending1_q;
  reg        mem_rsp_pending2_q;
  reg [2:0]  mem_rsp_kind1_q;
  reg [2:0]  mem_rsp_kind2_q;
  reg        mem_rsp_half1_q;
  reg        mem_rsp_half2_q;

  integer wi_out;
  integer wi_kernel;
  integer wi_cin;
  integer wi_bank_index;
  integer ii_y;
  integer ii_x;
  integer ii_word;
  integer output_word;
  integer pool_read_word;
  integer pool_write_word;
  integer lane;
  integer sum0, sum1, sum2, sum3, sum4, sum5, sum6, sum7;

  wire last_mac = (kernel_index == 4'd8) && (cin_group == 3'd7);
  assign busy = (state != ST_IDLE) && (state != ST_DONE);

  function automatic signed [31:0] rounded_high_mul;
    input signed [31:0] lhs;
    input signed [31:0] rhs;
    reg signed [63:0] product;
    reg signed [63:0] nudge;
    begin
      product = lhs * rhs;
      nudge = product >= 0 ? 64'sh0000000040000000 : -64'sh000000003fffffff;
      rounded_high_mul = (product + nudge) >>> 31;
    end
  endfunction

  function automatic signed [31:0] rounding_divide_by_pot;
    input signed [31:0] value;
    input signed [31:0] exponent;
    reg signed [31:0] mask;
    reg signed [31:0] remainder;
    reg signed [31:0] threshold;
    begin
      if (exponent <= 0) begin
        rounding_divide_by_pot = value <<< (-exponent);
      end else begin
        // This is the TFLite RoundingDivideByPOT rule. Adding a constant
        // before an arithmetic shift is not equivalent at exact half-way
        // points (the first real sample exercises that boundary).
        mask = (32'sd1 <<< exponent) - 1;
        remainder = value & mask;
        threshold = (mask >>> 1) + (value < 0 ? 32'sd1 : 32'sd0);
        rounding_divide_by_pot = (value >>> exponent) +
                                 (remainder > threshold ? 32'sd1 : 32'sd0);
      end
    end
  endfunction

  function automatic signed [7:0] requantize;
    input signed [31:0] value;
    input signed [31:0] multiplier;
    input signed [31:0] shift;
    reg signed [31:0] scaled;
    reg signed [31:0] shifted;
    begin
      scaled = rounded_high_mul(value, multiplier);
      shifted = rounding_divide_by_pot(scaled, -shift);
      // The layer's fused ReLU has zero-point -128, so normal int8 clamping
      // also implements its lower activation bound.
      shifted = shifted - 128;
      if (shifted > 127) requantize = 8'sd127;
      else if (shifted < -128) requantize = -8'sd128;
      else requantize = shifted[7:0];
    end
  endfunction

  function automatic signed [7:0] max4_i8;
    input signed [7:0] a;
    input signed [7:0] b;
    input signed [7:0] c;
    input signed [7:0] d;
    reg signed [7:0] ab;
    reg signed [7:0] cd;
    begin
      ab = (a > b) ? a : b;
      cd = (c > d) ? c : d;
      max4_i8 = (ab > cd) ? ab : cd;
    end
  endfunction

  // PROJECT_LOCAL_MOD: all tensor-memory ports are synchronous and reset-free.
  // The PS only stages data in IDLE. During execution, ST_FETCH owns the read
  // ports; ST_WRITE owns output writes. A mem_re pulse with mem_kind=5
  // (tensor25) or 6 (tensor26) initiates a registered read in IDLE. The extra
  // command register keeps asynchronous AXI-Lite state off BRAM pins.
  always @(posedge clk) begin
    if (stage_we_q) begin
      case (stage_kind_q)
        3'd0: begin
          if (stage_addr_q[0]) input_mem[stage_addr_q[13:1]][63:32] <= stage_wdata_q;
          else input_mem[stage_addr_q[13:1]][31:0] <= stage_wdata_q;
        end
        3'd1: begin
          wi_out = stage_addr_q / 16'd144;
          wi_kernel = (stage_addr_q % 16'd144) / 16'd16;
          wi_cin = (stage_addr_q % 16'd16) * 4;
          wi_bank_index = ((wi_out / 8) * 72) + (wi_kernel * 8) + (wi_cin / 8);
          case (wi_out[2:0])
            3'd0: if (wi_cin[2]) weight_mem0[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem0[wi_bank_index][31:0] <= stage_wdata_q;
            3'd1: if (wi_cin[2]) weight_mem1[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem1[wi_bank_index][31:0] <= stage_wdata_q;
            3'd2: if (wi_cin[2]) weight_mem2[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem2[wi_bank_index][31:0] <= stage_wdata_q;
            3'd3: if (wi_cin[2]) weight_mem3[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem3[wi_bank_index][31:0] <= stage_wdata_q;
            3'd4: if (wi_cin[2]) weight_mem4[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem4[wi_bank_index][31:0] <= stage_wdata_q;
            3'd5: if (wi_cin[2]) weight_mem5[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem5[wi_bank_index][31:0] <= stage_wdata_q;
            3'd6: if (wi_cin[2]) weight_mem6[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem6[wi_bank_index][31:0] <= stage_wdata_q;
            default: if (wi_cin[2]) weight_mem7[wi_bank_index][63:32] <= stage_wdata_q; else weight_mem7[wi_bank_index][31:0] <= stage_wdata_q;
          endcase
        end
        3'd2: bias_mem[stage_addr_q[5:0]] <= stage_wdata_q;
        3'd3: multiplier_mem[stage_addr_q[5:0]] <= stage_wdata_q;
        3'd4: shift_mem[stage_addr_q[5:0]] <= stage_wdata_q;
      endcase
    end

    if (state == ST_FETCH) begin
      ii_y = $signed({1'b0, out_y}) + (kernel_index / 3) - 1;
      ii_x = $signed({1'b0, out_x}) + (kernel_index % 3) - 1;
      if ((ii_y < 0) || (ii_y >= 24) || (ii_x < 0) || (ii_x >= 24)) begin
        input_q <= {8{-8'sd128}};
      end else begin
        ii_word = ((ii_y * 24 + ii_x) * 8) + cin_group;
        input_q <= input_mem[ii_word];
      end
      wi_bank_index = (out_group * 72) + (kernel_index * 8) + cin_group;
      weight_q0 <= weight_mem0[wi_bank_index]; weight_q1 <= weight_mem1[wi_bank_index];
      weight_q2 <= weight_mem2[wi_bank_index]; weight_q3 <= weight_mem3[wi_bank_index];
      weight_q4 <= weight_mem4[wi_bank_index]; weight_q5 <= weight_mem5[wi_bank_index];
      weight_q6 <= weight_mem6[wi_bank_index]; weight_q7 <= weight_mem7[wi_bank_index];
    end

    if (state == ST_WRITE) begin
      output_word = ((out_y * 24 + out_x) * 8) + out_group;
      output_mem[output_word] <= {
          requantize(final7, multiplier_mem[{out_group,3'd7}], shift_mem[{out_group,3'd7}]),
          requantize(final6, multiplier_mem[{out_group,3'd6}], shift_mem[{out_group,3'd6}]),
          requantize(final5, multiplier_mem[{out_group,3'd5}], shift_mem[{out_group,3'd5}]),
          requantize(final4, multiplier_mem[{out_group,3'd4}], shift_mem[{out_group,3'd4}]),
          requantize(final3, multiplier_mem[{out_group,3'd3}], shift_mem[{out_group,3'd3}]),
          requantize(final2, multiplier_mem[{out_group,3'd2}], shift_mem[{out_group,3'd2}]),
          requantize(final1, multiplier_mem[{out_group,3'd1}], shift_mem[{out_group,3'd1}]),
          requantize(final0, multiplier_mem[{out_group,3'd0}], shift_mem[{out_group,3'd0}])};
    end

    if (state == ST_POOL_WRITE) begin
      pool_write_word = (pool_y * 12 + pool_x) * 8 + pool_group;
      pool_mem[pool_write_word] <= {
          max4_i8(pool_q00[63:56], pool_q01[63:56], pool_q10[63:56], pool_q11[63:56]),
          max4_i8(pool_q00[55:48], pool_q01[55:48], pool_q10[55:48], pool_q11[55:48]),
          max4_i8(pool_q00[47:40], pool_q01[47:40], pool_q10[47:40], pool_q11[47:40]),
          max4_i8(pool_q00[39:32], pool_q01[39:32], pool_q10[39:32], pool_q11[39:32]),
          max4_i8(pool_q00[31:24], pool_q01[31:24], pool_q10[31:24], pool_q11[31:24]),
          max4_i8(pool_q00[23:16], pool_q01[23:16], pool_q10[23:16], pool_q11[23:16]),
          max4_i8(pool_q00[15:8],  pool_q01[15:8],  pool_q10[15:8],  pool_q11[15:8]),
          max4_i8(pool_q00[7:0],   pool_q01[7:0],   pool_q10[7:0],   pool_q11[7:0])};
    end

    if (output_rd_en_q) output_rd_data_q <= output_mem[output_rd_addr_q];
    if (pool_rd_en_q) pool_rd_data_q <= pool_mem[pool_rd_addr_q];
  end

  always @(posedge clk) begin
    if (!rstn) begin
      state <= ST_IDLE;
      done <= 1'b0;
      fault <= 1'b0;
      out_y <= 5'd0;
      out_x <= 5'd0;
      out_group <= 3'd0;
      kernel_index <= 4'd0;
      cin_group <= 3'd0;
      pool_y <= 4'd0;
      pool_x <= 4'd0;
      pool_group <= 3'd0;
      pool_phase <= 2'd0;
      acc0 <= 0; acc1 <= 0; acc2 <= 0; acc3 <= 0;
      acc4 <= 0; acc5 <= 0; acc6 <= 0; acc7 <= 0;
      final0 <= 0; final1 <= 0; final2 <= 0; final3 <= 0;
      final4 <= 0; final5 <= 0; final6 <= 0; final7 <= 0;
      stage_we_q <= 1'b0;
      stage_kind_q <= 3'd0;
      stage_addr_q <= 16'd0;
      stage_wdata_q <= 32'd0;
      output_rd_en_q <= 1'b0;
      output_rd_addr_q <= 13'd0;
      pool_rd_en_q <= 1'b0;
      pool_rd_addr_q <= 11'd0;
      mem_rsp_pending1_q <= 1'b0;
      mem_rsp_pending2_q <= 1'b0;
      mem_rsp_kind1_q <= 3'd0;
      mem_rsp_kind2_q <= 3'd0;
      mem_rsp_half1_q <= 1'b0;
      mem_rsp_half2_q <= 1'b0;
    end else begin
      done <= 1'b0;

      stage_we_q <= mem_we && (state == ST_IDLE) && (mem_kind <= 3'd4);
      stage_kind_q <= mem_kind;
      stage_addr_q <= mem_addr;
      stage_wdata_q <= mem_wdata;
      output_rd_en_q <= 1'b0;
      pool_rd_en_q <= 1'b0;
      mem_rsp_pending1_q <= 1'b0;
      mem_rsp_pending2_q <= mem_rsp_pending1_q;
      mem_rsp_kind2_q <= mem_rsp_kind1_q;
      mem_rsp_half2_q <= mem_rsp_half1_q;

      if (mem_rsp_pending2_q) begin
        if (mem_rsp_kind2_q == 3'd5) begin
          mem_rdata <= mem_rsp_half2_q ? output_rd_data_q[63:32] : output_rd_data_q[31:0];
        end else begin
          mem_rdata <= mem_rsp_half2_q ? pool_rd_data_q[63:32] : pool_rd_data_q[31:0];
        end
      end

      if (mem_we && (state == ST_IDLE) && (mem_kind > 3'd4)) begin
        fault <= 1'b1;
      end

      if (mem_re && (state == ST_IDLE)) begin
        if (mem_kind == 3'd5) begin
          output_rd_en_q <= 1'b1;
          output_rd_addr_q <= mem_addr[13:1];
          mem_rsp_pending1_q <= 1'b1;
          mem_rsp_kind1_q <= 3'd5;
          mem_rsp_half1_q <= mem_addr[0];
        end else if (mem_kind == 3'd6) begin
          pool_rd_en_q <= 1'b1;
          pool_rd_addr_q <= mem_addr[11:1];
          mem_rsp_pending1_q <= 1'b1;
          mem_rsp_kind1_q <= 3'd6;
          mem_rsp_half1_q <= mem_addr[0];
        end else begin
          fault <= 1'b1;
        end
      end

      case (state)
        ST_IDLE: begin
          if (start) begin
            fault <= 1'b0;
            out_y <= 0;
            out_x <= 0;
            out_group <= 0;
            state <= ST_INIT;
          end
        end
        ST_INIT: begin
          acc0 <= bias_mem[{out_group, 3'd0}]; acc1 <= bias_mem[{out_group, 3'd1}];
          acc2 <= bias_mem[{out_group, 3'd2}]; acc3 <= bias_mem[{out_group, 3'd3}];
          acc4 <= bias_mem[{out_group, 3'd4}]; acc5 <= bias_mem[{out_group, 3'd5}];
          acc6 <= bias_mem[{out_group, 3'd6}]; acc7 <= bias_mem[{out_group, 3'd7}];
          kernel_index <= 0;
          cin_group <= 0;
          state <= ST_FETCH;
        end
        ST_FETCH: state <= ST_MAC;
        ST_MAC: begin
          sum0 = 0; sum1 = 0; sum2 = 0; sum3 = 0; sum4 = 0; sum5 = 0; sum6 = 0; sum7 = 0;
          for (lane = 0; lane < 8; lane = lane + 1) begin
            sum0 = sum0 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q0[lane*8 +: 8]);
            sum1 = sum1 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q1[lane*8 +: 8]);
            sum2 = sum2 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q2[lane*8 +: 8]);
            sum3 = sum3 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q3[lane*8 +: 8]);
            sum4 = sum4 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q4[lane*8 +: 8]);
            sum5 = sum5 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q5[lane*8 +: 8]);
            sum6 = sum6 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q6[lane*8 +: 8]);
            sum7 = sum7 + ($signed(input_q[lane*8 +: 8]) + 128) * $signed(weight_q7[lane*8 +: 8]);
          end
          if (last_mac) begin
            final0 <= acc0 + sum0; final1 <= acc1 + sum1; final2 <= acc2 + sum2; final3 <= acc3 + sum3;
            final4 <= acc4 + sum4; final5 <= acc5 + sum5; final6 <= acc6 + sum6; final7 <= acc7 + sum7;
            state <= ST_WRITE;
          end else begin
            acc0 <= acc0 + sum0; acc1 <= acc1 + sum1; acc2 <= acc2 + sum2; acc3 <= acc3 + sum3;
            acc4 <= acc4 + sum4; acc5 <= acc5 + sum5; acc6 <= acc6 + sum6; acc7 <= acc7 + sum7;
            if (cin_group == 7) begin cin_group <= 0; kernel_index <= kernel_index + 1; end
            else cin_group <= cin_group + 1;
            state <= ST_FETCH;
          end
        end
        ST_WRITE: begin
          if (out_group == 7) begin
            out_group <= 0;
            if (out_x == 23) begin
              out_x <= 0;
              if (out_y != 23) out_y <= out_y + 1;
            end else out_x <= out_x + 1;
          end else out_group <= out_group + 1;
          if ((out_group == 7) && (out_x == 23) && (out_y == 23)) begin
            pool_y <= 0;
            pool_x <= 0;
            pool_group <= 0;
            pool_phase <= 0;
            state <= ST_POOL_ISSUE;
          end else begin
            state <= ST_INIT;
          end
        end
        ST_POOL_ISSUE: begin
          pool_read_word = ((pool_y * 2) * 24 + (pool_x * 2)) * 8 + pool_group;
          output_rd_en_q <= 1'b1;
          case (pool_phase)
            2'd0: output_rd_addr_q <= pool_read_word;
            2'd1: output_rd_addr_q <= pool_read_word + 8;
            2'd2: output_rd_addr_q <= pool_read_word + 192;
            default: output_rd_addr_q <= pool_read_word + 200;
          endcase
          state <= ST_POOL_WAIT;
        end
        ST_POOL_WAIT: begin
          state <= ST_POOL_CAPTURE;
        end
        ST_POOL_CAPTURE: begin
          case (pool_phase)
            2'd0: pool_q00 <= output_rd_data_q;
            2'd1: pool_q01 <= output_rd_data_q;
            2'd2: pool_q10 <= output_rd_data_q;
            default: pool_q11 <= output_rd_data_q;
          endcase
          if (pool_phase == 2'd3) begin
            pool_phase <= 0;
            state <= ST_POOL_WRITE;
          end else begin
            pool_phase <= pool_phase + 1;
            state <= ST_POOL_ISSUE;
          end
        end
        ST_POOL_WRITE: begin
          if (pool_group == 7) begin
            pool_group <= 0;
            if (pool_x == 11) begin
              pool_x <= 0;
              if (pool_y == 11) state <= ST_DONE;
              else begin
                pool_y <= pool_y + 1;
                state <= ST_POOL_ISSUE;
              end
            end else begin
              pool_x <= pool_x + 1;
              state <= ST_POOL_ISSUE;
            end
          end else begin
            pool_group <= pool_group + 1;
            state <= ST_POOL_ISSUE;
          end
        end
        ST_DONE: begin
          done <= 1'b1;
          state <= ST_IDLE;
        end
        default: begin
          state <= ST_IDLE;
          fault <= 1'b1;
        end
      endcase
    end
  end
endmodule
