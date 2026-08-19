// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// One reusable 7020 layer engine.  The same 16-output x 4-input DSP tile,
// window cache, INT32 accumulator, requantizer, output bank and HP0 writer
// execute either the RGB first layer (3 active lanes) or the signed 16-channel
// body layer.  The PS changes only the descriptor and resident weights between
// the two runs; it never copies the intermediate activation back through the
// ARM.  This is the first single-bitstream layer-handoff baseline, not Google
// CoralNPU RTL.
`timescale 1ns/1ps
module gestureflow_layer_chain_hp0_axil #(
  parameter int IMAGE_WIDTH = 96,
  parameter int IMAGE_HEIGHT = 96,
  parameter int OUTPUTS = IMAGE_WIDTH * IMAGE_HEIGHT,
  parameter int OUT_LANES = 16,
  parameter int OUTPUT_ADDR_W = 14
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 25000000" *) input wire aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW" *) input wire aresetn,
  input wire [31:0] s_axi_awaddr, input wire [2:0] s_axi_awprot, input wire s_axi_awvalid, output logic s_axi_awready,
  input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb, input wire s_axi_wvalid, output logic s_axi_wready,
  output logic [1:0] s_axi_bresp, output logic s_axi_bvalid, input wire s_axi_bready,
  input wire [31:0] s_axi_araddr, input wire [2:0] s_axi_arprot, input wire s_axi_arvalid, output logic s_axi_arready,
  output logic [31:0] s_axi_rdata, output logic [1:0] s_axi_rresp, output logic s_axi_rvalid, input wire s_axi_rready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *) output logic [31:0] m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *) output logic [5:0] m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *) output logic [7:0] m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *) output logic [2:0] m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *) output logic [1:0] m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *) output logic m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *) output logic [3:0] m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *) output logic [2:0] m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *) output logic [3:0] m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREGION" *) output logic [3:0] m_axi_arregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *) output logic m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *) input wire m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *) input wire [5:0] m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *) input wire [63:0] m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *) input wire [1:0] m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *) input wire m_axi_rlast,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BRESP 1, HAS_RRESP 1, HAS_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 16" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output logic m_axi_rready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *) output logic [31:0] m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *) output logic [5:0] m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *) output logic [7:0] m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *) output logic [2:0] m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *) output logic [1:0] m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *) output logic m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *) output logic [3:0] m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *) output logic [2:0] m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *) output logic [3:0] m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREGION" *) output logic [3:0] m_axi_awregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *) output logic m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *) input wire m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *) output logic [63:0] m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *) output logic [7:0] m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *) output logic m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *) output logic m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *) input wire m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *) input wire [5:0] m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *) input wire [1:0] m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *) input wire m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *) output logic m_axi_bready
);
  localparam logic [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008, STATUS=12'h00c,
    QCFG=12'h010, WCTRL=12'h014, WDATA=12'h018, BIDX=12'h01c, BDATA=12'h020,
    RQIDX=12'h024, RQMULT=12'h028, RQSHIFT=12'h02c, CYCLES=12'h034,
    INPUT_PIXELS=12'h038, OUTPUT_VECTORS=12'h03c, OUTPUT_FNV1A=12'h040,
    DMA_SOURCE=12'h044, DMA_BYTES=12'h048, DMA_PIXELS=12'h04c, DMA_STATUS=12'h050,
    STORE_DESTINATION=12'h054, STORE_BYTES=12'h058, STORE_CONTROL=12'h05c,
    STORE_STATUS=12'h060, LAYER_MODE=12'h064, JOB_WIDTH=12'h068,
    JOB_HEIGHT=12'h06c, OUTPUT_LANE_MASK=12'h070, STORE_STRIDE=12'h074,
    STORE_VALID_BYTES=12'h078, POST_GAP_MULT=12'h080, POST_GAP_SHIFT=12'h084,
    POST_QCFG=12'h088, POST_GAP_FNV1A=12'h08c, POST_FC_FNV1A=12'h090,
    POST_CLASS=12'h094, POST_CYCLES=12'h098, POST_PROGRESS=12'h09c;
  localparam logic [31:0] FNV_OFFSET=32'h811c9dc5, FNV_PRIME=32'h01000193;
  // The physical 16x4 DSP tile remains fixed. Mode 3 only widens the
  // ingress/window storage so 20 Cin groups accumulate locally before one
  // requantized output is emitted; no second MAC array or DDR partial sum is
  // introduced for conv3_b.
  localparam int MAX_INPUT_CHANNELS = 80;
  localparam int PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;

  logic [31:0] awaddr, wdata; logic [3:0] wstrb; logic aw_seen, w_seen;
  logic running, done, fault;
  logic [2:0] layer_mode;
  logic dma_start, dma_clear, store_start, store_clear, store_enable, store_pool_2x2;
  logic [31:0] dma_source_addr, dma_bytes;
  logic [13:0] dma_pixels;
  logic [31:0] store_destination, store_bytes;
  logic [15:0] job_width, job_height;
  logic [31:0] store_stride_bytes;
  logic [4:0] store_valid_bytes;
  logic [31:0] layer_cycles;
  logic weight_write_valid;
  logic [3:0] weight_write_oc, weight_write_tap, bias_index, requant_index;
  logic [4:0] weight_write_ic_group;
  logic signed [3:0][7:0] weight_write_data;
  logic signed [15:0][31:0] bias, requant_multiplier;
  logic [15:0][5:0] requant_right_shift;
  logic [15:0] output_lane_enable;
  logic signed [MAX_INPUT_CHANNELS-1:0][7:0] input_zero_point, selected_pixel;
  logic requant_enable, requant_relu_enable; logic signed [7:0] output_zero_point;
  logic post_start, post_clear, post_busy, post_done, post_fault;
  logic signed [31:0] post_gap_multiplier;
  logic [5:0] post_gap_right_shift;
  logic signed [7:0] post_gap_input_zero_point, post_gap_output_zero_point, post_fc_output_zero_point;
  logic [31:0] post_gap_fnv1a, post_fc_fnv1a, post_cycles;
  logic [2:0] post_predicted_class, post_fc_values_done;
  logic [6:0] post_gap_values_done;

  logic rgb_busy, rgb_done, rgb_fault, rgb_frame_start, rgb_pixel_valid, rgb_pixel_ready;
  logic signed [2:0][7:0] rgb_pixel; logic [13:0] rgb_pixels_emitted; logic [15:0] rgb_bytes_read;
  logic tensor_busy, tensor_done, tensor_fault, tensor_frame_start, tensor_pixel_valid, tensor_pixel_ready;
  logic signed [15:0][7:0] tensor_pixel; logic [13:0] tensor_pixels_emitted; logic [31:0] tensor_bytes_read;
  logic tensor40_busy, tensor40_done, tensor40_fault, tensor40_frame_start, tensor40_pixel_valid, tensor40_pixel_ready;
  logic signed [39:0][7:0] tensor40_pixel; logic [13:0] tensor40_pixels_emitted; logic [31:0] tensor40_bytes_read;
  logic tensor80_busy, tensor80_done, tensor80_fault, tensor80_frame_start, tensor80_pixel_valid, tensor80_pixel_ready;
  logic signed [79:0][7:0] tensor80_pixel; logic [13:0] tensor80_pixels_emitted; logic [31:0] tensor80_bytes_read;
  logic [31:0] rgb_araddr, tensor_araddr, tensor40_araddr, tensor80_araddr; logic [5:0] rgb_arid, tensor_arid, tensor40_arid, tensor80_arid;
  logic [7:0] rgb_arlen, tensor_arlen, tensor40_arlen, tensor80_arlen; logic [2:0] rgb_arsize, tensor_arsize, tensor40_arsize, tensor80_arsize;
  logic [1:0] rgb_arburst, tensor_arburst, tensor40_arburst, tensor80_arburst; logic rgb_arlock, rgb_arvalid, rgb_rready;
  logic tensor_arlock, tensor_arvalid, tensor_rready, tensor40_arlock, tensor40_arvalid, tensor40_rready, tensor80_arlock, tensor80_arvalid, tensor80_rready;
  logic [3:0] rgb_arcache, tensor_arcache, tensor40_arcache, tensor80_arcache, rgb_arqos, tensor_arqos, tensor40_arqos, tensor80_arqos, rgb_arregion, tensor_arregion, tensor40_arregion, tensor80_arregion;
  logic [2:0] rgb_arprot, tensor_arprot, tensor40_arprot, tensor80_arprot;
  logic [31:0] post_araddr; logic [5:0] post_arid; logic [7:0] post_arlen; logic [2:0] post_arsize;
  logic [1:0] post_arburst; logic post_arlock, post_arvalid, post_rready;
  logic [3:0] post_arcache, post_arqos, post_arregion; logic [2:0] post_arprot;
  logic [5:0] unused_rgb_rid, unused_tensor_rid;
  logic [63:0] unused_rgb_rdata, unused_tensor_rdata; logic [1:0] unused_rgb_rresp, unused_tensor_rresp;
  logic unused_rgb_rlast, unused_tensor_rlast;
  logic frame_start, pixel_valid, pixel_ready;
  logic signed [MAX_INPUT_CHANNELS-1:0][7:0] pixel_data;
  logic [13:0] input_pixels; logic dma_busy, dma_done, dma_fault; logic [31:0] dma_bytes_read;
  logic output_valid, output_ready, protocol_error; logic signed [15:0][31:0] output_psum;
  logic [15:0] output_lane_enable_valid; logic [15:0] output_row, output_column;
  logic frame_input_done;
  logic quant_valid, quant_ready, quant_fault; logic signed [15:0][7:0] quant_data;
  logic [15:0] quant_row, quant_column; logic [13:0] output_write_addr;
  logic output_write_valid; logic signed [15:0][7:0] output_write_data;
  logic [127:0] output_read_data, hash_vector; logic [4:0] hash_byte_index;
  logic [31:0] hash_value, completed_hash; logic hash_active, last_output_seen; logic [13:0] output_vectors;
  logic store_busy, store_done, store_fault; logic [13:0] store_vectors_written;
  logic [31:0] store_bytes_written; logic [13:0] output_read_addr; logic output_read_enable;

  function automatic logic [31:0] fnv_step(input logic [31:0] current, input logic [7:0] byte_value);
    fnv_step = (current ^ {24'd0, byte_value}) * FNV_PRIME;
  endfunction

  assign dma_busy = (layer_mode == 4) ? post_busy : (layer_mode == 3) ? tensor80_busy : (layer_mode == 2 ? tensor40_busy : (layer_mode == 1 ? tensor_busy : rgb_busy));
  assign dma_done = (layer_mode == 4) ? post_done : (layer_mode == 3) ? tensor80_done : (layer_mode == 2 ? tensor40_done : (layer_mode == 1 ? tensor_done : rgb_done));
  assign dma_fault = (layer_mode == 4) ? post_fault : (layer_mode == 3) ? tensor80_fault : (layer_mode == 2 ? tensor40_fault : (layer_mode == 1 ? tensor_fault : rgb_fault));
  assign dma_bytes_read = (layer_mode == 4) ? dma_bytes : (layer_mode == 3) ? tensor80_bytes_read : (layer_mode == 2 ? tensor40_bytes_read : (layer_mode == 1 ? tensor_bytes_read : {16'd0, rgb_bytes_read}));
  assign input_pixels = (layer_mode == 4) ? dma_pixels : (layer_mode == 3) ? tensor80_pixels_emitted : (layer_mode == 2 ? tensor40_pixels_emitted : (layer_mode == 1 ? tensor_pixels_emitted : rgb_pixels_emitted));
  assign frame_start = (layer_mode == 3) ? tensor80_frame_start : (layer_mode == 2 ? tensor40_frame_start : (layer_mode == 1 ? tensor_frame_start : rgb_frame_start));
  assign pixel_valid = (layer_mode == 4) ? 1'b0 : (layer_mode == 3) ? tensor80_pixel_valid : (layer_mode == 2 ? tensor40_pixel_valid : (layer_mode == 1 ? tensor_pixel_valid : rgb_pixel_valid));
  assign tensor_pixel_ready = (layer_mode == 1) ? pixel_ready : 1'b0;
  assign tensor40_pixel_ready = (layer_mode == 2) ? pixel_ready : 1'b0;
  assign tensor80_pixel_ready = (layer_mode == 3) ? pixel_ready : 1'b0;
  assign rgb_pixel_ready = (layer_mode == 0) ? pixel_ready : 1'b0;
  always_comb begin
    selected_pixel = '0;
    if (layer_mode == 3) begin
      selected_pixel = tensor80_pixel;
    end else if (layer_mode == 2) begin
      selected_pixel[39:0] = tensor40_pixel;
      for (int lane = 40; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end else if (layer_mode == 1) begin
      selected_pixel[15:0] = tensor_pixel;
      for (int lane = 16; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end else begin
      selected_pixel[0] = rgb_pixel[0]; selected_pixel[1] = rgb_pixel[1]; selected_pixel[2] = rgb_pixel[2];
      for (int lane = 3; lane < MAX_INPUT_CHANNELS; lane++) selected_pixel[lane] = input_zero_point[0];
    end
    m_axi_araddr = (layer_mode == 4) ? post_araddr : (layer_mode == 3) ? tensor80_araddr : (layer_mode == 2 ? tensor40_araddr : (layer_mode == 1 ? tensor_araddr : rgb_araddr));
    m_axi_arid = (layer_mode == 4) ? post_arid : (layer_mode == 3) ? tensor80_arid : (layer_mode == 2 ? tensor40_arid : (layer_mode == 1 ? tensor_arid : rgb_arid));
    m_axi_arlen = (layer_mode == 4) ? post_arlen : (layer_mode == 3) ? tensor80_arlen : (layer_mode == 2 ? tensor40_arlen : (layer_mode == 1 ? tensor_arlen : rgb_arlen));
    m_axi_arsize = (layer_mode == 4) ? post_arsize : (layer_mode == 3) ? tensor80_arsize : (layer_mode == 2 ? tensor40_arsize : (layer_mode == 1 ? tensor_arsize : rgb_arsize));
    m_axi_arburst = (layer_mode == 4) ? post_arburst : (layer_mode == 3) ? tensor80_arburst : (layer_mode == 2 ? tensor40_arburst : (layer_mode == 1 ? tensor_arburst : rgb_arburst));
    m_axi_arlock = (layer_mode == 4) ? post_arlock : (layer_mode == 3) ? tensor80_arlock : (layer_mode == 2 ? tensor40_arlock : (layer_mode == 1 ? tensor_arlock : rgb_arlock));
    m_axi_arcache = (layer_mode == 4) ? post_arcache : (layer_mode == 3) ? tensor80_arcache : (layer_mode == 2 ? tensor40_arcache : (layer_mode == 1 ? tensor_arcache : rgb_arcache));
    m_axi_arprot = (layer_mode == 4) ? post_arprot : (layer_mode == 3) ? tensor80_arprot : (layer_mode == 2 ? tensor40_arprot : (layer_mode == 1 ? tensor_arprot : rgb_arprot));
    m_axi_arqos = (layer_mode == 4) ? post_arqos : (layer_mode == 3) ? tensor80_arqos : (layer_mode == 2 ? tensor40_arqos : (layer_mode == 1 ? tensor_arqos : rgb_arqos));
    m_axi_arregion = (layer_mode == 4) ? post_arregion : (layer_mode == 3) ? tensor80_arregion : (layer_mode == 2 ? tensor40_arregion : (layer_mode == 1 ? tensor_arregion : rgb_arregion));
    m_axi_arvalid = (layer_mode == 4) ? post_arvalid : (layer_mode == 3) ? tensor80_arvalid : (layer_mode == 2 ? tensor40_arvalid : (layer_mode == 1 ? tensor_arvalid : rgb_arvalid));
    m_axi_rready = (layer_mode == 4) ? post_rready : (layer_mode == 3) ? tensor80_rready : (layer_mode == 2 ? tensor40_rready : (layer_mode == 1 ? tensor_rready : rgb_rready));
  end
  assign pixel_data = selected_pixel;
  assign output_ready = quant_ready;

  gestureflow_hp0_rgb_loader rgb_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 0)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes[15:0]), .pixel_count(dma_pixels),
    .busy(rgb_busy), .done(rgb_done), .fault(rgb_fault), .frame_start(rgb_frame_start),
    .pixel_valid(rgb_pixel_valid), .pixel_ready(rgb_pixel_ready), .pixel_rgb(rgb_pixel),
    .pixels_emitted(rgb_pixels_emitted), .bytes_read(rgb_bytes_read),
    .m_axi_araddr(rgb_araddr), .m_axi_arid(rgb_arid), .m_axi_arlen(rgb_arlen), .m_axi_arsize(rgb_arsize),
    .m_axi_arburst(rgb_arburst), .m_axi_arlock(rgb_arlock), .m_axi_arcache(rgb_arcache), .m_axi_arprot(rgb_arprot),
    .m_axi_arqos(rgb_arqos), .m_axi_arregion(rgb_arregion), .m_axi_arvalid(rgb_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(rgb_rready)
  );
  gestureflow_hp0_tensor_loader #(.CHANNELS(16)) tensor_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 1)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor_busy), .done(tensor_done), .fault(tensor_fault), .frame_start(tensor_frame_start),
    .pixel_valid(tensor_pixel_valid), .pixel_ready(tensor_pixel_ready), .pixel_data(tensor_pixel),
    .pixels_emitted(tensor_pixels_emitted), .bytes_read(tensor_bytes_read),
    .m_axi_araddr(tensor_araddr), .m_axi_arid(tensor_arid), .m_axi_arlen(tensor_arlen), .m_axi_arsize(tensor_arsize),
    .m_axi_arburst(tensor_arburst), .m_axi_arlock(tensor_arlock), .m_axi_arcache(tensor_arcache), .m_axi_arprot(tensor_arprot),
    .m_axi_arqos(tensor_arqos), .m_axi_arregion(tensor_arregion), .m_axi_arvalid(tensor_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor_rready)
  );
  gestureflow_hp0_tensor_loader #(.CHANNELS(40)) tensor40_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 2)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor40_busy), .done(tensor40_done), .fault(tensor40_fault), .frame_start(tensor40_frame_start),
    .pixel_valid(tensor40_pixel_valid), .pixel_ready(tensor40_pixel_ready), .pixel_data(tensor40_pixel),
    .pixels_emitted(tensor40_pixels_emitted), .bytes_read(tensor40_bytes_read),
    .m_axi_araddr(tensor40_araddr), .m_axi_arid(tensor40_arid), .m_axi_arlen(tensor40_arlen), .m_axi_arsize(tensor40_arsize),
    .m_axi_arburst(tensor40_arburst), .m_axi_arlock(tensor40_arlock), .m_axi_arcache(tensor40_arcache), .m_axi_arprot(tensor40_arprot),
    .m_axi_arqos(tensor40_arqos), .m_axi_arregion(tensor40_arregion), .m_axi_arvalid(tensor40_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor40_rready)
  );
  gestureflow_hp0_tensor_loader #(.CHANNELS(80)) tensor80_loader (
    .clk(aclk), .rst_n(aresetn), .start(dma_start && (layer_mode == 3)), .clear(dma_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .busy(tensor80_busy), .done(tensor80_done), .fault(tensor80_fault), .frame_start(tensor80_frame_start),
    .pixel_valid(tensor80_pixel_valid), .pixel_ready(tensor80_pixel_ready), .pixel_data(tensor80_pixel),
    .pixels_emitted(tensor80_pixels_emitted), .bytes_read(tensor80_bytes_read),
    .m_axi_araddr(tensor80_araddr), .m_axi_arid(tensor80_arid), .m_axi_arlen(tensor80_arlen), .m_axi_arsize(tensor80_arsize),
    .m_axi_arburst(tensor80_arburst), .m_axi_arlock(tensor80_arlock), .m_axi_arcache(tensor80_arcache), .m_axi_arprot(tensor80_arprot),
    .m_axi_arqos(tensor80_arqos), .m_axi_arregion(tensor80_arregion), .m_axi_arvalid(tensor80_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(tensor80_rready)
  );
  gestureflow_hp0_gap_fc postprocess (
    .clk(aclk), .rst_n(aresetn), .start(post_start), .clear(post_clear),
    .source_addr(dma_source_addr), .byte_count(dma_bytes), .pixel_count(dma_pixels),
    .gap_multiplier(post_gap_multiplier), .gap_right_shift(post_gap_right_shift),
    .gap_input_zero_point(post_gap_input_zero_point), .gap_output_zero_point(post_gap_output_zero_point),
    .fc_output_zero_point(post_fc_output_zero_point), .fc_weight_write_valid(weight_write_valid),
    .fc_weight_write_class(weight_write_oc[2:0]), .fc_weight_write_group(weight_write_ic_group),
    .fc_weight_write_data(weight_write_data), .fc_bias(bias[5:0]),
    .fc_multiplier(requant_multiplier[5:0]), .fc_right_shift(requant_right_shift[5:0]),
    .busy(post_busy), .done(post_done), .fault(post_fault), .cycles(post_cycles),
    .gap_fnv1a(post_gap_fnv1a), .fc_fnv1a(post_fc_fnv1a), .predicted_class(post_predicted_class),
    .gap_values_done(post_gap_values_done), .fc_values_done(post_fc_values_done),
    .m_axi_araddr(post_araddr), .m_axi_arid(post_arid), .m_axi_arlen(post_arlen), .m_axi_arsize(post_arsize),
    .m_axi_arburst(post_arburst), .m_axi_arlock(post_arlock), .m_axi_arcache(post_arcache), .m_axi_arprot(post_arprot),
    .m_axi_arqos(post_arqos), .m_axi_arregion(post_arregion), .m_axi_arvalid(post_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(post_rready)
  );
  gestureflow_conv4x4_cin_same_stream #(.IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT), .INPUT_CHANNELS(MAX_INPUT_CHANNELS), .OUT_LANES(OUT_LANES)) stream (
    .clk(aclk), .rst_n(aresetn), .image_width(job_width), .image_height(job_height), .frame_start(frame_start), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
    .pixel_data(pixel_data), .input_zero_point(input_zero_point), .input_group_count(layer_mode == 3 ? 5'd20 : (layer_mode == 2 ? 5'd10 : 5'd4)),
    .input_lane_enable(layer_mode == 0 ? 4'b0111 : 4'hf),
    .weight_write_valid(weight_write_valid), .weight_write_oc(weight_write_oc), .weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group), .weight_write_data(weight_write_data), .bias(bias),
    .output_lane_enable(output_lane_enable), .output_valid(output_valid), .output_ready(output_ready),
    .output_psum(output_psum), .output_lane_enable_valid(output_lane_enable_valid), .output_row(output_row),
    .output_column(output_column), .busy(), .protocol_error(protocol_error), .frame_input_done(frame_input_done)
  );
  gestureflow_requant_relu #(.LANES(OUT_LANES)) requant (
    .clk(aclk), .rst_n(aresetn), .in_valid(output_valid), .in_ready(quant_ready), .in_psum(output_psum),
    .in_lane_enable(output_lane_enable_valid), .enable(requant_enable), .relu_enable(requant_relu_enable),
    .output_zero_point(output_zero_point), .multiplier(requant_multiplier), .right_shift(requant_right_shift),
    .out_valid(quant_valid), .out_ready(1'b1), .out_data(quant_data), .out_lane_enable(), .config_error(quant_fault)
  );
  assign output_write_valid = quant_valid;
  assign output_write_addr = OUTPUT_ADDR_W'(int'(quant_row) * int'(job_width) + int'(quant_column));
  assign output_write_data = quant_data;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      quant_row <= '0;
      quant_column <= '0;
    end else if (output_valid && output_ready) begin
      quant_row <= output_row;
      quant_column <= output_column;
    end
  end
  gestureflow_output_bank #(.ADDR_W(OUTPUT_ADDR_W), .DATA_W(OUT_LANES*8)) output_bank (
    .clk(aclk), .write_enable(output_write_valid), .write_addr(output_write_addr), .write_data(quant_data),
    .read_enable(output_read_enable), .read_addr(output_read_addr), .read_data(output_read_data)
  );
  gestureflow_hp0_tensor_writer #(.VECTOR_COUNT(OUTPUTS), .VECTOR_ADDR_W(OUTPUT_ADDR_W), .VECTOR_BYTES(16), .INPUT_WIDTH(IMAGE_WIDTH)) store (
    .clk(aclk), .rst_n(aresetn), .start(store_start), .clear(store_clear), .destination_addr(store_destination),
    .pool_2x2(store_pool_2x2), .vector_count(dma_pixels), .input_width(job_width),
    .destination_stride_bytes(store_stride_bytes), .valid_vector_bytes(store_valid_bytes),
    .byte_count(store_bytes), .busy(store_busy), .done(store_done), .fault(store_fault), .bank_read_addr(output_read_addr),
    .bank_read_enable(output_read_enable), .bank_read_data(output_read_data), .vectors_written(store_vectors_written),
    .bytes_written(store_bytes_written), .m_axi_awaddr(m_axi_awaddr), .m_axi_awid(m_axi_awid), .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos), .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  assign s_axi_awready = !aw_seen && !s_axi_bvalid;
  assign s_axi_wready = !w_seen && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      awaddr<='0; wdata<='0; wstrb<='0; aw_seen<=0; w_seen<=0; s_axi_bvalid<=0; s_axi_bresp<=0;
      s_axi_rvalid<=0; s_axi_rresp<=0; s_axi_rdata<=0; running<=0; done<=0; fault<=0; layer_mode<=0;
      dma_start<=0; dma_clear<=0; post_start<=0; post_clear<=0; store_start<=0; store_clear<=0; store_enable<=0; store_pool_2x2<=0; dma_source_addr<=0;
      dma_bytes<=0; dma_pixels<=0; store_destination<=0; store_bytes<=0; layer_cycles<=0;
      job_width<=16'(IMAGE_WIDTH); job_height<=16'(IMAGE_HEIGHT);
      store_stride_bytes<=0; store_valid_bytes<=0;
      weight_write_valid<=0; weight_write_oc<=0; weight_write_tap<=0; weight_write_ic_group<=0; weight_write_data<=0;
      bias<='0; bias_index<=0; input_zero_point<='0; output_zero_point<=0; output_lane_enable<=16'hffff;
      requant_enable<=0; requant_relu_enable<=0; requant_index<=0; requant_multiplier<='0; requant_right_shift<='0;
      post_gap_multiplier<=0; post_gap_right_shift<=0; post_gap_input_zero_point<=0; post_gap_output_zero_point<=0; post_fc_output_zero_point<=0;
      hash_active<=0; last_output_seen<=0; hash_vector<='0; hash_byte_index<=0; hash_value<=FNV_OFFSET;
      completed_hash<=FNV_OFFSET; output_vectors<=0;
    end else begin
      weight_write_valid<=0; dma_start<=0; dma_clear<=0; post_start<=0; post_clear<=0; store_start<=0; store_clear<=0;
      if (running) layer_cycles <= layer_cycles + 1'b1;
      if (protocol_error || quant_fault || dma_fault || store_fault) fault <= 1'b1;
      if (hash_active) begin
        hash_value <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]);
        if (hash_byte_index == 15) begin
          completed_hash <= fnv_step(hash_value, hash_vector[hash_byte_index*8 +: 8]); hash_active <= 0;
          if (last_output_seen) begin
            if (store_enable) store_start <= 1'b1; else begin running<=0; done<=1; end
          end
        end else hash_byte_index <= hash_byte_index + 1'b1;
      end
      if (output_write_valid) begin
        if (hash_active) fault <= 1'b1;
        hash_vector <= output_write_data; hash_byte_index<=0; hash_active<=1; output_vectors<=output_vectors+1'b1;
        if (output_vectors == 14'(dma_pixels-1'b1)) last_output_seen<=1;
      end
      if (s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr; aw_seen<=1; end
      if (s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata; wstrb<=s_axi_wstrb; w_seen<=1; end
      if (aw_seen && w_seen && !s_axi_bvalid) begin
        case (awaddr[11:0])
          CONTROL: begin
            if (wdata[0]) begin running<=0; done<=0; fault<=0; dma_clear<=1; post_clear<=1; store_clear<=1; hash_active<=0; last_output_seen<=0; hash_value<=FNV_OFFSET; completed_hash<=FNV_OFFSET; layer_cycles<=0; output_vectors<=0; end
            if (wdata[1]) begin
              if (running || dma_busy || store_busy || hash_active) fault<=1;
              else begin running<=1; done<=0; fault<=0; if (layer_mode == 4) post_start<=1; else dma_start<=1; hash_active<=0; last_output_seen<=0; hash_value<=FNV_OFFSET; completed_hash<=FNV_OFFSET; layer_cycles<=0; output_vectors<=0; end
            end
          end
          LAYER_MODE: if (running || dma_busy || store_busy) fault<=1; else layer_mode<=wdata[2:0];
          JOB_WIDTH: if (running || dma_busy || store_busy) fault<=1; else job_width<=wdata[15:0];
          JOB_HEIGHT: if (running || dma_busy || store_busy) fault<=1; else job_height<=wdata[15:0];
          OUTPUT_LANE_MASK: if (running || dma_busy || store_busy) fault<=1; else output_lane_enable<=wdata[15:0];
          STORE_STRIDE: if (running || store_busy) fault<=1; else store_stride_bytes<=wdata;
          STORE_VALID_BYTES: if (running || store_busy) fault<=1; else store_valid_bytes<=wdata[4:0];
          QCFG: begin input_zero_point<={MAX_INPUT_CHANNELS{wdata[7:0]}}; output_zero_point<=wdata[15:8]; requant_enable<=wdata[16]; requant_relu_enable<=wdata[17]; end
          WCTRL: begin weight_write_oc<=wdata[3:0]; weight_write_tap<=wdata[7:4]; weight_write_ic_group<=wdata[12:8]; end
          WDATA: if (running || dma_busy) fault<=1; else weight_write_data<=wdata;
          BIDX: bias_index<=wdata[3:0];
          BDATA: if (running) fault<=1; else bias[bias_index]<=wdata;
          RQIDX: requant_index<=wdata[3:0];
          RQMULT: if (running) fault<=1; else requant_multiplier[requant_index]<=wdata;
          RQSHIFT: if (running) fault<=1; else requant_right_shift[requant_index]<=wdata[5:0];
          DMA_SOURCE: if (running || dma_busy) fault<=1; else dma_source_addr<=wdata;
          DMA_BYTES: if (running || dma_busy) fault<=1; else dma_bytes<=wdata;
          DMA_PIXELS: if (running || dma_busy) fault<=1; else dma_pixels<=wdata[13:0];
          STORE_DESTINATION: if (running || store_busy) fault<=1; else store_destination<=wdata;
          STORE_BYTES: if (running || store_busy) fault<=1; else store_bytes<=wdata;
          STORE_CONTROL: if (running || store_busy) fault<=1; else begin store_enable<=wdata[0]; store_pool_2x2<=wdata[1]; end
          POST_GAP_MULT: if (running) fault<=1; else post_gap_multiplier<=wdata;
          POST_GAP_SHIFT: if (running) fault<=1; else post_gap_right_shift<=wdata[5:0];
          POST_QCFG: if (running) fault<=1; else begin post_gap_input_zero_point<=wdata[7:0]; post_gap_output_zero_point<=wdata[15:8]; post_fc_output_zero_point<=wdata[23:16]; end
          default: begin end
        endcase
        if (awaddr[11:0] == WDATA && !(running || dma_busy)) weight_write_valid<=1;
        s_axi_bvalid<=1; s_axi_bresp<=0; aw_seen<=0; w_seen<=0;
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
      if (store_done && store_enable && running) begin running<=0; done<=1; end
      if (post_done && running && layer_mode == 4) begin running<=0; done<=1; completed_hash<=post_fc_fnv1a; end
      if (s_axi_arvalid && s_axi_arready) begin
        case (s_axi_araddr[11:0])
          MAGIC: s_axi_rdata<=32'h47464e50; VERSION: s_axi_rdata<=32'h00040004;
          STATUS: s_axi_rdata<={24'd0,frame_input_done,protocol_error||quant_fault,hash_active,1'b0,dma_busy,fault,done,running};
          QCFG: s_axi_rdata<={14'd0,requant_relu_enable,requant_enable,output_zero_point,input_zero_point[0]};
          LAYER_MODE: s_axi_rdata<={29'd0,layer_mode}; JOB_WIDTH:s_axi_rdata<={16'd0,job_width}; JOB_HEIGHT:s_axi_rdata<={16'd0,job_height}; OUTPUT_LANE_MASK:s_axi_rdata<={16'd0,output_lane_enable}; CYCLES:s_axi_rdata<=layer_cycles;
          INPUT_PIXELS:s_axi_rdata<={18'd0,input_pixels}; OUTPUT_VECTORS:s_axi_rdata<={18'd0,output_vectors}; OUTPUT_FNV1A:s_axi_rdata<=completed_hash;
          DMA_SOURCE:s_axi_rdata<=dma_source_addr; DMA_BYTES:s_axi_rdata<=dma_bytes; DMA_PIXELS:s_axi_rdata<={18'd0,dma_pixels};
          // Keep the established [31:3] byte-count field wide enough for a
          // 96x96x16 activation (147456 bytes); the assignment naturally
          // discards only the unused upper three bits.
          DMA_STATUS:s_axi_rdata<={dma_bytes_read[28:0],dma_fault,dma_done,dma_busy};
          STORE_DESTINATION:s_axi_rdata<=store_destination; STORE_BYTES:s_axi_rdata<=store_bytes; STORE_CONTROL:s_axi_rdata<={30'd0,store_pool_2x2,store_enable}; STORE_STRIDE:s_axi_rdata<=store_stride_bytes; STORE_VALID_BYTES:s_axi_rdata<={27'd0,store_valid_bytes};
          STORE_STATUS:s_axi_rdata<={store_bytes_written[28:0],store_fault,store_done,store_busy};
          POST_GAP_MULT:s_axi_rdata<=post_gap_multiplier; POST_GAP_SHIFT:s_axi_rdata<={26'd0,post_gap_right_shift};
          POST_QCFG:s_axi_rdata<={8'd0,post_fc_output_zero_point,post_gap_output_zero_point,post_gap_input_zero_point};
          POST_GAP_FNV1A:s_axi_rdata<=post_gap_fnv1a; POST_FC_FNV1A:s_axi_rdata<=post_fc_fnv1a;
          POST_CLASS:s_axi_rdata<={19'd0,post_fc_values_done,post_gap_values_done,post_predicted_class}; POST_CYCLES:s_axi_rdata<=post_cycles;
          POST_PROGRESS:s_axi_rdata<={19'd0,post_fc_values_done,post_gap_values_done,post_busy,post_fault,post_done};
          default:s_axi_rdata<=32'hdeadbeef;
        endcase
        s_axi_rvalid<=1; s_axi_rresp<=0;
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
    end
  end
endmodule
