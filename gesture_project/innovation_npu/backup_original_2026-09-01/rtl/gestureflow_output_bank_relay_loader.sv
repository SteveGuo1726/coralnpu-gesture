// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Local relay loader: reads quantized INT8 vectors back from the output bank
// and replays them as a tensor stream for the next layer without a DDR round
// trip. A small FIFO absorbs the output-bank one-cycle synchronous read
// latency so the downstream window generator can still see one pixel per cycle
// in the steady state.
`timescale 1ns/1ps
module gestureflow_output_bank_relay_loader #(
  parameter int CHANNELS = 16,
  parameter int ADDR_W = 14,
  parameter int FIFO_DEPTH = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear,
  input  logic [13:0] pixel_count,
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
  localparam int FIFO_PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int FIFO_COUNT_W = $clog2(FIFO_DEPTH + 1);

  logic active;
  logic stream_started;
  logic read_pending;
  logic [ADDR_W-1:0] next_read_addr;
  logic [13:0] pixels_requested;
  logic signed [CHANNELS-1:0][7:0] fifo_data [0:FIFO_DEPTH-1];
  logic [FIFO_PTR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
  logic [FIFO_COUNT_W-1:0] fifo_count;
  logic consume_pixel, push_response, issue_read;
  logic [FIFO_COUNT_W:0] fifo_count_ext;
  logic [FIFO_COUNT_W:0] occupancy_after_cycle;

  initial begin
    if (FIFO_DEPTH < 2) $error("FIFO_DEPTH must be at least two");
  end

  assign pixel_valid = active && (fifo_count != 0);
  assign frame_start = active && !stream_started && pixel_valid;
  assign pixel_data = fifo_data[fifo_rd_ptr];
  assign busy = active;
  assign consume_pixel = pixel_valid && pixel_ready;
  assign push_response = read_pending;
  assign fifo_count_ext = {1'b0, fifo_count};
  assign occupancy_after_cycle = fifo_count_ext +
    (push_response ? {{FIFO_COUNT_W{1'b0}}, 1'b1} : '0) -
    (consume_pixel ? {{FIFO_COUNT_W{1'b0}}, 1'b1} : '0);
  assign issue_read = active &&
    (pixels_requested < pixel_count) &&
    (occupancy_after_cycle < (FIFO_COUNT_W + 1)'(FIFO_DEPTH));
  assign bank_read_enable = issue_read;
  assign bank_read_addr = next_read_addr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 1'b0;
      stream_started <= 1'b0;
      read_pending <= 1'b0;
      next_read_addr <= '0;
      pixels_requested <= '0;
      pixels_emitted <= '0;
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else if (clear) begin
      active <= 1'b0;
      stream_started <= 1'b0;
      read_pending <= 1'b0;
      next_read_addr <= '0;
      pixels_requested <= '0;
      pixels_emitted <= '0;
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count <= '0;
      done <= 1'b0;
      fault <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start) begin
        active <= 1'b1;
        stream_started <= 1'b0;
        read_pending <= 1'b0;
        next_read_addr <= '0;
        pixels_requested <= '0;
        pixels_emitted <= '0;
        fifo_wr_ptr <= '0;
        fifo_rd_ptr <= '0;
        fifo_count <= '0;
        fault <= (pixel_count == 0);
        if (pixel_count == 0) active <= 1'b0;
      end else begin
        if (!stream_started && frame_start) stream_started <= 1'b1;

        if (push_response) begin
          fifo_data[fifo_wr_ptr] <= bank_read_data;
          fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
        end
        if (consume_pixel) begin
          fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
          pixels_emitted <= pixels_emitted + 1'b1;
          if (pixels_emitted == pixel_count - 1'b1) begin
            active <= 1'b0;
            done <= 1'b1;
          end
        end

        case ({push_response, consume_pixel})
          2'b10: fifo_count <= fifo_count + 1'b1;
          2'b01: fifo_count <= fifo_count - 1'b1;
          default: begin end
        endcase

        if (issue_read) begin
          next_read_addr <= next_read_addr + 1'b1;
          pixels_requested <= pixels_requested + 1'b1;
        end
        read_pending <= issue_read;
      end
    end
  end
endmodule
