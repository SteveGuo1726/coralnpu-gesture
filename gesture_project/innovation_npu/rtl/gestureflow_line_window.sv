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
  output logic pixel_ready,
  input  logic window_ready,
  output logic window_valid,
  output logic signed [KERNEL_SIZE*KERNEL_SIZE-1:0][7:0] window_data
);

  localparam int COLUMN_W = (IMAGE_WIDTH <= 1) ? 1 : $clog2(IMAGE_WIDTH);
  localparam int COUNT_W = $clog2(KERNEL_SIZE + 1);

  logic [COLUMN_W-1:0] column_index;
  logic [COUNT_W-1:0] rows_seen;
  logic input_accept;
  logic stage_will_emit_window;
  logic stage_valid;
  logic signed [7:0] stage_pixel_data;
  logic [COLUMN_W-1:0] stage_column_index;
  logic [COUNT_W-1:0] stage_rows_seen;
  logic signed [7:0] line_read_data [0:KERNEL_SIZE-2];
  logic signed [7:0] horizontal_history [0:KERNEL_SIZE-1][0:KERNEL_SIZE-2];
  logic signed [7:0] vertical_source [0:KERNEL_SIZE-1];

  always_comb begin
    for (int row = 0; row < KERNEL_SIZE - 1; row++) begin
      vertical_source[row] = line_read_data[KERNEL_SIZE - 2 - row];
    end
    vertical_source[KERNEL_SIZE - 1] = stage_pixel_data;
  end

  assign stage_will_emit_window = stage_valid &&
    (stage_rows_seen >= COUNT_W'(KERNEL_SIZE - 1)) &&
    (stage_column_index >= COLUMN_W'(KERNEL_SIZE - 1));
  // The output is a single elastic register. Do not prefetch a pixel whose
  // delayed BRAM response would overwrite a window emitted this cycle.
  // A later two-entry window FIFO can remove this bubble safely.
  assign pixel_ready = !frame_start && (!window_valid || window_ready) &&
    !stage_will_emit_window;
  assign input_accept = pixel_valid && pixel_ready;

  // Bank zero receives the current raster pixel. Each later bank receives
  // the prior bank's synchronous read one cycle later, producing K-1 rows of
  // vertical delay with no combinational memory read or circular-bank mux.
  for (genvar bank = 0; bank < KERNEL_SIZE - 1; bank++) begin : line_delay
    gestureflow_line_delay_bank #(.ADDR_W(COLUMN_W)) delay_bank (
      .clk(clk),
      .write_enable(bank == 0 ? input_accept : stage_valid),
      .write_addr(bank == 0 ? column_index : stage_column_index),
      .write_data(bank == 0 ? pixel_data : line_read_data[bank - 1]),
      .read_enable(input_accept),
      .read_addr(column_index),
      .read_data(line_read_data[bank])
    );
  end

  // These state registers directly drive line-delay BRAM addresses/enables.
  // Keep reset synchronous so an assertion cannot asynchronously perturb a
  // RAMB18 control pin; frame_start provides the per-frame logical clear.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      column_index <= '0;
      rows_seen <= '0;
      stage_valid <= 1'b0;
      stage_pixel_data <= '0;
      stage_column_index <= '0;
      stage_rows_seen <= '0;
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
        stage_valid <= 1'b0;
        window_valid <= 1'b0;
        for (int row = 0; row < KERNEL_SIZE; row++) begin
          for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
            horizontal_history[row][column] <= '0;
          end
        end
      end

      // A held window must not consume another pixel. This lets a later
      // multi-cycle MAC tile apply backpressure without losing a position.
      // The BRAM read data belongs to the pixel accepted in the preceding
      // cycle. Its valid, coordinate and row count are carried explicitly so
      // this one-cycle latency is fully hidden by continuous raster input.
      if (stage_valid) begin
        for (int row = 0; row < KERNEL_SIZE; row++) begin
          for (int column = 0; column < KERNEL_SIZE - 2; column++) begin
            horizontal_history[row][column] <= horizontal_history[row][column + 1];
          end
          horizontal_history[row][KERNEL_SIZE - 2] <= vertical_source[row];
        end

        if ((stage_rows_seen >= COUNT_W'(KERNEL_SIZE - 1)) &&
            (stage_column_index >= COLUMN_W'(KERNEL_SIZE - 1))) begin
          for (int row = 0; row < KERNEL_SIZE; row++) begin
            for (int column = 0; column < KERNEL_SIZE - 1; column++) begin
              window_data[row*KERNEL_SIZE + column] <= horizontal_history[row][column];
            end
            window_data[row*KERNEL_SIZE + KERNEL_SIZE - 1] <= vertical_source[row];
          end
          window_valid <= 1'b1;
        end

      end

      stage_valid <= input_accept;
      if (input_accept) begin
        stage_pixel_data <= pixel_data;
        stage_column_index <= column_index;
        stage_rows_seen <= rows_seen;
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
