`timescale 1ns/1ps
// Low-speed transaction engine. The command mailbox is acknowledged only
// after the DDR-side operation completes, including fence and frame commit.
module uart_image_control #(
 parameter MAX_MODE=16,
 parameter CLOCK_HZ=100000000, parameter W720=1280,H720=720,W1080=1920,H1080=1080,
 parameter KEY_BITS=21, parameter EXTERNAL_CONTROLS=0, parameter CASCADE_VIEW_SUPPORT=0
)(
 input wire clk,rst_n,uart_rx,output wire uart_tx,
 input wire mode1080,path_run,key1_n,
 input wire cascade_view,
 input wire front_valid,input wire [31:0] displayed_id,
 output wire source_uart,output reg [1:0] compare_mode,
 output reg mode_set,output reg [4:0] requested_mode,input wire [4:0] current_mode,
 output wire [155:0] mem_data,output reg mem_valid,input wire mem_ready,input wire mem_error,
 input wire [383:0] mem_reply,
 output wire [31:0] image_id_status,
 input wire external_source_set,external_source_value,external_compare_set,
 input wire [1:0] external_compare_value
);
 // Keep original source intent while SW2 overrides the effective display.
 reg source_intent;
 reg cascade_view_previous;
 assign source_uart = CASCADE_VIEW_SUPPORT ? (source_intent | cascade_view) : source_intent;
 localparam HELLO=1,BEGIN_IMG=2,DATA=3,END_IMG=4,ABORT_IMG=5,SOURCE=6,MODE=7,COMPARE=8,BAUD=9,STATUS_EXT=10,CAPS=11;
 localparam IDLE=0,FETCH=1,WAIT_RAM=2,READ_RAM=3,DISPATCH=4,DATA_FETCH=5,DATA_WAIT=6,DATA_READ=7,
  EMIT=8,SEND_MEM=9,WAIT_ACCEPT=10,WAIT_MEM=11,RESPOND=12,WAIT_TX=13,BAUD_WAIT=14;
 reg [4:0] state,after_mem;
 reg [15:0] divider;reg fast_baud;reg [1:0] pending_baud;
 wire [7:0] rb,tb;wire rv,re,tv,tr;
 uart_link link(.clk(clk),.rst_n(rst_n),.rx(uart_rx),.divider(divider),.rx_data(rb),.rx_valid(rv),.rx_error(re),
  .tx_data(tb),.tx_valid(tv),.tx_ready(tr),.tx(uart_tx));
 wire pv,pe;reg release_packet;wire [7:0] cmd,flags;wire [31:0] session,seq,pcrc;
 wire [15:0] plen;reg [10:0] raddr;wire [7:0] rdata;
 uart_packet_rx #(.TIMEOUT_CYCLES(CLOCK_HZ/2)) parser(.clk(clk),.rst_n(rst_n),.byte_data(rb),.byte_valid(rv),.byte_error(re),
  .packet_valid(pv),.packet_release(release_packet),.packet_error(pe),.command(cmd),.flags(flags),
  .session(session),.packet_sequence(seq),.length(plen),.packet_crc(pcrc),.rd_addr(raddr),.rd_data(rdata));
 reg tx_start;wire tx_ready;reg [191:0] response;reg [41:0] reply_controls;
 uart_packet_tx reply(.clk(clk),.rst_n(rst_n),.start(tx_start),.command(cmd),.session(session),.packet_sequence(seq),
  .payload(response),.ready(tx_ready),.byte_data(tb),.byte_valid(tv),.byte_ready(tr));
 reg [7:0] cfg_bytes[0:19];reg [10:0] index;
 reg active,completed,format565,release_pending,op_mode;
 reg window8,new_data;
 reg [24:0] upload_base;
 reg [31:0] ready_image_id;
 reg [383:0] snapshot;
 reg [127:0] snapshot_upload;
 localparam IDLE_TIMER_BITS=$clog2(CLOCK_HZ*5+1);
 localparam MEM_TIMER_BITS=$clog2(CLOCK_HZ+1);
 localparam BAUD_TIMER_BITS=$clog2(CLOCK_HZ/100+1);
 reg [31:0] snapshot_token;
 reg [IDLE_TIMER_BITS-1:0] snapshot_timer;
 reg snapshot_valid;
 reg [31:0] active_session,total_bytes,received,expected_seq,frame_crc,expected_crc,image_id,last_crc,last_seq;
 reg [15:0] last_len;reg [7:0] status;
 reg [127:0] packed_word;reg [3:0] packed_count;
 reg [24:0] write_addr,last_addr,op_addr;reg [8:0] op_control;reg [1:0] op;
 wire [127:0] op_data=(op==0 || op==1)?packed_word:
  op==2?{96'd0,image_id}:{119'd0,op_control};
 reg [23:0] pixel;reg [1:0] emit_count;reg [7:0] low565;
 // Size timers to their actual limits; do not spend 32 FFs per short timer.
 reg [IDLE_TIMER_BITS-1:0] watchdog;
 reg [BAUD_TIMER_BITS-1:0] baud_timer;
 reg [MEM_TIMER_BITS-1:0] mem_timer;reg old_mode;
 reg [1:0] keys;reg key_stable,key_previous;reg [KEY_BITS-1:0] key_count;
 // The packed pixel word is frozen while a DDR command is outstanding.
 assign mem_data={op_mode,op,op_addr,op_data};
 assign image_id_status=ready_image_id;
 wire [15:0] width_in={cfg_bytes[1],cfg_bytes[0]},height_in={cfg_bytes[3],cfg_bytes[2]};
 wire [31:0] length_in={cfg_bytes[11],cfg_bytes[10],cfg_bytes[9],cfg_bytes[8]};
 wire [31:0] id_in={cfg_bytes[15],cfg_bytes[14],cfg_bytes[13],cfg_bytes[12]};
 wire [31:0] crc_in={cfg_bytes[19],cfg_bytes[18],cfg_bytes[17],cfg_bytes[16]};
 wire begin1080=width_in==W1080 && height_in==H1080;
 wire begin720=width_in==W720 && height_in==H720;
 wire [31:0] request_token={cfg_bytes[4],cfg_bytes[3],cfg_bytes[2],cfg_bytes[1]};
 wire [31:0] required_bytes=begin1080 ? (cfg_bytes[4]==1 ? W1080*H1080*2:W1080*H1080*3) :
                                                    (cfg_bytes[4]==1 ? W720*H720*2:W720*H720*3);
 wire [15:0] rgb565={rdata,low565};
 wire [23:0] expanded565={rgb565[15:11],rgb565[15:13],rgb565[10:5],rgb565[10:9],rgb565[4:0],rgb565[4:2]};
 wire [7:0] emit_byte=pixel[23:16];
 function [31:0] crc_next;
 input [31:0] c;input [7:0] d;integer i;reg [31:0] v;
 begin v=c^{24'd0,d};for(i=0;i<8;i=i+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_next=v;end
 endfunction
 // Avoid a second 192-bit ACK copy. The serializer still owns a full
 // immutable response, including when Window8 releases this packet early.
 always @*begin
     response={8'd0,{7'd0,reply_controls[41]},{7'd0,fast_baud},{3'd0,reply_controls[40:36]},reply_controls[35:4],
                ready_image_id,received,expected_seq,{6'd0,reply_controls[3:2]},{7'd0,reply_controls[1]},{7'd0,reply_controls[0]},status};
     // Fixed CAPS v1: error, 15 reserved zero bytes, "ANW8", 1, 0, 1, 8.
     if(cmd==CAPS) response={8'd8,8'd1,8'd0,8'd1,32'h38574e41,96'd0,24'd0,status};
     if(cmd==STATUS_EXT) begin
      case(cfg_bytes[0])
       0: response={snapshot[127:0],request_token,8'd0,cfg_bytes[0],8'd2,status};
       1: response={snapshot[255:128],request_token,8'd0,cfg_bytes[0],8'd2,status};
       2: response={snapshot[383:256],request_token,8'd0,cfg_bytes[0],8'd2,status};
       default: response={snapshot_upload,request_token,8'd0,cfg_bytes[0],8'd2,status};
      endcase
     end
 end
 integer k;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;after_mem<=IDLE;divider<=(CLOCK_HZ+57600)/115200;fast_baud<=0;pending_baud<=0;
   release_packet<=0;tx_start<=0;reply_controls<=0;raddr<=0;index<=0;active<=0;completed<=0;
   format565<=0;release_pending<=0;op_mode<=0;upload_base<=0;ready_image_id<=0;window8<=0;new_data<=0;
   snapshot<=0;snapshot_upload<=0;snapshot_token<=0;snapshot_valid<=0;snapshot_timer<=0;
   active_session<=0;total_bytes<=0;received<=0;
   expected_seq<=0;frame_crc<=32'hffffffff;expected_crc<=0;image_id<=0;last_crc<=0;last_seq<=32'hffffffff;last_len<=0;
   packed_word<=0;packed_count<=0;write_addr<=0;last_addr<=0;op_addr<=0;op_control<=0;op<=0;
   pixel<=0;emit_count<=0;low565<=0;status<=0;watchdog<=0;baud_timer<=0;mem_timer<=0;old_mode<=0;
   mem_valid<=0;source_intent<=0;cascade_view_previous<=0;compare_mode<=0;mode_set<=0;requested_mode<=0;
   keys<=3;key_stable<=1;key_previous<=1;key_count<=0;
   for(k=0;k<20;k=k+1) cfg_bytes[k]<=0;
  end else begin
   release_packet<=0;tx_start<=0;mode_set<=0;cascade_view_previous<=cascade_view;
   // FETCH already precedes every consumed RAM byte by two clocks.
   // An unconditional address register avoids command-dependent clock enable.
   raddr<=index;
   keys<={keys[0],key1_n};key_previous<=key_stable;
   if(keys[1]==key_stable) key_count<=0;
   else if(&key_count) begin key_stable<=keys[1];key_count<=0;end
   else key_count<=key_count+1;
   if(key_previous && !key_stable) source_intent<=~source_intent;
   if(snapshot_valid) begin
    if(snapshot_timer==CLOCK_HZ*5-1) snapshot_valid<=0;
    else snapshot_timer<=snapshot_timer+1;
   end
   if(state==IDLE && !pv) begin
    if(watchdog<CLOCK_HZ*5) watchdog<=watchdog+1;
    else if(active || fast_baud) begin
     if(active) release_pending<=1;
     active<=0;fast_baud<=0;divider<=(CLOCK_HZ+57600)/115200;
    end
   end else watchdog<=0;
   case(state)
    IDLE: if(release_pending && mem_ready) begin
     op<=3;op_control<=1;op_addr<=0;after_mem<=IDLE;release_pending<=0;state<=SEND_MEM;
    end else if(pv && !release_packet && (tx_ready || window8)) begin
     status<=0;index<=0;new_data<=0;
     if(cmd==DATA) state<=DISPATCH;
     else if(plen==0) state<=DISPATCH;
     else if(plen<=20) state<=FETCH;
     else begin status<=4;state<=RESPOND;end
    end
    FETCH: begin state<=WAIT_RAM;end
    WAIT_RAM: state<=READ_RAM;
    READ_RAM: begin cfg_bytes[index]<=rdata;if(index+1==plen) state<=DISPATCH;else begin index<=index+1;state<=FETCH;end end
    DISPATCH: begin
     state<=RESPOND;
     case(cmd)
      HELLO: if(plen!=0) status<=4;
      CAPS: if(plen!=0 || flags!=0) status<=4;
      BEGIN_IMG: begin
       if(plen!=20 || cfg_bytes[4]>1 || cfg_bytes[5]!=0 || cfg_bytes[6]!=0 || cfg_bytes[7]!=0 || flags[7:2]!=0 || flags[1:0]==3) status<=4;
       else if(!mem_ready || release_pending) status<=7;
       else if(!begin720 && !begin1080) status<=3;
       else if(length_in!=required_bytes) status<=4;
       else if((active || completed) && session==active_session) begin
        if(id_in!=image_id || crc_in!=expected_crc || length_in!=total_bytes || cfg_bytes[4]!=format565 || begin1080!=old_mode || flags[1]!=window8) status<=2;
       end else if(active) status<=7;
       else begin
        op<=3;op_mode<=begin1080;op_addr<=0;op_control<={cfg_bytes[4][0],8'd0};
        after_mem<=RESPOND;state<=SEND_MEM;
       end
      end
      DATA: begin
       if(!active || session!=active_session) status<=2;
       else if((window8 && flags!=2) || (!window8 && flags[7:1]!=0)) status<=4;
       // Discard already committed packets; reply with the contiguous frontier.
       else if(window8 && seq<expected_seq) status<=0;
       else if(seq==last_seq && plen==last_len && pcrc==last_crc) status<=0;
       else if(seq!=expected_seq) status<=6;
       else if(plen==0 || plen>1536 || plen!=(total_bytes-received>=1536 ? 1536:total_bytes-received)) status<=4;
       else begin index<=0;new_data<=1;state<=DATA_FETCH;end
      end
      END_IMG: begin
       if(plen!=0 || seq!=expected_seq || session!=active_session) status<=6;
       else if(completed) status<=0;
       else if(!active || received!=total_bytes || packed_count!=0) status<=2;
       else if(~frame_crc!=expected_crc) begin status<=5;active<=0;release_pending<=1;end
       else begin op<=1;op_mode<=old_mode;op_addr<=last_addr;after_mem<=RESPOND;state<=SEND_MEM;end
      end
      ABORT_IMG: if(plen!=0) status<=4;
                 else if(session!=active_session) status<=2;
                 else if(active) begin active<=0;release_pending<=1;end
      SOURCE: if(plen!=1 || cfg_bytes[0]>1) status<=4;else source_intent<=cfg_bytes[0][0];
      MODE: if(plen!=1 || cfg_bytes[0]>MAX_MODE) status<=4;else begin requested_mode<=cfg_bytes[0][4:0];mode_set<=1;end
      COMPARE: if(plen!=1 || cfg_bytes[0]>2) status<=4;else compare_mode<=cfg_bytes[0][1:0];
      BAUD: if(plen!=1 || cfg_bytes[0]>3 || active || flags!=0) status<=4;else pending_baud<=cfg_bytes[0][1:0];
      STATUS_EXT: begin
       if(plen!=5 || cfg_bytes[0]>3 || flags!=0) status<=4;
       else if(snapshot_valid && request_token==snapshot_token) snapshot_timer<=0;
       else if(cfg_bytes[0]!=0) status<=2;
       else if(!mem_ready || release_pending) status<=7;
       else begin
        snapshot_token<=request_token;snapshot_valid<=0;op<=3;op_control<=2;op_addr<=0;
        after_mem<=RESPOND;state<=SEND_MEM;
       end
      end
      default: status<=1;
     endcase
    end
    DATA_FETCH: begin state<=DATA_WAIT;end
    DATA_WAIT: state<=DATA_READ;
    DATA_READ: begin
     frame_crc<=crc_next(frame_crc,rdata);
     if(!format565) begin pixel<={rdata,16'd0};emit_count<=1;state<=EMIT;end
     else if(!index[0]) begin low565<=rdata;index<=index+1;state<=DATA_FETCH;end
     else begin pixel<=expanded565;emit_count<=3;state<=EMIT;end
    end
    EMIT: begin
     packed_word<={packed_word[119:0],emit_byte};packed_count<=packed_count+1;
     pixel<={pixel[15:0],8'd0};emit_count<=emit_count-1;
     if(emit_count==1) begin
      if(index+1==plen) begin
       received<=received+plen;expected_seq<=expected_seq+1;last_seq<=seq;last_len<=plen;last_crc<=pcrc;
       state<=RESPOND;
      end else begin index<=index+1;state<=DATA_FETCH;end
     end
     if(packed_count==15) begin
      op<=0;op_mode<=old_mode;op_addr<=write_addr;
      last_addr<=write_addr;write_addr<=write_addr+8;
      state<=SEND_MEM;
      after_mem<=emit_count!=1 ? EMIT : index+1==plen ? RESPOND:DATA_FETCH;
     end
    end
    SEND_MEM: if(mem_ready) begin mem_valid<=1;mem_timer<=0;state<=WAIT_ACCEPT;end
    WAIT_ACCEPT: begin mem_valid<=0;state<=WAIT_MEM;end
    WAIT_MEM: if(mem_ready) begin
     if(mem_error) begin
      status<=mem_reply[7:0];state<=after_mem;
      if(op!=3) begin active<=0;release_pending<=1;state<=RESPOND;end
     end
     else if(op==1) begin
      op<=2;op_addr<=upload_base;state<=SEND_MEM;
     end else if(op==2) begin
      active<=0;completed<=1;ready_image_id<=image_id;state<=RESPOND;
     end else if(op==3 && op_data[7:0]==0) begin
      active<=1;completed<=0;format565<=cfg_bytes[4][0];old_mode<=op_mode;window8<=flags[1];
      active_session<=session;total_bytes<=length_in;received<=0;expected_seq<=0;frame_crc<=32'hffffffff;
      expected_crc<=crc_in;image_id<=id_in;last_seq<=32'hffffffff;packed_count<=0;packed_word<=0;
      upload_base<=mem_reply[32:8];write_addr<=mem_reply[32:8];state<=after_mem;
     end else if(op==3 && op_data[7:0]==2) begin
      snapshot<=mem_reply;snapshot[15:8]<={7'd0,source_uart};snapshot[39:32]<={3'd0,current_mode};
      snapshot_upload<={expected_seq,received,active_session,{7'd0,active},{7'd0,format565},{7'd0,old_mode},{7'd0,active}};
      snapshot_valid<=1;snapshot_timer<=0;state<=after_mem;
     end else state<=after_mem;
    end else if(mem_timer==CLOCK_HZ-1) begin
     // Do not recycle the outstanding mailbox after a timeout. BEGIN remains
     // BUSY until it drains. Commit operations cannot be cancelled mid-boundary.
     active<=0;status<=8;release_pending<=1;state<=RESPOND;
    end else mem_timer<=mem_timer+1;
    RESPOND: begin
     // status,resolution,requested source,compare,next seq,bytes,image,displayed,
     // requested algorithm,baud,front valid,reserved (all multibyte fields LE).
     // Only asynchronous/live display controls need a snapshot here.
     // FSM fields and STATUS_EXT snapshot stay stable until the next edge,
     // when uart_packet_tx snapshots the complete payload into its own body.
     reply_controls<={front_valid,current_mode,displayed_id,compare_mode,source_uart,mode1080};
     if(flags[0]) begin release_packet<=1;state<=IDLE;end
     else if(cmd==DATA && window8 && status==0 && new_data &&
             expected_seq[2:0]!=0 && received!=total_bytes) begin
      release_packet<=1;state<=IDLE;
     end else if(tx_ready) begin
      tx_start<=1;
      // TX snapshots header/payload on the same edge that releases this bank.
      if(cmd==DATA && window8) begin release_packet<=1;state<=IDLE;end
      else state<=WAIT_TX;
     end
    end
    WAIT_TX: if(tx_ready && !tx_start) begin
     release_packet<=1;
     if(cmd==BAUD && status==0) begin baud_timer<=0;state<=BAUD_WAIT;end else state<=IDLE;
    end
    BAUD_WAIT: if(baud_timer==CLOCK_HZ/100-1) begin
     // Constant divisors: no run-time divider, no additional image storage.
     // ACK is completely transmitted at the OLD rate before this guard time.
     case(pending_baud)
      0: divider<=(CLOCK_HZ+57600)/115200;
      1: divider<=(CLOCK_HZ+460800)/921600;
      2: divider<=(CLOCK_HZ+1000000)/2000000;
      3: divider<=(CLOCK_HZ+1500000)/3000000;
     endcase
     fast_baud<=(pending_baud!=0);state<=IDLE;
    end else baud_timer<=baud_timer+1;
    default: state<=IDLE;
   endcase
   // Optional Ethernet controls share the existing persistent registers.
   // Legacy builds leave EXTERNAL_CONTROLS=0, including unconnected new ports.
   if(EXTERNAL_CONTROLS && external_source_set) source_intent<=external_source_value;
   // SW2 is a board-view selector: leaving peer view always returns CAMERA.
   // Subsequent KEY1/UART/ETH commands can still select a static IMAGE.
   if(CASCADE_VIEW_SUPPORT && cascade_view_previous && !cascade_view) source_intent<=0;
   if(EXTERNAL_CONTROLS && external_compare_set) compare_mode<=external_compare_value;
   // Display reset/resolution never owns upload or persistent source intent.
  end
 end
endmodule
