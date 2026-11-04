`timescale 1ns/1ps
// Fixed 24-byte response body, little-endian packed in payload[7:0] first.
module uart_packet_tx(
 input wire clk,rst_n,input wire start,input wire [7:0] command,
 input wire [31:0] session,packet_sequence,input wire [191:0] payload,
 output wire ready,output reg [7:0] byte_data,output reg byte_valid,input wire byte_ready
);
 reg [7:0] header[0:15];reg [191:0] body;reg [6:0] index;
 reg [31:0] crc,tail;reg [15:0] hcrc;reg [3:0] state;reg [7:0] value;
 function [31:0] crc32_next;
 input [31:0] c;input [7:0] d;integer i;reg [31:0] v;
 begin v=c^{24'd0,d};for(i=0;i<8;i=i+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32_next=v;end
 endfunction
 function [15:0] crc16_next;
 input [15:0] c;input [7:0] d;integer i;reg [15:0] v;
 begin v=c^{d,8'd0};for(i=0;i<8;i=i+1) v=v[15]?(v<<1)^16'h1021:v<<1;crc16_next=v;end
 endfunction
 // Fixed byte positions; the FSM only requests indices 0..43.
 reg [7:0] selected_byte;
 always @*begin
  selected_byte=0;
  case(index)
   7'd0:selected_byte=header[0];
   7'd1:selected_byte=header[1];
   7'd2:selected_byte=header[2];
   7'd3:selected_byte=header[3];
   7'd4:selected_byte=header[4];
   7'd5:selected_byte=header[5];
   7'd6:selected_byte=header[6];
   7'd7:selected_byte=header[7];
   7'd8:selected_byte=header[8];
   7'd9:selected_byte=header[9];
   7'd10:selected_byte=header[10];
   7'd11:selected_byte=header[11];
   7'd12:selected_byte=header[12];
   7'd13:selected_byte=header[13];
   7'd14:selected_byte=header[14];
   7'd15:selected_byte=header[15];
   7'd16:selected_byte=body[0+:8];
   7'd17:selected_byte=body[8+:8];
   7'd18:selected_byte=body[16+:8];
   7'd19:selected_byte=body[24+:8];
   7'd20:selected_byte=body[32+:8];
   7'd21:selected_byte=body[40+:8];
   7'd22:selected_byte=body[48+:8];
   7'd23:selected_byte=body[56+:8];
   7'd24:selected_byte=body[64+:8];
   7'd25:selected_byte=body[72+:8];
   7'd26:selected_byte=body[80+:8];
   7'd27:selected_byte=body[88+:8];
   7'd28:selected_byte=body[96+:8];
   7'd29:selected_byte=body[104+:8];
   7'd30:selected_byte=body[112+:8];
   7'd31:selected_byte=body[120+:8];
   7'd32:selected_byte=body[128+:8];
   7'd33:selected_byte=body[136+:8];
   7'd34:selected_byte=body[144+:8];
   7'd35:selected_byte=body[152+:8];
   7'd36:selected_byte=body[160+:8];
   7'd37:selected_byte=body[168+:8];
   7'd38:selected_byte=body[176+:8];
   7'd39:selected_byte=body[184+:8];
   7'd40:selected_byte=tail[0+:8];
   7'd41:selected_byte=tail[8+:8];
   7'd42:selected_byte=tail[16+:8];
   7'd43:selected_byte=tail[24+:8];
   default:selected_byte=0;
  endcase
 end
 assign ready=(state==0);
 // Byte-valid stays asserted until accepted; a gap allows the physical UART
 // to lower byte_ready before the next escaped byte is offered.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=0;index<=0;crc<=0;tail<=0;hcrc<=0;body<=0;value<=0;byte_valid<=0;byte_data<=0;end
  else case(state)
   0: if(start) begin
    header[0]<=1;header[1]<=command|8'h80;header[2]<=0;header[3]<=0;
    header[4]<=session[7:0];header[5]<=session[15:8];header[6]<=session[23:16];header[7]<=session[31:24];
    header[8]<=packet_sequence[7:0];header[9]<=packet_sequence[15:8];header[10]<=packet_sequence[23:16];header[11]<=packet_sequence[31:24];
    header[12]<=24;header[13]<=0;body<=payload;hcrc<=16'hffff;index<=0;state<=1;
   end
   1: begin hcrc<=crc16_next(hcrc,selected_byte);if(index==13) state<=2;else index<=index+1;end
   2: begin header[14]<=hcrc[7:0];header[15]<=hcrc[15:8];index<=0;crc<=32'hffffffff;state<=3;end
   3: begin byte_data<=8'h7e;byte_valid<=1;state<=4;end
   4: if(byte_ready && byte_valid) begin byte_valid<=0;state<=5;end
   5: begin
    value<=selected_byte;
    state<=6;
   end
   6: begin
    if(index<40) begin crc<=crc32_next(crc,value);if(index==39) tail<=~crc32_next(crc,value);end
    byte_data<=(value==8'h7e || value==8'h7d)?8'h7d:value;byte_valid<=1;state<=7;
   end
   7: if(byte_ready && byte_valid) begin
    byte_valid<=0;if(value==8'h7e || value==8'h7d) state<=8;else state<=10;
   end
   8: begin byte_data<=value^8'h20;byte_valid<=1;state<=9;end
   9: if(byte_ready && byte_valid) begin byte_valid<=0;state<=10;end
   10: if(index==43) state<=11;else begin index<=index+1;state<=5;end
   11: begin byte_data<=8'h7e;byte_valid<=1;state<=12;end
   12: if(byte_ready && byte_valid) begin byte_valid<=0;state<=13;end
   13: if(byte_ready) state<=0;
   default: state<=0;
  endcase
 end
endmodule
