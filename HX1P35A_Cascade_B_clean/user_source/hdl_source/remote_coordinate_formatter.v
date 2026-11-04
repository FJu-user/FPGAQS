`timescale 1ns/1ps
// System-clock B-only formatter. Recognition pixels and algorithms are untouched.
// Each object carries {1080p X/Y BCD,720p X/Y BCD}; no divider or frame RAM.
module remote_coordinate_formatter(
 input wire clk,rst_n,input wire [325:0] raw,
 output wire [325:0] result,output reg [255:0] coordinate_bcd);
 reg [325:0] snapshot;
 reg complete;reg [1:0] state;reg [3:0] item,bit_count;
 reg [11:0] binary_value;reg [15:0] bcd;
 reg [15:0] corrected;integer n;
 wire same=raw==snapshot && raw[261];
 assign result={snapshot[325:262],complete && same,snapshot[260:0]};
 reg [63:0] obj;reg [11:0] lo,hi,mlo,mhi;reg [12:0] sum;
 always @*begin
  obj=snapshot[item[3:2]*64+:64];
  lo=item[0]?obj[44:33]:obj[56:45];
  hi=item[0]?obj[20:9]:obj[32:21];
  mlo=item[1]?lo+(lo>>1):lo;
  mhi=item[1]?hi+(hi>>1)+{11'd0,hi[0]}:hi;
  sum={1'b0,mlo}+{1'b0,mhi};
  corrected=bcd;
  for(n=0;n<4;n=n+1)
   if(bcd[n*4+:4]>=5)corrected[n*4+:4]=bcd[n*4+:4]+4'd3;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin snapshot<=0;complete<=0;state<=0;item<=0;bit_count<=0;binary_value<=0;bcd<=0;coordinate_bcd<=0;end
  else begin
   case(state)
    0:if(raw[261] && (!complete || !same))begin snapshot<=raw;complete<=0;item<=0;state<=1;end
    1:begin binary_value<=sum[12:1];bcd<=0;bit_count<=0;state<=2;end
    2:begin
     bcd<={corrected[14:0],binary_value[11]};binary_value<={binary_value[10:0],1'b0};
     if(bit_count==11)state<=3;else bit_count<=bit_count+1'b1;
    end
    3:begin
     // X precedes Y in each 32-bit decimal pair.
     coordinate_bcd[item[3:2]*64+item[1]*32+(item[0]?0:16)+:16]<=bcd;
     if(item==15)begin complete<=1;state<=0;end
     else begin item<=item+1'b1;state<=1;end
    end
   endcase
  end
 end
endmodule
