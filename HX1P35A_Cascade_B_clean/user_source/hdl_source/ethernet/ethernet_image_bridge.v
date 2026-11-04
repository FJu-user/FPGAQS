`timescale 1ns/1ps
// HX1P35 RGMII physical transport + single-slot image endpoint.
module ethernet_image_bridge #(
 parameter VISION_ROLE=0,MAX_MODE=16,VISION_POLL=5000000,VISION_TIMEOUT=25000000,
 parameter CASCADE_COMPACT=1,CASCADE_DEMAND=1,CASCADE_SUPPORT=0,SHARED_TX=1,
 parameter CASCADE_WIDTH=320,CASCADE_HEIGHT=180,CASCADE_GAP=5000000,CASCADE_ACK=25000000,
 parameter [47:0] LOCAL_MAC=48'h020000000002,PEER_MAC=48'h020000000003,
 parameter [31:0] LOCAL_IP=32'hc0a88902,PEER_IP=32'hc0a88903
) (
 input wire ref_clk,sys_clk,rst_n,mode1080,
 input wire [3:0] rgmii_rxd,input wire rgmii_rx_ctl,rgmii_rxc,
 output wire [3:0] rgmii_txd,output wire rgmii_tx_ctl,rgmii_txc,phy_rst_n,
 input wire source_image,input wire [1:0] compare_mode,input wire [4:0] current_mode,
 input wire front_valid,input wire [31:0] displayed_id,
 output wire source_set,source_value,compare_set,mode_set,
 output wire [1:0] compare_value,output wire [4:0] requested_mode,
 output wire [155:0] mem_data,output wire mem_valid,input wire mem_ready,
 input wire mem_error,input wire [383:0] mem_reply,
 input wire cascade_run,input wire [127:0] cascade_read_reply,input wire cascade_read_ready,
 output wire [26:0] cascade_read_command,output wire cascade_read_valid,
 input wire [4:0] vision_mode,
 output wire [255:0] vision_objects,output wire [3:0] vision_count,
 output wire vision_overflow,vision_valid,output wire [31:0] vision_source_id,vision_config_epoch,
 input wire [191:0] vision_reply,
 output wire vision_request,output wire [31:0] vision_request_epoch,vision_request_sequence,
 output wire vision_request_native,vision_request_mode1080,
 output wire [4:0] vision_request_mode
);
 wire clk125,clk90,clk25,locked;
 ethernet_pll u_eth_pll(.refclk(ref_clk),.reset(1'b0),.clk0_out(clk125),.clk1_out(clk90),.clk2_out(clk25),.lock(locked));
 // PHY strap pins settle while reset stays low for 20 ms after PLL lock.
 reg [18:0] reset_count;
 reg phy_run;
 always @(posedge clk25 or negedge locked)
  if(!locked) begin reset_count<=0;phy_run<=0;end
  else if(!phy_run) begin
   if(reset_count==499999) phy_run<=1;else reset_count<=reset_count+1'b1;
  end
 assign phy_rst_n=phy_run;
 wire eth_reset_n=rst_n && locked && phy_run;
 wire eth_sys_reset_n,eth_tx_reset_n,eth_tx90_reset_n,control_sys_reset_n;
 wire eth_tx_data_io_reset;
 ethernet_reset_sync u_sys_reset_sync(.clk(sys_clk),.async_reset_n(eth_reset_n),.reset_n(eth_sys_reset_n));
 ethernet_reset_sync u_tx_reset_sync(.clk(clk125),.async_reset_n(eth_reset_n),.reset_n(eth_tx_reset_n));
 // DATA/CTL C0 reset releases on C1, midway between the DDR edges.
 // TXC only forwards the PLL C1 clock: no dynamic ODDR reset is needed.
 // It continues through application reset while DATA/CTL are held at idle.
 // PLL unlock still asserts PHY reset and restarts its 20 ms lock wait.
 // Do not gate the clock or false-path a fabric reset -> TXC recovery path.
 ethernet_io_reset_sync u_tx_data_io_reset_sync(.clk(clk90),.async_reset_n(eth_reset_n),.reset(eth_tx_data_io_reset));
 assign eth_tx90_reset_n=!eth_tx_data_io_reset;
 // Preserve the existing application/DDR lease reset cause. A transport PLL
 // relock must not erase an allocated upload session or a pending DDR command.
 ethernet_reset_sync u_control_sys_reset_sync(.clk(sys_clk),.async_reset_n(rst_n),.reset_n(control_sys_reset_n));
 wire rx_clk,rx_valid,rx_error;wire [7:0] rx_data,tx_data;wire tx_valid;
 ethernet_rgmii_io u_rgmii (
  // TX data uses C0; forwarded clock uses C1 (+90 degrees / +2 ns).
  // Only DATA/CTL use the phase-centered IO reset. TXC remains a continuous
  // forwarded clock; its constant 1/0 ODDR data needs no reset state.
  .speed_10_100(1'b0),.gmii_tx_clk_d(clk90),.gmii_tx_reset_d(1'b0),
  .gmii_tx_reset(eth_tx_data_io_reset),.gmii_tx_clk(clk125),.gmii_txd(tx_data),.gmii_tx_en(tx_valid),.gmii_tx_er(1'b0),
  .gmii_rx_reset(!eth_reset_n),.gmii_rx_clk(rx_clk),.gmii_rxd(rx_data),.gmii_rx_dv(rx_valid),.gmii_rx_er(rx_error),
  .rgmii_txd(rgmii_txd),.rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txc(rgmii_txc),
  .rgmii_rxd(rgmii_rxd),.rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_rxc(rgmii_rxc),
  .gmii_crs(),.gmii_col(),.link_status(),.clock_speed(),.duplex_status()
 );
 wire frame_valid,frame_release;wire [11:0] frame_length;wire [10:0] rd_addr;wire [7:0] rd_data;
 ethernet_frame_rx u_rx (
  .rx_clk(rx_clk),.sys_clk(sys_clk),.rst_n(eth_reset_n),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),
  .frame_valid(frame_valid),.frame_length(frame_length),.frame_release(frame_release),.rd_addr(rd_addr),.rd_data(rd_data),
  .crc_errors(),.dropped_frames()
 );
 wire [448:0] tx_message,tx_message_eth;wire tx_request,tx_ready,tx_ready_cdc,tx_request_eth,tx_ready_eth;
 // A reset CDC is not an accepting consumer, even though req==ack==0.
 assign tx_ready=eth_sys_reset_n && tx_ready_cdc;
 wire ack_valid,ack_source_image,cascade_enable;wire [7:0] ack_command,ack_status;wire [31:0] ack_session,ack_sequence;
 wire vrx;wire [31:0] vrxs,vrxq;wire [191:0] vrxp;
 ethernet_image_control #(.VISION_ROLE(VISION_ROLE),.MAX_MODE(MAX_MODE),.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),
  .CASCADE_SUPPORT(CASCADE_SUPPORT),.COMPACT_SUPPORT(CASCADE_COMPACT),.CASCADE_WIDTH(CASCADE_WIDTH),.CASCADE_HEIGHT(CASCADE_HEIGHT),
  .W720(CASCADE_WIDTH*4),.H720(CASCADE_HEIGHT*4),.W1080(CASCADE_WIDTH*6),.H1080(CASCADE_HEIGHT*6),
  .PEER_MAC(PEER_MAC),.PEER_IP(PEER_IP)) u_control (
  .clk(sys_clk),.rst_n(control_sys_reset_n),.mode1080(mode1080),
  .frame_valid(frame_valid),.frame_length(frame_length),.frame_release(frame_release),.rd_addr(rd_addr),.rd_data(rd_data),
  .tx_message(tx_message),.tx_valid(tx_request),.tx_ready(tx_ready),
  .source_image(source_image),.compare_mode(compare_mode),.current_mode(current_mode),
  .front_valid(front_valid),.displayed_id(displayed_id),
  .source_set(source_set),.source_value(source_value),.compare_set(compare_set),.compare_value(compare_value),
  .mode_set(mode_set),.requested_mode(requested_mode),
  .mem_data(mem_data),.mem_valid(mem_valid),.mem_ready(mem_ready),.mem_error(mem_error),.mem_reply(mem_reply),
  .ack_valid(ack_valid),.ack_source_image(ack_source_image),.ack_command(ack_command),.ack_status(ack_status),.ack_session(ack_session),.ack_sequence(ack_sequence),.cascade_enable(cascade_enable),
  .vision_reply(vision_reply),.vision_request(vision_request),.vision_request_epoch(vision_request_epoch),
  .vision_request_sequence(vision_request_sequence),.vision_request_mode(vision_request_mode),.vision_request_native(vision_request_native),.vision_request_mode1080(vision_request_mode1080),
  .vision_rx_valid(vrx),.vision_rx_session(vrxs),.vision_rx_sequence(vrxq),.vision_rx_payload(vrxp)
 );
 ethernet_reply_cdc #(.WIDTH(449)) u_response_cdc (
  .s_clk(sys_clk),.s_rst_n(eth_sys_reset_n),.s_data(tx_message),.s_valid(tx_request && eth_sys_reset_n),.s_ready(tx_ready_cdc),
  .d_clk(clk125),.d_rst_n(eth_tx_reset_n),.d_data(tx_message_eth),.d_valid(tx_request_eth),.d_ready(tx_ready_eth)
 );
 // B receives A previews and returns control/recognition replies only.
 // Retain the proven response serializer and completion handshake; tie its
 // unused video input inactive so synthesis removes every image-TX datapath.
 assign vision_objects=0;assign vision_count=0;assign vision_overflow=0;
 assign vision_valid=0;assign vision_source_id=0;assign vision_config_epoch=0;
 assign cascade_read_command=0;assign cascade_read_valid=0;
 ethernet_shared_tx #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),
  .PEER_MAC(PEER_MAC),.PEER_IP(PEER_IP),.WIDTH(CASCADE_WIDTH),.HEIGHT(CASCADE_HEIGHT)) u_tx(
  .clk(clk125),.rst_n(eth_tx_reset_n),
  .control_message(tx_message_eth),.control_valid(tx_request_eth),.control_ready(tx_ready_eth),
  .video_message(104'd0),.video_valid(1'b0),.video_ready(),.ram_addr(),.ram_data(8'd0),
  .tx_data(tx_data),.tx_valid(tx_valid));
endmodule
