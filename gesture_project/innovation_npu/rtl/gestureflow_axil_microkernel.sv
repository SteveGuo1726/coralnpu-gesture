// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// First board baseline: AXI-Lite controlled 16x4 MAC transaction engine.
// It is intentionally a correctness/performance-counter baseline before DMA.
`timescale 1ns/1ps
module gestureflow_axil_microkernel (
  input wire aclk, input wire aresetn,
  input wire [31:0] s_axi_awaddr, input wire [2:0] s_axi_awprot, input wire s_axi_awvalid, output logic s_axi_awready,
  input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb, input wire s_axi_wvalid, output logic s_axi_wready,
  output logic [1:0] s_axi_bresp, output logic s_axi_bvalid, input wire s_axi_bready,
  input wire [31:0] s_axi_araddr, input wire [2:0] s_axi_arprot, input wire s_axi_arvalid, output logic s_axi_arready,
  output logic [31:0] s_axi_rdata, output logic [1:0] s_axi_rresp, output logic s_axi_rvalid, input wire s_axi_rready
);
  // RESULT_IDX is deliberately write-index/read-mask. This lets a PS program
  // select one output lane then obtain its full signed INT32 accumulator from
  // RESULT_DATA without relying on an AXI read side effect.
  localparam [11:0] MAGIC=12'h000, VERSION=12'h004, CONTROL=12'h008, STATUS=12'h00c, WCTRL=12'h010, WDATA=12'h014, BIDX=12'h018, BDATA=12'h01c, ACTRL=12'h020, ADATA=12'h024, RESULT_IDX=12'h028, RESULT_DATA=12'h02c, CYCLES=12'h030;
  logic [31:0] awaddr,wdata; logic aw_seen,w_seen; logic [3:0] wstrb;
  logic [3:0] w_oc,w_tap,w_group,b_index,result_index; logic signed [15:0][31:0] bias,result_psum; logic [15:0] result_mask; logic [31:0] cycles; logic done, fault;
  logic weight_we,start_v,mac_v; logic [3:0] mac_tap,mac_group; logic mac_last; logic signed [3:0][7:0] weight_data,activation; logic tile_start_ready,tile_mac_ready,tile_result_valid,tile_busy,tile_fault; logic [15:0] tile_result_mask; logic signed [15:0][31:0] tile_result;
  assign s_axi_awready=!aw_seen&&!s_axi_bvalid; assign s_axi_wready=!w_seen&&!s_axi_bvalid; assign s_axi_arready=!s_axi_rvalid;
  gestureflow_mac_tile #(.OUT_LANES(16),.INPUT_LANES(4),.MAX_TAPS(16),.MAX_IC_GROUPS(16)) tile(
    .clk(aclk),.rst_n(aresetn),.weight_write_valid(weight_we),.weight_write_oc(w_oc),.weight_write_tap(w_tap),.weight_write_ic_group(w_group),.weight_write_data(weight_data),.start_valid(start_v),.start_ready(tile_start_ready),.bias(bias),.output_lane_enable(16'hffff),.mac_valid(mac_v),.mac_ready(tile_mac_ready),.mac_tap(mac_tap),.mac_ic_group(mac_group),.activation(activation),.input_lane_enable(4'hf),.mac_last(mac_last),.result_valid(tile_result_valid),.result_ready(1'b1),.result_psum(tile_result),.result_lane_enable(tile_result_mask),.busy(tile_busy),.protocol_error(tile_fault));
  // This shell feeds BRAM address/control signals through the tile. Use a
  // synchronous reset so the PS7 reset cannot asynchronously disturb RAMB
  // address/enable inputs during configuration.
  always_ff @(posedge aclk) begin
    if(!aresetn) begin aw_seen<=0;w_seen<=0;s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;weight_we<=0;start_v<=0;mac_v<=0;bias<='0;done<=0;fault<=0;cycles<=0;result_psum<='0;result_mask<=0;w_oc<=0;w_tap<=0;w_group<=0;b_index<=0;result_index<=0; end
    else begin
      weight_we<=0;start_v<=0;mac_v<=0;
      if(tile_busy) cycles<=cycles+1'b1;
      if(tile_result_valid) begin result_psum<=tile_result;result_mask<=tile_result_mask;done<=1; end
      if(tile_fault) fault<=1;
      if(s_axi_awvalid&&s_axi_awready) begin awaddr<=s_axi_awaddr;aw_seen<=1;end
      if(s_axi_wvalid&&s_axi_wready) begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;w_seen<=1;end
      if(aw_seen&&w_seen&&!s_axi_bvalid) begin
        case(awaddr[11:0])
          CONTROL: begin if(wdata[1]) begin done<=0;fault<=0;cycles<=0;end if(wdata[0]&&tile_start_ready) start_v<=1; else if(wdata[0]) fault<=1; end
          WCTRL: begin w_oc<=wdata[3:0];w_tap<=wdata[7:4];w_group<=wdata[11:8];end
          WDATA: begin weight_data<=wdata;weight_we<=1;end
          BIDX: b_index<=wdata[3:0]; BDATA: bias[b_index]<=wdata;
          ACTRL: begin mac_tap<=wdata[3:0];mac_group<=wdata[7:4];mac_last<=wdata[8];end
          ADATA: begin activation<=wdata; if(tile_mac_ready) mac_v<=1; else fault<=1; end
          RESULT_IDX: result_index<=wdata[3:0];
          default: begin end
        endcase
        s_axi_bvalid<=1; s_axi_bresp<=0; aw_seen<=0;w_seen<=0;
      end
      if(s_axi_bvalid&&s_axi_bready) s_axi_bvalid<=0;
      if(s_axi_arvalid&&s_axi_arready) begin
        case(s_axi_araddr[11:0])
          MAGIC:s_axi_rdata<=32'h47464e50; VERSION:s_axi_rdata<=32'h00010000; STATUS:s_axi_rdata<={27'd0,fault,done,tile_busy,tile_fault,tile_result_valid};
          RESULT_DATA:s_axi_rdata<=result_psum[result_index]; RESULT_IDX:s_axi_rdata<={16'd0,result_mask}; CYCLES:s_axi_rdata<=cycles; default:s_axi_rdata<=32'hdeadbeef;
        endcase s_axi_rvalid<=1;s_axi_rresp<=0;
      end
      if(s_axi_rvalid&&s_axi_rready) s_axi_rvalid<=0;
    end
  end
endmodule
