// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// AXI4-Stream RGB ingress for a future camera front end. TUSER[0] marks SOF;
// the first pixel is held for one cycle so frame_start is never concurrent
// with pixel_valid. RGB bytes are recentered from camera uint8 to TFLite
// signed q = u - 128. First-layer zero-point compensation is folded into the
// exported bias, so the MAC itself remains signed INT8.
`timescale 1ns/1ps
module gestureflow_axi_stream_rgb_ingress (
  input logic aclk, input logic aresetn,
  input logic [23:0] s_axis_tdata,
  input logic [2:0] s_axis_tkeep,
  input logic s_axis_tuser,
  input logic s_axis_tlast,
  input logic s_axis_tvalid,
  output logic s_axis_tready,
  output logic frame_start,
  output logic line_end,
  output logic pixel_valid,
  input logic pixel_ready,
  output logic signed [2:0][7:0] pixel_rgb,
  output logic protocol_fault
);
  logic held_valid, held_last, start_pending;
  logic signed [2:0][7:0] held_rgb;
  assign pixel_valid = held_valid && !start_pending;
  assign pixel_rgb = held_rgb;
  // One elastic pixel is sufficient for the control boundary. A production
  // camera path adds a deeper async FIFO ahead of this interface when the
  // sensor clock cannot tolerate MAC-side backpressure.
  assign s_axis_tready = !held_valid || (pixel_valid && pixel_ready);
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin held_valid<=0; held_last<=0; start_pending<=0; held_rgb<='0; frame_start<=0; line_end<=0; protocol_fault<=0; end
    else begin
      frame_start<=0; line_end<=0;
      if (start_pending) begin frame_start<=1; start_pending<=0; end
      if (pixel_valid && pixel_ready) begin held_valid<=0; line_end<=held_last; end
      if (s_axis_tvalid && s_axis_tready) begin
        if (s_axis_tkeep != 3'b111) protocol_fault<=1;
        if (s_axis_tuser && held_valid) protocol_fault<=1;
        held_rgb[0] <= {~s_axis_tdata[23],s_axis_tdata[22:16]};
        held_rgb[1] <= {~s_axis_tdata[15],s_axis_tdata[14:8]};
        held_rgb[2] <= {~s_axis_tdata[7],s_axis_tdata[6:0]};
        held_valid<=1;
        held_last<=s_axis_tlast;
        if(s_axis_tuser) start_pending<=1;
      end
    end
  end
endmodule
