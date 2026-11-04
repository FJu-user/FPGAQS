`timescale 1ns/1ps
// Freeze all four objects at query slot zero. Later slots must name the same
// request group and control epoch; a lost/mixed bank is never presented as OK.
module remote_vision_server #(parameter CLOCK_HZ=100000000)(
 input wire clk,rst_n,request,input wire [31:0] request_epoch,request_sequence,
 input wire [4:0] request_mode,
 input wire [255:0] objects,input wire [3:0] count,input wire overflow,valid,
 input wire [31:0] source_id,result_epoch,
 output reg [191:0] reply,output reg [4:0] remote_mode,output reg [31:0] remote_epoch,output wire active);
 reg [255:0] bank;reg [31:0] bank_id,bank_epoch,bank_group;reg [3:0] bank_count;
 reg bank_overflow,bank_valid;
 reg [31:0] watchdog;
 assign active=remote_mode==17 && watchdog<CLOCK_HZ*2;
 wire new_mode=request_epoch!=remote_epoch || request_mode!=remote_mode;
 wire good=valid && result_epoch==request_epoch && !new_mode;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin bank<=0;bank_id<=0;bank_epoch<=0;bank_group<=0;bank_count<=0;bank_overflow<=0;bank_valid<=0;
   reply<=0;remote_mode<=0;remote_epoch<=0;watchdog<=CLOCK_HZ*2;end
  else begin
   if(watchdog<CLOCK_HZ*2)watchdog<=watchdog+1'b1;
   if(request)begin
   watchdog<=0;
   remote_mode<=request_mode;remote_epoch<=request_epoch;
   if(request_sequence[1:0]==0)begin
    bank<=objects;bank_id<=source_id;bank_epoch<=request_epoch;bank_group<=request_sequence>>2;
    bank_count<=count;bank_overflow<=overflow;bank_valid<=good;
    reply<={80'd0,objects[63:0],source_id,3'd0,overflow,count,(good?8'd0:8'd7)};
   end else begin
    reply<={80'd0,bank[request_sequence[1:0]*64+:64],bank_id,3'd0,bank_overflow,bank_count,
     ((bank_valid && bank_epoch==request_epoch && bank_group==(request_sequence>>2) && !new_mode)?8'd0:8'd7)};
   end
   end
  end
 end
endmodule
