`timescale 1ns/1ps
// Rate-adaptive snapshot exporter: acquire one camera DDR bank, sample rows,
// send one row at a time, retry the SAME frozen row until the peer acknowledges.
// Local camera only; a selected incoming image is never echoed to the peer.
module cascade_video_sender #(
 parameter DEMAND_STREAM=0,CLOCK_HZ=100000000,WIDTH=320,HEIGHT=180,
 parameter GAP_CYCLES=5000000,ACK_CYCLES=25000000,MAX_RETRIES=3
)(input wire clk,rst_n,enable,path_run,mode1080,
 output reg [26:0] read_command,output reg read_valid,input wire read_ready,
 input wire [127:0] read_reply,
 output wire [103:0] tx_message,output reg tx_request,input wire tx_ready,
 output reg ram_we,output reg [9:0] ram_addr,output reg [7:0] ram_data,
 input wire ack_valid,ack_source_image,input wire [7:0] ack_command,ack_status,
 input wire [31:0] ack_session,ack_sequence,
 output reg [31:0] sent_frames,failed_frames,retries
);
 localparam GAP=0,ACQUIRE=1,R_SEND=2,R_ACCEPT=3,R_WAIT=4,BEGIN_TX=5,TX_SEND=6,TX_ACCEPT=7,TX_WAIT=8,ACK_WAIT=9,
  PIXEL=10,READ_PIXEL=11,PIXEL_DATA=12,READ_NEXT=13,NEXT_DATA=14,WRITE_LOW=15,WRITE_HIGH=16,
  END_TX=17,RELEASE=18,RELEASED=19,ABORT_TX=20,PROBE=21;
 reg [4:0] state,after_read;reg [7:0] command;reg [31:0] session,seq,arg,frame_crc;
 reg [31:0] timer;reg [2:0] attempts;
 reg source_mode,reuse_word;reg [24:0] row_base,word_addr;reg [3:0] offset;
 reg [8:0] x;reg [7:0] y;reg [15:0] packed565,partial;
 wire [5:0] byte_advance={2'd0,offset}+(source_mode?6'd18:6'd12);
 assign tx_message={command,session,seq,arg};
 function [31:0] crc32(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;begin v=c^{24'd0,d};for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32=v;end
 endfunction
 function [7:0] byte_at(input [127:0] w,input [3:0] n);
  begin byte_at=w[127-n*8-:8];end
 endfunction
 wire [7:0] cr=byte_at(read_reply,offset),cg=byte_at(read_reply,offset+4'd1),cb=byte_at(read_reply,offset+4'd2);
 wire expected_ack=ack_valid && ack_command==(command|8'h80) && ack_session==session && ack_sequence==seq;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=GAP;after_read<=GAP;read_command<=0;read_valid<=0;tx_request<=0;ram_we<=0;ram_addr<=0;ram_data<=0;
   command<=0;session<=0;seq<=0;arg<=0;frame_crc<=32'hffffffff;timer<=0;attempts<=0;
   source_mode<=0;reuse_word<=0;row_base<=0;word_addr<=0;offset<=0;x<=0;y<=0;packed565<=0;partial<=0;
   sent_frames<=0;failed_frames<=0;retries<=0;
  end else begin
   ram_we<=0;
   case(state)
    GAP:if(enable && path_run)begin if(timer>=GAP_CYCLES-1)begin timer<=0;state<=PROBE;end else timer<=timer+1'b1;end else timer<=0;
    PROBE:begin command<=1;seq<=0;arg<=0;attempts<=0;source_mode<=mode1080;state<=TX_SEND;end
    ACQUIRE:begin read_command<=0;after_read<=BEGIN_TX;state<=R_SEND;end
    R_SEND:if(read_ready)begin read_valid<=1;state<=R_ACCEPT;end
    R_ACCEPT:begin read_valid<=0;state<=R_WAIT;end
    R_WAIT:if(read_ready)state<=after_read;
    BEGIN_TX:begin
     if(read_reply[26] || !path_run || !enable)state<=RELEASE;
     else begin source_mode<=read_reply[25];row_base<=read_reply[24:0];word_addr<=read_reply[24:0];
      session<=session+1'b1;seq<=0;arg<=0;command<=66;frame_crc<=32'hffffffff;x<=0;y<=0;offset<=0;reuse_word<=0;attempts<=0;state<=TX_SEND;end
    end
    TX_SEND:if(tx_ready)begin tx_request<=1;state<=TX_ACCEPT;end
    TX_ACCEPT:begin tx_request<=0;state<=TX_WAIT;end
    TX_WAIT:if(tx_ready)begin timer<=0;state<=command==5?RELEASE:ACK_WAIT;end
    ACK_WAIT:begin
     if(!enable || !path_run || mode1080!=source_mode)state<=ABORT_TX;
     else if(expected_ack)begin
      if(ack_status!=0)state<=ABORT_TX;
      else begin attempts<=0;
       if(command==1)begin
        if(DEMAND_STREAM && !ack_source_image)begin timer<=0;state<=GAP;end
        else state<=ACQUIRE;
       end
       else if(DEMAND_STREAM && !ack_source_image && command!=68)state<=ABORT_TX;
       else if(command==66)state<=PIXEL;
       else if(command==68)begin sent_frames<=sent_frames+1'b1;state<=RELEASE;end
       else if(y==HEIGHT-1)begin seq<=seq+1'b1;state<=END_TX;end
       else begin y<=y+1'b1;seq<=seq+1'b1;x<=0;offset<=0;reuse_word<=0;
        row_base<=row_base+(source_mode?25'd17280:25'd7680);word_addr<=row_base+(source_mode?25'd17280:25'd7680);state<=PIXEL;end
      end
     end else if(timer>=ACK_CYCLES-1)begin
      if(attempts==MAX_RETRIES)state<=ABORT_TX;
      else begin attempts<=attempts+1'b1;retries<=retries+1'b1;state<=TX_SEND;end
     end else timer<=timer+1'b1;
    end
    PIXEL:if(!enable || !path_run || mode1080!=source_mode)state<=ABORT_TX;else state<=reuse_word?PIXEL_DATA:READ_PIXEL;
    READ_PIXEL:begin read_command<={2'd1,word_addr};after_read<=PIXEL_DATA;state<=R_SEND;end
    PIXEL_DATA:if(offset==14)begin partial<=read_reply[15:0];state<=READ_NEXT;end
     else begin packed565<={cr[7:3],cg[7:2],cb[7:3]};state<=WRITE_LOW;end
    READ_NEXT:begin read_command<={2'd1,(word_addr+25'd8)};after_read<=NEXT_DATA;state<=R_SEND;end
    NEXT_DATA:begin packed565<={partial[15:11],partial[7:2],read_reply[127:123]};state<=WRITE_LOW;end
    WRITE_LOW:begin ram_we<=1;ram_addr<={x,1'b0};ram_data<=packed565[7:0];frame_crc<=crc32(frame_crc,packed565[7:0]);state<=WRITE_HIGH;end
    WRITE_HIGH:begin
     ram_we<=1;ram_addr<={x,1'b1};ram_data<=packed565[15:8];frame_crc<=crc32(frame_crc,packed565[15:8]);
     if(x==WIDTH-1)begin command<=67;arg<=0;attempts<=0;state<=TX_SEND;end
     else begin x<=x+1'b1;word_addr<=word_addr+{16'd0,byte_advance[5:4],3'd0};offset<=byte_advance[3:0];reuse_word<=byte_advance[5:4]==0 && offset!=14;state<=PIXEL;end
    end
    END_TX:begin command<=68;arg<=~frame_crc;attempts<=0;state<=TX_SEND;end
    ABORT_TX:begin command<=5;arg<=0;failed_frames<=failed_frames+1'b1;state<=TX_SEND;end
    RELEASE:begin read_command<={2'd2,25'd0};after_read<=RELEASED;state<=R_SEND;end
    RELEASED:begin timer<=0;state<=GAP;end
    default:state<=GAP;
   endcase
  end
 end
endmodule
