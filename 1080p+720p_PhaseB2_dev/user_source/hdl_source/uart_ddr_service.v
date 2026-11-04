`timescale 1ns/1ps
// One upload, two published descriptors, four protected slots.
// cmd_reply is bundled return data: set before ACK, held until the next command.
module uart_ddr_service #(
 parameter COMPACT_SUPPORT=0,PREVIEW_WIDTH=320,PREVIEW_HEIGHT=180,W720=1280,H720=720,W1080=1920,H1080=1080
)(
 input wire clk,rst_n,mode1080,path_run,
 input wire [155:0] cmd_data,input wire cmd_valid,output wire cmd_ready,output reg cmd_error,
 output reg [383:0] cmd_reply,
 input wire camera_busy,camera_write,video_busy,video_read,
 input wire user_ready,queue_empty,input wire rd_valid,input wire [127:0] rd_data,
 input wire frame_window,frame_boundary,
 input wire reader_ref_valid,input wire [24:0] reader_ref_base,
 input wire [127:0] display_status,
 output wire hold_frame,lock_bus,wr_en,rd_en,
 output wire [24:0] addr,output wire [127:0] wr_data,output wire fence_response,
 output wire front_valid,output wire front_preview,output wire [24:0] front_addr,
 output wire [31:0] front_id,front_generation
);
 localparam [24:0] A720=25'd3200000,B720=25'd4600000,A1080=25'd25000000,B1080=25'd29000000;
 localparam [15:0] WIDTH720=W720,HEIGHT720=H720,WIDTH1080=W1080,HEIGHT1080=H1080;
 wire cmode=cmd_data[155];wire [1:0] op=cmd_data[154:153];
 wire [24:0] ca=cmd_data[152:128];wire [127:0] cd=cmd_data[127:0];
 reg [2:0] state;
 reg [1:0] valid,front_slot,formats,previews;
 reg [31:0] generation[0:1],image_id[0:1];
 reg allocated,target_mode,target_slot,target_format,target_preview,fenced;
 reg [24:0] next_addr,allocated_base;
 reg [18:0] written;
 wire [18:0] total_beats=target_preview?PREVIEW_WIDTH*PREVIEW_HEIGHT*3/16:target_mode?W1080*H1080*3/16:W720*H720*3/16;
 function [24:0] slot_base(input mode,input slot);
  begin slot_base=mode?(slot?B1080:A1080):(slot?B720:A720);end
 endfunction
 wire idle_bus=!camera_busy && !camera_write && !video_busy && !video_read;
 wire blocked_a=(valid[cmode] && !front_slot[cmode]) ||
                (reader_ref_valid && reader_ref_base==slot_base(cmode,1'b0));
 wire blocked_b=(valid[cmode] && front_slot[cmode]) ||
                (reader_ref_valid && reader_ref_base==slot_base(cmode,1'b1));
 wire choose_slot=blocked_a;
 wire allocation_ok=!allocated && !(blocked_a && blocked_b);
 wire write_ok=allocated && cmode==target_mode && written<total_beats &&
               ca==next_addr && ca[2:0]==0 &&
               !(reader_ref_valid && reader_ref_base==allocated_base) &&
               !(valid[target_mode] && front_slot[target_mode]==target_slot);
 wire fence_ok=allocated && cmode==target_mode && written==total_beats && ca==next_addr-8;
 wire publish_ok=allocated && cmode==target_mode && fenced && ca==allocated_base;
 assign wr_en=cmd_valid && op==0 && write_ok && state==0 && idle_bus && user_ready;
 assign rd_en=(state==2) && user_ready;
 assign addr=ca;assign wr_data=cd;
 assign hold_frame=cmd_valid && op==1 && fence_ok;
 assign lock_bus=(state!=0);
 assign fence_response=(state==3) && rd_valid;
 assign cmd_ready=cmd_valid && ((op==0 && state==0 && (!write_ok || wr_en)) ||
                   (op==1 && ((!fence_ok && state==0) || state==4)) ||
                   ((op==2 || op==3) && state==0));
 assign front_valid=valid[mode1080];
 assign front_preview=COMPACT_SUPPORT && previews[mode1080];
 assign front_addr=slot_base(mode1080,front_slot[mode1080]);
 assign front_id=image_id[mode1080];assign front_generation=generation[mode1080];
 // All state dependencies are explicit function inputs. Constant mode/slot
 // arguments alone can leave status stale in event-driven simulators.
 function [3:0] slot_state(input is_front,input is_allocated,input is_fenced,input is_referenced);
  begin
   if(is_front) slot_state=4;
   else if(is_allocated) slot_state=is_fenced?3:1;
   else if(is_referenced) slot_state=5;
   else slot_state=0;
  end
 endfunction
 wire [127:0] page720={HEIGHT720,WIDTH720,image_id[0],generation[0],
     {7'd0,formats[0]},
     slot_state(valid[0] && front_slot[0],allocated && !target_mode && target_slot,fenced,reader_ref_valid && reader_ref_base==B720),
     slot_state(valid[0] && !front_slot[0],allocated && !target_mode && !target_slot,fenced,reader_ref_valid && reader_ref_base==A720),
     {7'd0,front_slot[0]},{7'd0,valid[0]}};
 wire [127:0] page1080={HEIGHT1080,WIDTH1080,image_id[1],generation[1],
     {7'd0,formats[1]},
     slot_state(valid[1] && front_slot[1],allocated && target_mode && target_slot,fenced,reader_ref_valid && reader_ref_base==B1080),
     slot_state(valid[1] && !front_slot[1],allocated && target_mode && !target_slot,fenced,reader_ref_valid && reader_ref_base==A1080),
     {7'd0,front_slot[1]},{7'd0,valid[1]}};
 integer i;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=0;cmd_error<=0;cmd_reply<=0;valid<=0;front_slot<=0;formats<=0;previews<=0;
   allocated<=0;target_mode<=0;target_slot<=0;target_format<=0;target_preview<=0;fenced<=0;
   next_addr<=0;allocated_base<=0;written<=0;
   for(i=0;i<2;i=i+1) begin generation[i]<=0;image_id[i]<=0;end
  end else begin
   if(cmd_valid && state==0) begin
    if(op==0 && cmd_ready) begin
     cmd_error<=!write_ok;cmd_reply<=write_ok?384'd0:384'd8;
     if(wr_en) begin next_addr<=next_addr+8;written<=written+1'b1;fenced<=0;end
    end
    if(op==1 && !fence_ok) begin cmd_error<=1;cmd_reply<=8;end
    if(op==2) begin
     cmd_error<=!publish_ok;cmd_reply<=publish_ok?384'd0:384'd8;
     if(publish_ok) begin
      valid[target_mode]<=1;front_slot[target_mode]<=target_slot;formats[target_mode]<=target_format;previews[target_mode]<=target_preview;
      generation[target_mode]<=generation[target_mode]+1'b1;image_id[target_mode]<=cd[31:0];
      allocated<=0;fenced<=0;
     end
    end
    if(op==3) begin
     cmd_error<=0;cmd_reply<=0;
     case(cd[7:0])
      0: begin
       if(!allocation_ok) begin cmd_error<=1;cmd_reply<=7;end
       else begin
        allocated<=1;target_mode<=cmode;target_slot<=choose_slot;target_format<=cd[8];target_preview<=COMPACT_SUPPORT && cd[9];
        allocated_base<=slot_base(cmode,choose_slot);next_addr<=slot_base(cmode,choose_slot);
        written<=0;fenced<=0;cmd_reply<={351'd0,slot_base(cmode,choose_slot),8'd0};
       end
      end
      1: begin allocated<=0;fenced<=0;end
      2: cmd_reply<={page1080,page720,display_status};
      default: begin cmd_error<=1;cmd_reply<=4;end
     endcase
    end
   end
   case(state)
    0: if(cmd_valid && op==1 && fence_ok && frame_window && idle_bus) begin
     state<=1;cmd_error<=0;cmd_reply<=0;
    end
    1: if(queue_empty) state<=2;
    2: if(rd_en) state<=3;
    3: if(rd_valid) begin
     fenced<=(rd_data==cd);cmd_error<=(rd_data!=cd);cmd_reply<=(rd_data==cd)?384'd0:384'd8;state<=4;
    end
    4: state<=0;
    default: state<=0;
   endcase
  end
 end
endmodule
