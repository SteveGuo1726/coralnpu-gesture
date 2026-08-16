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
  parameter int VECTOR_BYTES = 16
) (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic [31:0] destination_addr,
  input logic [31:0] byte_count,
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
  localparam int EXPECTED_BYTES = VECTOR_COUNT * VECTOR_BYTES;
  state_t state;
  logic [VECTOR_ADDR_W-1:0] vector_index;
  logic [31:0] next_addr;
  logic [VECTOR_BYTES*8-1:0] vector_data;
  logic beat_index;

  assign busy = (state != IDLE);

  always_comb begin
    bank_read_addr = vector_index;
    bank_read_enable = (state == ISSUE_READ);
    m_axi_awaddr = next_addr;
    m_axi_awid = 6'd0;
    m_axi_awlen = 8'd1;
    m_axi_awsize = 3'd3;
    m_axi_awburst = 2'b01;
    m_axi_awlock = 1'b0;
    m_axi_awcache = 4'b0011;
    m_axi_awprot = 3'b000;
    m_axi_awqos = 4'd0;
    m_axi_awregion = 4'd0;
    m_axi_awvalid = (state == ISSUE_AW);
    m_axi_wdata = beat_index ? vector_data[127:64] : vector_data[63:0];
    m_axi_wstrb = 8'hff;
    m_axi_wlast = (state == SEND_W) && beat_index;
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
          if ((destination_addr[3:0] != 0) || (byte_count != EXPECTED_BYTES)) begin
            fault <= 1'b1;
          end else begin
            next_addr <= destination_addr;
            state <= ISSUE_READ;
          end
        end
        ISSUE_READ: state <= CAPTURE_READ;
        CAPTURE_READ: begin
          vector_data <= bank_read_data;
          state <= ISSUE_AW;
        end
        ISSUE_AW: if (m_axi_awvalid && m_axi_awready) begin
          beat_index <= 1'b0;
          state <= SEND_W;
        end
        SEND_W: if (m_axi_wvalid && m_axi_wready) begin
          if (!beat_index) begin
            beat_index <= 1'b1;
          end else begin
            state <= WAIT_B;
          end
        end
        WAIT_B: if (m_axi_bvalid && m_axi_bready) begin
          if ((m_axi_bid != 0) || (m_axi_bresp != 0)) fault <= 1'b1;
          vectors_written <= vectors_written + 1'b1;
          bytes_written <= bytes_written + VECTOR_BYTES;
          if (vector_index == VECTOR_ADDR_W'(VECTOR_COUNT - 1)) begin
            done <= 1'b1;
            state <= IDLE;
          end else begin
            vector_index <= vector_index + 1'b1;
            next_addr <= next_addr + VECTOR_BYTES;
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
