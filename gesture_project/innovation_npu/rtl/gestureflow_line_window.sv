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
  output logic window_valid,
  output logic signed [KERNEL_SIZE*KERNEL_SIZE-1:0][7:0] window_data
);

  localparam int COLUMN_W = (IMAGE_WIDTH <= 1) ? 1 : $clog2(IMAGE_WIDTH);
  localparam int BANK_W = (KERNEL_SIZE <= 1) ? 1 : $clog2(KERNEL_SIZE);
  localparam int COUNT_W = $clog2(KERNEL_SIZE + 1);

  logic [COLUMN_W-1:0] column_index;
  logic [BANK_W-1:0] write_bank;
  logic [COUNT_W-1:0] rows_seen;
  logic signed [7:0] line_memory [0:KERNEL_SIZE-1][0:IMAGE_WIDTH-1];
  logic signed [7:0] horizontal_history [0:KERNEL_SIZE-1][0:KERNEL_SIZE-2];
  logic signed [7:0] vertical_source [0:KERNEL_SIZE-1];

  always_comb begin
    for (int row = 0; row < KERNEL_SIZE - 1; row++) begin
      // write_bank names the row being received. The following banks contain
      // old-to-new prior rows in circular order before this write is committed.
      vertical_source[row] = line_memory[(int'(write_bank) + row + 1) % KERNEL_SIZE][column_index];
    end
    vertical_source[KERNEL_SIZE - 1] = pixel_data;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      column_index <= '0;
      write_bank <= '0;
      rows_seen <= '0;
      window_valid <= 1'b0;
      window_data <= '0;
      for (int row = 0; row < KERNEL_SIZE; row++) begin
        for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
          horizontal_history[row][column] <= '0;
        end
      end
    end else begin
      window_valid <= 1'b0;
      if (frame_start) begin
        column_index <= '0;
        write_bank <= '0;
        rows_seen <= '0;
        for (int row = 0; row < KERNEL_SIZE; row++) begin
          for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
            horizontal_history[row][column] <= '0;
          end
        end
      end

      if (pixel_valid) begin
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

        line_memory[write_bank][column_index] <= pixel_data;
        if (column_index == COLUMN_W'(IMAGE_WIDTH - 1)) begin
          column_index <= '0;
          if (write_bank == BANK_W'(KERNEL_SIZE - 1)) begin
            write_bank <= '0;
          end else begin
            write_bank <= write_bank + 1'b1;
          end
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
