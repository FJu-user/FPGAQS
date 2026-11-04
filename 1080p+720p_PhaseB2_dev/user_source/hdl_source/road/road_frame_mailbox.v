`timescale 1ns/1ps
module road_frame_mailbox #(parameter WIDTH=391)(
 input wire s_clk,s_rst_n,input wire [WIDTH-1:0] s_data,
 input wire d_clk,d_rst_n,frame_prepare,frame_capture,
 output reg [WIDTH-1:0] d_data,output reg d_valid,
 input wire route_available,route_tag,
 output wire taken_pulse,taken_available,taken_tag);
 reg [WIDTH-1:0] held;
 reg req,ack;
 reg [1:0] demand,prepared,held_tag;
 (* ASYNC_REG="TRUE" *)reg [1:0] demand_meta,demand_sync;
 (* ASYNC_REG="TRUE" *)reg a1,a2,r1,r2;
 wire fresh=(demand_sync!=prepared);
 wire ready=(req==a2);
 wire pending=(r2!=ack);
 wire matching=(held_tag==demand);
 // Only the control state needs reset; invalid payload is masked by the caller.
 always @(posedge s_clk or negedge s_rst_n)
  if(!s_rst_n)begin demand_meta<=0;demand_sync<=0;prepared<=0;req<=0;a1<=0;a2<=0;end
  else begin
   demand_meta<=demand;demand_sync<=demand_meta;a1<=ack;a2<=a1;
   if(fresh && ready)begin prepared<=demand_sync;req<=~req;end
  end
 always @(posedge s_clk)if(s_rst_n && fresh && ready)begin held<=s_data;held_tag<=demand_sync;end
 always @(posedge d_clk or negedge d_rst_n)
  if(!d_rst_n)begin demand<=0;ack<=0;r1<=0;r2<=0;d_valid<=0;end
  else begin
   r1<=req;r2<=r1;d_valid<=0;
   if(frame_prepare)begin
    case(demand)2'b00:demand<=2'b01;2'b01:demand<=2'b11;2'b11:demand<=2'b10;2'b10:demand<=2'b00;endcase
   end
   if(pending)begin
    if(frame_prepare || !matching)ack<=r2;
    else if(frame_capture)begin ack<=r2;d_valid<=1;end
   end
  end
 always @(posedge d_clk)
  if(d_rst_n && frame_capture && !frame_prepare && pending && matching)d_data<=held;

 // The original frame mailbox data/control behavior is unchanged. The small
 // return mailbox acknowledges actual capture, one pixel clock after SOF.
 reg [1:0] held_sideband,notice_data;reg notice;
 always @(posedge s_clk)if(s_rst_n && fresh && ready)
  held_sideband<={route_available,route_tag};
 always @(posedge d_clk or negedge d_rst_n)
  if(!d_rst_n)begin notice<=0;notice_data<=0;end
  else begin
   notice<=0;
   if(frame_capture && !frame_prepare && pending && matching)begin
    notice<=1;notice_data<=held_sideband;
   end
  end
 uart_mailbox #(.WIDTH(2)) consumed(
  .s_clk(d_clk),.s_rst_n(d_rst_n),.s_data(notice_data),.s_valid(notice),.s_ready(),
  .d_clk(s_clk),.d_rst_n(s_rst_n),.d_data({taken_available,taken_tag}),.d_valid(taken_pulse),.d_ready(1'b1));
endmodule
