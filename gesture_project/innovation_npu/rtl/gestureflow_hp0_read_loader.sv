// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Bounded DDR-to-activation-BRAM reader for the Zynq-7020 HP0 port.  The
// loader owns one outstanding INCR burst at a time, uses 64-bit beats to
// match HP0, and serializes each beat into the existing 32-bit activation
// bank.  Keeping this unit separate from the MAC scheduler makes the proven
// staged compute contract unchanged while replacing PS AXI-Lite word writes.
`timescale 1ns/1ps
module gestureflow_hp0_read_loader (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic        clear,
  input  logic [31:0] source_addr,
  input  logic [8:0]  word_count,
  input  logic [7:0]  destination_addr,
  output logic        busy,
  output logic        done,
  output logic        fault,
  output logic        stage_write_enable,
  output logic [7:0]  stage_write_addr,
  output logic [31:0] stage_write_data,

  output logic [31:0] m_axi_araddr,
  output logic [5:0]  m_axi_arid,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arlock,
  output logic [3:0]  m_axi_arcache,
  output logic [2:0]  m_axi_arprot,
  output logic [3:0]  m_axi_arqos,
  output logic [3:0]  m_axi_arregion,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [5:0]  m_axi_rid,
  input  logic [63:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready
);
  typedef enum logic [1:0] {IDLE, ISSUE_AR, RECEIVE_R, WRITE_HIGH} state_t;
  state_t state;
  logic [31:0] next_addr;
  logic [8:0] remaining_words;
  logic [7:0] next_stage_addr;
  logic [4:0] beats_remaining;
  logic       saved_last_beat;
  logic [31:0] saved_high_word;

  function automatic [4:0] choose_burst_beats(
    input logic [8:0] words,
    input logic [11:0] low_addr
  );
    integer requested_beats;
    integer page_beats;
    begin
      requested_beats = (int'(words) + 1) >> 1;
      page_beats = (4096 - int'(low_addr)) >> 3;
      if (page_beats == 0) page_beats = 512;
      if (requested_beats > 16) requested_beats = 16;
      if (requested_beats > page_beats) requested_beats = page_beats;
      choose_burst_beats = requested_beats[4:0];
    end
  endfunction

  logic [4:0] requested_beats;
  assign requested_beats = choose_burst_beats(remaining_words, next_addr[11:0]);
  assign busy = (state != IDLE);

  always_comb begin
    m_axi_araddr = next_addr;
    m_axi_arid = 6'd0;
    m_axi_arlen = {3'd0, requested_beats} - 8'd1;
    m_axi_arsize = 3'd3; // 8-byte HP0 beat
    m_axi_arburst = 2'b01;
    m_axi_arlock = 1'b0;
    m_axi_arcache = 4'b0011;
    m_axi_arprot = 3'b000;
    m_axi_arqos = 4'd0;
    m_axi_arregion = 4'd0;
    m_axi_arvalid = (state == ISSUE_AR);
    m_axi_rready = (state == RECEIVE_R);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      next_addr <= '0;
      remaining_words <= '0;
      next_stage_addr <= '0;
      beats_remaining <= '0;
      saved_last_beat <= 1'b0;
      saved_high_word <= '0;
      done <= 1'b0;
      fault <= 1'b0;
      stage_write_enable <= 1'b0;
      stage_write_addr <= '0;
      stage_write_data <= '0;
    end else begin
      stage_write_enable <= 1'b0;
      if (clear) begin
        state <= IDLE;
        done <= 1'b0;
        fault <= 1'b0;
        remaining_words <= '0;
        beats_remaining <= '0;
      end else begin
        case (state)
          IDLE: begin
            if (start) begin
              done <= 1'b0;
              fault <= 1'b0;
              if ((word_count == 0) || (source_addr[2:0] != 3'd0)) begin
                fault <= 1'b1;
              end else begin
                next_addr <= source_addr;
                remaining_words <= word_count;
                next_stage_addr <= destination_addr;
                state <= ISSUE_AR;
              end
            end
          end
          ISSUE_AR: begin
            if (m_axi_arvalid && m_axi_arready) begin
              if (requested_beats == 0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                beats_remaining <= requested_beats;
                next_addr <= next_addr + ({27'd0, requested_beats} << 3);
                state <= RECEIVE_R;
              end
            end
          end
          RECEIVE_R: begin
            if (m_axi_rvalid && m_axi_rready) begin
              stage_write_enable <= 1'b1;
              stage_write_addr <= next_stage_addr;
              stage_write_data <= m_axi_rdata[31:0];
              next_stage_addr <= next_stage_addr + 1'b1;
              remaining_words <= remaining_words - 1'b1;
              beats_remaining <= beats_remaining - 1'b1;
              saved_last_beat <= (beats_remaining == 5'd1);
              if ((m_axi_rid != 6'd0) || (m_axi_rresp != 2'b00) ||
                  (m_axi_rlast != (beats_remaining == 5'd1))) begin
                fault <= 1'b1;
              end
              if (remaining_words > 9'd1) begin
                saved_high_word <= m_axi_rdata[63:32];
                state <= WRITE_HIGH;
              end else begin
                if (beats_remaining != 5'd1) fault <= 1'b1;
                done <= 1'b1;
                state <= IDLE;
              end
            end
          end
          WRITE_HIGH: begin
            stage_write_enable <= 1'b1;
            stage_write_addr <= next_stage_addr;
            stage_write_data <= saved_high_word;
            next_stage_addr <= next_stage_addr + 1'b1;
            remaining_words <= remaining_words - 1'b1;
            if (saved_last_beat) begin
              if (remaining_words <= 9'd2) begin
                done <= 1'b1;
                state <= IDLE;
              end else begin
                state <= ISSUE_AR;
              end
            end else begin
              state <= RECEIVE_R;
            end
          end
          default: begin
            fault <= 1'b1;
            state <= IDLE;
          end
        endcase
      end
    end
  end
endmodule
