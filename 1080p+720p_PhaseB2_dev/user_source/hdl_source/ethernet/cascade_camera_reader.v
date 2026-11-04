`timescale 1ns/1ps
// DDR-domain single-beat snapshot reader. cmd_ready acknowledges COMPLETION,
// including returned data, so reply is bundled with the mailbox acknowledgement.
module cascade_camera_reader(
 input wire clk,rst_n,path_run,mode1080,
 input wire [1:0] camera_bank,input wire camera_safe,camera_busy,camera_write,video_busy,video_read,
 input wire video_drained,upload_lock,user_ready,queue_empty,rd_valid,
 input wire [127:0] rd_data,input wire [26:0] cmd,input wire cmd_valid,
 output wire cmd_ready,output reg [127:0] reply,
 output reg lease_valid,output reg [1:0] lease_bank,
 output wire lock_bus,rd_en,response_owned,output wire [24:0] rd_addr
);
 localparam IDLE=0,WAIT_BUS=1,ISSUE=2,WAIT_DATA=3,DONE=4;
 reg [2:0] state; reg [24:0] request_addr,lease_base;reg lease_mode;
 wire [1:0] op=cmd[26:25];
 function [24:0] bank_base(input [1:0] bank);
  begin case(bank) 0:bank_base=0;1:bank_base=7000000;
   2:bank_base=14000000;3:bank_base=21000000;endcase end
 endfunction
 wire allowed=lease_valid && path_run && mode1080==lease_mode &&
  cmd[24:0]>=lease_base && cmd[24:0]<lease_base+(lease_mode?25'd3110400:25'd1382400) && cmd[2:0]==0;
 assign cmd_ready=(state==DONE);
 assign lock_bus=(state==ISSUE || state==WAIT_DATA);
 assign rd_en=(state==ISSUE) && user_ready;
 assign response_owned=(state==WAIT_DATA);
 assign rd_addr=request_addr;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;lease_valid<=0;lease_bank<=0;lease_base<=0;lease_mode<=0;reply<=0;request_addr<=0;end
  else begin
   if(!path_run || mode1080!=lease_mode)lease_valid<=0;
   case(state)
    IDLE: if(cmd_valid) begin
     if(op==0)begin
      lease_valid<=path_run && camera_safe;lease_bank<=camera_bank;lease_base<=bank_base(camera_bank);lease_mode<=mode1080;
      reply<={101'd0,!(path_run && camera_safe),mode1080,bank_base(camera_bank)};state<=DONE;
     end else if(op==2)begin lease_valid<=0;reply<=0;state<=DONE;end
     else if(op!=1 || !allowed)begin reply<={1'b1,127'd0};state<=DONE;end
     else begin request_addr<=cmd[24:0];state<=WAIT_BUS;end
    end
    WAIT_BUS: if(!path_run || mode1080!=lease_mode)begin reply<={1'b1,127'd0};state<=DONE;end
     else if(!camera_busy && !camera_write && !video_busy && !video_read && video_drained && !upload_lock && queue_empty)state<=ISSUE;
    ISSUE: if(rd_en)state<=WAIT_DATA;
    WAIT_DATA: if(rd_valid)begin reply<=rd_data;state<=DONE;end
    DONE: state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
