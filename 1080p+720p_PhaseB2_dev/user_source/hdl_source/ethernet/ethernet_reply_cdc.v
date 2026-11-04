`timescale 1ns/1ps
// Response-only bundled-data handshake. The producer already owns a stable
// response descriptor; the transmitter captures it on d_valid && d_ready.
// Unlike the general UART mailbox, do not create two more full bus copies.
// REQUIREMENT: s_data must remain unchanged until s_ready returns after a
// request. Both resets must share the same asynchronous assertion cause;
// destination-clock-synchronized release may differ (as in bridge).
// No independently synchronized bus bits, no combinational request crossing.
module ethernet_reply_cdc # (parameter WIDTH=449) (
 input wire s_clk,s_rst_n,input wire [WIDTH-1:0] s_data,input wire s_valid,
 output wire s_ready,input wire d_clk,d_rst_n,
 output wire [WIDTH-1:0] d_data,output wire d_valid,input wire d_ready
);
 reg req,ack;
 (* ASYNC_REG="TRUE" *) reg a1,a2,r1,r2;
 assign s_ready=req==a2;
 assign d_valid=r2!=ack;
 assign d_data=s_data;
 always @(posedge s_clk or negedge s_rst_n)
  if(!s_rst_n) begin req<=0;a1<=0;a2<=0;end
  else begin
   a1<=ack;a2<=a1;
   if(s_valid && s_ready) req<=~req;
  end
 always @(posedge d_clk or negedge d_rst_n)
  if(!d_rst_n) begin ack<=0;r1<=0;r2<=0;end
  else begin
   r1<=req;r2<=r1;
   if(d_valid && d_ready) ack<=r2;
  end
endmodule
