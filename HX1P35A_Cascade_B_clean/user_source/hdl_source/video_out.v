`timescale 1ns/1ps
module video_out #(parameter META_HANDSHAKE=0,PREVIEW_SUPPORT=0,PREVIEW_WIDTH=320,PREVIEW_HEIGHT=180) (
 input wire I_rst_n,I_system_rst_n,I_ddr_clk,
 output wire O_video_out_rd_busy,input wire I_video_in_wr_busy,
 input wire [1:0] I_video_out_rp,
 input wire I_mode_1080,I_source_uart,I_uart_valid,I_uart_preview,I_preview_pixel,I_preview_mode_1080,
 input wire [24:0] I_uart_base,input wire [31:0] I_uart_id,
 input wire [31:0] I_uart_generation,
 input wire I_metadata_ready,I_frame_enable,
 output wire O_reader_ref_valid,output wire [24:0] O_reader_ref_base,
 output wire O_reader_running,output wire O_reader_drained,output wire O_camera_ref_valid,
 output reg [31:0] O_uart_generation,output reg O_active_resolution,output reg O_active_preview,
 input wire I_hold_frame,
 output wire O_frame_window,O_frame_boundary,
 output reg [1:0] O_active_read_bank,
 output reg [7:0] O_display_frame_seq,
 output reg O_frame_info_toggle,O_source_uart,
 output reg [7:0] O_context_epoch,
 output reg [31:0] O_displayed_id,
 output wire O_ddr_user_rd_en,output reg [24:0] O_ddr_user_addr,
 input wire I_ddr_user_ready,I_ddr_user_rd_valid,
 input wire [127:0] I_ddr_user_rd_data,
 input wire I_dsi_clk,I_video_vsync,I_video_rd_en,
 output reg [23:0] O_vdieo_data
);
 localparam DRAIN=0,CLEAR=1,ACTIVE=2;
 reg [1:0] state;reg [4:0] reset_count;
 reg [5:0] preview_word;reg [2:0] preview_line_repeat;reg [24:0] preview_row_base;
 reg [10:0] outstanding;reg [18:0] requested,total_beats;
 reg burst;reg [7:0] burst_count;
 reg vs1,vs2,vs3;reg have_frame;reg [24:0] active_uart_base;
 wire S_video_frame_start=vs2 && !vs3;
 wire S_fifo_rst=(state!=ACTIVE) || !I_rst_n;
 wire [8:0] S_fifo_wr_num;
 wire [127:0] S_fifo_rd_data;
 wire S_fifo_rd_en,S_fifo_emtpy;
 reg [3:0] S_fifo_rd_cnt,S_fifo_rd_cnt_1d;
 reg S_video_rd_en_1d;
 reg [127:0] S_fifo_rd_data_1d;
 wire use_uart=I_source_uart && I_uart_valid;
 wire [31:0] selected_generation=META_HANDSHAKE?I_uart_generation:32'd0;
 wire pixel_request=I_video_rd_en && (!META_HANDSHAKE || I_frame_enable);
 wire preview_pixel=PREVIEW_SUPPORT && I_preview_pixel;
 // Pixel-domain resolution arrives atomically with the preview descriptor.
 wire [2:0] preview_scale=I_preview_mode_1080?3'd6:3'd4;
 reg [2:0] pixel_repeat;
 wire pixel_step=pixel_request && (!preview_pixel || pixel_repeat==0);
 reg S_pixel_step_1d;
 always @(posedge I_dsi_clk)begin
  if(!pixel_request || !preview_pixel)pixel_repeat<=0;
  else if(pixel_repeat+1==preview_scale)pixel_repeat<=0;
  else pixel_repeat<=pixel_repeat+1'b1;
 end
 wire use_preview=PREVIEW_SUPPORT && use_uart && I_uart_preview;
 assign O_reader_ref_valid=O_source_uart && (have_frame || outstanding!=0 || state!=DRAIN);
 // A camera descriptor remains referenced across DRAIN/CLEAR while
 // responses retire and until the next frame descriptor replaces it.
 assign O_camera_ref_valid=!O_source_uart && (have_frame || outstanding!=0 || state!=DRAIN);
 assign O_reader_ref_base=active_uart_base;
 assign O_reader_running=(state==ACTIVE) && I_rst_n;
 assign O_reader_drained=(outstanding==0);
 assign O_frame_window=(state==DRAIN && outstanding==0);
 assign O_frame_boundary=O_frame_window && !I_hold_frame && I_rst_n && !S_video_frame_start;
 wire start_burst=(state==ACTIVE) && !burst && I_rst_n && !S_video_frame_start &&
                  !I_video_in_wr_busy && ({2'd0,S_fifo_wr_num}+{1'b0,outstanding})<=12'd211 && requested<total_beats;
 assign O_video_out_rd_busy=start_burst || burst;
 assign O_ddr_user_rd_en=(state==ACTIVE) && burst && I_ddr_user_ready && I_rst_n &&
                         !S_video_frame_start && requested<total_beats;
 // Outstanding tracking survives a display clock reset and SW4 transition.
 // Old responses drain while the FIFO is held reset, before any new descriptor.
 always @(posedge I_ddr_clk or negedge I_system_rst_n) begin
  if(!I_system_rst_n) begin
   state<=DRAIN;reset_count<=0;outstanding<=0;requested<=0;total_beats<=172800;
   burst<=0;burst_count<=0;vs1<=0;vs2<=0;vs3<=0;have_frame<=0;
   O_active_read_bank<=0;O_display_frame_seq<=0;O_frame_info_toggle<=0;
   O_source_uart<=0;O_context_epoch<=0;O_displayed_id<=0;O_ddr_user_addr<=0;active_uart_base<=0;
   O_uart_generation<=0;O_active_resolution<=0;O_active_preview<=0;preview_word<=0;preview_line_repeat<=0;preview_row_base<=0;
  end else begin
   vs1<=I_video_vsync;vs2<=vs1;vs3<=vs2;
   case({O_ddr_user_rd_en,I_ddr_user_rd_valid})
    2'b10:outstanding<=outstanding+1;
    2'b01:if(outstanding!=0) outstanding<=outstanding-1;
   endcase
   if(!I_rst_n || S_video_frame_start) begin
    state<=DRAIN;burst<=0;burst_count<=0;
    if(!I_rst_n) have_frame<=0;
   end else case(state)
    DRAIN: if(O_frame_boundary) begin
     state<=CLEAR;reset_count<=0;requested<=0;total_beats<=use_preview?(I_mode_1080?PREVIEW_WIDTH*PREVIEW_HEIGHT*3/16*6:PREVIEW_WIDTH*PREVIEW_HEIGHT*3/16*4):(I_mode_1080?388800:172800);
     preview_word<=0;preview_line_repeat<=0;preview_row_base<=I_uart_base;O_active_preview<=use_preview;
     O_source_uart<=use_uart;O_displayed_id<=use_uart?I_uart_id:32'd0;active_uart_base<=I_uart_base;
     O_uart_generation<=use_uart?selected_generation:32'd0;O_active_resolution<=I_mode_1080;
     O_active_read_bank<=I_video_out_rp;O_frame_info_toggle<=~O_frame_info_toggle;
     if(!have_frame || use_uart || use_uart!=O_source_uart || I_video_out_rp!=O_active_read_bank)
      O_display_frame_seq<=O_display_frame_seq+1;
     if(!have_frame || I_mode_1080!=O_active_resolution || use_uart!=O_source_uart || use_preview!=O_active_preview ||
        (use_uart && (selected_generation!=O_uart_generation || I_uart_id!=O_displayed_id || I_uart_base!=active_uart_base)))
      O_context_epoch<=O_context_epoch+1;
     have_frame<=1;
     if(use_uart) O_ddr_user_addr<=I_uart_base;
     else case(I_video_out_rp)
      0:O_ddr_user_addr<=0;
      1:O_ddr_user_addr<=7000000;
      2:O_ddr_user_addr<=14000000;
      3:O_ddr_user_addr<=21000000;
     endcase
    end
    CLEAR: if(reset_count==15) begin
     if(!META_HANDSHAKE || I_metadata_ready) state<=ACTIVE;
    end else reset_count<=reset_count+1;
    ACTIVE: begin
     if(start_burst) begin burst<=1;burst_count<=0;end
     if(O_ddr_user_rd_en) begin
      requested<=requested+1;
      if(O_active_preview && preview_word==PREVIEW_WIDTH*3/16-1)begin
       preview_word<=0;
       if(preview_line_repeat+1==(O_active_resolution?6:4))begin
        preview_line_repeat<=0;preview_row_base<=preview_row_base+PREVIEW_WIDTH*3/2;
        O_ddr_user_addr<=preview_row_base+PREVIEW_WIDTH*3/2;
       end else begin preview_line_repeat<=preview_line_repeat+1'b1;O_ddr_user_addr<=preview_row_base;end
      end else begin O_ddr_user_addr<=O_ddr_user_addr+8;if(O_active_preview)preview_word<=preview_word+1'b1;end
      if(burst_count==239 || requested+1==total_beats) begin burst<=0;burst_count<=0;end
      else burst_count<=burst_count+1;
     end
    end
    default:state<=DRAIN;
   endcase
  end
 end

    w128_d512_fifo U_w128_d512_fifo(
        .rst        ( S_fifo_rst          ),   

        .clkw       ( I_ddr_clk           ),     
        .we         ( I_ddr_user_rd_valid && state==ACTIVE && !S_video_frame_start ),
        .di         ( I_ddr_user_rd_data  ),
        .wrusedw    ( S_fifo_wr_num       ),
        .afull      (),
        .full_flag  (),
 
        .clkr       ( I_dsi_clk           ),
        .re         ( S_fifo_rd_en        ), 
        .dout       ( S_fifo_rd_data      ),  
        .rdusedw    (), 
        .valid      (),  
        .empty_flag ( S_fifo_emtpy        ),
        .aempty     ()
    );


   always @(posedge I_dsi_clk) begin
       if(pixel_step)
           S_fifo_rd_cnt <= S_fifo_rd_cnt + 'd1;
       else if(!pixel_request)
           S_fifo_rd_cnt <= 'd0;
   end

   assign S_fifo_rd_en = pixel_step && (S_fifo_rd_cnt == 'd0)  ? 1'b1 :
                         pixel_step && (S_fifo_rd_cnt == 'd5)  ? 1'b1 :
                         pixel_step && (S_fifo_rd_cnt == 'd10) ? 1'b1 : 1'b0;

   always @(posedge I_dsi_clk) begin
       S_video_rd_en_1d  <= pixel_request;
       S_pixel_step_1d <= pixel_step;
       S_fifo_rd_cnt_1d  <= S_fifo_rd_cnt;
       S_fifo_rd_data_1d <= S_fifo_rd_data;
   end

   always @(posedge I_dsi_clk) begin
       if(S_pixel_step_1d)
           begin
               case(S_fifo_rd_cnt_1d)
                   'd0: O_vdieo_data  <= S_fifo_rd_data[127:104];
                   'd1: O_vdieo_data  <= S_fifo_rd_data[103:80];
                   'd2: O_vdieo_data  <= S_fifo_rd_data[79:56];
                   'd3: O_vdieo_data  <= S_fifo_rd_data[55:32];
                   'd4: O_vdieo_data  <= S_fifo_rd_data[31:8];
                   'd5: O_vdieo_data  <= {S_fifo_rd_data_1d[7:0],S_fifo_rd_data[127:112]};
                   'd6: O_vdieo_data  <= S_fifo_rd_data[111:88];
                   'd7: O_vdieo_data  <= S_fifo_rd_data[87:64];
                   'd8: O_vdieo_data  <= S_fifo_rd_data[63:40];
                   'd9: O_vdieo_data  <= S_fifo_rd_data[39:16];
                   'd10: O_vdieo_data <= {S_fifo_rd_data_1d[15:0],S_fifo_rd_data[127:120]};
                   'd11: O_vdieo_data <= S_fifo_rd_data[119:96];
                   'd12: O_vdieo_data <= S_fifo_rd_data[95:72];
                   'd13: O_vdieo_data <= S_fifo_rd_data[71:48];
                   'd14: O_vdieo_data <= S_fifo_rd_data[47:24];
                   'd15: O_vdieo_data <= S_fifo_rd_data[23:0];
               endcase
           end
       else if(!S_video_rd_en_1d)
           O_vdieo_data <= 'd0;
   end

    
endmodule

// Atomic metadata handoff plus a complete-frame admission decision. Video
// clocks may stop: mailboxes use GLOBAL reset and retain unacknowledged data.
module uart_frame_bridge(
 input wire ddr_clk,sys_rst_n,pixel_clk,pixel_rst_n,
 input wire [85:0] metadata,input wire reader_running,
 output wire metadata_ready,
 input wire pixel_vsync,pixel_read_de,present_frame,
 input wire [4:0] active_mode,input wire [1:0] active_view,
 output reg [85:0] pixel_metadata,output wire frame_enable,
 output wire [127:0] display_status
);
 reg [85:0] last_sent;reg sent;
 wire send_ready,forward_valid;wire [85:0] forward_data;
 wire send=!sent || last_sent!=metadata;
 // A late descriptor waits for the next vertical blank. Horizontal blank
 // must never admit a new identity halfway through an already-started frame.
 wire accept=pixel_rst_n && !pixel_read_de && !frame_started;
 assign metadata_ready=sent && last_sent==metadata && send_ready;
 always @(posedge ddr_clk or negedge sys_rst_n)
  if(!sys_rst_n) begin sent<=0;last_sent<=0;end
  else if(send && send_ready) begin sent<=1;last_sent<=metadata;end
 uart_mailbox #(.WIDTH(86)) forward_mailbox(
  .s_clk(ddr_clk),.s_rst_n(sys_rst_n),.s_data(metadata),.s_valid(send),.s_ready(send_ready),
  .d_clk(pixel_clk),.d_rst_n(sys_rst_n),.d_data(forward_data),.d_valid(forward_valid),.d_ready(accept));
 reg live,frame_started,admitted;
 reg [5:0] settle;
 (* ASYNC_REG="TRUE" *) reg [1:0] running_sync;
 wire can_start=live && running_sync[1] && settle==6'd32 && !pixel_vsync;
 assign frame_enable=pixel_rst_n && (frame_started?admitted:can_start);
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
  if(!pixel_rst_n) begin
   live<=0;pixel_metadata<=0;frame_started<=0;admitted<=0;settle<=0;running_sync<=0;
  end else begin
   running_sync<={running_sync[0],reader_running};
   if(forward_valid && accept) begin pixel_metadata<=forward_data;live<=1;settle<=0;end
   else if(settle<32) settle<=settle+1'b1;
   if(pixel_vsync) begin frame_started<=0;admitted<=0;end
   else if(pixel_read_de && !frame_started) begin frame_started<=1;admitted<=can_start;end
  end
 end
 reg [91:0] present_data;reg present_pending;
 wire present_ready,returned_valid;wire [91:0] returned;
 always @(posedge pixel_clk or negedge sys_rst_n) begin
  if(!sys_rst_n) begin present_data<=0;present_pending<=0;end
  else begin
   if(present_pending && present_ready) present_pending<=0;
   if(present_frame && frame_enable) begin
    present_data<={pixel_metadata[84:0],active_mode,active_view};present_pending<=1;
   end
  end
 end
 uart_mailbox #(.WIDTH(92)) present_mailbox(
  .s_clk(pixel_clk),.s_rst_n(sys_rst_n),.s_data(present_data),.s_valid(present_pending),.s_ready(present_ready),
  .d_clk(ddr_clk),.d_rst_n(sys_rst_n),.d_data(returned),.d_valid(returned_valid),.d_ready(1'b1));
 wire confirmed=reader_running && metadata_ready && returned[91:7]==metadata[84:0];
 // Preview is internal transport metadata; DISPLAYED keeps its 85-bit ABI.
 // 85-bit identity: {resolution,generation,id,epoch,source,toggle,seq,bank}.
 assign display_status={metadata[51:20],metadata[83:52],{7'd0,!confirmed},{7'd0,confirmed},
                         {3'd0,returned[6:2]},8'd0,{6'd0,returned[1:0]},
                         {7'd0,metadata[11]},8'd0,{7'd0,metadata[84]}};
endmodule
