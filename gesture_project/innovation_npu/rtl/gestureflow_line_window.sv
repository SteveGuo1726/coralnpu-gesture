// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Single-channel streaming KxK window generator. A vector/channel-group
// wrapper will instantiate this storage pattern per input lane or SRAM bank.
// The scalar primitive is intentionally parameterized so the current 4x4
// student network and future 3x3 networks use identical control semantics.
`timescale 1ns/1ps
module gestureflow_line_window #(
  parameter int IMAGE_WIDTH = 96,
  parameter int KERNEL_SIZE = 4
) (
  input  logic clk,
  input  logic rst_n,
  // Assert on a cycle without pixel_valid before the next frame's first pixel.
  input  logic frame_start,
  input  logic pixel_valid,
  input  logic signed [7:0] pixel_data,
  input  logic window_ready,
  output logic window_valid,
  output logic signed [KERNEL_SIZE*KERNEL_SIZE-1:0][7:0] window_data
);

  localparam int COLUMN_W = (IMAGE_WIDTH <= 1) ? 1 : $clog2(IMAGE_WIDTH);
  localparam int COUNT_W = $clog2(KERNEL_SIZE + 1);

  logic [COLUMN_W-1:0] column_index;
  logic [COUNT_W-1:0] rows_seen;
  // This is a conventional K-1 line-delay chain, not a circular array.  At
  // a raster position, bank 0 holds the preceding row, bank 1 the row before
  // that, and so forth. The fixed topology removes the variable bank mux and
  // modulo arithmetic that previously expanded a 96-pixel line store into
  // thousands of LUTs on XC7.
  (* ram_style = "block" *) logic signed [7:0]
    line_memory [0:KERNEL_SIZE-2][0:IMAGE_WIDTH-1];
  logic signed [7:0] horizontal_history [0:KERNEL_SIZE-1][0:KERNEL_SIZE-2];
  logic signed [7:0] vertical_source [0:KERNEL_SIZE-1];

  always_comb begin
    for (int row = 0; row < KERNEL_SIZE - 1; row++) begin
      // The oldest required row is in the last delay bank; the current input
      // supplies the newest row. This ordering is the row-major 4x4 window.
      vertical_source[row] = line_memory[KERNEL_SIZE - 2 - row][column_index];
    end
    vertical_source[KERNEL_SIZE - 1] = pixel_data;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      column_index <= '0;
      rows_seen <= '0;
      window_valid <= 1'b0;
      window_data <= '0;
      for (int row = 0; row < KERNEL_SIZE; row++) begin
        for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
          horizontal_history[row][column] <= '0;
        end
      end
    end else begin
      if (window_valid && window_ready) begin
        window_valid <= 1'b0;
      end
      if (frame_start) begin
        column_index <= '0;
        rows_seen <= '0;
        window_valid <= 1'b0;
        for (int row = 0; row < KERNEL_SIZE; row++) begin
          for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
            horizontal_history[row][column] <= '0;
          end
        end
      end

      // A held window must not consume another pixel. This lets a later
      // multi-cycle MAC tile apply backpressure without losing a position.
      if (pixel_valid && (!window_valid || window_ready)) begin
        for (int row = 0; row < KERNEL_SIZE; row++) begin
          for (int column = 0; column < KERNEL_SIZE - 2; column++) begin
            horizontal_history[row][column] <= horizontal_history[row][column + 1];
          end
          horizontal_history[row][KERNEL_SIZE - 2] <= vertical_source[row];
        end

        if ((rows_seen >= COUNT_W'(KERNEL_SIZE - 1)) &&
            (column_index >= COLUMN_W'(KERNEL_SIZE - 1))) begin
          for (int row = 0; row < KERNEL_SIZE; row++) begin
            for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
              window_data[row*KERNEL_SIZE + column] <= horizontal_history[row][column];
            end
            window_data[row*KERNEL_SIZE + KERNEL_SIZE - 1] <= vertical_source[row];
          end
          window_valid <= 1'b1;
        end

        line_memory[0][column_index] <= pixel_data;
        for (int bank = 1; bank < KERNEL_SIZE - 1; bank++) begin
          line_memory[bank][column_index] <= line_memory[bank - 1][column_index];
        end
        if (column_index == COLUMN_W'(IMAGE_WIDTH - 1)) begin
          column_index <= '0;
          if (rows_seen < COUNT_W'(KERNEL_SIZE)) begin
            rows_seen <= rows_seen + 1'b1;
          end
        end else begin
          column_index <= column_index + 1'b1;
        end
      end
    end
  end

endmodule
