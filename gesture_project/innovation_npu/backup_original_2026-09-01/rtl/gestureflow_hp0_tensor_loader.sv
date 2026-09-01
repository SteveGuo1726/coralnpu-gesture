// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// HP0 AXI4 reader for an already quantized NHWC feature tensor. Unlike the
// camera RGB loader, payload bytes are consumed as signed INT8 verbatim: this
// is the required format for layer-to-layer DDR handoff. One complete feature
// vector is emitted only when all of its channels are present in the elastic
// byte FIFO, preserving pixel atomicity under MAC backpressure.
`timescale 1ns/1ps
module gestureflow_hp0_tensor_loader #(
  parameter int CHANNELS = 16
) (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic [31:0] source_addr,
  input logic [31:0] byte_count,
  input logic [13:0] pixel_count,
  output logic busy,
  output logic done,
  output logic fault,
  output logic frame_start,
  output logic pixel_valid,
  input logic pixel_ready,
  output logic signed [CHANNELS-1:0][7:0] pixel_data,
  output logic [13:0] pixels_emitted,
  output logic [31:0] bytes_read,

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
  typedef enum logic [1:0] {IDLE, ISSUE_AR, RECEIVE_R, DRAIN} state_t;
  localparam int FIFO_BYTES = CHANNELS;
  localparam int FIFO_BYTES_W = (FIFO_BYTES < 2) ? 1 : $clog2(FIFO_BYTES + 1);
  localparam logic [FIFO_BYTES_W-1:0] FIFO_LIMIT = FIFO_BYTES_W'(FIFO_BYTES - 8);
  // Keep the compare/subtract operand sized to this instance's FIFO counter.
  // The 16-channel reader has a 5-bit counter while the 80-channel reader
  // needs seven bits; a universal constant would truncate in smaller modes.
  localparam logic [FIFO_BYTES_W-1:0] CHANNEL_BYTES = FIFO_BYTES_W'(CHANNELS);
  state_t state;
  logic [31:0] next_addr;
  logic [31:0] bytes_remaining;
  logic [5:0] beats_remaining;
  logic [FIFO_BYTES*8-1:0] byte_fifo;
  logic [FIFO_BYTES_W-1:0] fifo_bytes;
  logic stream_started;
  logic [5:0] requested_beats;
  logic pixel_fire;

  function automatic [5:0] choose_burst_beats(
    input logic [31:0] remaining,
    input logic [11:0] low_addr
  );
    integer requested;
    integer until_boundary;
    begin
      requested = int'(remaining >> 3);
      until_boundary = (4096 - int'(low_addr)) >> 3;
      if (until_boundary == 0) until_boundary = 512;
      if (requested > 16) requested = 16;
      if (requested > until_boundary) requested = until_boundary;
      choose_burst_beats = requested[5:0];
    end
  endfunction

  initial begin
    if (CHANNELS > 112 || (CHANNELS % 8) != 0) begin
      $error("CHANNELS must be an 8-byte multiple not exceeding the 112-byte FIFO");
    end
  end

  assign requested_beats = choose_burst_beats(bytes_remaining, next_addr[11:0]);
  assign busy = (state != IDLE);
  assign pixel_valid = (state != IDLE) && stream_started && (fifo_bytes >= CHANNEL_BYTES);
  assign pixel_fire = pixel_valid && pixel_ready;
  for (genvar channel = 0; channel < CHANNELS; channel++) begin : unpack_pixel
    assign pixel_data[channel] = byte_fifo[channel*8 +: 8];
  end

  always_comb begin
    m_axi_araddr = next_addr;
    m_axi_arid = 6'd0;
    m_axi_arlen = {2'b0, requested_beats} - 8'd1;
    m_axi_arsize = 3'd3;
    m_axi_arburst = 2'b01;
    m_axi_arlock = 1'b0;
    m_axi_arcache = 4'b0011;
    m_axi_arprot = 3'b000;
    m_axi_arqos = 4'd0;
    m_axi_arregion = 4'd0;
    m_axi_arvalid = (state == ISSUE_AR);
    // A complete vector consumes the FIFO atomically. Permit a response
    // only when the next 64-bit beat cannot overflow it and never append on
    // the same cycle in which the FIFO shifts by a feature vector.
    m_axi_rready = (state == RECEIVE_R) && (fifo_bytes <= FIFO_LIMIT) && !pixel_fire;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      next_addr <= '0;
      bytes_remaining <= '0;
      beats_remaining <= '0;
      byte_fifo <= '0;
      fifo_bytes <= '0;
      stream_started <= 1'b0;
      done <= 1'b0;
      fault <= 1'b0;
      frame_start <= 1'b0;
      pixels_emitted <= '0;
      bytes_read <= '0;
    end else begin
      frame_start <= 1'b0;
      if (clear) begin
        state <= IDLE;
        done <= 1'b0;
        fault <= 1'b0;
        fifo_bytes <= '0;
        stream_started <= 1'b0;
        pixels_emitted <= '0;
        bytes_read <= '0;
        bytes_remaining <= '0;
        beats_remaining <= '0;
      end else begin
        if (!stream_started && state != IDLE && fifo_bytes >= CHANNEL_BYTES) begin
          frame_start <= 1'b1;
          stream_started <= 1'b1;
        end
        if (pixel_fire) begin
          byte_fifo <= byte_fifo >> (CHANNELS * 8);
          fifo_bytes <= fifo_bytes - CHANNEL_BYTES;
          pixels_emitted <= pixels_emitted + 1'b1;
          if ((pixels_emitted == pixel_count - 1'b1) && state == DRAIN) begin
            done <= 1'b1;
            state <= IDLE;
          end
        end
        case (state)
          IDLE: if (start) begin
            done <= 1'b0;
            fault <= 1'b0;
            fifo_bytes <= '0;
            byte_fifo <= '0;
            stream_started <= 1'b0;
            pixels_emitted <= '0;
            bytes_read <= '0;
            if ((source_addr[2:0] != 0) || (byte_count == 0) ||
                (byte_count[2:0] != 0) || (byte_count != pixel_count * CHANNELS)) begin
              fault <= 1'b1;
            end else begin
              next_addr <= source_addr;
              bytes_remaining <= byte_count;
              state <= ISSUE_AR;
            end
          end
          ISSUE_AR: if (m_axi_arvalid && m_axi_arready) begin
            if (requested_beats == 0) begin
              fault <= 1'b1;
              state <= IDLE;
            end else begin
              beats_remaining <= requested_beats;
              next_addr <= next_addr + ({26'd0, requested_beats} << 3);
              state <= RECEIVE_R;
            end
          end
          RECEIVE_R: if (m_axi_rvalid && m_axi_rready) begin
            byte_fifo[fifo_bytes*8 +: 64] <= m_axi_rdata;
            fifo_bytes <= fifo_bytes + 8;
            bytes_remaining <= bytes_remaining - 8;
            bytes_read <= bytes_read + 8;
            beats_remaining <= beats_remaining - 1'b1;
            if ((m_axi_rid != 0) || (m_axi_rresp != 0) ||
                (m_axi_rlast != (beats_remaining == 1))) fault <= 1'b1;
            if (beats_remaining == 1) begin
              if (bytes_remaining == 8) state <= DRAIN;
              else state <= ISSUE_AR;
            end
          end
          DRAIN: begin end
          default: begin
            fault <= 1'b1;
            state <= IDLE;
          end
        endcase
      end
    end
  end
endmodule
