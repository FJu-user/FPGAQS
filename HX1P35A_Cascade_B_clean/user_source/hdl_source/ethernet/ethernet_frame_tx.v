`timescale 1ns/1ps
// One small ARP/UDP response at a time. No packet FIFO and no additional ERAM.
module ethernet_frame_tx #(
 parameter [47:0] LOCAL_MAC=48'h020000000002,
 parameter [31:0] LOCAL_IP=32'hc0a88902,
 parameter [15:0] LOCAL_PORT=16'd6002
)(
 input wire clk,rst_n,input wire [448:0] message,input wire message_valid,
 output wire message_ready,output reg [7:0] tx_data,output reg tx_valid
);
 localparam IDLE=0,SUM1=1,SUM2=2,SUM3=3,PREAMBLE=4,BODY=5,FCS=6,IFG=7,SUM4=8;
 localparam [19:0] IP_SUM_BASE=20'h04500+20'd72+20'h04000+20'h04011+
                  {4'd0,LOCAL_IP[31:16]}+{4'd0,LOCAL_IP[15:0]};
 reg [3:0] state;reg udp;
 reg [47:0] remote_mac;reg [31:0] remote_ip;reg [15:0] remote_port;
 reg [351:0] response;reg [19:0] ip_sum;reg [15:0] ip_checksum;
 reg [6:0] count;reg [31:0] crc,fcs;
 reg [7:0] body_byte;
 assign message_ready=state==IDLE;
 function [31:0] crc_next(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;begin v=c^{24'd0,d};for(k=0;k<8;k=k+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_next=v;end
 endfunction
 function [7:0] mac_byte(input [47:0] mac,input [2:0] index);
  begin case(index)
   0:mac_byte=mac[47:40];1:mac_byte=mac[39:32];2:mac_byte=mac[31:24];
   3:mac_byte=mac[23:16];4:mac_byte=mac[15:8];5:mac_byte=mac[7:0];
   default:mac_byte=0;
  endcase end
 endfunction
 always @* begin
  body_byte=0;
  if(count<6) body_byte=mac_byte(remote_mac,count[2:0]);
  else if(count<12) begin
   case(count)
    6:body_byte=LOCAL_MAC[47:40];7:body_byte=LOCAL_MAC[39:32];8:body_byte=LOCAL_MAC[31:24];
    9:body_byte=LOCAL_MAC[23:16];10:body_byte=LOCAL_MAC[15:8];11:body_byte=LOCAL_MAC[7:0];
    default:body_byte=0;
   endcase
  end
  else if(udp) begin
   case(count)
    12:body_byte=8'h08;13:body_byte=8'h00;
    14:body_byte=8'h45;15:body_byte=0;
    16:body_byte=0;17:body_byte=72; // IPv4 20 + UDP 8 + application response 44
    18,19:body_byte=0;20:body_byte=8'h40;21:body_byte=0;
    22:body_byte=64;23:body_byte=17;
    24:body_byte=ip_checksum[15:8];25:body_byte=ip_checksum[7:0];
    26:body_byte=LOCAL_IP[31:24];27:body_byte=LOCAL_IP[23:16];
    28:body_byte=LOCAL_IP[15:8];29:body_byte=LOCAL_IP[7:0];
    30:body_byte=remote_ip[31:24];31:body_byte=remote_ip[23:16];
    32:body_byte=remote_ip[15:8];33:body_byte=remote_ip[7:0];
    34:body_byte=LOCAL_PORT[15:8];35:body_byte=LOCAL_PORT[7:0];
    36:body_byte=remote_port[15:8];37:body_byte=remote_port[7:0];
    38:body_byte=0;39:body_byte=52;40,41:body_byte=0;
    default: if(count>=42 && count<86) body_byte=response[7:0];
   endcase
  end else begin
   case(count)
    12:body_byte=8'h08;13:body_byte=8'h06;
    14:body_byte=0;15:body_byte=1;16:body_byte=8'h08;17:body_byte=0;
    18:body_byte=6;19:body_byte=4;20:body_byte=0;21:body_byte=2;
    22:body_byte=LOCAL_MAC[47:40];23:body_byte=LOCAL_MAC[39:32];24:body_byte=LOCAL_MAC[31:24];
    25:body_byte=LOCAL_MAC[23:16];26:body_byte=LOCAL_MAC[15:8];27:body_byte=LOCAL_MAC[7:0];
    28:body_byte=LOCAL_IP[31:24];29:body_byte=LOCAL_IP[23:16];
    30:body_byte=LOCAL_IP[15:8];31:body_byte=LOCAL_IP[7:0];
    38:body_byte=remote_ip[31:24];39:body_byte=remote_ip[23:16];
    40:body_byte=remote_ip[15:8];41:body_byte=remote_ip[7:0];
    default: begin
     if(count>=32 && count<38) body_byte=mac_byte(remote_mac,count[2:0]);
    end
   endcase
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;udp<=0;remote_mac<=0;remote_ip<=0;remote_port<=0;response<=0;
   ip_sum<=0;ip_checksum<=0;count<=0;crc<=32'hffffffff;fcs<=0;tx_data<=0;tx_valid<=0;
  end else begin
   tx_valid<=0;
   case(state)
    IDLE: if(message_valid) begin
     {udp,remote_mac,remote_ip,remote_port,response}<=message;
     count<=0;crc<=32'hffffffff;state<=SUM1;
    end
    SUM1: begin
     ip_sum<=IP_SUM_BASE+{4'd0,remote_ip[31:16]};
     state<=SUM2;
    end
    SUM2: begin ip_sum<=ip_sum+{4'd0,remote_ip[15:0]};state<=SUM3;end
    SUM3: begin ip_sum<={4'd0,ip_sum[15:0]}+ip_sum[19:16];state<=SUM4;end
    SUM4: begin ip_checksum<=~(ip_sum[15:0]+{12'd0,ip_sum[19:16]});state<=PREAMBLE;end
    PREAMBLE: begin
     tx_valid<=1;tx_data<=count==7?8'hd5:8'h55;
     if(count==7) begin count<=0;state<=BODY;end else count<=count+1'b1;
    end
    BODY: begin
     tx_valid<=1;tx_data<=body_byte;crc<=crc_next(crc,body_byte);
     // Fixed byte shift instead of a 44:1 dynamically indexed response mux.
     if(udp && count>=42) response<={8'd0,response[351:8]};
     if(count==(udp?85:59)) begin fcs<=~crc_next(crc,body_byte);count<=0;state<=FCS;end
     else count<=count+1'b1;
    end
    FCS: begin
     tx_valid<=1;tx_data<=fcs[7:0];fcs<={8'd0,fcs[31:8]};
     if(count==3) begin count<=0;state<=IFG;end else count<=count+1'b1;
    end
    IFG: if(count==11) state<=IDLE;else count<=count+1'b1;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
