`timescale 1ns/1ps
// One serializer for ARP, short UDP replies and cascade video packets.
// Descriptors are bundled-data CDC requests: producers hold ALL fields until
// *_ready acknowledges completion, after FCS and IFG. No wide descriptor copy.
// Precompute cascade application CRC before transmission, then reuse the SAME
// byte CRC32 datapath for Ethernet FCS. Row RAM stays frozen until peer ACK.
module ethernet_shared_tx #(
 parameter [47:0] LOCAL_MAC=48'h020000000002,PEER_MAC=48'h020000000003,
 parameter [31:0] LOCAL_IP=32'hc0a88902,PEER_IP=32'hc0a88903,
 parameter [15:0] LOCAL_PORT=6002,PEER_PORT=6002,
 parameter WIDTH=320,HEIGHT=180
)(
 input wire clk,rst_n,
 input wire [448:0] control_message,input wire control_valid,output wire control_ready,
 input wire [103:0] video_message,input wire video_valid,output wire video_ready,
 output wire [9:0] ram_addr,input wire [7:0] ram_data,
 output reg [7:0] tx_data,output reg tx_valid
);
 localparam IDLE=0,HCRC=1,SUM1=2,SUM2=3,PRE=4,BODY=5,FCS=6,IFG=7,
  SUM3=8,SUM4=9,APP_CRC=10,DONE=11,DRAIN=12;
 reg [3:0] state;
 reg owner_video;
 reg [10:0] count;
 reg [3:0] hi;
 reg [15:0] hcrc,ip_checksum;
 reg [19:0] ip_sum;
 reg [31:0] crc,tail;
 wire udp=owner_video || control_message[448];
 wire [7:0] command=video_message[103:96];
 wire [31:0] session=video_message[95:64],seq=video_message[63:32],argument=video_message[31:0];
 wire [47:0] remote_mac=owner_video?PEER_MAC:control_message[447:400];
 wire [31:0] remote_ip=owner_video?PEER_IP:control_message[399:368];
 wire [15:0] remote_port=owner_video?PEER_PORT:control_message[367:352];
 wire [10:0] plen=command==66?11'd20:command==67?WIDTH*2:command==68?11'd4:(command==12 || command==69)?11'd1:11'd0;
 wire [15:0] udp_len=owner_video?{5'd0,plen}+16'd28:16'd52;
 wire [15:0] ip_len=owner_video?{5'd0,plen}+16'd48:16'd72;
 wire [10:0] body_last=owner_video?11'd61+plen:udp?11'd85:11'd59;
 wire [10:0] app_last=11'd57+plen;
 wire [5:0] response_index=count-11'd42;
 wire [351:0] response_payload=control_message[351:0];
 wire [7:0] response_byte=response_payload[response_index*8+:8];
 wire [31:0] crc_next;
 assign control_ready=(state==DONE) && !owner_video;
 assign video_ready=(state==DONE) && owner_video;
 assign ram_addr=owner_video && (state==BODY || state==APP_CRC) && count>=57 && count<58+plen ? count-57:10'd0;
 function [31:0] crc32(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;begin v=c^{24'd0,d};for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32=v;end
 endfunction
 function [15:0] crc16(input [15:0] c,input [7:0] d);
  integer k;reg [15:0] v;begin v=c^{d,8'd0};for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc16=v;end
 endfunction
 function [7:0] mac_byte(input [47:0] mac,input [2:0] n);
  begin case(n)
   0:mac_byte=mac[47:40];1:mac_byte=mac[39:32];2:mac_byte=mac[31:24];
   3:mac_byte=mac[23:16];4:mac_byte=mac[15:8];5:mac_byte=mac[7:0];default:mac_byte=0;
  endcase end
 endfunction
 function [7:0] app_header(input [4:0] n);
  begin case(n)
   0:app_header=1;1:app_header=command;2,3:app_header=0;
   4:app_header=session[7:0];5:app_header=session[15:8];6:app_header=session[23:16];7:app_header=session[31:24];
   8:app_header=seq[7:0];9:app_header=seq[15:8];10:app_header=seq[23:16];11:app_header=seq[31:24];
   12:app_header=plen[7:0];13:app_header={5'd0,plen[10:8]};14:app_header=hcrc[7:0];15:app_header=hcrc[15:8];
   default:app_header=0;
  endcase end
 endfunction
 localparam [15:0] CW=WIDTH,CH=HEIGHT;
 localparam [31:0] CB=WIDTH*HEIGHT*2;
 reg [7:0] body_byte;
 reg [4:0] pn;
 always @* begin
  body_byte=0;pn=count-58;
  if(count<6)body_byte=mac_byte(remote_mac,count[2:0]);
  else if(count<12)body_byte=mac_byte(LOCAL_MAC,count-6);
  else if(udp)begin
   case(count)
    12:body_byte=8'h08;14:body_byte=8'h45;
    16:body_byte=ip_len[15:8];17:body_byte=ip_len[7:0];20:body_byte=8'h40;22:body_byte=64;23:body_byte=17;
    24:body_byte=ip_checksum[15:8];25:body_byte=ip_checksum[7:0];
    26:body_byte=LOCAL_IP[31:24];27:body_byte=LOCAL_IP[23:16];28:body_byte=LOCAL_IP[15:8];29:body_byte=LOCAL_IP[7:0];
    30:body_byte=remote_ip[31:24];31:body_byte=remote_ip[23:16];32:body_byte=remote_ip[15:8];33:body_byte=remote_ip[7:0];
    34:body_byte=LOCAL_PORT[15:8];35:body_byte=LOCAL_PORT[7:0];36:body_byte=remote_port[15:8];37:body_byte=remote_port[7:0];
    38:body_byte=udp_len[15:8];39:body_byte=udp_len[7:0];
    default:if(!owner_video)begin
     if(count>=42 && count<86)body_byte=response_byte;
    end else if(count>=42 && count<58)body_byte=app_header(count-42);
    else if(count>=58 && count<58+plen)begin
     if(command==67)body_byte=ram_data;
     else if((command==12 || command==69))body_byte=argument[7:0];
     else if(command==68)case(pn)
      0:body_byte=argument[7:0];1:body_byte=argument[15:8];2:body_byte=argument[23:16];3:body_byte=argument[31:24];default:body_byte=0;
     endcase
     else if(command==66)case(pn)
      0:body_byte=CW[7:0];1:body_byte=CW[15:8];2:body_byte=CH[7:0];3:body_byte=CH[15:8];4:body_byte=1;
      8:body_byte=CB[7:0];9:body_byte=CB[15:8];10:body_byte=CB[23:16];11:body_byte=CB[31:24];
      12:body_byte=session[7:0];13:body_byte=session[15:8];14:body_byte=session[23:16];15:body_byte=session[31:24];default:body_byte=0;
     endcase
    end else if(count>=58+plen)body_byte=tail[7:0];
   endcase
  end else begin
   case(count)
    12:body_byte=8'h08;13:body_byte=8'h06;
    15:body_byte=1;16:body_byte=8'h08;18:body_byte=6;19:body_byte=4;21:body_byte=2;
    22:body_byte=LOCAL_MAC[47:40];23:body_byte=LOCAL_MAC[39:32];24:body_byte=LOCAL_MAC[31:24];
    25:body_byte=LOCAL_MAC[23:16];26:body_byte=LOCAL_MAC[15:8];27:body_byte=LOCAL_MAC[7:0];
    28:body_byte=LOCAL_IP[31:24];29:body_byte=LOCAL_IP[23:16];30:body_byte=LOCAL_IP[15:8];31:body_byte=LOCAL_IP[7:0];
    38:body_byte=remote_ip[31:24];39:body_byte=remote_ip[23:16];40:body_byte=remote_ip[15:8];41:body_byte=remote_ip[7:0];
    default:if(count>=32 && count<38)body_byte=mac_byte(remote_mac,count[2:0]);
   endcase
  end
 end
 assign crc_next=crc32(crc,body_byte);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;owner_video<=0;count<=0;hi<=0;hcrc<=0;crc<=32'hffffffff;tail<=0;
   ip_sum<=0;ip_checksum<=0;tx_data<=0;tx_valid<=0;end
  else begin
   tx_valid<=0;
   case(state)
    IDLE:if(control_valid || video_valid)begin
     owner_video<=!control_valid;count<=0;hi<=0;hcrc<=16'hffff;crc<=32'hffffffff;
     state<=control_valid?SUM1:HCRC;
    end
    HCRC:begin hcrc<=crc16(hcrc,app_header({1'b0,hi}));
     if(hi==13)begin count<=42;state<=APP_CRC;end else hi<=hi+1'b1;
    end
    APP_CRC:begin
     crc<=crc_next;
     if(count==app_last)begin tail<=~crc_next;crc<=32'hffffffff;count<=0;state<=SUM1;end
     else count<=count+1'b1;
    end
    SUM1:begin ip_sum<=20'h04500+20'h04000+20'h04011+{4'd0,LOCAL_IP[31:16]}+{4'd0,LOCAL_IP[15:0]}+ip_len;state<=SUM2;end
    SUM2:begin ip_sum<=ip_sum+{4'd0,remote_ip[31:16]};state<=SUM3;end
    SUM3:begin ip_sum<=ip_sum+{4'd0,remote_ip[15:0]};state<=SUM4;end
    SUM4:begin ip_sum<={4'd0,ip_sum[15:0]}+ip_sum[19:16];state<=PRE;end
    PRE:begin
     if(count==0)ip_checksum<=~(ip_sum[15:0]+{12'd0,ip_sum[19:16]});
     tx_valid<=1;tx_data<=count==7?8'hd5:8'h55;
     if(count==7)begin count<=0;state<=BODY;end else count<=count+1'b1;
    end
    BODY:begin
     tx_valid<=1;tx_data<=body_byte;crc<=crc_next;
     if(owner_video && count>=58+plen)tail<={8'd0,tail[31:8]};
     if(count==body_last)begin tail<=~crc_next;count<=0;state<=FCS;end else count<=count+1'b1;
    end
    FCS:begin tx_valid<=1;tx_data<=tail[7:0];tail<={8'd0,tail[31:8]};
     if(count==3)begin count<=0;state<=IFG;end else count<=count+1'b1;
    end
    IFG:if(count==11)state<=DONE;else count<=count+1'b1;
    DONE:state<=DRAIN; // acknowledge CDC only when descriptor is no longer read
    DRAIN:state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
