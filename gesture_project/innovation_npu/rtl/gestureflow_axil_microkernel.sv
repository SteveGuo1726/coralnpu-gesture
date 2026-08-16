// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// First board baseline: AXI-Lite controlled 16x4 MAC transaction engine.
// It is intentionally a correctness/performance-counter baseline before DMA.
`timescale 1ns/1ps
module gestureflow_axil_microkernel (
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
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BRESP 0, HAS_RRESP 1, HAS_WSTRB 0, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 0, READ_WRITE_MODE READ_ONLY, MAX_BURST_LENGTH 16" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output logic m_axi_rready
);
  // RESULT_IDX is deliberately write-index/read-mask. This lets a PS program
  // select one output lane then obtain its full signed INT32 accumulator from
  // RESULT_DATA without relying on an AXI read side effect.
  localparam [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008, STATUS=12'h00c, WCTRL=12'h010, WDATA=12'h014, BIDX=12'h018, BDATA=12'h01c, ACTRL=12'h020, ADATA=12'h024, RESULT_IDX=12'h028, RESULT_DATA=12'h02c, CYCLES=12'h030, ACT_STAGE_ADDR=12'h034, ACT_STAGE_DATA=12'h038, JOB_CFG=12'h03c, RQIDX=12'h040, RQMULT=12'h044, RQSHIFT=12'h048, RQCTRL=12'h04c, OUT_STAGE_ADDR=12'h050, OUT_READ_CTRL=12'h054, OUT_READ_DATA=12'h058, QUANT_RESULT_IDX=12'h05c, QUANT_RESULT_DATA=12'h060, DMA_SOURCE_ADDR=12'h064, DMA_WORD_COUNT=12'h068, DMA_STAGE_ADDR=12'h06c, DMA_CONTROL=12'h070, DMA_STATUS=12'h074;
  logic [31:0] awaddr,wdata; logic aw_seen,w_seen; logic [3:0] wstrb;
  logic [3:0] w_oc,w_tap,w_group,b_index,result_index; logic signed [15:0][31:0] bias,result_psum; logic [15:0] result_mask; logic [31:0] cycles; logic done, fault;
  logic weight_we,start_v,mac_v; logic [3:0] mac_tap,mac_group; logic mac_last; logic signed [3:0][7:0] weight_data,activation; logic tile_start_ready,tile_mac_ready,tile_result_valid,tile_busy,tile_fault; logic [15:0] tile_result_mask; logic signed [15:0][31:0] tile_result;
  logic requant_in_ready,requant_out_valid,requant_config_error,requant_enable,requant_relu_enable; logic signed [7:0] requant_zero_point; logic [3:0] requant_index,quant_result_index; logic signed [15:0][31:0] requant_multiplier; logic [15:0][5:0] requant_right_shift; logic signed [15:0][7:0] quant_result; logic [15:0] quant_result_mask;
  logic [7:0] output_write_addr,output_read_addr; logic output_read_enable; logic [1:0] output_read_word_index; logic [127:0] output_read_data;
  logic stage_write_enable,stage_read_enable,stage_running,stage_data_valid;
  logic [7:0] stage_write_addr,stage_read_addr,stage_read_linear;
  logic [31:0] stage_write_data,stage_read_data;
  logic [3:0] stage_read_tap,stage_read_group,stage_issue_tap,stage_issue_group,job_tap_limit,job_group_limit,job_tail_input_mask,mac_input_lane_enable;
  logic [15:0] job_output_lane_enable;
  logic stage_read_active;
  logic dma_start,dma_clear,dma_busy,dma_done,dma_fault,dma_stage_write_enable;
  logic [31:0] dma_source_addr,dma_stage_write_data;
  logic [8:0] dma_word_count;
  logic [7:0] dma_stage_addr,dma_stage_write_addr;
  assign s_axi_awready=!aw_seen&&!s_axi_bvalid; assign s_axi_wready=!w_seen&&!s_axi_bvalid; assign s_axi_arready=!s_axi_rvalid;
  gestureflow_mac_tile #(.OUT_LANES(16),.INPUT_LANES(4),.MAX_TAPS(16),.MAX_IC_GROUPS(16)) tile(
    .clk(aclk),.rst_n(aresetn),.weight_write_valid(weight_we),.weight_write_oc(w_oc),.weight_write_tap(w_tap),.weight_write_ic_group(w_group),.weight_write_data(weight_data),.start_valid(start_v),.start_ready(tile_start_ready),.bias(bias),.output_lane_enable(job_output_lane_enable),.mac_valid(mac_v),.mac_ready(tile_mac_ready),.mac_tap(mac_tap),.mac_ic_group(mac_group),.activation(activation),.input_lane_enable(mac_input_lane_enable),.mac_last(mac_last),.result_valid(tile_result_valid),.result_ready(requant_in_ready),.result_psum(tile_result),.result_lane_enable(tile_result_mask),.busy(tile_busy),.protocol_error(tile_fault));
  gestureflow_activation_bank #(.ADDR_W(8),.DATA_W(32)) activation_bank(
    .clk(aclk),.write_enable(stage_write_enable||dma_stage_write_enable),.write_addr(dma_stage_write_enable?dma_stage_write_addr:stage_write_addr),.write_data(dma_stage_write_enable?dma_stage_write_data:stage_write_data),.read_enable(stage_read_enable),.read_addr(stage_read_addr),.read_data(stage_read_data));
  gestureflow_hp0_read_loader hp0_read_loader(
    .clk(aclk),.rst_n(aresetn),.start(dma_start),.clear(dma_clear),.source_addr(dma_source_addr),.word_count(dma_word_count),.destination_addr(dma_stage_addr),.busy(dma_busy),.done(dma_done),.fault(dma_fault),.stage_write_enable(dma_stage_write_enable),.stage_write_addr(dma_stage_write_addr),.stage_write_data(dma_stage_write_data),
    .m_axi_araddr(m_axi_araddr),.m_axi_arid(m_axi_arid),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arlock(m_axi_arlock),.m_axi_arcache(m_axi_arcache),.m_axi_arprot(m_axi_arprot),.m_axi_arqos(m_axi_arqos),.m_axi_arregion(m_axi_arregion),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
  gestureflow_requant_relu #(.LANES(16)) requant(
    .clk(aclk),.rst_n(aresetn),.in_valid(tile_result_valid),.in_ready(requant_in_ready),.in_psum(tile_result),.in_lane_enable(tile_result_mask),.enable(requant_enable),.relu_enable(requant_relu_enable),.output_zero_point(requant_zero_point),.multiplier(requant_multiplier),.right_shift(requant_right_shift),.out_valid(requant_out_valid),.out_ready(1'b1),.out_data(quant_result),.out_lane_enable(quant_result_mask),.config_error(requant_config_error));
  gestureflow_output_bank #(.ADDR_W(8),.DATA_W(128)) output_bank(
    .clk(aclk),.write_enable(requant_out_valid),.write_addr(output_write_addr),.write_data(quant_result),.read_enable(output_read_enable),.read_addr(output_read_addr),.read_data(output_read_data));
  // This shell feeds BRAM address/control signals through the tile. Use a
  // synchronous reset so the PS7 reset cannot asynchronously disturb RAMB
  // address/enable inputs during configuration.
  always_ff @(posedge aclk) begin
    if(!aresetn) begin aw_seen<=0;w_seen<=0;s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;weight_we<=0;start_v<=0;mac_v<=0;bias<='0;done<=0;fault<=0;cycles<=0;result_psum<='0;result_mask<=0;w_oc<=0;w_tap<=0;w_group<=0;b_index<=0;result_index<=0;stage_write_enable<=0;stage_write_addr<=0;stage_write_data<=0;stage_read_enable<=0;stage_read_addr<=0;stage_read_linear<=0;stage_running<=0;stage_read_active<=0;stage_data_valid<=0;stage_read_tap<=0;stage_read_group<=0;stage_issue_tap<=0;stage_issue_group<=0;job_tap_limit<=4'd15;job_group_limit<=4'd15;job_tail_input_mask<=4'hf;job_output_lane_enable<=16'hffff;mac_input_lane_enable<=4'hf;requant_enable<=0;requant_relu_enable<=0;requant_zero_point<=0;requant_index<=0;quant_result_index<=0;requant_multiplier<='0;requant_right_shift<='0;output_write_addr<=0;output_read_addr<=0;output_read_enable<=0;output_read_word_index<=0;dma_start<=0;dma_clear<=0;dma_source_addr<=0;dma_word_count<=0;dma_stage_addr<=0; end
    else begin
      weight_we<=0;start_v<=0;mac_v<=0;stage_write_enable<=0;stage_read_enable<=0;output_read_enable<=0;dma_start<=0;dma_clear<=0;
      if(tile_busy) cycles<=cycles+1'b1;
      if(tile_result_valid&&requant_in_ready) begin result_psum<=tile_result;result_mask<=tile_result_mask; end
      if(requant_out_valid) begin done<=1; output_write_addr<=output_write_addr+1'b1; end
      if(tile_fault||requant_config_error) fault<=1;
      // The synchronous BRAM has one cycle read latency, so requests are
      // issued ahead of the MAC stream and its tail is explicitly drained.
      // The descriptor limits make the same engine cover a full 16x16 tile
      // and a real RGB first layer (16 taps, one 3-lane input group).
      if(stage_running) begin
        stage_data_valid<=stage_read_enable;
        if(stage_read_active) begin
          stage_read_enable<=1;stage_read_addr<=stage_read_linear;stage_read_linear<=stage_read_linear+1'b1;
          if(stage_read_group==job_group_limit) begin
            stage_read_group<=0;
            if(stage_read_tap==job_tap_limit) stage_read_active<=0;
            else stage_read_tap<=stage_read_tap+1'b1;
          end else stage_read_group<=stage_read_group+1'b1;
        end
        if(stage_data_valid&&tile_mac_ready) begin
          activation<=stage_read_data;mac_tap<=stage_issue_tap;mac_group<=stage_issue_group;mac_input_lane_enable<=(stage_issue_group==job_group_limit)?job_tail_input_mask:4'hf;mac_last<=(stage_issue_tap==job_tap_limit)&&(stage_issue_group==job_group_limit);mac_v<=1;
          if(stage_issue_group==job_group_limit) begin
            stage_issue_group<=0;
            if(stage_issue_tap==job_tap_limit) begin stage_running<=0;stage_data_valid<=0; end
            else stage_issue_tap<=stage_issue_tap+1'b1;
          end else stage_issue_group<=stage_issue_group+1'b1;
        end
      end else begin
        stage_data_valid<=0;
      end
      if(s_axi_awvalid&&s_axi_awready) begin awaddr<=s_axi_awaddr;aw_seen<=1;end
      if(s_axi_wvalid&&s_axi_wready) begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;w_seen<=1;end
      if(aw_seen&&w_seen&&!s_axi_bvalid) begin
        case(awaddr[11:0])
          CONTROL: begin
            if(wdata[1]) begin done<=0;fault<=0;cycles<=0;stage_running<=0;stage_read_active<=0;stage_data_valid<=0;stage_read_linear<=0;stage_read_tap<=0;stage_read_group<=0;stage_issue_tap<=0;stage_issue_group<=0;dma_clear<=1;end
            if(wdata[0]&&tile_start_ready&&!dma_busy) begin
              start_v<=1;
              if(wdata[2]) begin stage_running<=1;stage_read_active<=1;stage_data_valid<=0;stage_read_linear<=0;stage_read_tap<=0;stage_read_group<=0;stage_issue_tap<=0;stage_issue_group<=0;end
            end else if(wdata[0]) fault<=1;
          end
          WCTRL: begin w_oc<=wdata[3:0];w_tap<=wdata[7:4];w_group<=wdata[11:8];end
          WDATA: begin weight_data<=wdata;weight_we<=1;end
          BIDX: b_index<=wdata[3:0]; BDATA: bias[b_index]<=wdata;
          ACTRL: begin mac_tap<=wdata[3:0];mac_group<=wdata[7:4];mac_last<=wdata[8];end
          ADATA: begin activation<=wdata; if(tile_mac_ready) mac_v<=1; else fault<=1; end
          ACT_STAGE_ADDR: stage_write_addr<=wdata[7:0];
          ACT_STAGE_DATA: begin
            if(!tile_busy&&!stage_running&&!dma_busy) begin stage_write_data<=wdata;stage_write_enable<=1;end else fault<=1;
          end
          // [3:0] tap_count-1, [7:4] Cin-group-count-1, [11:8] valid
          // lanes in the final Cin group, [31:16] active output lanes.
          JOB_CFG: begin job_tap_limit<=wdata[3:0];job_group_limit<=wdata[7:4];job_tail_input_mask<=wdata[11:8];job_output_lane_enable<=wdata[31:16];end
          RQIDX: requant_index<=wdata[3:0];
          RQMULT: if(!tile_busy&&!requant_out_valid) requant_multiplier[requant_index]<=wdata; else fault<=1;
          RQSHIFT: if(!tile_busy&&!requant_out_valid) requant_right_shift[requant_index]<=wdata[5:0]; else fault<=1;
          RQCTRL: if(!tile_busy&&!requant_out_valid) begin requant_enable<=wdata[0];requant_relu_enable<=wdata[1];requant_zero_point<=wdata[15:8];end else fault<=1;
          OUT_STAGE_ADDR: output_write_addr<=wdata[7:0];
          OUT_READ_CTRL: begin output_read_addr<=wdata[7:0];output_read_word_index<=wdata[9:8];output_read_enable<=1;end
          RESULT_IDX: result_index<=wdata[3:0];
          QUANT_RESULT_IDX: quant_result_index<=wdata[3:0];
          DMA_SOURCE_ADDR: if(!dma_busy) dma_source_addr<=wdata; else fault<=1;
          DMA_WORD_COUNT: if(!dma_busy) dma_word_count<=wdata[8:0]; else fault<=1;
          DMA_STAGE_ADDR: if(!dma_busy) dma_stage_addr<=wdata[7:0]; else fault<=1;
          DMA_CONTROL: begin
            if(wdata[1]) dma_clear<=1;
            if(wdata[0]) begin
              if(!tile_busy&&!stage_running&&!dma_busy) dma_start<=1;
              else fault<=1;
            end
          end
          default: begin end
        endcase
        s_axi_bvalid<=1; s_axi_bresp<=0; aw_seen<=0;w_seen<=0;
      end
      if(s_axi_bvalid&&s_axi_bready) s_axi_bvalid<=0;
      if(s_axi_arvalid&&s_axi_arready) begin
        case(s_axi_araddr[11:0])
          MAGIC:s_axi_rdata<=32'h47464e50; VERSION:s_axi_rdata<=32'h00010004; STATUS:s_axi_rdata<={26'd0,stage_running,fault,done,tile_busy,tile_fault,tile_result_valid};
          RESULT_DATA:s_axi_rdata<=result_psum[result_index]; RESULT_IDX:s_axi_rdata<={16'd0,result_mask}; CYCLES:s_axi_rdata<=cycles;
          QUANT_RESULT_DATA:s_axi_rdata<={{24{quant_result[quant_result_index][7]}},quant_result[quant_result_index]}; QUANT_RESULT_IDX:s_axi_rdata<={16'd0,quant_result_mask}; OUT_READ_DATA:s_axi_rdata<=output_read_data[output_read_word_index*32 +: 32]; DMA_STATUS:s_axi_rdata<={29'd0,dma_fault,dma_done,dma_busy}; default:s_axi_rdata<=32'hdeadbeef;
        endcase s_axi_rvalid<=1;s_axi_rresp<=0;
      end
      if(s_axi_rvalid&&s_axi_rready) s_axi_rvalid<=0;
    end
  end
endmodule
