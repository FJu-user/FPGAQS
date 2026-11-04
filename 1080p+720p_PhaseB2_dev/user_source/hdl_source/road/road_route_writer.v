`timescale 1ns/1ps
// Build the inactive mask at 100 MHz. Reuse a bank only after real pixel
// capture has returned through the acknowledged two-bit mailbox.
module road_route_writer(
 input wire clk,rst_n,enable,valid,input wire [255:0] route,
 input wire [31:0] source_id,input wire taken_pulse,taken_available,taken_tag,
 output wire [15:0] metadata,output reg available,output reg tag,
 output reg we,output reg [12:0] wa,output reg [1:0] wd);
 wire [239:0] logical_route;
 genvar ri;
 generate for(ri=0;ri<4;ri=ri+1)begin:g_route_unpack
  wire [63:0] p=route[ri*64+:64];
  assign logical_route[ri*60+:60]={p[63:57],p[55:45],p[43:33],p[31:21],p[19:0]};
 end endgenerate
 function [11:0] addr;input [6:0] px;input [5:0] py;
 begin addr=({6'd0,py}<<6)+({6'd0,py}<<4)+{5'd0,px};end endfunction
 reg complete_bank,work_bank,acked,seen;
 reg [31:0] last_id,build_id;
 reg [1:0] status,build_status,dir;
 reg [2:0] state;reg [11:0] index;
 reg [6:0] px;reg [5:0] py,length;reg [4:0] run_index;reg corner;
 wire [7:0] run_byte=logical_route[32+{run_index,3'b000}+:8];
 assign metadata={3'd0,available,tag,complete_bank,status,8'he1};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   complete_bank<=0;work_bank<=1;acked<=1;seen<=0;last_id<=0;build_id<=0;
   status<=0;build_status<=0;dir<=0;state<=0;index<=0;
   px<=0;py<=0;length<=0;run_index<=0;corner<=0;available<=0;tag<=0;
   we<=0;wa<=0;wd<=0;
  end else begin
   we<=0;
   if(taken_pulse && taken_available && taken_tag==tag)acked<=1;
   case(state)
    0:if(enable && valid && acked && (!seen || source_id!=last_id))begin
     build_id<=source_id;work_bank<=~complete_bank;index<=0;state<=1;corner<=0;
     build_status<=logical_route[7:0]!=8'hd4 ? 2'd3:
      ((logical_route[9:8]==1 && (logical_route[14:10]==0 || logical_route[14:10]>26 || logical_route[21:15]>=80 || logical_route[27:22]>=45))?2'd3:logical_route[9:8]);
     px<=logical_route[21:15];py<=logical_route[27:22];run_index<=logical_route[14:10]-1'b1;
    end
    1:begin
     we<=1;wa<={work_bank,index};wd<=0;
     if(index==4095)begin
      if(build_status==1 && run_index<26 && px<80 && py<45)state<=2;
      else state<=5;
     end else index<=index+1'b1;
    end
    2:begin dir<=run_byte[7:6];length<=run_byte[5:0];state<=3;end
    3:if(length==0 || px>=80 || py>=45)begin build_status<=3;state<=5;end
      else begin
       we<=1;wa<={work_bank,addr(px,py)};wd<=corner?2'b11:(dir[1]?2'b10:2'b01);
       corner<=0;length<=length-1'b1;
       case(dir)0:px<=px-1'b1;1:px<=px+1'b1;2:py<=py-1'b1;3:py<=py+1'b1;endcase
       if(length==1)state<=4;
      end
    4:if(px>=80 || py>=45)begin build_status<=3;state<=5;end
      else begin
       we<=1;wa<={work_bank,addr(px,py)};wd<=dir[1]?2'b10:2'b01;
       if(run_index==0)state<=5;
       else begin run_index<=run_index-1'b1;corner<=1;state<=2;end
      end
    5:begin
     complete_bank<=work_bank;status<=build_status;available<=1;tag<=~tag;
     last_id<=build_id;seen<=1;acked<=0;state<=0;
    end
    default:state<=0;
   endcase
   // Invalid context aborts only the free bank. Keep ownership across mode
   // and clock changes until a real capture returns the pending bank tag.
   if(!enable || !valid)begin state<=0;we<=0;seen<=0;end
   else if(state!=0 && source_id!=build_id)begin state<=0;we<=0;end
  end
 end
endmodule
