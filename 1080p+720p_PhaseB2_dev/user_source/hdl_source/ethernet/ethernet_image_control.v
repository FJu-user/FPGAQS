`timescale 1ns/1ps
// Stop-and-wait IPv4/UDP image endpoint. One validated MAC frame in ERAM;
// payload is reread only after BOTH header CRC16 and packet CRC32 pass.
// Reuses the existing DDR command contract; no separate framebuffer/descriptor.
module ethernet_image_control #(
 parameter CLOCK_HZ=100000000,W720=1280,H720=720,W1080=1920,H1080=1080,
 parameter [47:0] LOCAL_MAC=48'h020000000002,
 parameter [31:0] LOCAL_IP=32'hc0a88902,
 parameter [15:0] LOCAL_PORT=16'd6002,
 parameter VISION_ROLE=0,MAX_MODE=16,
 parameter CASCADE_SUPPORT=0,COMPACT_SUPPORT=0,CASCADE_WIDTH=320,CASCADE_HEIGHT=180,
 parameter [47:0] PEER_MAC=48'h020000000003,
 parameter [31:0] PEER_IP=32'hc0a88903
)(
 input wire clk,rst_n,mode1080,
 input wire frame_valid,input wire [11:0] frame_length,
 output reg frame_release,output reg [10:0] rd_addr,input wire [7:0] rd_data,
 output wire [448:0] tx_message,output reg tx_valid,input wire tx_ready,
 input wire source_image,input wire [1:0] compare_mode,input wire [4:0] current_mode,
 input wire front_valid,input wire [31:0] displayed_id,
 output reg source_set,output reg source_value,
 output reg compare_set,output reg [1:0] compare_value,
 output reg mode_set,output reg [4:0] requested_mode,
 output wire [155:0] mem_data,output reg mem_valid,input wire mem_ready,
 input wire mem_error,input wire [383:0] mem_reply,
 output reg ack_valid,output reg ack_source_image,output reg [7:0] ack_command,ack_status,
 output reg [31:0] ack_session,ack_sequence,
 output reg cascade_enable,
 input wire [191:0] vision_reply,
 output reg vision_request,output reg [31:0] vision_request_epoch,vision_request_sequence,
 output reg [4:0] vision_request_mode,
 output reg vision_rx_valid,output reg [31:0] vision_rx_session,vision_rx_sequence,
 output reg [191:0] vision_rx_payload
);
 localparam IDLE=0,FETCH=1,WAIT_RAM=2,READ_RAM=3,FOLD1=4,FOLD2=5,CHECK=6,
  DISPATCH=7,DATA_FETCH=8,DATA_WAIT=9,DATA_READ=10,EMIT=11,
  SEND_MEM=12,ACCEPT_MEM=13,WAIT_MEM=14,REPLY=15,HCRC=16,PCRC=17,
  SEND_TX=18,ACCEPT_TX=19,WAIT_TX=20,DROP=21,
  PSEUDO_SRC_LO=22,PSEUDO_LOCAL=23,PSEUDO_LENGTH=24;
 localparam [17:0] PSEUDO_LOCAL_SUM={2'd0,LOCAL_IP[31:16]}+{2'd0,LOCAL_IP[15:0]}+18'd17;
 reg [4:0] state,after_mem;
 // Fixed sequential header windows, not byte-addressed register-file writes.
 // Each window is complete before any consumer observes its fields. Byte 0
 // occupies the LSB after the last byte has shifted into that window.
 reg [47:0] mac_dst_bytes,mac_src_bytes;
 reg [15:0] eth_type_bytes;
 reg [159:0] network_bytes,begin_bytes;
 reg [63:0] udp_bytes;
 reg [127:0] app_bytes;
 // The CRC-gated valid pulse owns this shift window. Its payload may change
 // while valid is low; the same-clock client only consumes complete replies.
 reg [7:0] control_arg;reg ack_source_arg;
 wire [7:0] h[0:57],cfg[0:19];
 wire [7:0] command=h[43];
 wire is_begin=command==2 || (CASCADE_SUPPORT && command==66);
 wire [47:0] sender_mac={h[6],h[7],h[8],h[9],h[10],h[11]};
 wire [31:0] sender_ip={h[26],h[27],h[28],h[29]};
 genvar b;
 generate
  for(b=0;b<58;b=b+1) begin: header_fields
   if(b<6) assign h[b]=mac_dst_bytes[b*8+:8];
   else if(b<12) assign h[b]=mac_src_bytes[(b-6)*8+:8];
   else if(b<14) assign h[b]=eth_type_bytes[(b-12)*8+:8];
   else if(b<34) assign h[b]=network_bytes[(b-14)*8+:8];
   else if(b<42) assign h[b]=udp_bytes[(b-34)*8+:8];
   else assign h[b]=app_bytes[(b-42)*8+:8];
  end
  for(b=0;b<20;b=b+1) begin: begin_fields
   if(b==0) assign cfg[b]=is_begin ? begin_bytes[7:0]:control_arg;
   else assign cfg[b]=begin_bytes[b*8+:8];
  end
 endgenerate
 reg [10:0] pos,index;reg [11:0] packet_length;
 reg [10:0] udp_end,udp_last,payload_end;
 reg [19:0] ip_sum;reg [25:0] udp_sum;reg [7:0] ip_high,udp_high;
 reg [15:0] header_crc;reg [31:0] packet_crc,packet_tail;
 reg [47:0] remote_mac;reg [31:0] remote_ip;reg [15:0] remote_port;
 reg reply_udp;reg [7:0] status;
 reg active,completed,format565,target1080,cleanup;
 reg cascade_session;reg [2:0] repeat_x,repeat_y;reg [23:0] repeat_pixel;reg [31:0] end_crc;
 wire [2:0] scale=(COMPACT_SUPPORT && cascade_session)?3'd1:(target1080?3'd6:3'd4);
 wire is_data=command==3 || (CASCADE_SUPPORT && command==67);
 wire is_end=command==4 || (CASCADE_SUPPORT && command==68);
 wire peer_packet=sender_mac==PEER_MAC && sender_ip==PEER_IP;
 wire cascade_allowed=CASCADE_SUPPORT && peer_packet && cascade_enable;
 reg [31:0] active_session,total_bytes,received,expected_seq,image_id,ready_id;
 reg [31:0] frame_crc,expected_crc;
 reg [24:0] base,write_addr,last_addr,op_addr;
 reg [127:0] packed_word;
 reg abort_op;
 reg [3:0] packed_count;reg [1:0] op,emit_count;
 reg [23:0] pixel;reg [7:0] low565;
 reg [$clog2(CLOCK_HZ*5+1)-1:0] watchdog;
 reg [$clog2(CLOCK_HZ+1)-1:0] mem_timer;
 // Snapshot only live display controls. Session/frontier/image IDs are already
 // held by this FSM until TX acceptance; do not duplicate the 44-byte reply.
 reg [9:0] reply_controls;
 reg [31:0] reply_displayed_id;
 reg [5:0] reply_index;reg [15:0] reply_hcrc;reg [31:0] reply_pcrc;
 wire [15:0] plen={h[55],h[54]};
 wire [31:0] session={h[49],h[48],h[47],h[46]};
 wire [31:0] seq={h[53],h[52],h[51],h[50]};
 wire [15:0] width_in={cfg[1],cfg[0]},height_in={cfg[3],cfg[2]};
 wire begin720=width_in==W720 && height_in==H720;
 wire begin1080=width_in==W1080 && height_in==H1080;
 wire [31:0] length_in={cfg[11],cfg[10],cfg[9],cfg[8]};
 wire [31:0] id_in={cfg[15],cfg[14],cfg[13],cfg[12]};
 wire [31:0] crc_in={cfg[19],cfg[18],cfg[17],cfg[16]};
 // Four compile-time sizes, not a run-time variable multiplication/DSP.
 wire [31:0] required_bytes=begin1080?
   (cfg[4]==1?W1080*H1080*2:W1080*H1080*3):
   (cfg[4]==1?W720*H720*2:W720*H720*3);
 wire [15:0] rgb565={rd_data,low565};
 wire [23:0] expanded565={rgb565[15:11],rgb565[15:13],rgb565[10:5],rgb565[10:9],rgb565[4:0],rgb565[4:2]};
 wire [15:0] ip_length={h[16],h[17]},udp_length={h[38],h[39]};
 wire [47:0] destination={h[0],h[1],h[2],h[3],h[4],h[5]};
 wire [16:0] udp_folded={1'b0,udp_sum[15:0]}+udp_sum[25:16];
 // packed_word remains stable while an existing DDR command is outstanding.
 // At END packed_count==0, so it is also the last complete write/fence word.
 wire [127:0] op_data=op==2?{96'd0,image_id}:
   op==3?{118'd0,(COMPACT_SUPPORT && command==66 && !abort_op),(abort_op?1'b0:(command==66?1'b1:cfg[4][0])),7'd0,abort_op}:packed_word;
 assign mem_data={target1080,op,op_addr,op_data};
 wire [127:0] response_header={reply_hcrc,16'd24,seq,session,8'd0,8'd0,(command|8'h80),8'd1};
 wire [191:0] legacy_response_body={8'd0,{7'd0,reply_controls[9]},8'd0,{3'd0,reply_controls[8:4]},reply_displayed_id,
   ready_id,received,expected_seq,{6'd0,reply_controls[3:2]},{7'd0,reply_controls[1]},
   {7'd0,reply_controls[0]},status};
 wire custom_vision_reply=VISION_ROLE==2 && peer_packet && command==69 && plen==1 && control_arg==17;
 wire [191:0] response_body=custom_vision_reply?vision_reply:legacy_response_body;
 // Bundled-data CDC contract: ALL fields are held from SEND_TX until the
 // acknowledgement returns. No copy of the assembled message is required.
 assign tx_message={reply_udp,remote_mac,remote_ip,remote_port,
                    ~reply_pcrc,response_body,response_header};
 function [31:0] crc32_next(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;begin v=c^{24'd0,d};for(k=0;k<8;k=k+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32_next=v;end
 endfunction
 function [15:0] crc16_next(input [15:0] c,input [7:0] d);
  integer k;reg [15:0] v;begin v=c^{d,8'd0};for(k=0;k<8;k=k+1) v=v[15]?(v<<1)^16'h1021:v<<1;crc16_next=v;end
 endfunction
 // Decode fixed fields directly; no 320-bit dynamic byte selection, no
 // variable subtraction/multiply to construct a barrel-mux shift index.
 reg [7:0] reply_byte;
 always @* begin
  reply_byte=0;
  case(reply_index)
   0:reply_byte=1;1:reply_byte=command|8'h80;
   4:reply_byte=session[7:0];5:reply_byte=session[15:8];
   6:reply_byte=session[23:16];7:reply_byte=session[31:24];
   8:reply_byte=seq[7:0];9:reply_byte=seq[15:8];
   10:reply_byte=seq[23:16];11:reply_byte=seq[31:24];
   12:reply_byte=24;
   14:reply_byte=reply_hcrc[7:0];15:reply_byte=reply_hcrc[15:8];
   16:reply_byte=status;17:reply_byte={7'd0,reply_controls[0]};
   18:reply_byte={7'd0,reply_controls[1]};19:reply_byte={6'd0,reply_controls[3:2]};
   20:reply_byte=expected_seq[7:0];21:reply_byte=expected_seq[15:8];
   22:reply_byte=expected_seq[23:16];23:reply_byte=expected_seq[31:24];
   24:reply_byte=received[7:0];25:reply_byte=received[15:8];
   26:reply_byte=received[23:16];27:reply_byte=received[31:24];
   28:reply_byte=ready_id[7:0];29:reply_byte=ready_id[15:8];
   30:reply_byte=ready_id[23:16];31:reply_byte=ready_id[31:24];
   32:reply_byte=reply_displayed_id[7:0];33:reply_byte=reply_displayed_id[15:8];
   34:reply_byte=reply_displayed_id[23:16];35:reply_byte=reply_displayed_id[31:24];
   36:reply_byte={3'd0,reply_controls[8:4]};38:reply_byte={7'd0,reply_controls[9]};
   default:reply_byte=0;
  endcase
  if(custom_vision_reply && reply_index>=16 && reply_index<40)
   reply_byte=vision_reply[(reply_index-16)*8+:8];
 end
 // FSM phases never update packet/frame/reply CRC32 concurrently.
 // Share one BYTE-fold datapath instead of synthesizing three 8-bit-unrolled
 // polynomial networks. Same cycles, seeds, polynomial and register updates.
 // READ_RAM still updates CRC16 + CRC32 in parallel with the same input byte.
 wire crc_reply_phase=(state==HCRC || state==PCRC);
 wire [7:0] crc_byte=crc_reply_phase ? reply_byte : rd_data;
 wire [31:0] crc32_seed=(state==PCRC) ? reply_pcrc :
                        (state==DATA_READ) ? frame_crc : packet_crc;
 wire [15:0] crc16_seed=(state==HCRC) ? reply_hcrc : header_crc;
 wire [31:0] crc32_shared=crc32_next(crc32_seed,crc_byte);
 wire [15:0] crc16_shared=crc16_next(crc16_seed,crc_byte);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;after_mem<=IDLE;frame_release<=0;rd_addr<=0;pos<=0;index<=0;packet_length<=0;
   udp_end<=0;udp_last<=0;payload_end<=0;
   ip_sum<=0;ip_high<=0;udp_sum<=0;udp_high<=0;header_crc<=16'hffff;packet_crc<=32'hffffffff;packet_tail<=0;
   remote_mac<=0;remote_ip<=0;remote_port<=0;reply_udp<=0;status<=0;
   active<=0;completed<=0;format565<=0;target1080<=0;cleanup<=0;
   cascade_session<=0;repeat_x<=0;repeat_y<=0;repeat_pixel<=0;end_crc<=0;
   ack_valid<=0;ack_source_image<=0;ack_source_arg<=0;ack_command<=0;ack_status<=0;ack_session<=0;ack_sequence<=0;
   cascade_enable<=CASCADE_SUPPORT;
   vision_request<=0;vision_request_epoch<=0;vision_request_sequence<=0;vision_request_mode<=0;
   vision_rx_valid<=0;vision_rx_session<=0;vision_rx_sequence<=0;vision_rx_payload<=0;
   active_session<=0;total_bytes<=0;received<=0;expected_seq<=0;image_id<=0;ready_id<=0;
   frame_crc<=32'hffffffff;expected_crc<=0;base<=0;write_addr<=0;last_addr<=0;op_addr<=0;
   packed_word<=0;abort_op<=0;packed_count<=0;op<=0;emit_count<=0;pixel<=0;low565<=0;
   watchdog<=0;mem_timer<=0;mem_valid<=0;tx_valid<=0;
   source_set<=0;source_value<=0;compare_set<=0;compare_value<=0;mode_set<=0;requested_mode<=0;
   reply_controls<=0;reply_displayed_id<=0;reply_index<=0;reply_hcrc<=0;reply_pcrc<=0;
   mac_dst_bytes<=0;mac_src_bytes<=0;eth_type_bytes<=0;network_bytes<=0;
   udp_bytes<=0;app_bytes<=0;begin_bytes<=0;control_arg<=0;
  end else begin
   vision_request<=0;vision_rx_valid<=0;
   frame_release<=0;source_set<=0;compare_set<=0;mode_set<=0;ack_valid<=0;
   if(active) begin
    if(watchdog==CLOCK_HZ*5-1) begin cleanup<=1;active<=0;watchdog<=0;end
    else watchdog<=watchdog+1'b1;
   end else watchdog<=0;
   if(state==WAIT_MEM && mem_ready && !mem_error)watchdog<=0;
   case(state)
    IDLE: if(cleanup && mem_ready) begin
     op<=3;op_addr<=0;abort_op<=1;after_mem<=IDLE;state<=SEND_MEM;
    end else if(frame_valid) begin
     packet_length<=frame_length;pos<=0;ip_sum<=0;ip_high<=0;udp_sum<=0;udp_high<=0;
     header_crc<=16'hffff;packet_crc<=32'hffffffff;packet_tail<=0;state<=FETCH;
    end
    FETCH: begin
     rd_addr<=pos;state<=WAIT_RAM;
     // Complete UDP/app headers are now available. Only legal UDP <=1052 and
     // app <=1024 reach DISPATCH; overflowed invalid sizes are still rejected
     // by the unchanged full-width CHECK conditions before any DDR activity.
     if(pos==42) begin udp_end<=11'd34+udp_length[10:0];udp_last<=11'd33+udp_length[10:0];end
     if(pos==58) payload_end<=11'd58+plen[10:0];
    end
    WAIT_RAM: state<=READ_RAM;
    READ_RAM: begin
     if(VISION_ROLE==1 && pos>=58 && pos<82)vision_rx_payload<={rd_data,vision_rx_payload[191:8]};
     if(pos<6) mac_dst_bytes<={rd_data,mac_dst_bytes[47:8]};
     else if(pos<12) mac_src_bytes<={rd_data,mac_src_bytes[47:8]};
     else if(pos<14) eth_type_bytes<={rd_data,eth_type_bytes[15:8]};
     else if(pos<34) network_bytes<={rd_data,network_bytes[159:8]};
     else if(pos<42) udp_bytes<={rd_data,udp_bytes[63:8]};
     else if(pos<58) app_bytes<={rd_data,app_bytes[127:8]};
     if(pos==58) control_arg<=rd_data;
     if(pos==60) ack_source_arg<=rd_data[0];
     if(command==68 && pos>=58 && pos<62)end_crc<={rd_data,end_crc[31:8]};
     if(is_begin && pos>=58 && pos<78) begin_bytes<={rd_data,begin_bytes[159:8]};
     if(pos>=14 && pos<34) begin
      if(!pos[0]) ip_high<=rd_data;else ip_sum<=ip_sum+{ip_high,rd_data};
     end
     if(pos>=34 && (pos<42 || pos<udp_end)) begin
      if(pos[0]) udp_sum<=udp_sum+{udp_high,rd_data};
      else if(pos==udp_last && pos>=42) udp_sum<=udp_sum+{rd_data,8'd0};
      else udp_high<=rd_data;
     end
     if(pos>=42 && pos<56) header_crc<=crc16_shared;
     if(pos>=42 && (pos<58 || pos<payload_end)) packet_crc<=crc32_shared;
     if(pos>=payload_end && pos>=58 && pos<payload_end+11'd4) packet_tail<={rd_data,packet_tail[31:8]};
     if(pos+1==packet_length) state<=FOLD1;else begin pos<=pos+1'b1;state<=FETCH;end
    end
    FOLD1: begin
     ip_sum<={4'd0,ip_sum[15:0]}+ip_sum[19:16];
     udp_sum<=udp_sum+{h[26],h[27]};
     state<=PSEUDO_SRC_LO;
    end
    PSEUDO_SRC_LO: begin udp_sum<=udp_sum+{h[28],h[29]};state<=PSEUDO_LOCAL;end
    PSEUDO_LOCAL: begin udp_sum<=udp_sum+PSEUDO_LOCAL_SUM;state<=PSEUDO_LENGTH;end
    PSEUDO_LENGTH: begin udp_sum<=udp_sum+udp_length;state<=FOLD2;end
    FOLD2: begin
     ip_sum<={4'd0,ip_sum[15:0]}+ip_sum[19:16];
     udp_sum<={10'd0,udp_sum[15:0]}+udp_sum[25:16];state<=CHECK;
    end
    CHECK: begin
     state<=DROP;
     if({h[12],h[13]}==16'h0806 && (destination==LOCAL_MAC || destination==48'hffffffffffff) &&
        {h[14],h[15],h[16],h[17],h[18],h[19],h[20],h[21]}==64'h0001080006040001 &&
        {h[38],h[39],h[40],h[41]}==LOCAL_IP &&
        {h[22],h[23],h[24],h[25],h[26],h[27]}==sender_mac) begin
      remote_mac<=sender_mac;remote_ip<={h[28],h[29],h[30],h[31]};remote_port<=0;
      reply_udp<=0;state<=SEND_TX;
     end else if(destination==LOCAL_MAC && {h[12],h[13]}==16'h0800 && h[14]==8'h45 &&
        ip_sum==20'h0ffff && (h[20]&8'hbf)==0 && h[21]==0 && h[23]==17 &&
        {h[30],h[31],h[32],h[33]}==LOCAL_IP && {h[36],h[37]}==LOCAL_PORT &&
        ip_length==udp_length+20 && udp_length==plen+28 && plen<=1024 &&
        packet_length>=ip_length+18 && h[42]==1 && h[44]==0 && h[45]==0 &&
        {h[57],h[56]}==header_crc && packet_tail==~packet_crc) begin
      // IPv4 permits zero UDP checksum; ordinary OS-generated nonzero UDP
      // checksums are validated including the pseudoheader and odd-byte pad.
      if({h[40],h[41]}==0 || udp_folded==17'h0ffff) begin
       remote_mac<=sender_mac;remote_ip<=sender_ip;remote_port<={h[34],h[35]};
       reply_udp<=1;status<=0;index<=0;state<=DISPATCH;
       // ACKs are consumed locally, never ACKed again (prevents reply storms).
       if(VISION_ROLE==1 && peer_packet && command==8'hc5 && plen==24)begin
        vision_rx_valid<=1;vision_rx_session<=session;vision_rx_sequence<=seq;
       end
       if(CASCADE_SUPPORT && command[7])begin
        state<=DROP;
        if(peer_packet && plen==24 && (command==8'h81 || command==8'hc2 || command==8'hc3 || command==8'hc4 || command==8'h85))begin
         ack_valid<=1;ack_source_image<=ack_source_arg;ack_command<=command;ack_session<=session;ack_sequence<=seq;ack_status<=control_arg;
        end
       end
      end
     end
    end
    DISPATCH: begin
     state<=REPLY;
     case(command)
      1: if(plen!=0) status<=4;
      69: if(VISION_ROLE!=2 || !peer_packet)status<=1;
          else if(plen!=1 || control_arg!=17)status<=4;
          else begin vision_request<=1;vision_request_epoch<=session;vision_request_sequence<=seq;vision_request_mode<=control_arg[4:0];end
      2,66: begin
       if(command==66 && !cascade_allowed)status<=1;
       else if(command==66 && cfg[4]!=1)status<=4;
       else if(plen!=20 || cfg[4]>1 || cfg[5]!=0 || cfg[6]!=0 || cfg[7]!=0) status<=4;
       else if(command==66 ? (width_in!=CASCADE_WIDTH || height_in!=CASCADE_HEIGHT) : (!begin720 && !begin1080)) status<=3;
       else if(length_in!=(command==66?CASCADE_WIDTH*CASCADE_HEIGHT*2:required_bytes)) status<=4;
       else if((active || completed) && session==active_session) begin
        if(id_in!=image_id || crc_in!=expected_crc || length_in!=total_bytes || cfg[4]!=format565 || (command==66?mode1080:begin1080)!=target1080 || (command==66)!=cascade_session) status<=2;
       end else if(active || !mem_ready) status<=7;
       else begin target1080<=command==66?mode1080:begin1080;op<=3;op_addr<=0;abort_op<=0;after_mem<=REPLY;state<=SEND_MEM;end
      end
      3,67: begin
       if(command==67 && !cascade_allowed)status<=1;
       else if((command==67)!=cascade_session)status<=2;
       else if(!active || session!=active_session) status<=2;
       else if(seq<expected_seq) status<=0;
       else if(seq!=expected_seq) status<=6;
       else if(plen==0 || plen!=(cascade_session?CASCADE_WIDTH*2:(total_bytes-received>=1024?1024:total_bytes-received))) status<=4;
       else begin index<=0;repeat_x<=0;repeat_y<=0;state<=DATA_FETCH;end
      end
      4,68: begin
       if(command==68 && !cascade_allowed)status<=1;
       else if((command==68)!=cascade_session)status<=2;
       else if(plen!=(command==68?4:0) || session!=active_session || seq!=expected_seq) status<=6;
       else if(completed) status<=0;
       else if(!active || received!=total_bytes || packed_count!=0) status<=2;
       else if(~frame_crc!=(cascade_session?end_crc:expected_crc)) begin status<=5;active<=0;cleanup<=1;end
       else begin op<=1;op_addr<=last_addr;after_mem<=REPLY;state<=SEND_MEM;end
      end
      5: if(plen!=0) status<=4;else if(session!=active_session) status<=2;
         else if(active) begin active<=0;cleanup<=1;end
      6: if(plen!=1 || cfg[0]>1) status<=4;else begin source_set<=1;source_value<=cfg[0][0];end
      7: if(plen!=1 || cfg[0]>MAX_MODE) status<=4;else begin mode_set<=1;requested_mode<=cfg[0][4:0];end
      8: if(plen!=1 || cfg[0]>2) status<=4;else begin compare_set<=1;compare_value<=cfg[0][1:0];end
      10: if(plen!=0) status<=4;
      12: if(!CASCADE_SUPPORT)status<=1;
          else if(plen!=1 || cfg[0]>1)status<=4;
          else cascade_enable<=cfg[0][0];
      default: status<=1;
     endcase
    end
    DATA_FETCH: begin rd_addr<=58+index;state<=DATA_WAIT;end
    DATA_WAIT: state<=DATA_READ;
    DATA_READ: begin
     if(!cascade_session || repeat_y==0)frame_crc<=crc32_shared;
     if(!format565) begin pixel<={rd_data,16'd0};emit_count<=1;state<=EMIT;end
     else if(!index[0]) begin low565<=rd_data;index<=index+1'b1;state<=DATA_FETCH;end
     else begin pixel<=expanded565;repeat_pixel<=expanded565;emit_count<=3;state<=EMIT;end
    end
    EMIT: begin
     packed_word<={packed_word[119:0],pixel[23:16]};packed_count<=packed_count+1'b1;
     pixel<={pixel[15:0],8'd0};emit_count<=emit_count-1'b1;
     if(emit_count==1) begin
      if(cascade_session && repeat_x+1<scale)begin
       repeat_x<=repeat_x+1'b1;pixel<=repeat_pixel;emit_count<=3;state<=EMIT;
      end else begin
       repeat_x<=0;
       if(index+1==plen)begin
        if(cascade_session && repeat_y+1<scale)begin repeat_y<=repeat_y+1'b1;index<=0;state<=DATA_FETCH;end
        else begin received<=received+plen;expected_seq<=expected_seq+1'b1;state<=REPLY;end
       end else begin index<=index+1'b1;state<=DATA_FETCH;end
      end
     end
     if(packed_count==15) begin
      op<=0;op_addr<=write_addr;
      last_addr<=write_addr;write_addr<=write_addr+8;
      after_mem<=emit_count!=1 || (cascade_session && repeat_x+1<scale)?EMIT:
       index+1==plen && !(cascade_session && repeat_y+1<scale)?REPLY:DATA_FETCH;state<=SEND_MEM;
     end
    end
    SEND_MEM: if(mem_ready) begin mem_valid<=1;mem_timer<=0;state<=ACCEPT_MEM;end
    ACCEPT_MEM: begin mem_valid<=0;state<=WAIT_MEM;end
    WAIT_MEM: if(mem_ready) begin
     if(mem_error) begin
      status<=mem_reply[7:0];state<=after_mem;
      if(op!=3) begin active<=0;cleanup<=1;state<=REPLY;end
     end else if(op==1) begin op<=2;op_addr<=base;state<=SEND_MEM;end
     else if(op==2) begin active<=0;completed<=1;ready_id<=image_id;state<=REPLY;end
     else if(op==3 && op_data[7:0]==0) begin
      active<=1;completed<=0;format565<=cfg[4][0];cascade_session<=command==66;active_session<=session;total_bytes<=length_in;
      received<=0;expected_seq<=0;frame_crc<=32'hffffffff;expected_crc<=crc_in;image_id<=id_in;
      packed_count<=0;packed_word<=0;base<=mem_reply[32:8];write_addr<=mem_reply[32:8];state<=after_mem;
     end else begin cleanup<=0;state<=after_mem;end
    end else if(mem_timer==CLOCK_HZ-1) begin active<=0;status<=8;cleanup<=1;state<=REPLY;end
         else mem_timer<=mem_timer+1'b1;
    REPLY: begin
     reply_controls<={front_valid,current_mode,compare_mode,source_image,mode1080};
     reply_displayed_id<=displayed_id;
     reply_index<=0;reply_hcrc<=16'hffff;state<=HCRC;
    end
    HCRC: begin
     reply_hcrc<=crc16_shared;
     if(reply_index==13) begin
      reply_index<=0;reply_pcrc<=32'hffffffff;state<=PCRC;
     end else reply_index<=reply_index+1'b1;
    end
    PCRC: begin
     reply_pcrc<=crc32_shared;
     if(reply_index==39) begin
      state<=SEND_TX;
     end else reply_index<=reply_index+1'b1;
    end
    SEND_TX: if(tx_ready) begin
     tx_valid<=1;state<=ACCEPT_TX;
    end
    ACCEPT_TX: begin tx_valid<=0;state<=WAIT_TX;end
    WAIT_TX: if(tx_ready) begin frame_release<=1;state<=DROP;end
    DROP: begin if(!frame_release) frame_release<=1;else state<=IDLE;end
    default: state<=IDLE;
   endcase
   // Resolution changes invalidate only an unfinished cascade upload. Wait
   // for any accepted DDR command to finish; preserve bundled CDC/TX data.
   if(CASCADE_SUPPORT && cascade_session && active && mode1080!=target1080 &&
      (state==IDLE || state==DISPATCH || state==DATA_FETCH || state==DATA_WAIT ||
       state==DATA_READ || state==EMIT || state==REPLY))begin
    active<=0;cleanup<=1;packed_count<=0;status<=2;
    state<=state==IDLE?IDLE:REPLY;
   end
  end
 end
endmodule
