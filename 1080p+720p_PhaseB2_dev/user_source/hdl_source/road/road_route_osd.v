`timescale 1ns/1ps
// Serial rasterizer; one ERAM contains two 80x45 route masks. No video stall.
// Output ink and RGB have exactly the existing three-cycle OSD latency.
module road_route_osd(
 input wire clk,rst_n,enable,clear,show,mode1080,de,fs,
 input wire [11:0] x,y,input wire [255:0] route,input wire valid,
 output reg ink,output reg [23:0] color,
 input wire [1:0] mask_q,output wire [12:0] mask_ra);

 function [11:0] addr;input [6:0] px;input [5:0] py;
 begin addr=({6'd0,py}<<6)+({6'd0,py}<<4)+{5'd0,px};end endfunction
 reg [4:0] xp,yp;reg [6:0] gx;reg [5:0] gy;
 wire [4:0] last=mode1080?5'd23:5'd15;
 wire [4:0] center=mode1080?5'd12:5'd8;
 wire [6:0] read_x=fs?7'd0:gx;wire [5:0] read_y=fs?6'd0:gy;
 reg display_bank,display_valid;reg [1:0] display_status;
 wire complete=enable && valid && route[7:0]==8'he1 && route[12] && !clear;
 wire visible_bank=(fs && complete)?route[10]:display_bank;
 wire visible_valid=fs?(complete && route[9:8]==1):display_valid;
 wire [1:0] visible_status=fs?(complete?route[9:8]:2'd0):display_status;
 assign mask_ra={visible_bank,addr(read_x,read_y)};
 reg [1:0] mask_center_s1;reg active_s1,indicator_s1;
 reg [1:0] status_s1,status_s2;reg ink_s2,indicator_s2;
 wire horizontal=((fs?5'd0:yp)+1'b1>=center && (fs?5'd0:yp)<=center+1'b1);
 wire vertical=((fs?5'd0:xp)+1'b1>=center && (fs?5'd0:xp)<=center+1'b1);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   xp<=0;yp<=0;gx<=0;gy<=0;display_bank<=0;display_valid<=0;display_status<=0;
   mask_center_s1<=0;active_s1<=0;indicator_s1<=0;status_s1<=0;status_s2<=0;
   ink_s2<=0;indicator_s2<=0;ink<=0;color<=0;
  end else begin
   if(de)begin
    if(fs)begin xp<=1;yp<=0;gx<=0;gy<=0;end
    else if(x==(mode1080?1919:1279))begin
     xp<=0;gx<=0;
     if(yp==last)begin yp<=0;gy<=gy+1'b1;end else yp<=yp+1'b1;
    end else if(xp==last)begin xp<=0;gx<=gx+1'b1;end else xp<=xp+1'b1;
   end
   mask_center_s1<={vertical,horizontal};
   active_s1<=enable && show && de && visible_valid && read_x<80 && read_y<45;
   indicator_s1<=enable && show && de && x>=16 && x<28 && y>=44 && y<56;
   status_s1<=visible_status;
   ink_s2<=(active_s1 && |(mask_q & mask_center_s1)) || indicator_s1;
   indicator_s2<=indicator_s1;status_s2<=status_s1;
   ink<=ink_s2;
   color<=!indicator_s2?24'hffe000:status_s2==1?24'h00e060:
     status_s2==2?24'hff3030:status_s2==3?24'hdf40df:24'hffb020;
   if(fs)begin
    if(complete)display_bank<=route[10];
    display_status<=visible_status;display_valid<=visible_valid;
   end
   if(!enable || clear)begin display_valid<=0;display_status<=0;end
  end
 end
endmodule
