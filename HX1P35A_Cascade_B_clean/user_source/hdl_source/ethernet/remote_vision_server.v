`timescale 1ns/1ps
// Freeze all four objects at query slot zero. Later slots must name the same
// request group and control epoch; a lost/mixed bank is never presented as OK.
module remote_vision_server #(parameter CLOCK_HZ=100000000)(
 input wire clk,rst_n,request,input wire [31:0] request_epoch,request_sequence,
 input wire [4:0] request_mode,input wire request_native,request_mode1080,
 input wire [255:0] coordinate_bcd,
 input wire [255:0] objects,input wire [3:0] count,input wire overflow,valid,
 input wire [31:0] source_id,result_epoch,
 output reg [191:0] reply,output reg [4:0] remote_mode,output reg [31:0] remote_epoch,output wire active);
 reg [255:0] coordinate_bank;
 reg [255:0] bank;reg [31:0] bank_id,bank_epoch,bank_group;reg [3:0] bank_count;
 reg bank_overflow,bank_valid,bank_native,bank_resolution;
 reg [31:0] watchdog;
 assign active=(remote_mode==17 || remote_mode==18) && watchdog<CLOCK_HZ*2;
  function [63:0] display_record;
  input [63:0] o;input res;
  reg [11:0] x0,y0,x1,y1,mx0,my0,mx1,my1;reg ok;
  begin
   x0=o[56:45];y0=o[44:33];x1=o[32:21];y1=o[20:9];
   ok=o[63] && x0<=x1 && y0<=y1 && x1<1280 && y1<720;
   mx0=res?x0+(x0>>1):x0;my0=res?y0+(y0>>1):y0;
   mx1=res?x1+(x1>>1)+{11'd0,x1[0]}:x1;
   my1=res?y1+(y1>>1)+{11'd0,y1[0]}:y1;
   display_record={ok,o[62:57],mx0,my0,mx1,my1,o[8:0]};
  end
 endfunction
 wire new_mode=request_epoch!=remote_epoch || request_mode!=remote_mode;
 wire [63:0] selected=request_sequence[1:0]==0?objects[63:0]:bank[request_sequence[1:0]*64+:64];
 wire selected_native=request_sequence[1:0]==0?request_native:bank_native;
 wire selected_resolution=request_sequence[1:0]==0?request_mode1080:bank_resolution;
 wire [63:0] response_object=(selected_native && request_mode!=18)?display_record(selected,selected_resolution):selected;
 wire good=valid && result_epoch==request_epoch && !new_mode;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin bank_native<=0;bank_resolution<=0;coordinate_bank<=0;bank<=0;bank_id<=0;bank_epoch<=0;bank_group<=0;bank_count<=0;bank_overflow<=0;bank_valid<=0;
   reply<=0;remote_mode<=0;remote_epoch<=0;watchdog<=CLOCK_HZ*2;end
  else begin
   if(watchdog<CLOCK_HZ*2)watchdog<=watchdog+1'b1;
   if(request)begin
   watchdog<=0;
   remote_mode<=request_mode;remote_epoch<=request_epoch;
   if(request_sequence[1:0]==0)begin
    bank_native<=request_native;bank_resolution<=request_mode1080;coordinate_bank<=coordinate_bcd;bank<=objects;bank_id<=source_id;bank_epoch<=request_epoch;bank_group<=request_sequence>>2;
    bank_count<=count;bank_overflow<=overflow;bank_valid<=good;
    reply<={16'hc031,coordinate_bcd[63:0],response_object,source_id,3'd0,overflow,count,(good?8'd0:8'd7)};
   end else begin
    reply<={16'hc031,coordinate_bank[request_sequence[1:0]*64+:64],response_object,bank_id,3'd0,bank_overflow,bank_count,
     ((bank_valid && bank_native==request_native && bank_resolution==request_mode1080 && bank_epoch==request_epoch && bank_group==(request_sequence>>2) && !new_mode)?8'd0:8'd7)};
   end
   end
  end
 end
endmodule
