// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Banked/ring-buffer A/B implementation of the HP0 NHWC tensor loader. The
// legacy loader shifts a CHANNELS*8-bit packed register after every pixel.
// This version stores 64-bit AXI beats in a fixed ring and advances pointers
// by beat count, so input consumption does not create a wide shift network.
// A vector remains atomic: no pixel_valid is asserted until all CHANNELS/8
// beats are buffered.
`timescale 1ns/1ps
module gestureflow_hp0_tensor_loader_banked #(
  parameter int CHANNELS = 16,
  parameter int FIFO_BEATS = 16
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
  localparam int VECTOR_BEATS = CHANNELS / 8;
  localparam int PTR_W = (FIFO_BEATS <= 1) ? 1 : $clog2(FIFO_BEATS);
  localparam int COUNT_W = $clog2(FIFO_BEATS + 1);

  state_t state;
  logic [63:0] beat_fifo [0:FIFO_BEATS-1];
  logic [PTR_W-1:0] read_ptr, write_ptr;
  logic [COUNT_W-1:0] buffered_beats;
  logic [31:0] next_addr;
  logic [31:0] bytes_remaining;
  logic [5:0] beats_remaining;
  logic stream_started;
  logic [5:0] requested_beats;
  logic pixel_fire;
  logic read_fire;

  initial begin
    if ((CHANNELS < 8) || ((CHANNELS % 8) != 0) || (CHANNELS > FIFO_BEATS * 8) ||
        (FIFO_BEATS < 2) || ((FIFO_BEATS & (FIFO_BEATS - 1)) != 0)) begin
      $error("CHANNELS/FIFO_BEATS must be byte-aligned and fit a power-of-two beat ring");
    end
  end

  function automatic logic [PTR_W-1:0] ptr_inc(
    input logic [PTR_W-1:0] value,
    input integer amount
  );
    begin
      // FIFO_BEATS is constrained to a power of two above. Truncation of
      // this fixed-width sum is therefore the ring modulo operation and is
      // directly synthesizable by Vivado, unlike an unbounded while loop.
      ptr_inc = value + PTR_W'(amount);
    end
  endfunction

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
      if (requested > FIFO_BEATS) requested = FIFO_BEATS;
      if (requested > 16) requested = 16;
      if (requested > until_boundary) requested = until_boundary;
      choose_burst_beats = requested[5:0];
    end
  endfunction

  assign requested_beats = choose_burst_beats(bytes_remaining, next_addr[11:0]);
  assign busy = (state != IDLE);
  assign pixel_valid = (state != IDLE) && stream_started &&
                       (buffered_beats >= COUNT_W'(VECTOR_BEATS));
  assign pixel_fire = pixel_valid && pixel_ready;
  assign read_fire = m_axi_rvalid && m_axi_rready;

  for (genvar channel = 0; channel < CHANNELS; channel++) begin : unpack_pixel
    localparam int BEAT_INDEX = channel / 8;
    localparam int BYTE_INDEX = channel % 8;
    assign pixel_data[channel] = beat_fifo[read_ptr + PTR_W'(BEAT_INDEX)][BYTE_INDEX * 8 +: 8];
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

    // The ring can accept a beat while the consumer removes a full vector.
    // This removes the legacy receive/consume mutual exclusion without ever
    // allowing the beat count to exceed FIFO_BEATS.
    m_axi_rready = (state == RECEIVE_R) &&
                   ((buffered_beats < COUNT_W'(FIFO_BEATS)) || pixel_fire);
    frame_start = !stream_started && (state != IDLE) &&
                  (buffered_beats >= COUNT_W'(VECTOR_BEATS));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      read_ptr <= '0;
      write_ptr <= '0;
      buffered_beats <= '0;
      next_addr <= '0;
      bytes_remaining <= '0;
      beats_remaining <= '0;
      stream_started <= 1'b0;
      done <= 1'b0;
      fault <= 1'b0;
      pixels_emitted <= '0;
      bytes_read <= '0;
    end else if (clear) begin
      state <= IDLE;
      read_ptr <= '0;
      write_ptr <= '0;
      buffered_beats <= '0;
      done <= 1'b0;
      fault <= 1'b0;
      stream_started <= 1'b0;
      pixels_emitted <= '0;
      bytes_read <= '0;
      bytes_remaining <= '0;
      beats_remaining <= '0;
    end else begin
      if (!stream_started && frame_start) stream_started <= 1'b1;

      if (pixel_fire) begin
        read_ptr <= ptr_inc(read_ptr, VECTOR_BEATS);
        pixels_emitted <= pixels_emitted + 1'b1;
        if ((pixels_emitted == pixel_count - 1'b1) && (state == DRAIN)) begin
          done <= 1'b1;
          state <= IDLE;
        end
      end

      if (read_fire) begin
        beat_fifo[write_ptr] <= m_axi_rdata;
        write_ptr <= ptr_inc(write_ptr, 1);
        bytes_remaining <= bytes_remaining - 8;
        bytes_read <= bytes_read + 8;
        beats_remaining <= beats_remaining - 1'b1;
        if ((m_axi_rid != 0) || (m_axi_rresp != 0) ||
            (m_axi_rlast != (beats_remaining == 1))) fault <= 1'b1;
      end

      case ({read_fire, pixel_fire})
        2'b10: buffered_beats <= buffered_beats + 1'b1;
        2'b01: buffered_beats <= buffered_beats - COUNT_W'(VECTOR_BEATS);
        2'b11: buffered_beats <= buffered_beats + 1'b1 - COUNT_W'(VECTOR_BEATS);
        default: begin end
      endcase

      case (state)
        IDLE: if (start) begin
          done <= 1'b0;
          fault <= 1'b0;
          read_ptr <= '0;
          write_ptr <= '0;
          buffered_beats <= '0;
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
        RECEIVE_R: begin
          if (read_fire && (beats_remaining == 1)) begin
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
endmodule
