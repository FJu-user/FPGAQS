`timescale 1ns/1ps
// One row RAM is frozen by the producer until its end-to-end ACK or abort.
// Standard Ethernet/IPv4/UDP plus the existing image protocol CRC16/CRC32.
module cascade_packet_tx #(
 parameter [47:0] LOCAL_MAC=48'h020000000002,PEER_MAC=48'h020000000003,
 parameter [31:0] LOCAL_IP=32'hc0a88902,PEER_IP=32'hc0a88903,
 parameter [15:0] LOCAL_PORT=6002,PEER_PORT=6002,
 parameter WIDTH=320,HEIGHT=180
)(input wire clk,rst_n,input wire [103:0] message,input wire message_valid,
 output wire message_ready,output wire [9:0] ram_addr,input wire [7:0] ram_data,
 output reg [7:0] tx_data,output reg tx_valid);
 localparam IDLE=0,HCRC=1,SUM1=2,SUM2=3,PRE=4,BODY=5,FCS=6,IFG=7;
 reg [2:0] state;reg [7:0] command;reg [31:0] session,seq,argument;
 reg [10:0] count;reg [4:0] hi;reg [15:0] plen,hcrc,ip_checksum;
 reg [19:0] ip_sum;reg [31:0] crc,app_crc,app_tail,fcs;
 wire [15:0] udp_len=plen+28,ip_len=plen+48;
 wire [10:0] body_last=11'd61+plen[10:0];
 assign message_ready=state==IDLE;
 assign ram_addr=(state==BODY && count>=57 && count<58+plen)?count-57:10'd0;
 function [31:0] crc32(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;begin v=c^{24'd0,d};for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32=v;end
 endfunction
 function [15:0] crc16(input [15:0] c,input [7:0] d);
  integer k;reg [15:0] v;begin v=c^{d,8'd0};for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc16=v;end
 endfunction
 function [7:0] app_header(input [4:0] n);
  begin case(n)
   0:app_header=1;1:app_header=command;2,3:app_header=0;
   4:app_header=session[7:0];5:app_header=session[15:8];6:app_header=session[23:16];7:app_header=session[31:24];
   8:app_header=seq[7:0];9:app_header=seq[15:8];10:app_header=seq[23:16];11:app_header=seq[31:24];
   12:app_header=plen[7:0];13:app_header=plen[15:8];14:app_header=hcrc[7:0];15:app_header=hcrc[15:8];
   default:app_header=0;endcase end
 endfunction
 localparam [15:0] CW=WIDTH,CH=HEIGHT;
 localparam [31:0] CB=WIDTH*HEIGHT*2;
 reg [7:0] body_byte;reg [4:0] pn;
 always @* begin
  pn=count-58;body_byte=0;
  case(count)
   0:body_byte=PEER_MAC[47:40];1:body_byte=PEER_MAC[39:32];2:body_byte=PEER_MAC[31:24];
   3:body_byte=PEER_MAC[23:16];4:body_byte=PEER_MAC[15:8];5:body_byte=PEER_MAC[7:0];
   6:body_byte=LOCAL_MAC[47:40];7:body_byte=LOCAL_MAC[39:32];8:body_byte=LOCAL_MAC[31:24];
   9:body_byte=LOCAL_MAC[23:16];10:body_byte=LOCAL_MAC[15:8];11:body_byte=LOCAL_MAC[7:0];
   12:body_byte=8'h08;13:body_byte=0;14:body_byte=8'h45;
   16:body_byte=ip_len[15:8];17:body_byte=ip_len[7:0];20:body_byte=8'h40;22:body_byte=64;23:body_byte=17;
   24:body_byte=ip_checksum[15:8];25:body_byte=ip_checksum[7:0];
   26:body_byte=LOCAL_IP[31:24];27:body_byte=LOCAL_IP[23:16];28:body_byte=LOCAL_IP[15:8];29:body_byte=LOCAL_IP[7:0];
   30:body_byte=PEER_IP[31:24];31:body_byte=PEER_IP[23:16];32:body_byte=PEER_IP[15:8];33:body_byte=PEER_IP[7:0];
   34:body_byte=LOCAL_PORT[15:8];35:body_byte=LOCAL_PORT[7:0];36:body_byte=PEER_PORT[15:8];37:body_byte=PEER_PORT[7:0];
   38:body_byte=udp_len[15:8];39:body_byte=udp_len[7:0];
   default:begin
    if(count>=42 && count<58)body_byte=app_header(count-42);
    else if(count>=58 && count<58+plen)begin
     if(command==67)body_byte=ram_data;
     else if((command==12 || command==69))body_byte=argument[7:0];
     else if(command==68)case(pn)0:body_byte=argument[7:0];1:body_byte=argument[15:8];2:body_byte=argument[23:16];3:body_byte=argument[31:24];endcase
     else if(command==66)case(pn)
      0:body_byte=CW[7:0];1:body_byte=CW[15:8];2:body_byte=CH[7:0];3:body_byte=CH[15:8];4:body_byte=1;
      8:body_byte=CB[7:0];9:body_byte=CB[15:8];10:body_byte=CB[23:16];11:body_byte=CB[31:24];
      12:body_byte=session[7:0];13:body_byte=session[15:8];14:body_byte=session[23:16];15:body_byte=session[31:24];
      default:body_byte=0;endcase
    end else if(count>=58+plen)body_byte=app_tail[7:0];
   end
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;command<=0;session<=0;seq<=0;argument<=0;plen<=0;hi<=0;hcrc<=0;
   count<=0;crc<=32'hffffffff;app_crc<=32'hffffffff;app_tail<=0;fcs<=0;ip_sum<=0;ip_checksum<=0;tx_data<=0;tx_valid<=0;end
  else begin
   tx_valid<=0;
   case(state)
    IDLE:if(message_valid)begin
     {command,session,seq,argument}<=message;plen<=message[103:96]==66?20:message[103:96]==67?WIDTH*2:message[103:96]==68?4:(message[103:96]==12 || message[103:96]==69)?1:0;
     hcrc<=16'hffff;hi<=0;count<=0;crc<=32'hffffffff;app_crc<=32'hffffffff;state<=HCRC;
    end
    HCRC:begin hcrc<=crc16(hcrc,app_header(hi));if(hi==13)begin
     ip_sum<=20'h04500+ip_len+20'h04000+20'h04011+{4'd0,LOCAL_IP[31:16]}+{4'd0,LOCAL_IP[15:0]}+{4'd0,PEER_IP[31:16]}+{4'd0,PEER_IP[15:0]};state<=SUM1;
    end else hi<=hi+1'b1;end
    SUM1:begin ip_sum<={4'd0,ip_sum[15:0]}+ip_sum[19:16];state<=SUM2;end
    SUM2:begin ip_checksum<=~(ip_sum[15:0]+{12'd0,ip_sum[19:16]});state<=PRE;end
    PRE:begin tx_valid<=1;tx_data<=count==7?8'hd5:8'h55;
     if(count==7)begin count<=0;state<=BODY;end else count<=count+1'b1;end
    BODY:begin
     tx_valid<=1;tx_data<=body_byte;crc<=crc32(crc,body_byte);
     if(count>=42 && count<58+plen)begin
      app_crc<=crc32(app_crc,body_byte);
      if(count==57+plen)app_tail<=~crc32(app_crc,body_byte);
     end else if(count>=58+plen)app_tail<={8'd0,app_tail[31:8]};
     if(count==body_last)begin fcs<=~crc32(crc,body_byte);count<=0;state<=FCS;end else count<=count+1'b1;
    end
    FCS:begin tx_valid<=1;tx_data<=fcs[7:0];fcs<={8'd0,fcs[31:8]};
     if(count==3)begin count<=0;state<=IFG;end else count<=count+1'b1;end
    IFG:if(count==11)state<=IDLE;else count<=count+1'b1;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
