// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Bounded AXI4 writer for an NHWC activation tile already resident in the
// local output bank. VECTOR_BYTES may be 16 or 32; the fixed 64-bit AXI port
// emits the required number of beats per vector and keeps burst boundaries
// explicit. This is the layer-to-layer handoff primitive, not a camera DMA.
`timescale 1ns/1ps
module gestureflow_hp0_tensor_writer #(
  parameter int VECTOR_COUNT = 9216,
  parameter int VECTOR_ADDR_W = 14,
  parameter int VECTOR_BYTES = 16,
  parameter int INPUT_WIDTH = 96,
  parameter int MAX_BURST_VECTORS = 8
) (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic pool_2x2,
  input logic [31:0] destination_addr,
  input logic [31:0] byte_count,
  // Zero selects the legacy contiguous full-vector layout. Nonzero values
  // allow a 16-lane physical tile to populate a wider NHWC output tensor.
  input logic [13:0] vector_count,
  input logic [15:0] input_width,
  input logic [31:0] destination_stride_bytes,
  input logic [5:0] valid_vector_bytes,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [VECTOR_ADDR_W-1:0] bank_read_addr,
  output logic bank_read_enable,
  input logic [VECTOR_BYTES*8-1:0] bank_read_data,
  output logic [VECTOR_ADDR_W-1:0] vectors_written,
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
  typedef enum logic [2:0] {
    IDLE, ISSUE_READ, CAPTURE_READ, ISSUE_AW, SEND_W, WAIT_B
  } state_t;
  state_t state;
  localparam int BURST_VECTOR_W = $clog2(MAX_BURST_VECTORS + 1);
  localparam int BEATS_PER_VECTOR = (VECTOR_BYTES + 7) / 8;
  localparam int BEAT_INDEX_W = (BEATS_PER_VECTOR <= 1) ? 1 : $clog2(BEATS_PER_VECTOR);
  localparam int BURST_BEAT_W = $clog2((MAX_BURST_VECTORS * BEATS_PER_VECTOR) + 1);
  localparam int BURST_READ_INDEX_W = (MAX_BURST_VECTORS <= 1) ? 1 : $clog2(MAX_BURST_VECTORS);
  localparam int BURST_BEAT_INDEX_W = ((MAX_BURST_VECTORS * BEATS_PER_VECTOR) <= 1) ? 1 : $clog2(MAX_BURST_VECTORS * BEATS_PER_VECTOR);
  logic [VECTOR_ADDR_W-1:0] vector_index;
  logic [31:0] next_addr;
  logic [VECTOR_BYTES*8-1:0] vector_data;
  logic [BEAT_INDEX_W-1:0] beat_index;
  logic contiguous_burst;
  logic [BURST_VECTOR_W-1:0] burst_vectors;
  logic [BURST_BEAT_W-1:0] burst_beats;
  logic [BURST_READ_INDEX_W-1:0] burst_read_index;
  logic [BURST_BEAT_INDEX_W-1:0] burst_beat_index;
  logic [VECTOR_BYTES*8-1:0] burst_data [0:MAX_BURST_VECTORS-1];
  logic pool_active;
  logic [1:0] pool_phase;
  logic [31:0] pool_read_address;
  logic [VECTOR_BYTES*8-1:0] pool_data0, pool_data1, pool_data2;
  logic [31:0] pool_row_base;
  logic [15:0] pool_column_base;
  logic [31:0] effective_stride_bytes, effective_valid_bytes;
  logic [31:0] effective_vector_count, effective_pooled_vector_count;
  logic [31:0] effective_valid_beats, beat_byte_base, beat_valid_bytes;

  function automatic logic [BURST_VECTOR_W-1:0] choose_burst_vectors(
    input logic [31:0] remaining_vectors,
    input logic [11:0] low_addr
  );
    integer available;
    integer until_boundary;
    begin
      available = int'(remaining_vectors);
      until_boundary = (4096 - int'(low_addr)) / VECTOR_BYTES;
      if (until_boundary == 0) until_boundary = 2048;
      if (available > MAX_BURST_VECTORS) available = MAX_BURST_VECTORS;
      if (available > until_boundary) available = until_boundary;
      choose_burst_vectors = BURST_VECTOR_W'(available);
    end
  endfunction

  logic [BURST_VECTOR_W-1:0] candidate_burst_vectors;
  logic [BURST_VECTOR_W-1:0] initial_burst_vectors;
  logic [BURST_BEAT_W-1:0] candidate_burst_beats;
  logic [BURST_BEAT_W-1:0] initial_burst_beats;
  logic [BURST_READ_INDEX_W-1:0] burst_data_index;
  logic [BURST_VECTOR_W-1:0] burst_last_vector_index;
  logic [BURST_BEAT_W-1:0] burst_last_beat_index;
  logic [31:0] burst_step_bytes;
  logic [31:0] vectors_in_transaction;

  function automatic logic [VECTOR_BYTES*8-1:0] max4_vectors(
    input logic [VECTOR_BYTES*8-1:0] a, input logic [VECTOR_BYTES*8-1:0] b,
    input logic [VECTOR_BYTES*8-1:0] c, input logic [VECTOR_BYTES*8-1:0] d
  );
    logic signed [7:0] maximum;
    for (int lane = 0; lane < VECTOR_BYTES; lane++) begin
      maximum = $signed(a[lane*8 +: 8]);
      if ($signed(b[lane*8 +: 8]) > maximum) maximum = $signed(b[lane*8 +: 8]);
      if ($signed(c[lane*8 +: 8]) > maximum) maximum = $signed(c[lane*8 +: 8]);
      if ($signed(d[lane*8 +: 8]) > maximum) maximum = $signed(d[lane*8 +: 8]);
      max4_vectors[lane*8 +: 8] = maximum;
    end
  endfunction

  assign busy = (state != IDLE);

  always_comb begin
    effective_stride_bytes = destination_stride_bytes == 0 ? VECTOR_BYTES : destination_stride_bytes;
    effective_valid_bytes = valid_vector_bytes == 0 ? 32'(VECTOR_BYTES) : {26'd0, valid_vector_bytes};
    effective_vector_count = vector_count == 0 ? 32'(VECTOR_COUNT) : {18'd0, vector_count};
    effective_pooled_vector_count = effective_vector_count >> 2;
    candidate_burst_vectors = choose_burst_vectors(
      effective_vector_count - 32'(vector_index), next_addr[11:0]);
    initial_burst_vectors = choose_burst_vectors(
      effective_vector_count, destination_addr[11:0]);
    effective_valid_beats = (effective_valid_bytes + 7) / 8;
    candidate_burst_beats = BURST_BEAT_W'(int'(candidate_burst_vectors) * BEATS_PER_VECTOR);
    initial_burst_beats = BURST_BEAT_W'(int'(initial_burst_vectors) * BEATS_PER_VECTOR);
    burst_data_index = BURST_READ_INDEX_W'(int'(burst_beat_index) / BEATS_PER_VECTOR);
    burst_last_vector_index = BURST_VECTOR_W'(int'(burst_vectors) - 1);
    burst_last_beat_index = BURST_BEAT_W'(int'(burst_beats) - 1);
    burst_step_bytes = 32'(int'(burst_vectors) * VECTOR_BYTES);
    vectors_in_transaction = contiguous_burst ? 32'(burst_vectors) : 32'd1;
    // This is intentionally counter based rather than vector_index divided
    // by runtime width. A dynamic divider would be an avoidable LUT/timing
    // hotspot on the 7020 write path.
    pool_read_address = pool_row_base + {16'd0, pool_column_base} +
      (pool_phase[1] ? {16'd0, input_width} : 32'd0) + {31'd0, pool_phase[0]};
    if (pool_active) bank_read_addr = VECTOR_ADDR_W'(pool_read_address);
    else if (contiguous_burst) bank_read_addr = VECTOR_ADDR_W'(int'(vector_index) + int'(burst_read_index));
    else bank_read_addr = vector_index;
    bank_read_enable = (state == ISSUE_READ);
    m_axi_awaddr = next_addr;
    m_axi_awid = 6'd0;
    m_axi_awlen = contiguous_burst ? (8'(burst_beats) - 8'd1) :
      (8'(effective_valid_beats) - 8'd1);
    m_axi_awsize = 3'd3;
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = 4'b0011;
    m_axi_awprot = 3'b000;
    m_axi_awqos = 4'd0;
    m_axi_awregion = 4'd0;
    m_axi_awvalid = (state == ISSUE_AW);
    m_axi_wdata = vector_data[int'(beat_index) * 64 +: 64];
    beat_byte_base = int'(beat_index) * 8;
    if (contiguous_burst) beat_byte_base = (int'(burst_beat_index) % BEATS_PER_VECTOR) * 8;
    beat_valid_bytes = effective_valid_bytes > beat_byte_base ? effective_valid_bytes - beat_byte_base : 0;
    if (contiguous_burst) begin
      m_axi_wdata = burst_data[int'(burst_data_index)][(int'(burst_beat_index) % BEATS_PER_VECTOR) * 64 +: 64];
      m_axi_wstrb = 8'hff;
    end else begin
      if (beat_valid_bytes >= 8) m_axi_wstrb = 8'hff;
      else if (beat_valid_bytes != 0) m_axi_wstrb = (8'h01 << beat_valid_bytes) - 1'b1;
      else m_axi_wstrb = 8'h00;
    end
    m_axi_wlast = (state == SEND_W) && (contiguous_burst ?
      (BURST_BEAT_W'(burst_beat_index) == burst_last_beat_index) :
      (BEAT_INDEX_W'(beat_index) == BEAT_INDEX_W'(effective_valid_beats - 1)));
    m_axi_wvalid = (state == SEND_W);
    m_axi_bready = (state == WAIT_B);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      vector_index <= '0;
      next_addr <= '0;
      vector_data <= '0;
      beat_index <= '0;
      contiguous_burst <= 1'b0;
      burst_vectors <= BURST_VECTOR_W'(1);
      burst_beats <= BURST_BEAT_W'(BEATS_PER_VECTOR);
      burst_read_index <= '0;
      burst_beat_index <= '0;
      for (int burst = 0; burst < MAX_BURST_VECTORS; burst++) burst_data[burst] <= '0;
      pool_active <= 1'b0;
      pool_phase <= '0;
      pool_data0 <= '0; pool_data1 <= '0; pool_data2 <= '0;
      pool_row_base <= '0; pool_column_base <= '0;
      done <= 1'b0;
      fault <= 1'b0;
      vectors_written <= '0;
      bytes_written <= '0;
    end else if (clear) begin
      state <= IDLE;
      done <= 1'b0;
      fault <= 1'b0;
      vector_index <= '0;
      beat_index <= '0;
      contiguous_burst <= 1'b0;
      burst_vectors <= BURST_VECTOR_W'(1);
      burst_beats <= BURST_BEAT_W'(BEATS_PER_VECTOR);
      burst_read_index <= '0;
      burst_beat_index <= '0;
      pool_active <= 1'b0;
      pool_phase <= '0;
      pool_row_base <= '0; pool_column_base <= '0;
      vectors_written <= '0;
      bytes_written <= '0;
    end else begin
      case (state)
        IDLE: if (start) begin
          done <= 1'b0;
          fault <= 1'b0;
          vector_index <= '0;
          beat_index <= '0;
          contiguous_burst <= !pool_2x2 && (effective_valid_bytes == VECTOR_BYTES) &&
            (effective_stride_bytes == VECTOR_BYTES) &&
            (effective_valid_bytes == VECTOR_BYTES);
          burst_vectors <= (!pool_2x2 && (effective_valid_bytes == VECTOR_BYTES) &&
            (effective_stride_bytes == VECTOR_BYTES) &&
            (effective_valid_bytes == VECTOR_BYTES)) ? initial_burst_vectors : BURST_VECTOR_W'(1);
          burst_beats <= (!pool_2x2 && (effective_valid_bytes == VECTOR_BYTES) &&
            (effective_stride_bytes == VECTOR_BYTES) &&
            (effective_valid_bytes == VECTOR_BYTES)) ? initial_burst_beats : BURST_BEAT_W'(effective_valid_beats);
          burst_read_index <= '0;
          burst_beat_index <= '0;
          vectors_written <= '0;
          bytes_written <= '0;
          pool_active <= pool_2x2;
          pool_phase <= '0;
          pool_row_base <= '0;
          pool_column_base <= '0;
          if ((destination_addr[2:0] != 0) || (effective_stride_bytes[2:0] != 0) ||
              (effective_valid_bytes == 0) || (effective_valid_bytes > VECTOR_BYTES) ||
              (input_width == 0) ||
              // Pooling reads full vectors from the local output bank, but
              // its DDR write may be a channel tile inside a wider NHWC
              // tensor.  Permit a runtime stride and an 8-byte tail here;
              // WSTRB already protects inactive tail lanes.
              (pool_2x2 && (effective_vector_count[1:0] != 0)) ||
              (byte_count != ((pool_2x2 ? effective_pooled_vector_count : effective_vector_count) * effective_valid_bytes))) begin
            fault <= 1'b1;
          end else begin
            next_addr <= destination_addr;
            state <= ISSUE_READ;
          end
        end
        ISSUE_READ: state <= CAPTURE_READ;
        CAPTURE_READ: if (!pool_active && contiguous_burst) begin
          burst_data[int'(burst_read_index)] <= bank_read_data;
          if (BURST_VECTOR_W'(burst_read_index) == burst_last_vector_index) begin
            burst_beat_index <= '0;
            state <= ISSUE_AW;
          end else begin
            burst_read_index <= burst_read_index + 1'b1;
            state <= ISSUE_READ;
          end
        end else if (!pool_active) begin
          vector_data <= bank_read_data;
          state <= ISSUE_AW;
        end else begin
          case (pool_phase)
            2'd0: begin pool_data0 <= bank_read_data; pool_phase <= 2'd1; state <= ISSUE_READ; end
            2'd1: begin pool_data1 <= bank_read_data; pool_phase <= 2'd2; state <= ISSUE_READ; end
            2'd2: begin pool_data2 <= bank_read_data; pool_phase <= 2'd3; state <= ISSUE_READ; end
            default: begin vector_data <= max4_vectors(pool_data0, pool_data1, pool_data2, bank_read_data); state <= ISSUE_AW; end
          endcase
        end
        ISSUE_AW: if (m_axi_awvalid && m_axi_awready) begin
          beat_index <= '0;
          state <= SEND_W;
        end
        SEND_W: if (m_axi_wvalid && m_axi_wready) begin
          if (contiguous_burst) begin
            if (BURST_BEAT_W'(burst_beat_index) == burst_last_beat_index) state <= WAIT_B;
            else burst_beat_index <= burst_beat_index + 1'b1;
          end else begin
            if (BEAT_INDEX_W'(beat_index) == BEAT_INDEX_W'(effective_valid_beats - 1)) state <= WAIT_B;
            else beat_index <= beat_index + 1'b1;
          end
        end
        WAIT_B: if (m_axi_bvalid && m_axi_bready) begin
          if ((m_axi_bid != 0) || (m_axi_bresp != 0)) fault <= 1'b1;
          vectors_written <= vectors_written + VECTOR_ADDR_W'(int'(vectors_in_transaction));
          bytes_written <= bytes_written + effective_valid_bytes * vectors_in_transaction;
          if (32'(vector_index) + vectors_in_transaction >=
              (pool_active ? effective_pooled_vector_count : effective_vector_count)) begin
            done <= 1'b1;
            state <= IDLE;
          end else begin
            vector_index <= VECTOR_ADDR_W'(int'(vector_index) +
              (contiguous_burst ? int'(burst_vectors) : 1));
            pool_phase <= '0;
            next_addr <= next_addr + (contiguous_burst ? burst_step_bytes : effective_stride_bytes);
            if (contiguous_burst) begin
              burst_vectors <= choose_burst_vectors(
                effective_vector_count - 32'(vector_index) - 32'(burst_vectors),
                next_addr[11:0] + burst_step_bytes[11:0]);
              burst_beats <= BURST_BEAT_W'(int'(choose_burst_vectors(
                effective_vector_count - 32'(vector_index) - 32'(burst_vectors),
                next_addr[11:0] + burst_step_bytes[11:0]) * BEATS_PER_VECTOR));
              burst_read_index <= '0;
              burst_beat_index <= '0;
            end
            if (pool_active) begin
              if (pool_column_base == input_width - 2) begin
                pool_column_base <= '0;
                pool_row_base <= pool_row_base + ({16'd0, input_width} << 1);
              end else begin
                pool_column_base <= pool_column_base + 2;
              end
            end
            state <= ISSUE_READ;
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
