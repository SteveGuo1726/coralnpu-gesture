// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Descriptor-driven weight tile reader for the 7020 GestureFlow-NPU.  The
// PS-side WCTRL/WDATA path remains the debug fallback; this block is the
// performance path being built for model weights that already reside in DDR.
// A descriptor starts one contiguous, 64-bit aligned tile transfer.  The
// reader converts AXI beats to four-byte local-bank writes and advances the
// output-channel/tap/input-group coordinates without ARM intervention.
`timescale 1ns/1ps
module gestureflow_hp0_weight_dma_loader #(
  parameter int FIFO_BEATS = 16,
  parameter int MAX_TAPS = 16,
  parameter int MAX_GROUPS = 20
) (
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic clear,
  input logic [31:0] source_addr,
  input logic [31:0] byte_count,
  input logic [4:0] taps_per_output,
  input logic [4:0] groups_per_tap,
  output logic busy,
  output logic done,
  output logic fault,
  output logic [31:0] bytes_read,
  output logic [31:0] write_count,
  output logic weight_write_valid,
  output logic [3:0] weight_write_oc,
  output logic [3:0] weight_write_tap,
  output logic [4:0] weight_write_ic_group,
  output logic signed [3:0][7:0] weight_write_data,

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
  localparam int PTR_W = (FIFO_BEATS <= 1) ? 1 : $clog2(FIFO_BEATS);
  localparam int COUNT_W = $clog2(FIFO_BEATS + 1);
  state_t state;
  logic [63:0] beat_fifo [0:FIFO_BEATS-1];
  logic [PTR_W-1:0] read_ptr, write_ptr;
  logic [COUNT_W-1:0] buffered_beats;
  logic [31:0] next_addr, bytes_remaining;
  logic [5:0] beats_remaining, requested_beats;
  logic [31:0] words_remaining;
  logic [4:0] cfg_taps, cfg_groups;
  logic [3:0] oc_count, tap_count;
  logic [4:0] group_count;
  logic word_half;
  logic [31:0] current_word;
  logic current_word_valid;
  logic read_fire, write_fire, beat_release;

  initial begin
    if ((FIFO_BEATS < 2) || ((FIFO_BEATS & (FIFO_BEATS - 1)) != 0) ||
        (MAX_TAPS > 16) || (MAX_GROUPS > 20))
      $error("invalid weight DMA parameters");
  end

  function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] value, input integer amount);
    ptr_inc = value + PTR_W'(amount);
  endfunction

  function automatic [5:0] choose_burst_beats(input logic [31:0] remaining, input logic [11:0] low_addr);
    integer requested, until_boundary;
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
  assign read_fire = m_axi_rvalid && m_axi_rready;
  assign write_fire = weight_write_valid;
  assign beat_release = write_fire && word_half;

  // A beat is consumed only after its two words have both been emitted.
  // Keeping the half-word state separate permits one local-bank write per
  // cycle while AXI continues filling the ring.
  always_comb begin
    current_word = word_half ? beat_fifo[read_ptr][63:32] : beat_fifo[read_ptr][31:0];
    weight_write_valid = (state != IDLE) && current_word_valid && (words_remaining != 0);
    weight_write_data = current_word;
    weight_write_oc = oc_count;
    weight_write_tap = tap_count;
    weight_write_ic_group = group_count;
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
    // A half-consumed beat still occupies one FIFO slot.  Only the second
    // word release can make room for a simultaneous AXI beat.
    m_axi_rready = (state == RECEIVE_R) &&
                   ((buffered_beats < COUNT_W'(FIFO_BEATS)) ||
                    (write_fire && word_half));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE; read_ptr <= '0; write_ptr <= '0; buffered_beats <= '0;
      next_addr <= '0; bytes_remaining <= '0; beats_remaining <= '0;
      words_remaining <= '0; cfg_taps <= '0; cfg_groups <= '0;
      oc_count <= '0; tap_count <= '0; group_count <= '0; word_half <= 1'b0;
      current_word_valid <= 1'b0; done <= 1'b0; fault <= 1'b0;
      bytes_read <= '0; write_count <= '0;
    end else if (clear) begin
      state <= IDLE; read_ptr <= '0; write_ptr <= '0; buffered_beats <= '0;
      bytes_remaining <= '0; beats_remaining <= '0; words_remaining <= '0;
      current_word_valid <= 1'b0; done <= 1'b0; fault <= 1'b0;
      bytes_read <= '0; write_count <= '0;
    end else begin
      if (read_fire) begin
        beat_fifo[write_ptr] <= m_axi_rdata;
        write_ptr <= ptr_inc(write_ptr, 1);
        bytes_remaining <= bytes_remaining - 8;
        bytes_read <= bytes_read + 8;
        beats_remaining <= beats_remaining - 1'b1;
        if ((m_axi_rid != 0) || (m_axi_rresp != 0) ||
            (m_axi_rlast != (beats_remaining == 1))) fault <= 1'b1;
      end

      if (write_fire) begin
        write_count <= write_count + 1'b1;
        words_remaining <= words_remaining - 1'b1;
        if (!word_half) begin
          word_half <= 1'b1;
        end else begin
          word_half <= 1'b0;
          read_ptr <= ptr_inc(read_ptr, 1);
        end
        if (group_count == cfg_groups - 1'b1) begin
          group_count <= '0;
          if (tap_count == (cfg_taps[3:0] - 4'd1)) begin
            tap_count <= '0;
            if (oc_count == 4'd15) oc_count <= '0;
            else oc_count <= oc_count + 1'b1;
          end else tap_count <= tap_count + 1'b1;
        end else group_count <= group_count + 1'b1;
        if (words_remaining == 1) begin
          current_word_valid <= 1'b0;
          state <= IDLE;
          done <= 1'b1;
        end
      end

      case ({read_fire, beat_release})
        2'b10: buffered_beats <= buffered_beats + 1'b1;
        2'b01: buffered_beats <= buffered_beats - 1'b1;
        default: begin end
      endcase

      // A beat becomes visible to the writer on the cycle after the AXI
      // handshake. This avoids exposing a just-written ring entry through a
      // combinational read path and keeps the BRAM inference conservative.
      if (beat_release) begin
        if (read_fire || (buffered_beats > 1)) current_word_valid <= 1'b1;
        else current_word_valid <= 1'b0;
      end else if (!current_word_valid && buffered_beats != 0) begin
        current_word_valid <= 1'b1;
      end
      case (state)
        IDLE: if (start) begin
          done <= 1'b0; fault <= 1'b0; read_ptr <= '0; write_ptr <= '0;
          buffered_beats <= '0; bytes_read <= '0; write_count <= '0;
          word_half <= 1'b0; current_word_valid <= 1'b0;
          oc_count <= '0; tap_count <= '0; group_count <= '0;
          cfg_taps <= taps_per_output; cfg_groups <= groups_per_tap;
          words_remaining <= (byte_count >> 2);
          if ((source_addr[2:0] != 0) || (byte_count == 0) ||
              (byte_count[2:0] != 0) || (taps_per_output == 0) ||
              (groups_per_tap == 0) || ((byte_count >> 2) !=
                (32'(16) * taps_per_output * groups_per_tap))) begin
            fault <= 1'b1;
          end else begin
            next_addr <= source_addr; bytes_remaining <= byte_count; state <= ISSUE_AR;
          end
        end
        ISSUE_AR: if (m_axi_arvalid && m_axi_arready) begin
          if (requested_beats == 0) begin fault <= 1'b1; state <= IDLE; end
          else begin beats_remaining <= requested_beats; next_addr <= next_addr + ({26'd0, requested_beats} << 3); state <= RECEIVE_R; end
        end
        RECEIVE_R: if (read_fire && (beats_remaining == 1)) begin
          if (bytes_remaining == 8) state <= DRAIN; else state <= ISSUE_AR;
        end
        DRAIN: begin end
        default: begin fault <= 1'b1; state <= IDLE; end
      endcase
    end
  end
endmodule
