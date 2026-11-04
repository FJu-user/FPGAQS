`timescale 1ns/1ps
// B analyses only complete, NEW A-preview images at fixed 1280x720. It never
// analyses B's camera or PC static images. Keep the imported detector intact.
module mode17_vision_engine #(
 parameter integer P_SERVO_USB_DIAG=0
)(
 input wire clk,rst_n,enable,input wire [31:0] control_epoch,
 input wire [23:0] rgb,input wire de,hs,vs,input wire preview_source,
 input wire [31:0] image_id,generation,
 output reg [255:0] objects,output reg [3:0] count,output reg overflow,valid,
 output reg [31:0] source_id,result_epoch,
 output reg [95:0] diagnostic);
 wire [11:0] x,y;wire fs,fe,ls,le;
 video_stream_context u_context(.I_clk(clk),.I_rst_n(rst_n),.I_active_width(12'd1280),.I_active_height(12'd720),
  .I_de(de),.I_vs(vs),.O_x(x),.O_y(y),.O_frame_start(fs),.O_frame_end(fe),.O_line_start(ls),.O_line_end(le));
 reg [31:0] epoch_q,seen_generation,frame_id,frame_epoch;reg seen,analyse,armed,enable_q;
 wire clear=control_epoch!=epoch_q || enable!=enable_q;
 wire fresh=fs && enable && preview_source && armed && (!seen || generation!=seen_generation);
 wire [575:0] detected;
 wire [255:0] compact;
 genvar ci;
 generate for(ci=0;ci<4;ci=ci+1)begin:g_compact
  wire [143:0] o=detected[ci*144+:144];
  assign compact[ci*64+:64]={o[143],o[142:140],o[12],o[139:138],o[116:105],o[104:93],o[92:81],o[80:69],9'd0};
 end endgenerate
wire [95:0] detected_diag;
wire [3:0] detected_count;wire detected_overflow,toggle;reg previous_toggle;
 vision_pipeline #(.P_SERVO_USB_DIAG(P_SERVO_USB_DIAG),.P_RUNTIME_CONFIG(1),.P_DOMINANCE_MARGIN(8'd24),.P_TRACKING(1),.P_CAMERA_CALIBRATION(1),.P_COMPACT_OUTPUT(1)) u_vision(
  .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_rgb(rgb),.I_de(de),.I_hs(hs),.I_vs(vs),
  .I_x(x),.I_y(y),.I_frame_start(fs),.I_frame_end(fe),.I_line_start(ls),.I_line_end(le),
  .I_frame_is_new(fs?fresh:analyse),.I_bright_min(8'd64),.I_chroma_min(8'd12),
  .O_diag_frame(detected_diag),.O_objects(detected),.O_count(detected_count),.O_overflow(detected_overflow),.O_result_toggle(toggle));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin epoch_q<=0;enable_q<=0;seen_generation<=0;frame_id<=0;frame_epoch<=0;seen<=0;analyse<=0;armed<=0;
   objects<=0;count<=0;overflow<=0;valid<=0;source_id<=0;result_epoch<=0;previous_toggle<=0;diagnostic<=0;end
  else begin
   epoch_q<=control_epoch;enable_q<=enable;previous_toggle<=toggle;
   if(clear)begin valid<=0;analyse<=0;armed<=0;seen_generation<=generation;seen<=1;end
   else begin
    // Require a publication after the request. A cached image from a previous
    // request cannot be reported as a newly analysed current-mode result.
    if(enable && generation!=seen_generation)armed<=1;
    if(fs)begin
     analyse<=fresh;
     if(fresh)begin seen<=1;seen_generation<=generation;frame_id<=image_id;frame_epoch<=control_epoch;end
    end
    if(toggle!=previous_toggle && analyse && enable && frame_epoch==control_epoch)begin
     diagnostic<=detected_diag;objects<=compact;count<=detected_count;overflow<=detected_overflow;source_id<=frame_id;result_epoch<=frame_epoch;valid<=1;
    end
   end
  end
 end
endmodule
