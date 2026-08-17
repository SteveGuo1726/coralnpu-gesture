// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Bounded AXI4 writer for an NHWC activation tile already resident in the
// local output bank. It serializes one 16-byte feature vector as two 64-bit
// beats, checks every B response, and never overlaps the input reader. This
// is the first layer-to-layer handoff primitive, not a camera DMA.
`timescale 1ns/1ps
module gestureflow_hp0_tensor_writer #(
  parameter int VECTOR_COUNT = 9216,
  parameter int VECTOR_ADDR_W = 14,
  parameter int VECTOR_BYTES = 16,
  parameter int INPUT_WIDTH = 96
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
  input logic [4:0] valid_vector_bytes,
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
  logic [VECTOR_ADDR_W-1:0] vector_index;
  logic [31:0] next_addr;
  logic [VECTOR_BYTES*8-1:0] vector_data;
  logic beat_index;
  logic pool_active;
  logic [1:0] pool_phase;
  logic [31:0] pool_read_address;
  logic [VECTOR_BYTES*8-1:0] pool_data0, pool_data1, pool_data2;
  logic [31:0] pool_row_base;
  logic [15:0] pool_column_base;
  logic [31:0] effective_stride_bytes, effective_valid_bytes;
  logic [31:0] effective_vector_count, effective_pooled_vector_count;

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
    effective_valid_bytes = valid_vector_bytes == 0 ? 32'(VECTOR_BYTES) : {27'd0, valid_vector_bytes};
    effective_vector_count = vector_count == 0 ? 32'(VECTOR_COUNT) : {18'd0, vector_count};
    effective_pooled_vector_count = effective_vector_count >> 2;
    // This is intentionally counter based rather than vector_index divided
    // by runtime width. A dynamic divider would be an avoidable LUT/timing
    // hotspot on the 7020 write path.
    pool_read_address = pool_row_base + {16'd0, pool_column_base} +
      (pool_phase[1] ? {16'd0, input_width} : 32'd0) + {31'd0, pool_phase[0]};
    if (pool_active) bank_read_addr = VECTOR_ADDR_W'(pool_read_address);
    else bank_read_addr = vector_index;
    bank_read_enable = (state == ISSUE_READ);
    m_axi_awaddr = next_addr;
    m_axi_awid = 6'd0;
    m_axi_awlen = effective_valid_bytes <= 8 ? 8'd0 : 8'd1;
    m_axi_awsize = 3'd3;
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = 4'b0011;
    m_axi_awprot = 3'b000;
    m_axi_awqos = 4'd0;
    m_axi_awregion = 4'd0;
    m_axi_awvalid = (state == ISSUE_AW);
    m_axi_wdata = beat_index ? vector_data[127:64] : vector_data[63:0];
    if (!beat_index) begin
      if (effective_valid_bytes >= 8) m_axi_wstrb = 8'hff;
      else m_axi_wstrb = (8'h01 << effective_valid_bytes) - 1'b1;
    end else if (effective_valid_bytes >= 16) begin
      m_axi_wstrb = 8'hff;
    end else begin
      m_axi_wstrb = (8'h01 << (effective_valid_bytes - 8)) - 1'b1;
    end
    m_axi_wlast = (state == SEND_W) && (beat_index || effective_valid_bytes <= 8);
    m_axi_wvalid = (state == SEND_W);
    m_axi_bready = (state == WAIT_B);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      vector_index <= '0;
      next_addr <= '0;
      vector_data <= '0;
      beat_index <= 1'b0;
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
      beat_index <= 1'b0;
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
          beat_index <= 1'b0;
          vectors_written <= '0;
          bytes_written <= '0;
          pool_active <= pool_2x2;
          pool_phase <= '0;
          pool_row_base <= '0;
          pool_column_base <= '0;
          if ((destination_addr[2:0] != 0) || (effective_stride_bytes[2:0] != 0) ||
              (effective_valid_bytes == 0) || (effective_valid_bytes > VECTOR_BYTES) ||
              (input_width == 0) ||
              (pool_2x2 && ((effective_valid_bytes != VECTOR_BYTES) ||
                             (effective_stride_bytes != VECTOR_BYTES) ||
                             (effective_vector_count[1:0] != 0))) ||
              (byte_count != ((pool_2x2 ? effective_pooled_vector_count : effective_vector_count) * effective_valid_bytes))) begin
            fault <= 1'b1;
          end else begin
            next_addr <= destination_addr;
            state <= ISSUE_READ;
          end
        end
        ISSUE_READ: state <= CAPTURE_READ;
        CAPTURE_READ: if (!pool_active) begin
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
          beat_index <= 1'b0;
          state <= SEND_W;
        end
        SEND_W: if (m_axi_wvalid && m_axi_wready) begin
          if (!beat_index) begin
            if (effective_valid_bytes <= 8) state <= WAIT_B;
            else beat_index <= 1'b1;
          end else begin
            state <= WAIT_B;
          end
        end
        WAIT_B: if (m_axi_bvalid && m_axi_bready) begin
          if ((m_axi_bid != 0) || (m_axi_bresp != 0)) fault <= 1'b1;
          vectors_written <= vectors_written + 1'b1;
          bytes_written <= bytes_written + effective_valid_bytes;
          if (vector_index == VECTOR_ADDR_W'((pool_active ? effective_pooled_vector_count : effective_vector_count) - 1)) begin
            done <= 1'b1;
            state <= IDLE;
          end else begin
            vector_index <= vector_index + 1'b1;
            pool_phase <= '0;
            next_addr <= next_addr + effective_stride_bytes;
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
