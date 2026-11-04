`timescale 1ns/1ps
// Two RLE producers, each emits at most once per three pixels. Two queued
// records cover simultaneous emissions without duplicating the CCL datapath.
module candidate_run_queue #(parameter W=53)(
input wire clk,rst_n,clear,input wire a_valid,b_valid,input wire[W-1:0] a,b,
input wire a_done,b_done,output wire valid,output wire[W-1:0] data,
output wire done,output reg overflow, output wire drop_event
);
reg[W-1:0] q0,q1,n0,n1;reg[1:0] used,next_used;
reg seen_a,seen_b,reported;reg excess;
assign valid=used!=0;assign data=q0;
assign drop_event=excess;
assign done=seen_a&&seen_b&&!reported&&used==0&&!a_valid&&!b_valid;
always @* begin
n0=q1;n1=0;next_used=(used==0)?0:used-1'b1;excess=0;
if(a_valid)begin
if(next_used==0)n0=a;else if(next_used==1)n1=a;else excess=1;
if(next_used<2)next_used=next_used+1'b1;
end
if(b_valid)begin
if(next_used==0)n0=b;else if(next_used==1)n1=b;else excess=1;
if(next_used<2)next_used=next_used+1'b1;
end
end
always @(posedge clk or negedge rst_n)begin
if(!rst_n)begin q0<=0;q1<=0;used<=0;seen_a<=0;seen_b<=0;reported<=0;overflow<=0;end
else if(clear)begin used<=0;seen_a<=0;seen_b<=0;reported<=0;overflow<=0;end
else begin
q0<=n0;q1<=n1;used<=next_used;
if(a_done)seen_a<=1;if(b_done)seen_b<=1;if(done)reported<=1;
if(excess)overflow<=1;
end
end
endmodule
