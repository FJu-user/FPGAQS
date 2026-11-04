`timescale 1ns/1ps
// Frame-domain age. The count is accepted post-ISP capture boundaries, not ms.
// Latch at HDMI's first actual DE pixel; publish only after its complete EOF.
module frame_latency #(parameter ID_WIDTH=32)(input wire clk,rst_n,input wire [31:0] capture_gray,
 input wire first,last,de,vsync,underflow,local_source,
 input wire [40:0] identity,input wire [1:0] stream_bank,descriptor_bank,
 output reg [8:0] token);
 (* ASYNC_REG="TRUE" *)reg [31:0] gray_meta,gray_sync;
 reg [31:0] first_gray,first_id,decoded,difference;
 reg [2:0] work;reg active,bad,sticky_underflow;
 reg [3:0] tens;reg [6:0] ones;
 reg [1:0] bank;wire [15:0] short_difference=decoded[15:0]-first_id[15:0];
 function [31:0] binary;input [31:0] g;integer k;begin
  binary[31]=g[31];for(k=30;k>=0;k=k-1)binary[k]=binary[k+1]^g[k];
 end endfunction
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin gray_meta<=0;gray_sync<=0;end
  else begin gray_meta<=capture_gray;gray_sync<=gray_meta;end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin first_gray<=0;first_id<=0;decoded<=0;difference<=0;work<=0;
   active<=0;bad<=0;sticky_underflow<=0;tens<=0;ones<=0;bank<=0;token<=0;end
  else begin
   if(vsync)begin sticky_underflow<=0;if(active)begin active<=0;token<=0;end end
   else if(underflow)sticky_underflow<=1;
   if(active && (underflow || !local_source || identity[31:0]!=first_id || descriptor_bank!=bank))bad<=1;
   case(work)
    1:begin decoded<=binary(first_gray);work<=2;end
    2:begin difference<=ID_WIDTH==16?{16'd0,short_difference}:decoded-first_id;work<=3;end
    3:begin
     if(difference>99)begin bad<=1;ones<=0;work<=0;end
     else begin ones<=difference[6:0];tens<=0;work<=4;end
    end
    4:if(ones>=10)begin ones<=ones-7'd10;tens<=tens+1'b1;end else work<=0;
    default:work<=0;
   endcase
   if(last&&de&&active)begin
    active<=0;
    token<=(!bad&&!underflow&&local_source&&identity[40]&&identity[31:0]==first_id&&
      stream_bank==bank&&descriptor_bank==bank&&work==0)?{1'b1,tens,ones[3:0]}:9'd0;
   end
   if(first&&de)begin
    first_gray<=gray_sync;first_id<=identity[31:0];bank<=descriptor_bank;
    active<=1;bad<=!local_source||!identity[40]||stream_bank!=descriptor_bank||sticky_underflow||underflow;
    work<=1;
   end
  end
endmodule

module frame_latency_paint #(parameter TIME_OSD=0)(input wire clk,rst_n,input wire [25:0] token,
 input wire [11:0] x,y,input wire de,output wire ink);
function [4:0] row_bits;input [7:0] ch;input [2:0] row;begin case(ch)
8'd48:case(row) 0:row_bits=5'b01110;1:row_bits=5'b10001;2:row_bits=5'b10011;3:row_bits=5'b10101;4:row_bits=5'b11001;5:row_bits=5'b10001;6:row_bits=5'b01110;default:row_bits=0;endcase
8'd49:case(row) 0:row_bits=5'b00100;1:row_bits=5'b01100;2:row_bits=5'b00100;3:row_bits=5'b00100;4:row_bits=5'b00100;5:row_bits=5'b00100;6:row_bits=5'b01110;default:row_bits=0;endcase
8'd50:case(row) 0:row_bits=5'b01110;1:row_bits=5'b10001;2:row_bits=5'b00001;3:row_bits=5'b00110;4:row_bits=5'b01000;5:row_bits=5'b10000;6:row_bits=5'b11111;default:row_bits=0;endcase
8'd51:case(row) 0:row_bits=5'b11110;1:row_bits=5'b00001;2:row_bits=5'b00001;3:row_bits=5'b01110;4:row_bits=5'b00001;5:row_bits=5'b00001;6:row_bits=5'b11110;default:row_bits=0;endcase
8'd52:case(row) 0:row_bits=5'b00010;1:row_bits=5'b00110;2:row_bits=5'b01010;3:row_bits=5'b10010;4:row_bits=5'b11111;5:row_bits=5'b00010;6:row_bits=5'b00010;default:row_bits=0;endcase
8'd53:case(row) 0:row_bits=5'b11111;1:row_bits=5'b10000;2:row_bits=5'b10000;3:row_bits=5'b11110;4:row_bits=5'b00001;5:row_bits=5'b00001;6:row_bits=5'b11110;default:row_bits=0;endcase
8'd54:case(row) 0:row_bits=5'b00110;1:row_bits=5'b01000;2:row_bits=5'b10000;3:row_bits=5'b11110;4:row_bits=5'b10001;5:row_bits=5'b10001;6:row_bits=5'b01110;default:row_bits=0;endcase
8'd55:case(row) 0:row_bits=5'b11111;1:row_bits=5'b00001;2:row_bits=5'b00010;3:row_bits=5'b00100;4:row_bits=5'b01000;5:row_bits=5'b01000;6:row_bits=5'b01000;default:row_bits=0;endcase
8'd56:case(row) 0:row_bits=5'b01110;1:row_bits=5'b10001;2:row_bits=5'b10001;3:row_bits=5'b01110;4:row_bits=5'b10001;5:row_bits=5'b10001;6:row_bits=5'b01110;default:row_bits=0;endcase
8'd57:case(row) 0:row_bits=5'b01110;1:row_bits=5'b10001;2:row_bits=5'b10001;3:row_bits=5'b01111;4:row_bits=5'b00001;5:row_bits=5'b00010;6:row_bits=5'b11100;default:row_bits=0;endcase
8'd76:case(row) 0:row_bits=5'b10000;1:row_bits=5'b10000;2:row_bits=5'b10000;3:row_bits=5'b10000;4:row_bits=5'b10000;5:row_bits=5'b10000;6:row_bits=5'b11111;default:row_bits=0;endcase
8'd65:case(row) 0:row_bits=5'b01110;1:row_bits=5'b10001;2:row_bits=5'b10001;3:row_bits=5'b11111;4:row_bits=5'b10001;5:row_bits=5'b10001;6:row_bits=5'b10001;default:row_bits=0;endcase
8'd83:case(row) 0:row_bits=5'b01111;1:row_bits=5'b10000;2:row_bits=5'b10000;3:row_bits=5'b01110;4:row_bits=5'b00001;5:row_bits=5'b00001;6:row_bits=5'b11110;default:row_bits=0;endcase
8'd84:case(row) 0:row_bits=5'b11111;1:row_bits=5'b00100;2:row_bits=5'b00100;3:row_bits=5'b00100;4:row_bits=5'b00100;5:row_bits=5'b00100;6:row_bits=5'b00100;default:row_bits=0;endcase
8'd78:case(row) 0:row_bits=5'b10001;1:row_bits=5'b11001;2:row_bits=5'b11001;3:row_bits=5'b10101;4:row_bits=5'b10011;5:row_bits=5'b10011;6:row_bits=5'b10001;default:row_bits=0;endcase
8'd47:case(row) 0:row_bits=5'b00001;1:row_bits=5'b00010;2:row_bits=5'b00010;3:row_bits=5'b00100;4:row_bits=5'b01000;5:row_bits=5'b01000;6:row_bits=5'b10000;default:row_bits=0;endcase
8'd46:case(row) 0:row_bits=5'b00000;1:row_bits=5'b00000;2:row_bits=5'b00000;3:row_bits=5'b00000;4:row_bits=5'b00000;5:row_bits=5'b00100;6:row_bits=5'b00100;default:row_bits=0;endcase
8'd109:case(row) 0:row_bits=5'b00000;1:row_bits=5'b00000;2:row_bits=5'b11010;3:row_bits=5'b10101;4:row_bits=5'b10101;5:row_bits=5'b10101;6:row_bits=5'b10101;default:row_bits=0;endcase
8'd115:case(row) 0:row_bits=5'b00000;1:row_bits=5'b00000;2:row_bits=5'b01111;3:row_bits=5'b10000;4:row_bits=5'b01110;5:row_bits=5'b00001;6:row_bits=5'b11110;default:row_bits=0;endcase
8'd70:case(row)0:row_bits=31;1:row_bits=16;2:row_bits=16;3:row_bits=30;4:row_bits=16;5:row_bits=16;6:row_bits=16;default:row_bits=0;endcase
default:row_bits=0;endcase end endfunction

 reg [7:0] ch;wire [3:0] cell_no=x[7:4];
 wire time_row=TIME_OSD && y[6];
 reg [7:0] ch_s1;reg [2:0] row_s1,col_s1,col_s2;
 reg visible_s1,visible_s2;reg [4:0] bits_s2;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin ch_s1<=0;row_s1<=0;col_s1<=0;col_s2<=0;
   visible_s1<=0;visible_s2<=0;bits_s2<=0;end
  else begin ch_s1<=ch;row_s1<=y[3:1];col_s1<=x[3:1];
   visible_s1<=de&&x>=256&&x<(time_row?464:400)&&((y>=48&&y<62)||(TIME_OSD&&y>=64&&y<78))&&x[3:0]<10;
   bits_s2<=row_bits(ch_s1,row_s1);col_s2<=col_s1;visible_s2<=visible_s1;end
 always @* begin
  ch=" ";
  if(time_row)begin
   if(!token[25])case(cell_no)0:ch="N";1:ch="/";2:ch="A";default:ch=" ";endcase
   else case(cell_no)
    0:ch="L";1:ch="A";2:ch="S";3:ch="T";
    5:ch={4'h3,token[24:21]};6:ch={4'h3,token[20:17]};7:ch={4'h3,token[16:13]};
    8:ch=".";9:ch={4'h3,token[12:9]};10:ch="m";11:ch="s";default:ch=" ";endcase
  end else if(!token[8])case(cell_no)0:ch="N";1:ch="/";2:ch="A";default:ch=" ";endcase
  else case(cell_no)
   0:ch="L";1:ch="A";2:ch="S";3:ch="T";
   5:ch={4'h3,token[7:4]};6:ch={4'h3,token[3:0]};8:ch="F";default:ch=" ";endcase
 end
 assign ink=visible_s2&&bits_s2[4-col_s2];
endmodule
