`timescale 1ns / 1ns

// Stable post-DDR algorithm insertion point.
//
// Keep the complete pixel transaction together.  Future algorithms are added
// inside this wrapper and must apply exactly the same fixed latency to RGB,
// DE, HS and VS.  active_width/active_height are ports (rather than constants)
// so the same algorithm shell can later serve 1280x720 and 1920x1080 modes.
module video_algorithm_wrapper #(parameter REMOTE_FRAME_LOCKED=0,REMOTE_LOW_RESET=0,MOTION_OVERLAY=0,LATENCY_OSD=0,TIME_OSD=0,UART_SUPPORT=0,REMOTE_VISION=0,ROAD_PLANNING=0,REMOTE_NATIVE_COORDINATES=0) (
    input wire I_shadow_motion_overlay,
    input wire [25:0] I_latency_token,
    input wire I_latency_local_source,
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_mode_1080,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [1:0]  I_display_bank,
    input  wire [7:0]  I_display_frame_seq,
    input  wire        I_frame_info_toggle,
    input wire [127:0] I_remote_coordinate_bcd,
    input wire [255:0] I_remote_objects,input wire [3:0] I_remote_count,
    input wire I_remote_valid,I_remote_enable,
    input wire [7:0] I_source_epoch,
    input wire [1:0] I_compare_mode,
    input  wire [4:0]  I_shadow_mode,
    input  wire        I_shadow_valid,
    input  wire        I_algorithm_reset_event,
    input  wire [7:0]  I_shadow_threshold,
    input  wire [7:0]  I_shadow_strength,
    output wire O_remote_capture,O_remote_prepare,
    output wire [23:0] O_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [11:0] O_stream_x,
    output wire [11:0] O_stream_y,
    output wire        O_stream_frame_start,
    output wire        O_stream_frame_end,
    output wire [1:0]  O_stream_display_bank,
    output wire [7:0]  O_stream_frame_seq,
    output wire        O_stream_frame_is_new,
    output wire        O_stream_new_frame_pulse,
    output wire [7:0]  O_stream_config_epoch,
    output wire [4:0]  O_active_mode,
    input wire [1:0] I_road_mask_q,output wire [12:0] O_road_mask_ra,
    output wire [1:0]  O_active_view
);

// -------------------------------------------------------------------------
// USER ALGORITHM INSERTION ZONE
// Step 0 establishes a single transaction contract.  Later algorithms must
// consume and produce this whole record at a declared fixed latency.  The
// present implementation is the permanently available original-image path.
// -------------------------------------------------------------------------
wire [11:0] context_x;
wire [11:0] context_y;
wire        context_frame_start;
wire        context_frame_end;
wire        context_line_start;
wire        context_line_end;

video_stream_context u_video_stream_context (
    .I_clk           ( I_clk               ),
    .I_rst_n         ( I_rst_n             ),
    .I_active_width  ( I_active_width      ),
    .I_active_height ( I_active_height     ),
    .I_de            ( I_de                ),
    .I_vs            ( I_vs                ),
    .O_x             ( context_x           ),
    .O_y             ( context_y           ),
    .O_frame_start   ( context_frame_start ),
    .O_frame_end     ( context_frame_end   ),
    .O_line_start    ( context_line_start  ),
    .O_line_end      ( context_line_end    )
);

// Bind asynchronous DDR identity to the first active pixel.  A changed
// display-frame toggle with an unchanged sequence is a repeated camera frame.
reg       frame_info_valid;
reg       last_frame_info_toggle;
reg [1:0] active_display_bank;
reg [7:0] active_display_frame_seq;
reg       active_frame_is_new;

// The result mailbox commits one clock before the existing twenty-clock
// algorithm SOF. Its data then remains stable for the entire rendered frame.
reg [18:0] remote_capture_pipe;
always @(posedge I_clk or negedge I_rst_n)
 if(!I_rst_n)remote_capture_pipe<=0;
 else remote_capture_pipe<={remote_capture_pipe[17:0],context_frame_start};
assign O_remote_prepare=REMOTE_FRAME_LOCKED?context_frame_start:1'b0;
assign O_remote_capture=REMOTE_FRAME_LOCKED?remote_capture_pipe[18]:1'b0;
wire frame_info_available = !frame_info_valid ||
                            (I_frame_info_toggle != last_frame_info_toggle);
wire frame_start_is_new = context_frame_start && frame_info_available &&
                          (!frame_info_valid ||
                           (I_display_frame_seq != active_display_frame_seq));
wire [1:0] transaction_display_bank =
    (context_frame_start && frame_info_available) ?
    I_display_bank : active_display_bank;
wire [7:0] transaction_display_frame_seq =
    (context_frame_start && frame_info_available) ?
    I_display_frame_seq : active_display_frame_seq;
wire transaction_frame_is_new = context_frame_start ?
                                frame_start_is_new : active_frame_is_new;
wire transaction_new_frame_pulse = context_frame_start && frame_start_is_new;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        frame_info_valid         <= 1'b0;
        last_frame_info_toggle   <= 1'b0;
        active_display_bank      <= 2'd0;
        active_display_frame_seq <= 8'd0;
        active_frame_is_new      <= 1'b0;
    end else if(context_frame_start) begin
        if(frame_info_available) begin
            frame_info_valid         <= 1'b1;
            last_frame_info_toggle   <= I_frame_info_toggle;
            active_display_bank      <= I_display_bank;
            active_display_frame_seq <= I_display_frame_seq;
            active_frame_is_new      <= frame_start_is_new;
        end else begin
            active_frame_is_new <= 1'b0;
        end
    end
end

reg [7:0] source_epoch_q;
wire source_context_reset=UART_SUPPORT && (I_source_epoch!=source_epoch_q);
always @(posedge I_clk or negedge I_rst_n)
 if(!I_rst_n) source_epoch_q<=0;
 else if(UART_SUPPORT) source_epoch_q<=I_source_epoch;
reg [1:0] compare_active;
wire [1:0] compare_this_pixel=context_frame_start ? I_compare_mode:compare_active;
reg [1:0] compare_pipe[0:19];
integer cp;
always @(posedge I_clk or negedge I_rst_n) begin
 if(!I_rst_n) begin compare_active<=0;for(cp=0;cp<20;cp=cp+1) compare_pipe[cp]<=0;end
 else begin
  if(context_frame_start) compare_active<=I_compare_mode;
  compare_pipe[0]<=UART_SUPPORT?compare_this_pixel:2'd0;
  for(cp=1;cp<20;cp=cp+1) compare_pipe[cp]<=compare_pipe[cp-1];
 end
end
wire [23:0] aligned_original;
wire [4:0] active_algorithm_mode;
assign O_active_mode=active_algorithm_mode;
assign O_active_view=compare_active;
wire [7:0] active_threshold;
wire [7:0] active_strength;
wire [7:0] active_config_epoch;

// KEY4 requests are held until the first active pixel.  Consequently all
// stateful algorithms see one unambiguous frame-boundary reset commit.
reg reset_pending;
wire soft_reset_commit = context_frame_start &&
                         (reset_pending || I_algorithm_reset_event);
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
        reset_pending <= 1'b0;
    else if(soft_reset_commit)
        reset_pending <= 1'b0;
    else if(I_algorithm_reset_event)
        reset_pending <= 1'b1;
end

algorithm_ctrl_commit u_algorithm_ctrl_commit (
    .I_clk              ( I_clk                ),
    .I_rst_n            ( I_rst_n              ),
    .I_frame_start      ( context_frame_start  ),
    .I_mode_1080        ( I_mode_1080          ),
    .I_active_width     ( I_active_width       ),
    .I_active_height    ( I_active_height      ),
    .I_shadow_mode      ( I_shadow_mode        ),
    .I_shadow_threshold ( I_shadow_threshold   ),
    .I_shadow_strength  ( I_shadow_strength    ),
    .I_shadow_valid     ( I_shadow_valid       ),
    .I_soft_reset_commit( soft_reset_commit    ),
    .O_active_mode      ( active_algorithm_mode),
    .O_active_threshold ( active_threshold     ),
    .O_active_strength  ( active_strength      ),
    .O_config_epoch     ( active_config_epoch  )
);

reg motion_overlay_active;
wire motion_overlay_commit = MOTION_OVERLAY && (active_algorithm_mode == 5'd13) &&
    !soft_reset_commit && !source_context_reset;
wire motion_overlay_this_pixel = motion_overlay_commit &&
    ((context_frame_start && I_shadow_valid) ? I_shadow_motion_overlay : motion_overlay_active);
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) motion_overlay_active <= 1'b0;
    else if(!motion_overlay_commit) motion_overlay_active <= 1'b0;
    else if(context_frame_start && I_shadow_valid)
        motion_overlay_active <= I_shadow_motion_overlay;
end

wire [23:0] algorithm_rgb;
wire        algorithm_de;
wire        algorithm_hs;
wire        algorithm_vs;
wire [11:0] algorithm_x;
wire [11:0] algorithm_y;
wire        algorithm_frame_start;
wire        algorithm_frame_end;
wire        algorithm_line_start;
wire        algorithm_line_end;
wire [1:0]  algorithm_display_bank;
wire [7:0]  algorithm_frame_seq;
wire        algorithm_frame_is_new;
wire        algorithm_new_frame_pulse;
wire [4:0]  algorithm_mode;
wire [7:0]  algorithm_threshold;
wire [7:0]  algorithm_strength;
wire [7:0]  algorithm_config_epoch;

// The shared algorithm chain has a twenty-cycle contract. Mode 0 remains
// the original-image branch and every branch carries the same transaction.
pixel_chain_v1 #(.MOTION_OVERLAY(MOTION_OVERLAY)) u_pixel_chain_v1 (
    .I_motion_overlay(motion_overlay_this_pixel),
    .I_clk             ( I_clk                         ),
    .I_rst_n           ( I_rst_n                       ),
    .I_rgb             ( I_rgb                         ),
    .I_de              ( I_de                          ),
    .I_hs              ( I_hs                          ),
    .I_vs              ( I_vs                          ),
    .I_active_width    ( I_active_width                 ),
    .I_active_height   ( I_active_height                ),
    .I_mode_1080       ( I_mode_1080                    ),
    .I_x               ( context_x                     ),
    .I_y               ( context_y                     ),
    .I_frame_start     ( context_frame_start           ),
    .I_frame_end       ( context_frame_end             ),
    .I_line_start      ( context_line_start            ),
    .I_line_end        ( context_line_end              ),
    .I_display_bank    ( transaction_display_bank      ),
    .I_frame_seq       ( transaction_display_frame_seq ),
    .I_frame_is_new    ( transaction_frame_is_new      ),
    .I_new_frame_pulse ( transaction_new_frame_pulse   ),
    .I_algorithm_mode  ( active_algorithm_mode         ),
    .I_threshold       ( active_threshold              ),
    .I_strength        ( active_strength               ),
    .I_config_epoch    ( active_config_epoch           ),
    .I_soft_reset      ( soft_reset_commit || source_context_reset ),
    .I_context_reset   ( source_context_reset ),
    .O_raw_rgb         ( aligned_original ),
    // Phase B2 keeps the board path on LOCAL_MASK. The external ports are
    // reserved for a future color-mask producer and are not mode controls.
    .I_mask_source_sel ( 1'b0                         ),
    .I_external_mask   ( 1'b0                         ),
    .I_external_mask_valid( 1'b0                     ),
    .O_rgb             ( algorithm_rgb                 ),
    .O_de              ( algorithm_de                  ),
    .O_hs              ( algorithm_hs                  ),
    .O_vs              ( algorithm_vs                  ),
    .O_x               ( algorithm_x                   ),
    .O_y               ( algorithm_y                   ),
    .O_frame_start     ( algorithm_frame_start         ),
    .O_frame_end       ( algorithm_frame_end           ),
    .O_line_start      ( algorithm_line_start          ),
    .O_line_end        ( algorithm_line_end            ),
    .O_display_bank    ( algorithm_display_bank        ),
    .O_frame_seq       ( algorithm_frame_seq           ),
    .O_frame_is_new    ( algorithm_frame_is_new        ),
    .O_new_frame_pulse ( algorithm_new_frame_pulse     ),
    .O_algorithm_mode  ( algorithm_mode                ),
    .O_threshold       ( algorithm_threshold           ),
    .O_strength        ( algorithm_strength            ),
    .O_config_epoch    ( algorithm_config_epoch        )
);

wire [11:0] x_pos = algorithm_x;
wire [11:0] y_pos = algorithm_y;

// Official contest asset.  The ROM contains a 160x160 RGB logo with a valid
// bit for transparency.  Keep it at the top-left in both display modes.
localparam [11:0] LOGO_W = 12'd160;
localparam [11:0] LOGO_H = 12'd160;

wire        logo_region = algorithm_de &&
                          (x_pos < LOGO_W) && (y_pos < LOGO_H);
// 160*y = 128*y + 32*y.  Shifts keep the address path smaller than a
// general multiplier at the 148.5 MHz 1080p output clock.
wire [14:0] logo_addr_next = {y_pos[7:0], 7'b0} +
                             {y_pos[9:0], 5'b0} + x_pos[7:0];

// 5x7 glyphs used by the two fixed mode labels.
function [4:0] glyph_row;
    input [7:0] ch;
    input [2:0] row;
    begin
        case(ch)
            "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;default:glyph_row=5'b01110; endcase
            "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=5'b01110; endcase
            "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00110;4:glyph_row=5'b01000;5:glyph_row=5'b10000;default:glyph_row=5'b11111; endcase
            "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;default:glyph_row=5'b11110; endcase
            "6": case(row) 0:glyph_row=5'b00110;1:glyph_row=5'b01000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;default:glyph_row=5'b01110; endcase
            "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;default:glyph_row=5'b01000; endcase
            "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;default:glyph_row=5'b01110; endcase
            "p": case(row) 0:glyph_row=5'b00000;1:glyph_row=5'b11110;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;default:glyph_row=5'b10000; endcase
            "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;default:glyph_row=5'b10001; endcase
            "z": case(row) 0:glyph_row=5'b00000;1:glyph_row=5'b11111;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b11111;default:glyph_row=5'b00000; endcase
            default: glyph_row=5'b00000;
        endcase
    end
endfunction

reg [7:0] label_char;
reg [3:0] label_index;
reg [4:0] label_bits;
reg       label_on;
reg [11:0] label_local_x;
reg [11:0] label_x_start;
reg [11:0] label_x_end;
reg [11:0] panel_x_start;

always @(*) begin
    label_char = 8'h20;
    label_index = 4'd0;
    label_bits = 5'd0;
    label_on = 1'b0;
    label_local_x = 12'd0;
    // 1080p30Hz is nine 16-pixel cells; 720p60Hz is eight.  The explicit
    // upper bound prevents the former low-bit index from wrapping every
    // 256 pixels and repeating the text across the whole top edge.
    label_x_start = I_mode_1080 ? (I_active_width - 12'd160) :
                                  (I_active_width - 12'd144);
    label_x_end   = I_mode_1080 ? (I_active_width - 12'd16) :
                                  (I_active_width - 12'd16);
    panel_x_start = label_x_start - 12'd8;

    if(algorithm_de &&
       (x_pos >= label_x_start) && (x_pos < label_x_end) &&
       (y_pos >= 12'd9) && (y_pos < 12'd23)) begin
        label_local_x = x_pos - label_x_start;
        // A 16-pixel character cell makes the cell and column selects simple
        // bit slices.  This keeps the final OSD path short enough for the
        // 148.5 MHz 1080p output clock without using a divider/modulo network.
        label_index = label_local_x[7:4];
        if(I_mode_1080) begin
            case(label_index)
                0:label_char="1"; 1:label_char="0"; 2:label_char="8";
                3:label_char="0"; 4:label_char="p"; 5:label_char="3";
                6:label_char="0"; 7:label_char="H"; 8:label_char="z";
                default:label_char=8'h20;
            endcase
        end else begin
            case(label_index)
                0:label_char="7"; 1:label_char="2"; 2:label_char="0";
                3:label_char="p"; 4:label_char="6"; 5:label_char="0";
                6:label_char="H"; 7:label_char="z";
                default:label_char=8'h20;
            endcase
        end
        label_bits = glyph_row(label_char, (y_pos-12'd9) >> 1);
        if(label_local_x[3:0] < 4'd10)
            label_on = label_bits[4-label_local_x[3:1]];
    end
end

// The B detector returns 720p coordinates. Expand x1/y1 by floor(3/2)
// and x2/y2 by ceil(3/2), clamped to the active display. RGB is never scaled
// here; only the rectangles are transformed. The image stays local and live.
wire [23:0] remote_rgb;wire remote_ink;
generate if(REMOTE_VISION)begin:g_remote_overlay
 wire [255:0] mapped;
 genvar ri;
 if(REMOTE_NATIVE_COORDINATES)begin:g_native
  assign mapped=I_remote_objects;
 end else begin:g_canonical
 for(ri=0;ri<4;ri=ri+1)begin:g_map
  wire [63:0] o=I_remote_objects[ri*64+:64];
  wire [11:0] x0=o[56:45],y0=o[44:33],x1=o[32:21],y1=o[20:9];
  wire ok=o[63] && x0<=x1 && y0<=y1 && x1<1280 && y1<720;
  wire [11:0] mx0=I_mode_1080?x0+(x0>>1):x0;
  wire [11:0] my0=I_mode_1080?y0+(y0>>1):y0;
  wire [11:0] mx1=I_mode_1080?x1+(x1>>1)+{11'd0,x1[0]}:x1;
  wire [11:0] my1=I_mode_1080?y1+(y1>>1)+{11'd0,y1[0]}:y1;
  assign mapped[ri*64+:64]={ok,o[62:57],mx0,my0,mx1,my1,o[8:0]};
 end
 end
 remote_vision_osd #(.FRAME_LOCKED_INPUT(REMOTE_FRAME_LOCKED),.RESET_BANK(!REMOTE_LOW_RESET)) u_overlay(.clk(I_clk),.rst_n(I_rst_n),
  .enable(algorithm_mode==17 && I_remote_enable && I_remote_count!=4'he && compare_pipe[19]!=1 &&
    (compare_pipe[19]!=2 || algorithm_x>=(I_active_width>>1))),
  .rgb(algorithm_rgb),.de(algorithm_de),.fs(algorithm_frame_start),.x(algorithm_x),.y(algorithm_y),
  .coordinate_bcd(I_remote_coordinate_bcd),.objects(mapped),.valid(I_remote_valid),.count(I_remote_count),.out_rgb(remote_rgb),.out_ink(remote_ink));
end else begin:g_no_remote
 assign remote_rgb=24'd0;assign remote_ink=0;
end endgenerate
wire road_ink;wire [23:0] road_color;
generate if(ROAD_PLANNING)begin:g_road
 road_route_osd route_osd(.clk(I_clk),.rst_n(I_rst_n),
 .enable(algorithm_mode==18 && I_remote_enable),.clear(soft_reset_commit || source_context_reset),
 .show(compare_pipe[19]!=1 && (compare_pipe[19]!=2 || algorithm_x>=(I_active_width>>1))),
 .mode1080(I_mode_1080),.de(algorithm_de),.fs(algorithm_frame_start),
 .x(algorithm_x),.y(algorithm_y),.route(I_remote_objects),.valid(I_remote_valid && I_remote_count==4'he),
 .ink(road_ink),.color(road_color),.mask_q(I_road_mask_q),.mask_ra(O_road_mask_ra));
end else begin:g_no_road assign road_ink=0;assign road_color=0;assign O_road_mask_ra=0;end endgenerate
wire latency_ink_s2;reg latency_ink_s3;
generate if(LATENCY_OSD)begin:g_latency_osd
 reg [25:0] frame_token;
 always @(posedge I_clk or negedge I_rst_n)
  if(!I_rst_n)frame_token<=0;
  else if(context_frame_start)frame_token<=I_latency_local_source?I_latency_token:9'd0;
 frame_latency_paint #(.TIME_OSD(TIME_OSD)) paint(I_clk,I_rst_n,frame_token,algorithm_x,algorithm_y,algorithm_de,latency_ink_s2);
end else begin:g_no_latency_osd assign latency_ink_s2=0;end endgenerate
always @(posedge I_clk or negedge I_rst_n)
 if(!I_rst_n)latency_ink_s3<=0;else latency_ink_s3<=latency_ink_s2;
reg [2:0] remote_select;
always @(posedge I_clk or negedge I_rst_n)
 if(!I_rst_n)remote_select<=0;
 else remote_select<={remote_select[1:0],(REMOTE_VISION && algorithm_mode==17)};
wire panel = algorithm_de && (x_pos >= panel_x_start) &&
             (x_pos < (I_active_width - 12'd8)) && (y_pos < 12'd32);

// Three OSD pipeline stages isolate the large official colour ROM from the
// 148.5 MHz coordinate path.  Stage 1 registers the ROM address and therefore
// cuts the previous routed critical path (coordinate arithmetic -> ERAM
// address).  Stage 2 follows the synchronous ROM read and stage 3 registers
// the final overlay inputs.  Every video qualifier follows the same latency.
reg [23:0] algorithm_rgb_s1;
reg [14:0] logo_addr_s1;
reg        logo_region_s1;
reg        label_on_s1;
reg        panel_s1;
reg        de_s1;
reg        hs_s1;
reg        vs_s1;
reg [45:0] stream_meta_s1;

wire [24:0] logo_pixel;
anlogic_logo_rom u_anlogic_logo_rom (
    .I_clk   (I_clk),
    .I_addr  (logo_region ? logo_addr_next : 15'd0),
    .O_pixel (logo_pixel)
);

reg [23:0] algorithm_rgb_s2;
reg        logo_region_s2;
reg        label_on_s2;
reg        panel_s2;
reg        de_s2;
reg        hs_s2;
reg        vs_s2;
reg [45:0] stream_meta_s2;

reg [23:0] algorithm_rgb_s3;
wire [23:0] logo_rgb_s3=logo_pixel[23:0];
reg        logo_region_s3;
wire       logo_valid_s3=logo_region_s3 && logo_pixel[24];
reg        label_on_s3;
reg        panel_s3;
reg        de_s3;
reg        hs_s3;
reg        vs_s3;
reg [45:0] stream_meta_s3;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        algorithm_rgb_s1 <= 24'd0;
        logo_addr_s1     <= 15'd0;
        logo_region_s1   <= 1'b0;
        label_on_s1      <= 1'b0;
        panel_s1         <= 1'b0;
        de_s1            <= 1'b0;
        hs_s1            <= 1'b0;
        vs_s1            <= 1'b0;
        stream_meta_s1   <= 46'd0;

        algorithm_rgb_s2 <= 24'd0;
        logo_region_s2   <= 1'b0;
        label_on_s2      <= 1'b0;
        panel_s2         <= 1'b0;
        de_s2            <= 1'b0;
        hs_s2            <= 1'b0;
        vs_s2            <= 1'b0;
        stream_meta_s2   <= 46'd0;

        algorithm_rgb_s3 <= 24'd0;
        logo_region_s3  <= 1'b0;
        label_on_s3      <= 1'b0;
        panel_s3         <= 1'b0;
        de_s3            <= 1'b0;
        hs_s3            <= 1'b0;
        vs_s3            <= 1'b0;
        stream_meta_s3   <= 46'd0;
    end else begin
        algorithm_rgb_s1 <= (compare_pipe[19]==1 ||
            (compare_pipe[19]==2 && algorithm_x<(I_active_width>>1))) ? aligned_original:algorithm_rgb;
        logo_addr_s1     <= logo_region ? logo_addr_next : 15'd0;
        logo_region_s1   <= logo_region;
        label_on_s1      <= label_on;
        panel_s1         <= panel;
        de_s1            <= algorithm_de;
        hs_s1            <= algorithm_hs;
        vs_s1            <= algorithm_vs;
        stream_meta_s1   <= {algorithm_x,
                             algorithm_y,
                             algorithm_frame_start,
                             algorithm_frame_end,
                             algorithm_display_bank,
                             algorithm_frame_seq,
                             algorithm_frame_is_new,
                             algorithm_new_frame_pulse,
                             algorithm_config_epoch};

        algorithm_rgb_s2 <= algorithm_rgb_s1;
        logo_region_s2   <= logo_region_s1;
        label_on_s2      <= label_on_s1;
        panel_s2         <= panel_s1;
        de_s2            <= de_s1;
        hs_s2            <= hs_s1;
        vs_s2            <= vs_s1;
        stream_meta_s2   <= stream_meta_s1;

        // The palette ROM performs its second synchronous read here.
        // Its output and these stage-3 qualifiers describe the same pixel.
        algorithm_rgb_s3 <= algorithm_rgb_s2;
        logo_region_s3  <= logo_region_s2;
        label_on_s3      <= label_on_s2;
        panel_s3         <= panel_s2;
        de_s3            <= de_s2;
        hs_s3            <= hs_s2;
        vs_s3            <= vs_s2;
        stream_meta_s3   <= stream_meta_s2;
    end
end

assign O_rgb = logo_valid_s3 ? logo_rgb_s3 :
               label_on_s3   ? 24'hffffff :
               panel_s3      ? {1'b0,algorithm_rgb_s3[23:17],
                                  1'b0,algorithm_rgb_s3[15:9],
                                  1'b0,algorithm_rgb_s3[7:1]} :
               (latency_ink_s3 && !(remote_select[2] && remote_ink)) ? 24'hffff00 :
                                 (road_ink?road_color:(remote_select[2]?remote_rgb:algorithm_rgb_s3));
assign O_de  = de_s3;
assign O_hs  = hs_s3;
assign O_vs  = vs_s3;
assign {O_stream_x,
        O_stream_y,
        O_stream_frame_start,
        O_stream_frame_end,
        O_stream_display_bank,
        O_stream_frame_seq,
        O_stream_frame_is_new,
        O_stream_new_frame_pulse,
        O_stream_config_epoch} = stream_meta_s3;

endmodule
