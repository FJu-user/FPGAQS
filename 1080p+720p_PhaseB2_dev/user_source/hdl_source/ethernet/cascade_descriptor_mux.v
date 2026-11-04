`timescale 1ns/1ps
// Ready is a completion handshake, not FIFO space. Reserve one producer
// BEFORE it asserts its request and retain ownership until CDC completion.
module cascade_descriptor_mux(
 input wire clk,rst_n,query_wants,input wire [103:0] query_data,video_data,
 input wire query_valid,video_valid,output wire query_ready,video_ready,
 output wire [103:0] data,output wire valid,input wire ready);
 reg owner,qp,vp,seen_busy;reg [1:0] state;
 reg [103:0] qhold,vhold;
 assign query_ready=!qp;
 assign video_ready=!vp;
 assign data=owner?qhold:vhold;
 assign valid=state==1 && ready;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin owner<=0;qp<=0;vp<=0;seen_busy<=0;state<=0;qhold<=0;vhold<=0;end
  else begin
   if(query_valid && query_ready)begin qhold<=query_data;qp<=1;end
   if(video_valid && video_ready)begin vhold<=video_data;vp<=1;end
   case(state)
    0:if(qp || vp)begin owner<=qp;state<=1;end
    1:if(ready)begin state<=2;seen_busy<=0;end
    2:begin
     if(!ready)seen_busy<=1;
     if(seen_busy && ready)begin if(owner)qp<=0;else vp<=0;state<=0;end
    end
    default:state<=0;
   endcase
  end
 end
endmodule
