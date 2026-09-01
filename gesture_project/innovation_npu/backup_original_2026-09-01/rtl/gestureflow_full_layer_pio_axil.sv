// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// First complete-layer board controller. This is deliberately a PIO ingress
// baseline: the PS configures one layer then submits camera-domain RGB pixels
// while the PL autonomously forms all SAME windows, accumulates, requantizes,
// and produces an on-chip result signature. It is a correctness stepping
// stone to MM2S/S2MM DMA, not a claimed camera-throughput architecture.
`timescale 1ns/1ps
module gestureflow_full_layer_pio_axil (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 25000000" *) input wire aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW" *) input wire aresetn,
  input wire [31:0] s_axi_awaddr, input wire [2:0] s_axi_awprot, input wire s_axi_awvalid, output logic s_axi_awready,
  input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb, input wire s_axi_wvalid, output logic s_axi_wready,
  output logic [1:0] s_axi_bresp, output logic s_axi_bvalid, input wire s_axi_bready,
  input wire [31:0] s_axi_araddr, input wire [2:0] s_axi_arprot, input wire s_axi_arvalid, output logic s_axi_arready,
  output logic [31:0] s_axi_rdata, output logic [1:0] s_axi_rresp, output logic s_axi_rvalid, input wire s_axi_rready
);
  localparam logic [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008,
    STATUS=12'h00c, QCFG=12'h010, WCTRL=12'h014, WDATA=12'h018,
    BIDX=12'h01c, BDATA=12'h020, RQIDX=12'h024, RQMULT=12'h028,
    RQSHIFT=12'h02c, PIXEL_DATA=12'h030, CYCLES=12'h034,
    INPUT_PIXELS=12'h038, OUTPUT_VECTORS=12'h03c, OUTPUT_FNV1A=12'h040;
  localparam logic [31:0] FNV_OFFSET = 32'h811c9dc5;
  localparam logic [31:0] FNV_PRIME = 32'h01000193;
  localparam int IMAGE_WIDTH = 96;
  localparam int IMAGE_HEIGHT = 96;
  localparam int OUTPUT_VECTORS_EXPECTED = IMAGE_WIDTH * IMAGE_HEIGHT;

  logic [31:0] awaddr, wdata;
  logic aw_seen, w_seen;
  logic [3:0] wstrb;
  logic frame_start, pixel_pending, running, done, fault, hash_active, last_output_seen;
  logic signed [2:0][7:0] pixel_rgb, input_zero_point;
  logic pixel_ready, frame_input_done, layer_fault;
  logic weight_write_valid;
  logic [3:0] weight_write_oc, weight_write_tap;
  logic signed [3:0][7:0] weight_write_data;
  logic signed [15:0][31:0] bias;
  logic [15:0] output_lane_enable;
  logic requant_enable, requant_relu_enable;
  logic signed [7:0] output_zero_point;
  logic signed [15:0][31:0] requant_multiplier;
  logic [15:0][5:0] requant_right_shift;
  logic [3:0] bias_index, requant_index;
  logic output_write_valid;
  logic [13:0] output_write_addr;
  logic signed [15:0][7:0] output_write_data;
  logic [127:0] unused_output_read_data;
  logic [127:0] hash_vector;
  logic [4:0] hash_byte_index;
  logic [31:0] hash_value, completed_hash;
  logic [31:0] layer_cycles;
  logic [14:0] input_pixels;
  logic [13:0] output_vectors;

  function automatic logic [31:0] fnv_step(
    input logic [31:0] current,
    input logic [7:0] byte_value
  );
    begin
      fnv_step = (current ^ {24'd0, byte_value}) * FNV_PRIME;
    end
  endfunction

  assign s_axi_awready = !aw_seen && !s_axi_bvalid;
  assign s_axi_wready = !w_seen && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;

  gestureflow_conv4x4_rgb_same_layer #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
    .OUT_LANES(16), .OUTPUT_ADDR_W(14)
  ) layer (
    .clk(aclk), .rst_n(aresetn), .frame_start(frame_start),
    .pixel_valid(pixel_pending), .pixel_ready(pixel_ready), .pixel_rgb(pixel_rgb),
    .input_zero_point(input_zero_point),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc),
    .weight_write_tap(weight_write_tap), .weight_write_data(weight_write_data),
    .bias(bias), .output_lane_enable(output_lane_enable),
    .requant_enable(requant_enable), .requant_relu_enable(requant_relu_enable),
    .output_zero_point(output_zero_point), .requant_multiplier(requant_multiplier),
    .requant_right_shift(requant_right_shift), .frame_input_done(frame_input_done),
    .layer_fault(layer_fault), .output_write_valid(output_write_valid),
    .output_write_addr(output_write_addr), .output_write_data(output_write_data),
    .output_read_enable(1'b0), .output_read_addr('0), .output_read_data(unused_output_read_data)
  );

  // Weight address and write-enable registers feed inferred RAMB18 ports.
  // Keep their reset synchronous: asynchronous reset on these controls is
  // unsafe on Xilinx block RAM and triggers REQP-1840 at implementation.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      awaddr <= '0; wdata <= '0; wstrb <= '0; aw_seen <= 1'b0; w_seen <= 1'b0;
      s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
      s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00; s_axi_rdata <= '0;
      frame_start <= 1'b0; pixel_pending <= 1'b0; running <= 1'b0; done <= 1'b0;
      fault <= 1'b0; weight_write_valid <= 1'b0; weight_write_oc <= '0;
      weight_write_tap <= '0; weight_write_data <= '0; bias <= '0; bias_index <= '0;
      input_zero_point <= '0; output_zero_point <= '0; output_lane_enable <= 16'hffff;
      requant_enable <= 1'b0; requant_relu_enable <= 1'b0; requant_index <= '0;
      requant_multiplier <= '0; requant_right_shift <= '0; hash_active <= 1'b0;
      last_output_seen <= 1'b0; hash_vector <= '0; hash_byte_index <= '0;
      hash_value <= FNV_OFFSET; completed_hash <= FNV_OFFSET; layer_cycles <= '0;
      input_pixels <= '0; output_vectors <= '0;
    end else begin
      frame_start <= 1'b0;
      weight_write_valid <= 1'b0;
      if (running) layer_cycles <= layer_cycles + 1'b1;
      if (layer_fault) fault <= 1'b1;
      if (pixel_pending && pixel_ready) begin
        pixel_pending <= 1'b0;
        input_pixels <= input_pixels + 1'b1;
      end

      // One vector arrives at least 23 cycles apart in the current tile, so
      // serializing its sixteen FNV bytes adds no compute-side backpressure.
      if (hash_active) begin
        hash_value <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]);
        if (hash_byte_index == 5'd15) begin
          completed_hash <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]);
          hash_active <= 1'b0;
          if (last_output_seen) begin
            running <= 1'b0;
            done <= 1'b1;
          end
        end else begin
          hash_byte_index <= hash_byte_index + 1'b1;
        end
      end
      if (output_write_valid) begin
        if (hash_active) fault <= 1'b1;
        hash_vector <= output_write_data;
        hash_byte_index <= '0;
        hash_active <= 1'b1;
        output_vectors <= output_vectors + 1'b1;
        if (output_vectors == 14'(OUTPUT_VECTORS_EXPECTED - 1)) last_output_seen <= 1'b1;
      end

      if (s_axi_awvalid && s_axi_awready) begin awaddr <= s_axi_awaddr; aw_seen <= 1'b1; end
      if (s_axi_wvalid && s_axi_wready) begin wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; w_seen <= 1'b1; end
      if (aw_seen && w_seen && !s_axi_bvalid) begin
        case (awaddr[11:0])
          CONTROL: begin
            if (wdata[0]) begin
              pixel_pending <= 1'b0; running <= 1'b0; done <= 1'b0; fault <= 1'b0;
              hash_active <= 1'b0; last_output_seen <= 1'b0; hash_value <= FNV_OFFSET;
              completed_hash <= FNV_OFFSET; layer_cycles <= '0; input_pixels <= '0; output_vectors <= '0;
            end
            if (wdata[1]) begin
              if (running || pixel_pending || hash_active) fault <= 1'b1;
              else begin
                frame_start <= 1'b1; running <= 1'b1; done <= 1'b0; fault <= 1'b0;
                hash_active <= 1'b0; last_output_seen <= 1'b0; hash_value <= FNV_OFFSET;
                completed_hash <= FNV_OFFSET; layer_cycles <= '0; input_pixels <= '0; output_vectors <= '0;
              end
            end
          end
          QCFG: begin
            input_zero_point <= {3{wdata[7:0]}};
            output_zero_point <= wdata[15:8];
            requant_enable <= wdata[16];
            requant_relu_enable <= wdata[17];
          end
          WCTRL: begin weight_write_oc <= wdata[3:0]; weight_write_tap <= wdata[7:4]; end
          WDATA: begin
            if (running || pixel_pending) fault <= 1'b1;
            else begin weight_write_data <= wdata; weight_write_valid <= 1'b1; end
          end
          BIDX: bias_index <= wdata[3:0];
          BDATA: begin if (running) fault <= 1'b1; else bias[bias_index] <= wdata; end
          RQIDX: requant_index <= wdata[3:0];
          RQMULT: begin if (running) fault <= 1'b1; else requant_multiplier[requant_index] <= wdata; end
          RQSHIFT: begin if (running) fault <= 1'b1; else requant_right_shift[requant_index] <= wdata[5:0]; end
          PIXEL_DATA: begin
            if (!running || pixel_pending || !pixel_ready) begin
              fault <= 1'b1;
            end else begin
              // Camera byte u is converted to signed tensor q=u-128 by
              // flipping bit7. The fourth byte is intentionally unused.
              pixel_rgb[0] <= {~wdata[7], wdata[6:0]};
              pixel_rgb[1] <= {~wdata[15], wdata[14:8]};
              pixel_rgb[2] <= {~wdata[23], wdata[22:16]};
              pixel_pending <= 1'b1;
            end
          end
          default: begin end
        endcase
        s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00; aw_seen <= 1'b0; w_seen <= 1'b0;
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
      if (s_axi_arvalid && s_axi_arready) begin
        case (s_axi_araddr[11:0])
          MAGIC: s_axi_rdata <= 32'h47464e50;
          VERSION: s_axi_rdata <= 32'h00020000;
          STATUS: s_axi_rdata <= {24'd0, frame_input_done, layer_fault, hash_active,
            pixel_pending, (running && !pixel_pending && pixel_ready), fault, done, running};
          QCFG: s_axi_rdata <= {14'd0, requant_relu_enable, requant_enable,
            output_zero_point, input_zero_point[0]};
          CYCLES: s_axi_rdata <= layer_cycles;
          INPUT_PIXELS: s_axi_rdata <= {17'd0, input_pixels};
          OUTPUT_VECTORS: s_axi_rdata <= {18'd0, output_vectors};
          OUTPUT_FNV1A: s_axi_rdata <= completed_hash;
          default: s_axi_rdata <= 32'hdeadbeef;
        endcase
        s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end
endmodule
