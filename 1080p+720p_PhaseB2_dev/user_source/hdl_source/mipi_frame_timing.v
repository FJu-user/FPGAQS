`timescale 1ns/1ps

module latency_timebase #(parameter TICK_CYCLES=3200)(
 input wire clk,rst_n,output reg [23:0] gray);
 reg [11:0] prescale;
 reg [19:0] ticks;
 wire [19:0] next_ticks=ticks+20'd1;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin prescale<=0;ticks<=0;gray<=0;end
  else if(prescale==TICK_CYCLES-1)begin
   prescale<=0;ticks<=next_ticks;gray<={4'd0,(next_ticks>>1)^next_ticks};
  end else prescale<=prescale+1'b1;
endmodule

// User contract: the first complete presentation measures one capture; later
// 1080p repeat presentations reuse that result until the capture ID changes.
module mipi_latency_measure(
 input wire clk,rst_n,input wire [31:0] capture_gray,
 input wire [23:0] time_gray,entry_gray,
 input wire first,last,de,vsync,underflow,local_source,
 input wire [40:0] identity,input wire [1:0] stream_bank,descriptor_bank,
 output wire [25:0] token);
 reg [40:0] measured_identity;
 reg cached,measuring,publish_pending;
 wire [8:0] frame_token;
 wire [16:0] time_token;
 wire new_first=first&&de&&!(cached&&identity==measured_identity&&local_source&&
                           stream_bank==descriptor_bank);
 frame_latency #(.ID_WIDTH(16)) frames(clk,rst_n,capture_gray,new_first,last,de,vsync,underflow,
                      local_source,identity,stream_bank,descriptor_bank,frame_token);
 mipi_time_latency elapsed(clk,rst_n,time_gray,entry_gray,new_first,last,de,vsync,
                          underflow,local_source,identity,stream_bank,descriptor_bank,time_token);
 assign token={time_token[16]&&frame_token[8],time_token[15:0],frame_token};
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin measured_identity<=0;cached<=0;measuring<=0;publish_pending<=0;end
  else begin
   publish_pending<=last&&de&&measuring;
   if(publish_pending)cached<=time_token[16]&&frame_token[8];
   if(vsync)measuring<=0;
   if(underflow||!local_source)cached<=0;
   if(last&&de)measuring<=0;
   if(new_first)begin measured_identity<=identity;cached<=0;measuring<=1;end
  end
endmodule

// Observer only. One ordered outstanding RAW first-pixel token; an impossible
// overlap/orphan invalidates measurements rather than guessing an identity.
module mipi_frame_timing(
 input wire clk,system_rst_n,path_rst_n,
 input wire [23:0] time_gray,
 input wire csi_sof,raw_sof,isp_sof,
 output reg [31:0] latest_gray,
 output reg [56:0] isp_descriptor);
 (* ASYNC_REG="TRUE" *) reg [23:0] time_meta,time_sync;
 reg [15:0] capture_sequence;
 reg [55:0] csi_descriptor;
 reg csi_pending,raw_pending,desync;
 reg csi_seen,tracking_ready;
 reg [56:0] raw_descriptor;
 wire [15:0] next_sequence=capture_sequence+16'd1;
 wire [56:0] raw_record={csi_pending&&!desync,csi_descriptor};
 always @(posedge clk or negedge system_rst_n)
  if(!system_rst_n)begin time_meta<=0;time_sync<=0;capture_sequence<=0;latest_gray<=0;end
  else begin
   time_meta<=time_gray;time_sync<=time_meta;
   if(path_rst_n&&csi_sof)begin capture_sequence<=next_sequence;latest_gray<={16'd0,(next_sequence>>1)^next_sequence};end
  end
 always @(posedge clk or negedge path_rst_n)
  if(!path_rst_n)begin
   csi_descriptor<=0;csi_pending<=0;raw_pending<=0;desync<=0;
   csi_seen<=0;tracking_ready<=0;
   raw_descriptor<=0;isp_descriptor<=0;
  end else begin
   // The receiver may leave reset in the middle of a sensor frame. The
   // first CSI frame is a warmup boundary; its RAW/ISP heads are ignored.
   // Start tracking at the second FS, after a sensor frame has drained.
   // This observer never gates pixels, resets the ISP, or changes DDR grants.
   if(csi_sof)begin
    csi_seen<=1;
    if(csi_seen)begin
     tracking_ready<=1;csi_descriptor<={next_sequence,time_sync};csi_pending<=1;
    end
   end
   if(tracking_ready && raw_sof)begin
    // In this pipeline RAW SOF follows CSI FS by registered unpack stages.
    // A simultaneous FS/RAW boundary is ambiguous and conservatively invalid.
    csi_pending<=0;
    raw_descriptor<=csi_sof?57'd0:raw_record;
    raw_pending<=1;
    if(raw_pending&&!isp_sof)desync<=1;
   end
   if(tracking_ready && isp_sof)begin
    if(raw_pending)begin
     isp_descriptor<={raw_descriptor[56]&&!desync,raw_descriptor[55:0]};
     if(!raw_sof)raw_pending<=0;
    end else if(raw_sof)begin
     isp_descriptor<=csi_sof?57'd0:raw_record;raw_pending<=0;
    end else begin isp_descriptor<=0;desync<=1;end
   end
  end
endmodule

// Sequential Gray decoding and constant division keep wide arithmetic out of
// the pixel timing path. 1 tick = 64 us = 16/25 tenths of one millisecond.
module mipi_time_latency(
 input wire clk,rst_n,input wire [23:0] time_gray,entry_gray,
 input wire first,last,de,vsync,underflow,local_source,
 input wire [40:0] identity,input wire [1:0] stream_bank,descriptor_bank,
 output reg [16:0] token);
 (* ASYNC_REG="TRUE" *)reg [23:0] time_meta,time_sync;
 reg [23:0] now_shift,entry_shift,now_binary,entry_binary;
 reg now_parity,entry_parity;
 reg [4:0] bit_count;
 reg [2:0] work;
 reg [17:0] remainder;
 reg [15:0] bcd;
 reg [40:0] first_identity,expired_identity;
 reg [1:0] bank;
 reg active,bad,sticky_underflow,expired;
 wire [19:0] elapsed_mod=now_binary[19:0]-entry_binary[19:0];
 wire [23:0] elapsed={4'd0,elapsed_mod};
 wire same_identity=identity==first_identity;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin time_meta<=0;time_sync<=0;end
  else begin time_meta<=time_gray;time_sync<=time_meta;end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   now_shift<=0;entry_shift<=0;now_binary<=0;entry_binary<=0;
   now_parity<=0;entry_parity<=0;bit_count<=0;work<=0;remainder<=0;bcd<=0;
   first_identity<=0;expired_identity<=0;bank<=0;
   active<=0;bad<=0;sticky_underflow<=0;expired<=0;token<=0;
  end else begin
   if(vsync)begin sticky_underflow<=0;if(active)begin active<=0;token<=0;end end
   else if(underflow)sticky_underflow<=1;
   if(active&&(underflow||!local_source||!same_identity||descriptor_bank!=bank))bad<=1;
   case(work)
    1:begin
     now_parity<=now_parity^now_shift[23];entry_parity<=entry_parity^entry_shift[23];
     now_binary<={now_binary[22:0],now_parity^now_shift[23]};
     entry_binary<={entry_binary[22:0],entry_parity^entry_shift[23]};
     now_shift<={now_shift[22:0],1'b0};entry_shift<={entry_shift[22:0],1'b0};
     if(bit_count==0)work<=2;else bit_count<=bit_count-1'b1;
    end
    2:begin
     if(elapsed>24'd15624)begin
      bad<=1;work<=0;expired<=1;expired_identity<=first_identity;
     end else begin remainder<={elapsed[13:0],4'b0};bcd<=0;work<=3;end
    end
    3:if(remainder>=18'd25)begin
     remainder<=remainder-18'd25;
     if(bcd[3:0]!=9)bcd[3:0]<=bcd[3:0]+1'b1;
     else begin bcd[3:0]<=0;
      if(bcd[7:4]!=9)bcd[7:4]<=bcd[7:4]+1'b1;
      else begin bcd[7:4]<=0;
       if(bcd[11:8]!=9)bcd[11:8]<=bcd[11:8]+1'b1;
       else begin bcd[11:8]<=0;bcd[15:12]<=bcd[15:12]+1'b1;end
      end
     end
    end else work<=0;
    default:work<=0;
   endcase
   if(last&&de&&active)begin
    active<=0;
    token<=(!bad&&!underflow&&local_source&&identity[40]&&same_identity&&
     stream_bank==bank&&descriptor_bank==bank&&work==0)?{1'b1,bcd}:17'd0;
   end
   if(first&&de)begin
    now_shift<=time_sync;entry_shift<=entry_gray;now_binary<=0;entry_binary<=0;
    now_parity<=0;entry_parity<=0;bit_count<=23;work<=1;
    first_identity<=identity;bank<=descriptor_bank;active<=1;
    bad<=!local_source||!identity[40]||stream_bank!=descriptor_bank||sticky_underflow||underflow||
         (expired&&identity==expired_identity);
   end
  end
endmodule
