`timescale 1ns/1ps
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
