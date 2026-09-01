// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Direct quantized-output writer for the 7020 production path. Quantized
// vectors are collected four at a time and emitted as one legal AXI4 burst
// on the 64-bit HP0 port when their layout is contiguous. Partial or
// strided vectors are emitted as one-vector bursts with byte strobes. This
// removes the full-frame output BRAM round trip used by
// gestureflow_hp0_tensor_writer while retaining bounded buffering,
// ready/valid backpressure, and response checking.
`timescale 1ns/1ps
module gestureflow_hp0_stream_writer #(
  parameter int VECTOR_BYTES = 32,
  parameter int MAX_BURST_VECTORS = 4,
  parameter int COUNT_W = 14,
  parameter int DEFAULT_VECTOR_COUNT = 9216
) (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic [31:0] destination_addr,
  input logic [31:0] destination_stride_bytes,
  input logic [31:0] byte_count,
  input logic [COUNT_W-1:0] vector_count,
  input logic [5:0] valid_vector_bytes,
  input logic vector_valid,
  output logic vector_ready,
  input logic [VECTOR_BYTES*8-1:0] vector_data,
  input logic vector_last,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [COUNT_W-1:0] vectors_written,
  output logic [31:0] bytes_written,
  output logic [31:0] m_axi_awaddr,
  output logic [5:0] m_axi_awid,
  output logic [7:0] m_axi_awlen,
  output logic [2:0] m_axi_awsize,
  output logic [1:0] m_axi_awburst,
  output logic m_axi_awlock,
  output logic [3:0] m_axi_awcache,
  output logic [2:0] m_axi_awprot,
  output logic [3:0] m_axi_awqos,
  output logic [3:0] m_axi_awregion,
  output logic m_axi_awvalid,
  input wire m_axi_awready,
  output logic [63:0] m_axi_wdata,
  output logic [7:0] m_axi_wstrb,
  output logic m_axi_wlast,
  output logic m_axi_wvalid,
  input wire m_axi_wready,
  input wire [5:0] m_axi_bid,
  input wire [1:0] m_axi_bresp,
  input wire m_axi_bvalid,
  output logic m_axi_bready
);
  typedef enum logic [2:0] {IDLE, COLLECT, ISSUE_AW, SEND_W, WAIT_B} state_t;
  state_t state;
  localparam int BEATS_PER_VECTOR = (VECTOR_BYTES + 7) / 8;
  localparam int BURST_BEATS = MAX_BURST_VECTORS * BEATS_PER_VECTOR;
  localparam int VECTOR_INDEX_W = (MAX_BURST_VECTORS <= 1) ? 1 : $clog2(MAX_BURST_VECTORS);
  localparam int BEAT_INDEX_W = (BURST_BEATS <= 1) ? 1 : $clog2(BURST_BEATS);
  localparam int BURST_COUNT_W = $clog2(MAX_BURST_VECTORS + 1);

  logic [VECTOR_BYTES*8-1:0] burst_data [0:MAX_BURST_VECTORS-1];
  logic [VECTOR_INDEX_W-1:0] collect_index;
  logic [BURST_COUNT_W-1:0] burst_vectors;
  logic [BEAT_INDEX_W-1:0] beat_index;
  logic [COUNT_W-1:0] total_vectors;
  logic [COUNT_W-1:0] accepted_vectors;
  logic [COUNT_W-1:0] burst_base_index;
  logic [31:0] next_address;
  logic [31:0] effective_bytes;
  logic [31:0] effective_stride;
  logic contiguous_burst;

  assign busy = (state != IDLE);
  // The last slot transitions to ISSUE_AW in the same clock, so the state
  // itself is the full-buffer guard; adding a narrow counter comparison here
  // would synthesize a constant comparator.
  assign vector_ready = (state == COLLECT);

  always_comb begin
    effective_bytes = (valid_vector_bytes == 0) ? VECTOR_BYTES :
      {26'd0, valid_vector_bytes};
    effective_stride = (destination_stride_bytes == 0) ? VECTOR_BYTES :
      destination_stride_bytes;
    contiguous_burst = (effective_bytes == VECTOR_BYTES) &&
      (effective_stride == VECTOR_BYTES);
    m_axi_awaddr = next_address;
    m_axi_awid = 6'd0;
    m_axi_awlen = 8'(int'(burst_vectors) * ((effective_bytes + 7) / 8) - 1);
    m_axi_awsize = 3'd3;
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = 4'b0011;
    m_axi_awprot = 3'b000;
    m_axi_awqos = 4'd0;
    m_axi_awregion = 4'd0;
    m_axi_awvalid = (state == ISSUE_AW);
    m_axi_wdata = burst_data[int'(beat_index) / BEATS_PER_VECTOR][
      (int'(beat_index) % BEATS_PER_VECTOR) * 64 +: 64];
    if ((int'(beat_index) % ((effective_bytes + 7) / 8)) * 8 + 8 <= effective_bytes)
      m_axi_wstrb = 8'hff;
    else
      m_axi_wstrb = (8'h01 << (effective_bytes - (int'(beat_index) % ((effective_bytes + 7) / 8)) * 8)) - 1'b1;
    m_axi_wlast = (state == SEND_W) &&
      (beat_index == BEAT_INDEX_W'(int'(burst_vectors) * ((effective_bytes + 7) / 8) - 1));
    m_axi_wvalid = (state == SEND_W);
    m_axi_bready = (state == WAIT_B);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      collect_index <= '0;
      burst_vectors <= '0;
      beat_index <= '0;
      total_vectors <= '0;
      accepted_vectors <= '0;
      burst_base_index <= '0;
      next_address <= '0;
      done <= 1'b0;
      fault <= 1'b0;
      vectors_written <= '0;
      bytes_written <= '0;
      for (int index = 0; index < MAX_BURST_VECTORS; index++) burst_data[index] <= '0;
    end else if (clear) begin
      state <= IDLE;
      collect_index <= '0;
      burst_vectors <= '0;
      beat_index <= '0;
      accepted_vectors <= '0;
      burst_base_index <= '0;
      done <= 1'b0;
      fault <= 1'b0;
      vectors_written <= '0;
      bytes_written <= '0;
    end else begin
      case (state)
        IDLE: if (start) begin
          total_vectors <= (vector_count == 0) ? COUNT_W'(DEFAULT_VECTOR_COUNT) : vector_count;
          accepted_vectors <= '0;
          burst_base_index <= '0;
          collect_index <= '0;
          next_address <= destination_addr;
          done <= 1'b0;
          fault <= (destination_addr[2:0] != 0) || (effective_bytes == 0) ||
            (effective_bytes > VECTOR_BYTES) || (effective_bytes[2:0] != 0) ||
            (effective_stride[2:0] != 0) || (effective_stride < effective_bytes) ||
            (byte_count != (((vector_count == 0) ? DEFAULT_VECTOR_COUNT : int'(vector_count)) * effective_bytes));
          if ((destination_addr[2:0] == 0) && (effective_bytes != 0) &&
              (effective_bytes <= VECTOR_BYTES) && (effective_bytes[2:0] == 0) &&
              (effective_stride[2:0] == 0) && (effective_stride >= effective_bytes) &&
              (byte_count == (((vector_count == 0) ? DEFAULT_VECTOR_COUNT : int'(vector_count)) * effective_bytes)))
            state <= COLLECT;
        end
        COLLECT: if (vector_valid && vector_ready) begin
          burst_data[int'(collect_index)] <= vector_data;
          accepted_vectors <= accepted_vectors + 1'b1;
          if (vector_last && (accepted_vectors + 1'b1 != total_vectors)) fault <= 1'b1;
          if (vector_last || (accepted_vectors + 1'b1 == total_vectors) ||
              (!contiguous_burst) ||
              (collect_index == VECTOR_INDEX_W'(MAX_BURST_VECTORS - 1))) begin
            burst_vectors <= BURST_COUNT_W'(collect_index + 1'b1);
            burst_base_index <= accepted_vectors - COUNT_W'(collect_index);
            beat_index <= '0;
            state <= ISSUE_AW;
          end else begin
            collect_index <= collect_index + 1'b1;
          end
        end
        ISSUE_AW: if (m_axi_awvalid && m_axi_awready) begin
          beat_index <= '0;
          state <= SEND_W;
        end
        SEND_W: if (m_axi_wvalid && m_axi_wready) begin
          if (m_axi_wlast) state <= WAIT_B;
          else beat_index <= beat_index + 1'b1;
        end
        WAIT_B: if (m_axi_bvalid && m_axi_bready) begin
          if ((m_axi_bid != 0) || (m_axi_bresp != 0)) fault <= 1'b1;
          vectors_written <= vectors_written + COUNT_W'(burst_vectors);
          bytes_written <= bytes_written + int'(burst_vectors) * effective_bytes;
          if (accepted_vectors >= total_vectors) begin
            done <= 1'b1;
            state <= IDLE;
          end else begin
            collect_index <= '0;
            next_address <= next_address + int'(burst_vectors) *
              (contiguous_burst ? VECTOR_BYTES : effective_stride);
            state <= COLLECT;
          end
        end
        default: begin
          fault <= 1'b1;
          state <= IDLE;
        end
      endcase
    end
  end
endmodule
