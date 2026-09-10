// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// Minimal ZCU104 bring-up design.  It uses the board's 300 MHz differential
// system clock, divides it with a free-running counter, and drives the four
// user LEDs.  This design has no PS, no AXI and no external memory dependency,
// so it isolates the board clock/configuration/LED path during first bring-up.
`timescale 1ns/1ps

module zcu104_led_blink (
  input  wire        sys_clk_p,
  input  wire        sys_clk_n,
  output logic [3:0] led
);

  logic clk_300;
  logic [27:0] counter;

  IBUFDS #(
    .DIFF_TERM("TRUE"),
    .IOSTANDARD("DIFF_SSTL12")
  ) sys_clk_ibufds (
    .I(sys_clk_p),
    .IB(sys_clk_n),
    .O(clk_300)
  );

  always_ff @(posedge clk_300) begin
    counter <= counter + 28'd1;
  end

  // GPIO_LED_*_LS are low-side LED connections on ZCU104, so invert here.
  // At 300 MHz, led[0] toggles at about 1.1 Hz.
  assign led = ~counter[27:24];

endmodule
