// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
//
// HP0-controlled real body-layer wrapper using the DMP compute engine.  It
// reads a signed 96x96x16 feature map from PS DDR, performs one real TFLite
// body convolution on the 8-input-lane dual-multiply MAC array, and emits the
// same requantized FNV/golden as the non-DMP body2 baseline.
//
// DMP weight programming uses WCTRL[2:0]=pair, WCTRL[6:3]=tap, WCTRL[8]=group.
// Six consecutive WDATA words form the 192-bit packed weight-bank word.
`timescale 1ns/1ps
module gestureflow_body2_dmp_hp0_axil (
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
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BRESP 0, HAS_RRESP 1, HAS_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 0, READ_WRITE_MODE READ_ONLY, MAX_BURST_LENGTH 16" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output logic m_axi_rready
);
  localparam logic [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008, STATUS=12'h00c,
    QCFG=12'h010, WCTRL=12'h014, WDATA=12'h018, BIDX=12'h01c, BDATA=12'h020,
    RQIDX=12'h024, RQMULT=12'h028, RQSHIFT=12'h02c, CYCLES=12'h034,
    INPUT_PIXELS=12'h038, OUTPUT_VECTORS=12'h03c, OUTPUT_FNV1A=12'h040,
    DMA_SOURCE=12'h044, DMA_BYTES=12'h048, DMA_PIXELS=12'h04c, DMA_STATUS=12'h050;
  localparam logic [31:0] FNV_OFFSET=32'h811c9dc5, FNV_PRIME=32'h01000193;
  localparam int IMAGE_WIDTH=96, IMAGE_HEIGHT=96, CHANNELS=16, OUTPUTS=IMAGE_WIDTH*IMAGE_HEIGHT;

  logic [31:0] awaddr,wdata; logic aw_seen,w_seen;
  logic running,done,fault,hash_active,last_output_seen,dma_start,dma_clear;
  logic frame_start,pixel_valid,pixel_ready,frame_input_done,raw_fault,quant_fault,dma_busy,dma_done,dma_fault;
  logic signed [CHANNELS-1:0][7:0] pixel_data,input_zero_point;
  logic [13:0] dma_pixels,input_pixels; logic [31:0] dma_bytes,dma_bytes_read;
  logic [31:0] dma_source_addr,layer_cycles;
  logic weight_write_valid; logic [2:0] weight_write_pair; logic [3:0] weight_write_tap; logic weight_write_ic_group;
  logic [8*24-1:0] weight_write_data;
  logic [8*24-1:0] dmp_weight_word, next_dmp_weight_word;
  logic [2:0] dmp_word_index;
  logic signed [15:0][31:0] bias,requant_multiplier;
  logic [3:0] bias_index,requant_index;
  logic [15:0][5:0] requant_right_shift; logic [15:0] output_lane_enable;
  logic requant_enable,requant_relu_enable; logic signed [7:0] output_zero_point;
  logic raw_valid,raw_ready; logic signed [15:0][31:0] raw_psum; logic [15:0] raw_mask;
  logic [15:0] raw_row,raw_column;
  logic quant_valid,quant_ready; logic signed [15:0][7:0] quant_data; logic [15:0] quant_mask;
  logic [127:0] hash_vector; logic [4:0] hash_byte_index;
  logic [31:0] hash_value,completed_hash; logic [13:0] output_vectors;

  function automatic logic [31:0] fnv_step(input logic [31:0] current,input logic [7:0] byte_value);
    fnv_step=(current^{24'd0,byte_value})*FNV_PRIME;
  endfunction

  assign s_axi_awready=!aw_seen&&!s_axi_bvalid;
  assign s_axi_wready=!w_seen&&!s_axi_bvalid;
  assign s_axi_arready=!s_axi_rvalid;

  gestureflow_hp0_tensor_loader #(.CHANNELS(CHANNELS)) loader (
    .clk(aclk),.rst_n(aresetn),.start(dma_start),.clear(dma_clear),.source_addr(dma_source_addr),.byte_count(dma_bytes),.pixel_count(dma_pixels),
    .busy(dma_busy),.done(dma_done),.fault(dma_fault),.frame_start(frame_start),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_data(pixel_data),
    .pixels_emitted(input_pixels),.bytes_read(dma_bytes_read),.m_axi_araddr(m_axi_araddr),.m_axi_arid(m_axi_arid),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),.m_axi_arlock(m_axi_arlock),.m_axi_arcache(m_axi_arcache),.m_axi_arprot(m_axi_arprot),.m_axi_arqos(m_axi_arqos),.m_axi_arregion(m_axi_arregion),
    .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));

  gestureflow_conv4x4_cin_same_stream_dmp #(
    .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
    .INPUT_CHANNELS(CHANNELS), .OUT_LANES(16), .KERNEL_SIZE(4)
  ) stream (
    .image_width(16'(IMAGE_WIDTH)), .image_height(16'(IMAGE_HEIGHT)), .pointwise_mode(1'b0),
    .clk(aclk),.rst_n(aresetn),.frame_start(frame_start),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_data(pixel_data),
    .input_zero_point(input_zero_point),.input_group_count(5'd2),.input_lane_enable(8'hff),
    .weight_write_valid(weight_write_valid),.weight_write_pair(weight_write_pair),.weight_write_tap(weight_write_tap),
    .weight_write_ic_group(weight_write_ic_group),.weight_write_data(weight_write_data),.weight_bank_select(1'b0),
    .read_bank_select(1'b0),.bias(bias),.output_lane_enable(output_lane_enable),.output_valid(raw_valid),
    .output_ready(raw_ready),.output_psum(raw_psum),.output_lane_enable_valid(raw_mask),.output_row(raw_row),.output_column(raw_column),
    .busy(),.protocol_error(raw_fault),.frame_input_done(frame_input_done));

  gestureflow_requant_relu #(.LANES(16)) requant (
    .clk(aclk),.rst_n(aresetn),.in_valid(raw_valid),.in_ready(raw_ready),.in_psum(raw_psum),.in_lane_enable(raw_mask),.enable(requant_enable),
    .relu_enable(requant_relu_enable),.output_zero_point(output_zero_point),.multiplier(requant_multiplier),.right_shift(requant_right_shift),
    .out_valid(quant_valid),.out_ready(quant_ready),.out_data(quant_data),.out_lane_enable(quant_mask),.config_error(quant_fault));

  assign quant_ready = !hash_active;
  always_comb begin
    next_dmp_weight_word = dmp_weight_word;
    next_dmp_weight_word[dmp_word_index*32 +: 32] = wdata;
  end

  always_ff @(posedge aclk) begin
    if(!aresetn) begin
      awaddr<='0;wdata<='0;aw_seen<=0;w_seen<=0;s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
      running<=0;done<=0;fault<=0;dma_start<=0;dma_clear<=0;dma_source_addr<=0;dma_bytes<=0;dma_pixels<=0;layer_cycles<=0;
      weight_write_valid<=0;weight_write_pair<=0;weight_write_tap<=0;weight_write_ic_group<=0;weight_write_data<=0;dmp_weight_word<=0;dmp_word_index<=0;
      bias<='0;bias_index<=0;input_zero_point<='0;output_zero_point<=0;output_lane_enable<=16'hffff;
      requant_enable<=0;requant_relu_enable<=0;requant_index<=0;requant_multiplier<='0;requant_right_shift<='0;
      hash_active<=0;last_output_seen<=0;hash_vector<='0;hash_byte_index<=0;hash_value<=FNV_OFFSET;completed_hash<=FNV_OFFSET;output_vectors<=0;
    end else begin
      weight_write_valid<=0;dma_start<=0;dma_clear<=0;
      if(running) layer_cycles<=layer_cycles+1'b1;
      if(raw_fault||quant_fault||dma_fault) fault<=1;
      if(hash_active) begin
        hash_value<=fnv_step(hash_value,hash_vector[hash_byte_index*8 +: 8]);
        if(hash_byte_index==15) begin completed_hash<=fnv_step(hash_value,hash_vector[hash_byte_index*8 +: 8]);hash_active<=0;if(last_output_seen) begin running<=0;done<=1;end end else hash_byte_index<=hash_byte_index+1'b1;
      end
      if(quant_valid&&quant_ready) begin
        hash_vector<=quant_data;hash_byte_index<=0;hash_active<=1;output_vectors<=output_vectors+1'b1;
        if(output_vectors==14'(OUTPUTS-1))last_output_seen<=1;
      end
      if(s_axi_awvalid&&s_axi_awready) begin awaddr<=s_axi_awaddr;aw_seen<=1;end
      if(s_axi_wvalid&&s_axi_wready) begin wdata<=s_axi_wdata;w_seen<=1;end
      if(aw_seen&&w_seen&&!s_axi_bvalid) begin
        case(awaddr[11:0])
          CONTROL: begin
            if(wdata[0])begin running<=0;done<=0;fault<=0;dma_clear<=1;hash_active<=0;last_output_seen<=0;hash_value<=FNV_OFFSET;completed_hash<=FNV_OFFSET;layer_cycles<=0;output_vectors<=0;end
            if(wdata[1])begin if(running||dma_busy||hash_active)fault<=1;else begin running<=1;done<=0;fault<=0;dma_start<=1;hash_active<=0;last_output_seen<=0;hash_value<=FNV_OFFSET;completed_hash<=FNV_OFFSET;layer_cycles<=0;output_vectors<=0;end end
          end
          QCFG:begin input_zero_point<={CHANNELS{wdata[7:0]}};output_zero_point<=wdata[15:8];requant_enable<=wdata[16];requant_relu_enable<=wdata[17];end
          WCTRL:begin weight_write_pair<=wdata[2:0];weight_write_tap<=wdata[6:3];weight_write_ic_group<=wdata[8];dmp_weight_word<=0;dmp_word_index<=0;end
          WDATA:begin
            if(running||dma_busy)fault<=1;
            else if(dmp_word_index==3'd5) begin
              weight_write_data<=next_dmp_weight_word;weight_write_valid<=1;dmp_weight_word<=0;dmp_word_index<=0;
            end else begin
              dmp_weight_word<=next_dmp_weight_word;dmp_word_index<=dmp_word_index+1'b1;
            end
          end
          BIDX:bias_index<=wdata[3:0]; BDATA:if(running)fault<=1;else bias[bias_index]<=wdata;
          RQIDX:requant_index<=wdata[3:0]; RQMULT:if(running)fault<=1;else requant_multiplier[requant_index]<=wdata;
          RQSHIFT:if(running)fault<=1;else requant_right_shift[requant_index]<=wdata[5:0];
          DMA_SOURCE:if(running||dma_busy)fault<=1;else dma_source_addr<=wdata;
          DMA_BYTES:if(running||dma_busy)fault<=1;else dma_bytes<=wdata;
          DMA_PIXELS:if(running||dma_busy)fault<=1;else dma_pixels<=wdata[13:0];
          default:begin end
        endcase
        s_axi_bvalid<=1;s_axi_bresp<=0;aw_seen<=0;w_seen<=0;
      end
      if(s_axi_bvalid&&s_axi_bready)s_axi_bvalid<=0;
      if(s_axi_arvalid&&s_axi_arready) begin
        case(s_axi_araddr[11:0])
          MAGIC:s_axi_rdata<=32'h47464e50; VERSION:s_axi_rdata<=32'h00040001;
          STATUS:s_axi_rdata<={24'd0,frame_input_done,raw_fault||quant_fault,hash_active,1'b0,dma_busy,fault,done,running};
          QCFG:s_axi_rdata<={14'd0,requant_relu_enable,requant_enable,output_zero_point,input_zero_point[0]};
          CYCLES:s_axi_rdata<=layer_cycles; INPUT_PIXELS:s_axi_rdata<={18'd0,input_pixels}; OUTPUT_VECTORS:s_axi_rdata<={18'd0,output_vectors}; OUTPUT_FNV1A:s_axi_rdata<=completed_hash;
          DMA_SOURCE:s_axi_rdata<=dma_source_addr; DMA_BYTES:s_axi_rdata<=dma_bytes; DMA_PIXELS:s_axi_rdata<={18'd0,dma_pixels}; DMA_STATUS:s_axi_rdata<={dma_bytes_read[28:0],dma_fault,dma_done,dma_busy};
          default:s_axi_rdata<=32'hdeadbeef;
        endcase s_axi_rvalid<=1;s_axi_rresp<=0;
      end
      if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
    end
  end
endmodule
