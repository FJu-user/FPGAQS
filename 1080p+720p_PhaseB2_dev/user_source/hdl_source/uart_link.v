`timescale 1ns/1ps
// 8N1, clock enables only. Divider changes only after an acknowledged command.
module uart_link (
 input wire clk, rst_n, rx, input wire [15:0] divider,
 output reg [7:0] rx_data, output reg rx_valid, rx_error,
 input wire [7:0] tx_data, input wire tx_valid,
 output wire tx_ready, output reg tx
);
 (* ASYNC_REG="TRUE" *) reg rx1,rx2;
 reg [1:0] rs; reg [15:0] rc,tc; reg [2:0] rb;
 reg [7:0] rshift; reg [9:0] tshift; reg [3:0] tb;
 assign tx_ready=(tb==0);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   rx1<=1;rx2<=1;rs<=0;rc<=0;rb<=0;rshift<=0;rx_data<=0;rx_valid<=0;rx_error<=0;
   tx<=1;tc<=0;tb<=0;tshift<=10'h3ff;
  end else begin
   rx1<=rx;rx2<=rx1;rx_valid<=0;rx_error<=0;
   case(rs)
    0: if(!rx2) begin rc<=(divider>>1)-1;rs<=1;end
    1: if(rc!=0) rc<=rc-1; else if(!rx2) begin rc<=divider-1;rb<=0;rs<=2;end else rs<=0;
    2: if(rc!=0) rc<=rc-1; else begin
     rshift[rb]<=rx2;rc<=divider-1;if(rb==7) rs<=3;else rb<=rb+1;
    end
    3: if(rc!=0) rc<=rc-1; else begin
     if(rx2) begin rx_valid<=1;rx_data<=rshift;end else rx_error<=1;
     rs<=0;
    end
   endcase
   if(tb==0) begin
    tx<=1;
    if(tx_valid) begin tshift<={1'b1,tx_data,1'b0};tx<=0;tb<=10;tc<=divider-1;end
   end else if(tc!=0) tc<=tc-1;
   else begin
    tc<=divider-1;tb<=tb-1;tshift<={1'b1,tshift[9:1]};tx<=tshift[1];
   end
  end
 end
endmodule

// One outstanding bundled-data mailbox. Both ends use the same global reset;
// independent video resets must be carried as payload events, not reset tokens.
module uart_mailbox #(parameter WIDTH=154)(
 input wire s_clk,s_rst_n,input wire [WIDTH-1:0] s_data,input wire s_valid,
 output wire s_ready,input wire d_clk,d_rst_n,
 output reg [WIDTH-1:0] d_data,output reg d_valid,input wire d_ready
);
 reg [WIDTH-1:0] held; reg req,ack;
 (* ASYNC_REG="TRUE" *) reg a1,a2,r1,r2;
 assign s_ready=(req==a2);
 always @(posedge s_clk or negedge s_rst_n) begin
  if(!s_rst_n) begin held<=0;req<=0;a1<=0;a2<=0;end
  else begin
   a1<=ack;a2<=a1;
   if(s_valid && s_ready) begin held<=s_data;req<=~req;end
  end
 end
 always @(posedge d_clk or negedge d_rst_n) begin
  if(!d_rst_n) begin ack<=0;r1<=0;r2<=0;d_data<=0;d_valid<=0;end
  else begin
   r1<=req;r2<=r1;
   if(!d_valid && r2!=ack) begin d_data<=held;d_valid<=1;end
   else if(d_valid && d_ready) begin d_valid<=0;ack<=r2;end
  end
 end
endmodule

// Fresh frame result mailbox. Raw SOF requests a new system snapshot;
// the existing nineteen-clock lead allows its synchronized arrival before
// OSD SOF. Abandoned frame requests are discarded, never rendered.
module uart_frame_mailbox #(parameter WIDTH=391)(
 input wire s_clk,s_rst_n,input wire [WIDTH-1:0] s_data,
 input wire d_clk,d_rst_n,frame_prepare,frame_capture,
 output reg [WIDTH-1:0] d_data,output reg d_valid);
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
endmodule
