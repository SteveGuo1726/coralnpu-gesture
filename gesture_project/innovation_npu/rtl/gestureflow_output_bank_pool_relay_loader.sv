// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Local 2x2 max-pool relay loader. It consumes a previously written 16-lane
// INT8 activation bank and replays the pooled tensor as a new input stream for
// the next layer without a DDR round trip. The four pixels of each 2x2 tile
// are read through a single bank read port in four cycles, so the output bank
// stays a true two-port BRAM.
`timescale 1ns/1ps
module gestureflow_output_bank_pool_relay_loader #(
  parameter int CHANNELS = 16,
  parameter int ADDR_W = 14,
  parameter int FIFO_DEPTH = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear,
  input  logic [13:0] pixel_count,
  input  logic [15:0] output_width,
  output logic busy,
  output logic done,
  output logic fault,
  output logic frame_start,
  output logic pixel_valid,
  input  logic pixel_ready,
  output logic signed [CHANNELS-1:0][7:0] pixel_data,
  output logic [13:0] pixels_emitted,
  output logic bank_read_enable,
  output logic [ADDR_W-1:0] bank_read_addr,
  input  logic [CHANNELS*8-1:0] bank_read_data
);
  typedef enum logic [2:0] {
    IDLE, READ_TL, READ_TR, READ_BL, READ_BR, PUSH_OUTPUT
  } state_t;

  localparam int FIFO_PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int FIFO_COUNT_W = $clog2(FIFO_DEPTH + 1);

  state_t state;
  logic active;
  logic stream_started;
  logic [31:0] source_row_base;
  logic [15:0] pooled_column;
  logic [13:0] pixels_generated;
  logic signed [CHANNELS-1:0][7:0] top_left_data, top_right_data, bottom_left_data;
  logic signed [CHANNELS-1:0][7:0] pending_output_data;
  logic signed [CHANNELS-1:0][7:0] fifo_data [0:FIFO_DEPTH-1];
  logic [FIFO_PTR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
  logic [FIFO_COUNT_W-1:0] fifo_count;
  logic consume_pixel, push_output, push_allowed;
  logic [31:0] source_width;
  logic [31:0] top_left_addr32;
  logic [31:0] bottom_left_addr32;
  logic [FIFO_COUNT_W:0] fifo_count_ext;
  logic [FIFO_COUNT_W:0] fifo_count_after_consume;

  function automatic logic signed [CHANNELS-1:0][7:0] max4_vectors(
    input logic signed [CHANNELS-1:0][7:0] a,
    input logic signed [CHANNELS-1:0][7:0] b,
    input logic signed [CHANNELS-1:0][7:0] c,
    input logic signed [CHANNELS-1:0][7:0] d
  );
    logic signed [7:0] maximum;
    for (int lane = 0; lane < CHANNELS; lane++) begin
      maximum = a[lane];
      if (b[lane] > maximum) maximum = b[lane];
      if (c[lane] > maximum) maximum = c[lane];
      if (d[lane] > maximum) maximum = d[lane];
      max4_vectors[lane] = maximum;
    end
  endfunction

  initial begin
    if (FIFO_DEPTH < 2) $error("FIFO_DEPTH must be at least two");
  end

  assign busy = active || (state != IDLE);
  assign pixel_valid = active && (fifo_count != 0);
  assign frame_start = active && !stream_started && pixel_valid;
  assign pixel_data = fifo_data[fifo_rd_ptr];
  assign consume_pixel = pixel_valid && pixel_ready;
  assign push_output = (state == PUSH_OUTPUT);
  assign source_width = {16'd0, output_width} << 1;
  assign top_left_addr32 = source_row_base + {15'd0, pooled_column, 1'b0};
  assign bottom_left_addr32 = top_left_addr32 + source_width;
  assign fifo_count_ext = {1'b0, fifo_count};
  assign fifo_count_after_consume = fifo_count_ext -
    (consume_pixel ? {{FIFO_COUNT_W{1'b0}}, 1'b1} : '0);
  assign push_allowed = !push_output || (fifo_count_after_consume < (FIFO_COUNT_W + 1)'(FIFO_DEPTH));

  always_comb begin
    bank_read_enable = 1'b0;
    bank_read_addr = '0;
    case (state)
      READ_TL: begin bank_read_enable = 1'b1; bank_read_addr = ADDR_W'(top_left_addr32); end
      READ_TR: begin bank_read_enable = 1'b1; bank_read_addr = ADDR_W'(top_left_addr32 + 1); end
      READ_BL: begin bank_read_enable = 1'b1; bank_read_addr = ADDR_W'(bottom_left_addr32); end
      READ_BR: begin bank_read_enable = 1'b1; bank_read_addr = ADDR_W'(bottom_left_addr32 + 1); end
      default: begin end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      active <= 1'b0;
      stream_started <= 1'b0;
      source_row_base <= '0;
      pooled_column <= '0;
      pixels_generated <= '0;
      pixels_emitted <= '0;
      top_left_data <= '0;
      top_right_data <= '0;
      bottom_left_data <= '0;
      pending_output_data <= '0;
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else if (clear) begin
      state <= IDLE;
      active <= 1'b0;
      stream_started <= 1'b0;
      source_row_base <= '0;
      pooled_column <= '0;
      pixels_generated <= '0;
      pixels_emitted <= '0;
      top_left_data <= '0;
      top_right_data <= '0;
      bottom_left_data <= '0;
      pending_output_data <= '0;
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start) begin
        state <= IDLE;
        active <= 1'b0;
        stream_started <= 1'b0;
        source_row_base <= '0;
        pooled_column <= '0;
        pixels_generated <= '0;
        pixels_emitted <= '0;
        fifo_wr_ptr <= '0;
        fifo_rd_ptr <= '0;
        fifo_count <= '0;
        top_left_data <= '0;
        top_right_data <= '0;
        bottom_left_data <= '0;
        pending_output_data <= '0;
        fault <= (pixel_count == 0) || (output_width == 0);
        if ((pixel_count != 0) && (output_width != 0)) begin
          active <= 1'b1;
          state <= READ_TL;
        end
      end else begin
        if (!stream_started && frame_start) stream_started <= 1'b1;

        if (consume_pixel) begin
          fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
          pixels_emitted <= pixels_emitted + 1'b1;
          if (pixels_emitted == pixel_count - 1'b1) begin
            active <= 1'b0;
            done <= 1'b1;
          end
        end

        case (state)
          IDLE: state <= IDLE;
          READ_TL: state <= READ_TR;
          READ_TR: begin
            top_left_data <= bank_read_data;
            state <= READ_BL;
          end
          READ_BL: begin
            top_right_data <= bank_read_data;
            state <= READ_BR;
          end
          READ_BR: begin
            bottom_left_data <= bank_read_data;
            state <= PUSH_OUTPUT;
          end
          PUSH_OUTPUT: begin
            if (push_allowed) begin
              fifo_data[fifo_wr_ptr] <= max4_vectors(top_left_data, top_right_data, bottom_left_data, bank_read_data);
              fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
              pixels_generated <= pixels_generated + 1'b1;
              if (pooled_column == output_width - 1'b1) begin
                pooled_column <= '0;
                source_row_base <= source_row_base + ({16'd0, output_width} << 2);
              end else begin
                pooled_column <= pooled_column + 1'b1;
              end
              if (pixels_generated + 1'b1 >= pixel_count) state <= IDLE;
              else state <= READ_TL;
            end
          end
          default: state <= IDLE;
        endcase

        case ({push_output && push_allowed, consume_pixel})
          2'b10: fifo_count <= fifo_count + 1'b1;
          2'b01: fifo_count <= fifo_count - 1'b1;
          default: begin end
        endcase
      end
    end
  end
endmodule
