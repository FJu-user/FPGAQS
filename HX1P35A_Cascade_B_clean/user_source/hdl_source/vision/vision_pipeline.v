`timescale 1ns / 1ns

// Complete traditional-vision result pipeline.
//
// RGB888 -> primary-colour segmentation -> horizontal speck filter ->
// bounded run-length CCL -> bbox/fill features -> shape classification ->
// centre/BCD coordinate generation -> stable four-object result bank.
//
// The pixel path accepts one RGB pixel per clock.  Component feature and
// shape processing runs in vertical blanking after the final active pixel.
// O_objects/O_count change atomically only after a complete *new* source
// frame has been analysed, so an OSD never sees half-updated boxes.
module vision_pipeline #(
    parameter integer DEBUG_STAGE=0,
    parameter integer P_SERVO_USB_DIAG=0,
    parameter [7:0]  P_BRIGHT_MIN       = 8'd64,
    parameter [7:0]  P_RED_MIN          = 8'd80,
    parameter [7:0]  P_GREEN_MIN        = 8'd80,
    parameter [7:0]  P_BLUE_MIN         = 8'd80,
    parameter [7:0]  P_DOMINANCE_MARGIN = 8'd40,
    parameter [20:0] P_MIN_AREA         = 21'd256,
    parameter [11:0] P_MIN_DIM          = 12'd12,
    parameter integer P_RUNTIME_CONFIG = 0,
    parameter integer P_TRACKING = 0,
    parameter integer P_CAMERA_CALIBRATION = 0,
    parameter integer P_COMPACT_OUTPUT = 0,
    parameter integer P_IMAGE_WIDTH=1280, P_IMAGE_HEIGHT=720,
    // Small-object operating envelope; override after camera-frame calibration.
    // Comparisons only: no extra frame store or CCL population.
    parameter [11:0] P_MAX_OBJECT_WIDTH=(P_IMAGE_WIDTH*3)/4,
    parameter [11:0] P_MAX_OBJECT_HEIGHT=(P_IMAGE_HEIGHT*3)/4,
    parameter [7:0] P_NEUTRAL_CONTRAST=64,
    parameter [11:0] P_ROI_X_MIN=0, P_ROI_X_MAX=4095,
    parameter [11:0] P_ROI_Y_MIN=0, P_ROI_Y_MAX=4095
) (
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_clear,
    input  wire [23:0]  I_rgb,
    input  wire         I_de,
    input  wire         I_hs,
    input  wire         I_vs,
    input  wire [11:0]  I_x,
    input  wire [11:0]  I_y,
    input  wire         I_frame_start,
    input  wire         I_frame_end,
    input  wire         I_line_start,
    input  wire         I_line_end,
    input  wire         I_frame_is_new,
    input  wire [7:0]   I_bright_min,
    input  wire [7:0]   I_chroma_min,

    output wire [23:0] O_debug_rgb,
    output wire [2:0] O_debug_color, O_debug_filtered_color,
    output wire O_debug_de,
    output reg  [575:0] O_objects,
    output reg  [3:0]   O_count,
    output reg          O_overflow,
    output reg          O_result_toggle,
    output wire [23:0] O_debug_stage_rgb,
    output wire O_debug_stage_de, O_debug_stage_hs, O_debug_stage_vs,
    output wire [11:0] O_debug_stage_x, O_debug_stage_y,
    output wire [415:0] O_debug_boxes,
    output wire [127:0] O_debug_counts,
    output wire O_debug_truncated,
    output wire [95:0] O_diag_frame
);

// CCL state is naturally restarted by every frame_start.  I_clear therefore
// clears only the published/work result banks below; it must not reset the
// colour pipeline on the first pixel of a frame and accidentally discard the
// frame_start marker.
wire pipeline_rst_n = I_rst_n;

wire [23:0] colour_rgb;
wire        colour_de;
wire        colour_hs;
wire        colour_vs;
wire [11:0] colour_x;
wire [11:0] colour_y;
wire        colour_frame_start;
wire        colour_frame_end;
wire        colour_line_start;
wire        colour_line_end;
wire [2:0]  colour_code;
wire [2:0]  colour_weak_code;
wire        colour_binary;

color_detect #(
    .P_BRIGHT_MIN       (P_BRIGHT_MIN),
    .P_RED_MIN          (P_RED_MIN),
    .P_GREEN_MIN        (P_GREEN_MIN),
    .P_BLUE_MIN         (P_BLUE_MIN),
    .P_DOMINANCE_MARGIN (P_DOMINANCE_MARGIN),
    .P_RUNTIME_CONFIG(P_RUNTIME_CONFIG), .P_ALLOW_DARK(1),
    .P_CAMERA_CALIBRATION(P_CAMERA_CALIBRATION),
    .P_ROI_X_MIN(P_ROI_X_MIN), .P_ROI_X_MAX(P_ROI_X_MAX),
    .P_ROI_Y_MIN(P_ROI_Y_MIN), .P_ROI_Y_MAX(P_ROI_Y_MAX)
) u_color_detect (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_bright_min(I_bright_min), .I_chroma_min(I_chroma_min),
    .I_rgb(I_rgb), .I_de(I_de), .I_hs(I_hs), .I_vs(I_vs),
    .I_x(I_x), .I_y(I_y),
    .I_frame_start(I_frame_start), .I_frame_end(I_frame_end),
    .I_line_start(I_line_start), .I_line_end(I_line_end),
    .O_rgb(colour_rgb), .O_de(colour_de),
    .O_hs(colour_hs), .O_vs(colour_vs),
    .O_x(colour_x), .O_y(colour_y),
    .O_frame_start(colour_frame_start),
    .O_frame_end(colour_frame_end),
    .O_line_start(colour_line_start), .O_line_end(colour_line_end),
    .O_color_code(colour_code), .O_binary(colour_binary),
    .O_weak_color_code(colour_weak_code),
    .O_red_mask(), .O_green_mask(), .O_blue_mask()
);

// Independent solid foreground with a bounded per-row background model.
// Seed from three head pixels; adopt a new row seed only when the preceding
// row's opposite edge agrees. This follows wall/table illumination changes
// without learning an isolated target touching the left or right edge.
reg [23:0] background_rgb,background_first,background_second,previous_line_tail;
reg [1:0] background_samples;
reg background_valid,previous_line_valid;
function [7:0] median3;
    input [7:0] a,b,c;
    begin median3=(a>b)?((b>c)?b:((a>c)?c:a)):((a>c)?a:((b>c)?c:b)); end
endfunction
function near_channel;
    input [7:0] a,b;
    reg [7:0] difference;
    begin difference=(a>=b)?a-b:b-a;near_channel=(difference<40);end
endfunction
wire [23:0] row_seed={median3(background_first[23:16],background_second[23:16],colour_rgb[23:16]),
    median3(background_first[15:8],background_second[15:8],colour_rgb[15:8]),
    median3(background_first[7:0],background_second[7:0],colour_rgb[7:0])};
wire row_seed_agrees=near_channel(row_seed[23:16],previous_line_tail[23:16]) &&
    near_channel(row_seed[15:8],previous_line_tail[15:8]) &&
    near_channel(row_seed[7:0],previous_line_tail[7:0]);
always @(posedge I_clk or negedge pipeline_rst_n) begin
    if(!pipeline_rst_n) begin
        background_rgb<=0;background_first<=0;background_second<=0;previous_line_tail<=0;
        background_samples<=3;background_valid<=0;previous_line_valid<=0;
    end else begin
        if(colour_line_end && colour_de) begin
            previous_line_tail<=colour_rgb;previous_line_valid<=1;
        end
        if(colour_frame_start || colour_line_start) begin
            background_samples<=colour_de ? 1 : 0;
            if(colour_de) background_first<=colour_rgb;
            if(colour_frame_start) begin background_valid<=0;previous_line_valid<=0;end
        end else if(colour_de && background_samples!=3) begin
            case(background_samples)
                0: begin background_first<=colour_rgb;background_samples<=1;end
                1: begin background_second<=colour_rgb;background_samples<=2;end
                2: begin
                    if(!background_valid || !previous_line_valid || row_seed_agrees)
                        background_rgb<=row_seed;
                    background_valid<=1;background_samples<=3;
                end
                default: begin end
            endcase
        end
    end
end
wire [7:0] dr = colour_rgb[23:16]>=background_rgb[23:16] ?
    colour_rgb[23:16]-background_rgb[23:16] : background_rgb[23:16]-colour_rgb[23:16];
wire [7:0] dg = colour_rgb[15:8]>=background_rgb[15:8] ?
    colour_rgb[15:8]-background_rgb[15:8] : background_rgb[15:8]-colour_rgb[15:8];
wire [7:0] db = colour_rgb[7:0]>=background_rgb[7:0] ?
    colour_rgb[7:0]-background_rgb[7:0] : background_rgb[7:0]-colour_rgb[7:0];
// Follow gradual background changes locally along a scanline. Freeze while
// inside a contrasting region, so a shaded object cannot be learnt as its own
// background. Colour alone must not turn a slightly tinted table into a mask.
reg [23:0] local_background;
reg local_valid,inside_foreground;
wire [23:0] reference_rgb=(local_valid && colour_x>=4 && !colour_line_start) ?
    local_background:background_rgb;
wire [7:0] lr=colour_rgb[23:16]>=reference_rgb[23:16] ?
    colour_rgb[23:16]-reference_rgb[23:16]:reference_rgb[23:16]-colour_rgb[23:16];
wire [7:0] lg=colour_rgb[15:8]>=reference_rgb[15:8] ?
    colour_rgb[15:8]-reference_rgb[15:8]:reference_rgb[15:8]-colour_rgb[15:8];
wire [7:0] lb=colour_rgb[7:0]>=reference_rgb[7:0] ?
    colour_rgb[7:0]-reference_rgb[7:0]:reference_rgb[7:0]-colour_rgb[7:0];
wire local_enter=(lr>=(P_NEUTRAL_CONTRAST>>1)) ||
    (lg>=(P_NEUTRAL_CONTRAST>>1)) || (lb>=(P_NEUTRAL_CONTRAST>>1));
wire local_stay=(lr>=((P_NEUTRAL_CONTRAST>>1)-(P_NEUTRAL_CONTRAST>>3))) ||
    (lg>=((P_NEUTRAL_CONTRAST>>1)-(P_NEUTRAL_CONTRAST>>3))) ||
    (lb>=((P_NEUTRAL_CONTRAST>>1)-(P_NEUTRAL_CONTRAST>>3)));
// A common illumination change on a tinted background is not a new coloured
// object. Compare opponent channels against the local background; unlike RGB
// distance this rejects a same-hue shadow before it can enter either CCL bank.
// Achromatic backgrounds retain the independent black/white/grey shape path.
wire [7:0] ref_max_rg=reference_rgb[23:16]>reference_rgb[15:8]?reference_rgb[23:16]:reference_rgb[15:8];
wire [7:0] ref_min_rg=reference_rgb[23:16]<reference_rgb[15:8]?reference_rgb[23:16]:reference_rgb[15:8];
wire [7:0] ref_max=ref_max_rg>reference_rgb[7:0]?ref_max_rg:reference_rgb[7:0];
wire [7:0] ref_min=ref_min_rg<reference_rgb[7:0]?ref_min_rg:reference_rgb[7:0];
wire [7:0] chroma_floor=P_RUNTIME_CONFIG?I_chroma_min:8'd16;
wire signed [9:0] opponent_rg=$signed({2'b0,colour_rgb[23:16]})-$signed({2'b0,colour_rgb[15:8]})-
    $signed({2'b0,reference_rgb[23:16]})+$signed({2'b0,reference_rgb[15:8]});
wire signed [9:0] opponent_gb=$signed({2'b0,colour_rgb[15:8]})-$signed({2'b0,colour_rgb[7:0]})-
    $signed({2'b0,reference_rgb[15:8]})+$signed({2'b0,reference_rgb[7:0]});
wire signed [9:0] opponent_rb=$signed({2'b0,colour_rgb[23:16]})-$signed({2'b0,colour_rgb[7:0]})-
    $signed({2'b0,reference_rgb[23:16]})+$signed({2'b0,reference_rgb[7:0]});
wire [9:0] opponent_rg_abs=opponent_rg[9]?-opponent_rg:opponent_rg;
wire [9:0] opponent_gb_abs=opponent_gb[9]?-opponent_gb:opponent_gb;
wire [9:0] opponent_rb_abs=opponent_rb[9]?-opponent_rb:opponent_rb;
wire foreground_separated=(ref_max-ref_min<chroma_floor) ||
    opponent_rg_abs>=chroma_floor || opponent_gb_abs>=chroma_floor || opponent_rb_abs>=chroma_floor;
wire model_foreground=colour_de && !colour_frame_start && background_valid && foreground_separated &&
    (local_enter || (inside_foreground && !colour_line_start && local_stay));
wire [7:0] colour_max_rg=colour_rgb[23:16]>colour_rgb[15:8]?colour_rgb[23:16]:colour_rgb[15:8];
wire [7:0] colour_min_rg=colour_rgb[23:16]<colour_rgb[15:8]?colour_rgb[23:16]:colour_rgb[15:8];
wire [7:0] colour_max=colour_max_rg>colour_rgb[7:0]?colour_max_rg:colour_rgb[7:0];
wire [7:0] colour_min=colour_min_rg<colour_rgb[7:0]?colour_min_rg:colour_rgb[7:0];
// Chromatic evidence defines each coloured silhouette. Low-chroma regions
// retain the existing neutral-shape path under a separate colour label.
wire foreground=P_CAMERA_CALIBRATION ?
    (colour_de && !colour_frame_start && ((colour_weak_code!=0) || (model_foreground && colour_max-colour_min<16))) : model_foreground;
always @(posedge I_clk or negedge pipeline_rst_n) begin
    if(!pipeline_rst_n) begin local_background<=0;local_valid<=0;inside_foreground<=0;end
    else if(colour_de) begin
        inside_foreground<=model_foreground;
        if(colour_line_start || colour_frame_start || colour_x==3) begin
            local_background<=background_rgb;local_valid<=background_valid;
        end else if(!model_foreground && colour_x[3:0]==0) begin
            local_background<=colour_rgb;local_valid<=background_valid;
        end
    end
end
// Code 5 represents foreground with unknown colour; zero is background only.
wire [2:0] candidate_code = foreground ? ((colour_code!=0)?colour_code:3'd5) : 3'd0;
wire[23:0] grown_rgb;
wire grown_de,grown_hs,grown_vs,grown_fs,grown_fe,grown_ls,grown_le,grown_core;
wire[11:0] grown_x,grown_y;wire[2:0] grown_color;
color_hysteresis #(.IMAGE_WIDTH(P_IMAGE_WIDTH),.USE_ERAM(1),.CALIBRATED_WEAK(P_CAMERA_CALIBRATION)) u_color_hysteresis(
 .clk(I_clk),.rst_n(pipeline_rst_n),.rgb(colour_rgb),.de(colour_de),.hs(colour_hs),.vs(colour_vs),
 .x(colour_x),.y(colour_y),.fs(colour_frame_start),.fe(colour_frame_end),
 .ls(colour_line_start),.le(colour_line_end),.foreground(foreground),.core_color(colour_code),
 .calibrated_weak_color(colour_weak_code),
 .out_rgb(grown_rgb),.out_de(grown_de),.out_hs(grown_hs),.out_vs(grown_vs),
 .out_x(grown_x),.out_y(grown_y),.out_fs(grown_fs),.out_fe(grown_fe),
 .out_ls(grown_ls),.out_le(grown_le),.out_color(grown_color),.out_core(grown_core));
reg filtered_core;
always @(posedge I_clk or negedge pipeline_rst_n)begin
 if(!pipeline_rst_n)filtered_core<=0;else filtered_core<=grown_core;
end

wire [23:0] filtered_rgb;
wire        filtered_de;
wire        filtered_hs;
wire        filtered_vs;
wire [11:0] filtered_x;
wire [11:0] filtered_y;
wire        filtered_frame_start;
wire        filtered_frame_end;
wire        filtered_line_start;
wire        filtered_line_end;
wire [2:0]  filtered_color;
wire        filtered_binary;

binary_filter #(.COLOR_AWARE(0),.FILL_NEUTRAL(1)) u_binary_filter (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_rgb(grown_rgb), .I_de(grown_de),
    .I_hs(grown_hs), .I_vs(grown_vs),
    .I_x(grown_x), .I_y(grown_y),
    .I_frame_start(grown_fs),
    .I_frame_end(grown_fe),
    .I_line_start(grown_ls), .I_line_end(grown_le),
    .I_color_code(grown_color), .I_binary(grown_color!=0),
    .O_rgb(filtered_rgb), .O_de(filtered_de),
    .O_hs(filtered_hs), .O_vs(filtered_vs),
    .O_x(filtered_x), .O_y(filtered_y),
    .O_frame_start(filtered_frame_start),
    .O_frame_end(filtered_frame_end),
    .O_line_start(filtered_line_start), .O_line_end(filtered_line_end),
    .O_color_code(filtered_color), .O_binary(filtered_binary)
);

// Three colour stages, two growth stages and one filter stage. NEW reaches CCL
// the same source frame_start, including consecutive zero-blanking rows.
reg [5:0] frame_is_new_delay;
always @(posedge I_clk or negedge pipeline_rst_n) begin
    if(!pipeline_rst_n) frame_is_new_delay<=0;
    else frame_is_new_delay<={frame_is_new_delay[4:0],I_frame_is_new};
end

wire [143:0] component_geometry;
reg [143:0] geometry_d1,geometry_d2,geometry_d3,geometry_d4;
always @(posedge I_clk)begin
 geometry_d1<=component_geometry;geometry_d2<=geometry_d1;
 geometry_d3<=geometry_d2;geometry_d4<=geometry_d3;
end
wire        component_strobe;
wire        component_last;
wire [12:0] component_first_width, component_last_width, component_max_width;
wire [11:0] component_peak_y;
reg [50:0] profile_d1, profile_d2;
always @(posedge I_clk or negedge pipeline_rst_n) begin
    if(!pipeline_rst_n) begin profile_d1<=0; profile_d2<=0; end
    else begin
        profile_d1 <= {component_first_width,component_last_width,
                       component_max_width,component_peak_y};
        profile_d2 <= profile_d1;
    end
end
wire [2:0]  component_index;
wire        component_active;
wire component_present;wire[1:0] component_reject_reason;
wire [2:0]  component_color;
wire [20:0] component_area;
wire [11:0] component_xmin;
wire [11:0] component_ymin;
wire [11:0] component_xmax;
wire [11:0] component_ymax;
wire        component_scan_done;
wire        component_overflow;
wire [15:0] debug_slot_drops,debug_queue_drops,debug_allocations,debug_emitted;
wire [15:0] debug_reclaimed,debug_wide_runs;
wire [7:0] debug_slot_active;
wire debug_slot_overflow,debug_queue_overflow;

// Explicit zero extension keeps the public 12-bit/13-bit result contract.
assign component_first_width[12]=1'b0,component_last_width[12]=1'b0,component_max_width[12]=1'b0;
assign component_peak_y[11]=1'b0,component_xmin[11]=1'b0,component_ymin[11]=1'b0,component_xmax[11]=1'b0,component_ymax[11]=1'b0;
connected_component #(
    .COORD_WIDTH(11), .GEOMETRY(P_CAMERA_CALIBRATION), .INDEPENDENT_COLOR(P_CAMERA_CALIBRATION?0:1),
    .SEPARATE_NEUTRAL(P_CAMERA_CALIBRATION?0:1), .SEEDED_COLOR(P_CAMERA_CALIBRATION?0:1),
    .MAX_COMPONENTS(8),
    .COLOR_PRIORITY(P_CAMERA_CALIBRATION),
    .DEBUG((DEBUG_STAGE==5)||P_SERVO_USB_DIAG),.RECLAIM_SPECKLES(1),.MIN_SEED_RUN(P_MIN_DIM),.MIN_COMPONENT_AREA(P_MIN_AREA),
    .MAX_RUN_WIDTH(P_MAX_OBJECT_WIDTH),
    .MIN_RUN_LENGTH(3),
    .CONNECT_MARGIN(1),
    .MAX_EMPTY_ROWS(P_CAMERA_CALIBRATION?7:1)
) u_connected_component (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_color(filtered_color),.I_core(filtered_core),
 .I_de(filtered_de),
    .I_x(filtered_x[10:0]), .I_y(filtered_y[10:0]),
    .I_line_start(filtered_line_start), .I_line_end(filtered_line_end),
    .I_frame_start(filtered_frame_start), .I_frame_end(filtered_frame_end),
    .I_frame_is_new(frame_is_new_delay[5]),
    .O_geometry(component_geometry),.O_component_strobe(component_strobe),
    .O_component_last(component_last),
    .O_first_width(component_first_width[11:0]), .O_last_width(component_last_width[11:0]),
    .O_max_width(component_max_width[11:0]), .O_peak_y(component_peak_y[10:0]),
    .O_component_index(component_index),
    .O_component_active(component_active),
    .O_component_present(component_present),.O_component_reject_reason(component_reject_reason),
    .O_component_color(component_color),
    .O_component_area(component_area),
    .O_component_xmin(component_xmin[10:0]),
    .O_component_ymin(component_ymin[10:0]),
    .O_component_xmax(component_xmax[10:0]),
    .O_component_ymax(component_ymax[10:0]),
    .O_scan_done(component_scan_done),
    .O_overflow(component_overflow),
    .O_slot_drops(debug_slot_drops),.O_queue_drops(debug_queue_drops),
    .O_allocations(debug_allocations),.O_emitted(debug_emitted),
    .O_reclaimed(debug_reclaimed),.O_wide_runs(debug_wide_runs),
    .O_slot_active(debug_slot_active),.O_slot_overflow(debug_slot_overflow),
    .O_queue_overflow(debug_queue_overflow)
);

wire        feature_strobe;
wire        feature_last;
wire [2:0]  feature_index;
wire        feature_valid;
wire [2:0]  feature_color;
wire [20:0] feature_area;
wire [11:0] feature_xmin, feature_ymin, feature_xmax, feature_ymax;
wire [11:0] feature_width, feature_height;
wire [23:0] feature_bbox_area;

feature_extract #(
    .MIN_AREA(P_MIN_AREA), .MIN_DIM(P_MIN_DIM),
    .MAX_WIDTH(P_MAX_OBJECT_WIDTH), .MAX_HEIGHT(P_MAX_OBJECT_HEIGHT)
) u_feature_extract (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_strobe(component_strobe),
    .I_last(component_last),
    .I_index(component_index), .I_active(component_active),
    .I_color(P_CAMERA_CALIBRATION && component_color==5?3'd0:component_color), .I_area(component_area),
    .I_xmin(component_xmin), .I_ymin(component_ymin),
    .I_xmax(component_xmax), .I_ymax(component_ymax),
    .O_strobe(feature_strobe), .O_last(feature_last),
    .O_index(feature_index), .O_valid(feature_valid),
    .O_color(feature_color), .O_area(feature_area),
    .O_xmin(feature_xmin), .O_ymin(feature_ymin),
    .O_xmax(feature_xmax), .O_ymax(feature_ymax),
    .O_width(feature_width), .O_height(feature_height),
    .O_bbox_area(feature_bbox_area)
);

wire        shape_strobe;
wire        shape_last;
wire [2:0]  shape_index;
wire        shape_valid;
wire [2:0]  shape_color;
wire [2:0]  shape_code;
wire [20:0] shape_area;
wire [11:0] shape_xmin, shape_ymin, shape_xmax, shape_ymax;

// A neutral region open to the image border has no closed object outline.
// Preserve known-colour edge targets; reject the whole-frame background.
wire candidate_closed=(feature_color!=0) ||
    (feature_xmin!=0 && feature_ymin!=0 &&
     feature_xmax<P_IMAGE_WIDTH-1 && feature_ymax<P_IMAGE_HEIGHT-1);
wire candidate_not_frame=!(feature_xmin==0 && feature_ymin==0 &&
    feature_xmax>=P_IMAGE_WIDTH-1 && feature_ymax>=P_IMAGE_HEIGHT-1);
shape_detect #(.USE_PROFILE(1),.COMPACT_TRIANGLES(P_CAMERA_CALIBRATION),.ROUND_PROFILE_REFINE(P_CAMERA_CALIBRATION)) u_shape_detect (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_strobe(feature_strobe), .I_last(feature_last),
    .I_index(feature_index), .I_valid(feature_valid && candidate_closed && candidate_not_frame),
    .I_color(feature_color), .I_area(feature_area),
    .I_xmin(feature_xmin), .I_ymin(feature_ymin),
    .I_xmax(feature_xmax), .I_ymax(feature_ymax),
    .I_width(feature_width), .I_height(feature_height),
    .I_bbox_area(feature_bbox_area),
    .I_first_width(profile_d2[50:38]), .I_last_width(profile_d2[37:25]),
    .I_max_width(profile_d2[24:12]), .I_peak_y(profile_d2[11:0]),
    .O_strobe(shape_strobe), .O_last(shape_last),
    .O_index(shape_index), .O_valid(shape_valid),
    .O_color(shape_color), .O_shape(shape_code), .O_area(shape_area),
    .O_xmin(shape_xmin), .O_ymin(shape_ymin),
    .O_xmax(shape_xmax), .O_ymax(shape_ymax)
);

wire         record_strobe;
wire         record_last;
wire [2:0]   record_index;
wire [143:0] record_data;

wire selected_strobe, selected_last, selected_truncated;
wire [2:0] selected_index;
wire [75:0] selected,ranked;
wire [143:0] ranked_geometry;
wire rank_ready,rank_strobe,rank_last;wire [2:0] rank_index;

// Top4 flags clear at the end of their own emission, before tracker/coordinate
// commit. Retain their event until this frame's result is published.
reg selection_overflow;
always @(posedge I_clk or negedge pipeline_rst_n)begin
 if(!pipeline_rst_n)selection_overflow<=0;
 else if(I_clear || filtered_frame_start)selection_overflow<=0;
 else if(selected_truncated)selection_overflow<=1;
end
generate if(P_CAMERA_CALIBRATION)begin:g_calibrated_rank
top4_select #(.GEOMETRY(1),.PREFER_COLOR(1),.PREFER_CLOSED(1),.IMAGE_WIDTH(P_IMAGE_WIDTH),.IMAGE_HEIGHT(P_IMAGE_HEIGHT),.MERGE_FRAGMENTS(1)) u_rank(
 .clk(I_clk),.rst_n(pipeline_rst_n),.clear(I_clear || I_frame_start),
 .strobe(shape_strobe),.last(shape_last),.valid(shape_valid),
 .color(shape_color),.shape(shape_code),.area(shape_area),
 .xmin(shape_xmin),.ymin(shape_ymin),.xmax(shape_xmax),.ymax(shape_ymax),
 .geometry(geometry_d4),.out_geometry(ranked_geometry),.emit_ready(rank_ready),
 .out_strobe(rank_strobe),.out_last(rank_last),.out_index(rank_index),
 .out_record(ranked),.truncated(selected_truncated),
 .peek_index(2'd0),.peek2_index(2'd0),.patch_valid(1'b0),.patch_index(2'd0),.patch_record(76'd0));
shape_geometry #(.IMAGE_WIDTH(P_IMAGE_WIDTH),.IMAGE_HEIGHT(P_IMAGE_HEIGHT)) u_geometry(
 .clk(I_clk),.rst_n(pipeline_rst_n),.clear(I_clear || I_frame_start),
 .strobe(rank_strobe),.last(rank_last),.index(rank_index),.record_in(ranked),.geometry(ranked_geometry),.ready(rank_ready),
 .out_strobe(selected_strobe),.out_last(selected_last),.out_index(selected_index),.record_out(selected));
end else begin:g_original_fusion
object_candidate_fusion u_top4_select (
    .clk(I_clk), .rst_n(pipeline_rst_n), .clear(I_clear || I_frame_start),
    .strobe(shape_strobe), .last(shape_last), .valid(shape_valid),
    .color(shape_color), .shape(shape_code), .area(shape_area),
    .xmin(shape_xmin), .ymin(shape_ymin), .xmax(shape_xmax), .ymax(shape_ymax),
    .out_strobe(selected_strobe), .out_last(selected_last),
    .out_index(selected_index), .out_record(selected), .truncated(selected_truncated)
);
end endgenerate

// Preserve small reflection fragments through CCL and merging. The minimum
// camera-object scale is an output qualification, not a fragment cutoff.
wire classified_strobe,classified_last;wire[2:0]classified_index;wire[75:0]classified_record;
// Geometry already checks circular silhouettes. A second bbox/fill-only
// classifier could resurrect rejected clutter and cost another multiplier.
assign classified_strobe=selected_strobe;assign classified_last=selected_last;
assign classified_index=selected_index;assign classified_record=selected;
wire [12:0] selected_width={1'b0,classified_record[23:12]}-{1'b0,classified_record[47:36]}+13'd1;
wire [12:0] selected_height={1'b0,classified_record[11:0]}-{1'b0,classified_record[35:24]}+13'd1;
wire [75:0] qualified_selected={classified_record[75] && (!P_CAMERA_CALIBRATION ||
    (classified_record[68:48]>=21'd1024 && selected_width>=13'd32 && selected_height>=13'd32)),classified_record[74:0]};
wire tracked_strobe, tracked_last;
wire [2:0] tracked_index;
wire [75:0] tracked;
wire publish_strobe,publish_last;wire[2:0]publish_index;wire[75:0]publish_record;
assign publish_strobe=tracked_strobe;assign publish_last=tracked_last;assign publish_index=tracked_index;assign publish_record=tracked;
// Bounded, size-relative preview margin covers quantization and colour-edge
// loss without greatly enlarging a small classified circular target.
wire pad_circle=P_CAMERA_CALIBRATION && publish_record[75] && publish_record[71:69]==1;
wire [12:0] publish_width={1'b0,publish_record[23:12]}-{1'b0,publish_record[47:36]}+13'd1;
wire [12:0] publish_height={1'b0,publish_record[11:0]}-{1'b0,publish_record[35:24]}+13'd1;
wire [12:0] smaller_extent=publish_width<publish_height?publish_width:publish_height;
wire [12:0] margin_proposal=smaller_extent>>4;
wire [11:0] box_margin=margin_proposal<4 ? 12'd4 : margin_proposal>12 ? 12'd12 : margin_proposal[11:0];
wire [12:0] padded_xmax={1'b0,publish_record[23:12]}+{1'b0,box_margin};
wire [12:0] padded_ymax={1'b0,publish_record[11:0]}+{1'b0,box_margin};
wire [11:0] output_xmin=pad_circle?(publish_record[47:36]>box_margin?publish_record[47:36]-box_margin:12'd0):publish_record[47:36];
wire [11:0] output_ymin=pad_circle?(publish_record[35:24]>box_margin?publish_record[35:24]-box_margin:12'd0):publish_record[35:24];
wire [11:0] output_xmax=pad_circle?(padded_xmax<P_IMAGE_WIDTH?padded_xmax[11:0]:P_IMAGE_WIDTH-1):publish_record[23:12];
wire [11:0] output_ymax=pad_circle?(padded_ymax<P_IMAGE_HEIGHT?padded_ymax[11:0]:P_IMAGE_HEIGHT-1):publish_record[11:0];

generate if(P_TRACKING) begin : g_tracker
    temporal_tracker #(.CAMERA_ASSOCIATION(P_CAMERA_CALIBRATION),.HOLD_FRAMES(P_CAMERA_CALIBRATION?1:2)) u_tracker (
        .clk(I_clk), .rst_n(pipeline_rst_n), .clear(I_clear),
        .strobe(classified_strobe), .last(classified_last),
        .index(classified_index), .record_in(qualified_selected),
        .out_strobe(tracked_strobe), .out_last(tracked_last),
        .out_index(tracked_index), .record_out(tracked)
    );
end else begin : g_no_tracker
    assign tracked_strobe=classified_strobe;
    assign tracked_last=classified_last;
    assign tracked_index=classified_index;
    assign tracked=qualified_selected;
end endgenerate

// The compute-only board sends binary bounds to the existing system-clock
// formatter. Avoid a second four-object buffer/BCD engine in this clock domain.
generate if(P_COMPACT_OUTPUT)begin:g_compact_output
 assign record_strobe=publish_strobe;
 assign record_last=publish_last;
 assign record_index=publish_index;
 assign record_data={publish_record[75],publish_record[74:72],publish_record[70:69],publish_record[68:48],
  output_xmin,output_ymin,output_xmax,output_ymax,56'd0,publish_record[71],12'd0};
end else begin:g_full_output
coordinate_calc u_coordinate_calc (
    .I_clk(I_clk), .I_rst_n(pipeline_rst_n),
    .I_strobe(publish_strobe), .I_last(publish_last),
    .I_index(publish_index), .I_valid(publish_record[75]),
    .I_color(publish_record[74:72]), .I_shape(publish_record[71:69]), .I_area(publish_record[68:48]),
    .I_xmin(output_xmin), .I_ymin(output_ymin),
    .I_xmax(output_xmax), .I_ymax(output_ymax),
    .O_strobe(record_strobe), .O_last(record_last),
    .O_index(record_index), .O_record(record_data)
);
end endgenerate

reg [143:0] work_record0;
reg [143:0] work_record1;
reg [143:0] work_record2;
reg [143:0] work_record3;
reg [3:0]   work_count;
reg         work_truncated;
reg         scan_overflow;
reg         commit_pending;

always @(posedge I_clk or negedge pipeline_rst_n) begin
    if(!pipeline_rst_n) begin
        work_record0   <= 144'd0;
        work_record1   <= 144'd0;
        work_record2   <= 144'd0;
        work_record3   <= 144'd0;
        work_count     <= 4'd0;
        work_truncated <= 1'b0;
        scan_overflow  <= 1'b0;
        commit_pending <= 1'b0;
        O_objects      <= 576'd0;
        O_count        <= 4'd0;
        O_overflow     <= 1'b0;
        O_result_toggle<= 1'b0;
    end else if(I_clear) begin
        work_record0    <= 144'd0;
        work_record1    <= 144'd0;
        work_record2    <= 144'd0;
        work_record3    <= 144'd0;
        work_count      <= 4'd0;
        work_truncated  <= 1'b0;
        scan_overflow   <= 1'b0;
        commit_pending  <= 1'b0;
        O_objects       <= 576'd0;
        O_count         <= 4'd0;
        O_overflow      <= 1'b0;
        O_result_toggle <= ~O_result_toggle;
    end else begin
        commit_pending <= 1'b0;

        if(component_scan_done)
            scan_overflow <= component_overflow;

        if(record_strobe) begin
            // Index zero marks a new, complete component-table scan.
            if(record_index == 3'd0) begin
                work_record0   <= 144'd0;
                work_record1   <= 144'd0;
                work_record2   <= 144'd0;
                work_record3   <= 144'd0;
                work_count     <= 4'd0;
                work_truncated <= 1'b0;

                if(record_data[143]) begin
                    work_record0 <= record_data;
                    work_count   <= 4'd1;
                end
            end else if(record_data[143]) begin
                case(work_count)
                    4'd0: work_record0 <= record_data;
                    4'd1: work_record1 <= record_data;
                    4'd2: work_record2 <= record_data;
                    4'd3: work_record3 <= record_data;
                    default: work_truncated <= 1'b1;
                endcase
                if(work_count < 4)
                    work_count <= work_count + 1'b1;
            end

            // Commit one clock later so a valid final slot is included.
            if(record_last)
                commit_pending <= 1'b1;
        end

        if(commit_pending) begin
            O_objects       <= {work_record3, work_record2,
                                work_record1, work_record0};
            O_count         <= work_count;
            O_overflow      <= scan_overflow | selection_overflow;
            O_result_toggle <= ~O_result_toggle;
        end
    end
end

assign O_debug_rgb = colour_rgb;
assign O_debug_color = colour_code;
assign O_debug_filtered_color = filtered_color;
assign O_debug_de = colour_de;

// The detector is a side branch; filtered video is deliberately unused.
wire _unused_filtered = filtered_rgb[0] ^ filtered_hs ^ filtered_vs ^
                        filtered_binary;

// All mask displays terminate at the six-clock filtered-pixel transaction.
// The original O_debug ports keep their legacy three-clock contract.
function [23:0] debug_color_rgb;
 input [2:0] c;
 begin case(c)
 1:debug_color_rgb=24'hff0000;2:debug_color_rgb=24'h00ff00;
 3:debug_color_rgb=24'h0000ff;4:debug_color_rgb=24'hffff00;
 5:debug_color_rgb=24'hffffff;default:debug_color_rgb=0;
 endcase end
endfunction
generate if(DEBUG_STAGE>=2 && DEBUG_STAGE<=4)begin:g_debug_masks
 reg [2:0] raw0,raw1,raw2;reg [2:0] fg_delay;
 always @(posedge I_clk or negedge pipeline_rst_n)begin
  if(!pipeline_rst_n)begin raw0<=0;raw1<=0;raw2<=0;fg_delay<=0;end
  else begin raw0<=colour_code;raw1<=raw0;raw2<=raw1;
   fg_delay<={fg_delay[1:0],foreground};end
 end
 assign O_debug_stage_rgb=(DEBUG_STAGE==2)?debug_color_rgb(raw2):
   (DEBUG_STAGE==3)?(fg_delay[2]?24'hffffff:24'd0):debug_color_rgb(filtered_color);
end else begin:g_no_debug_masks
 assign O_debug_stage_rgb=filtered_rgb;
end endgenerate
assign O_debug_stage_de=filtered_de;
assign O_debug_stage_hs=filtered_hs;assign O_debug_stage_vs=filtered_vs;
assign O_debug_stage_x=filtered_x;assign O_debug_stage_y=filtered_y;

generate if(DEBUG_STAGE==5)begin:g_debug_candidates
 reg [415:0] working_boxes,visible_boxes;
 reg [127:0] visible_counts;
 reg [15:0] valid_candidates;
 reg visible_truncated;
 always @(posedge I_clk or negedge pipeline_rst_n)begin
  if(!pipeline_rst_n)begin working_boxes<=0;visible_boxes<=0;visible_counts<=0;
   valid_candidates<=0;visible_truncated<=0;end
  else begin
   if(filtered_frame_start)begin working_boxes<=0;valid_candidates<=0;end
   else begin
    if(component_strobe && component_present)
     working_boxes[component_index*52 +: 52]<={1'b1,component_color,component_xmin,component_ymin,component_xmax,component_ymax};
    if(shape_strobe)begin
     if(shape_valid && valid_candidates!=65535)valid_candidates<=valid_candidates+1'b1;
    end
   end
   if(commit_pending)begin visible_boxes<=working_boxes;
    visible_counts<={(debug_emitted-valid_candidates),valid_candidates,debug_wide_runs,debug_reclaimed,
     debug_queue_drops,debug_slot_drops,debug_emitted,debug_allocations};
    visible_truncated<=selection_overflow;end
  end
 end
 assign O_debug_boxes=visible_boxes;assign O_debug_counts=visible_counts;
 assign O_debug_truncated=visible_truncated;
end else begin:g_no_debug_candidates
 assign O_debug_boxes=0;assign O_debug_counts=0;assign O_debug_truncated=0;
end endgenerate


// Sideband only: commit counters with the same frame as the published objects.
generate if(P_SERVO_USB_DIAG)begin:g_servo_usb_diag
 reg [3:0] present_count,feature_count,shape_count;
 reg scan_slot,scan_queue;
 reg [95:0] published;
 always @(posedge I_clk or negedge pipeline_rst_n)begin
  if(!pipeline_rst_n)begin
   present_count<=0;feature_count<=0;shape_count<=0;
   scan_slot<=0;scan_queue<=0;published<=0;
  end else if(I_clear)begin
   present_count<=0;feature_count<=0;shape_count<=0;
   scan_slot<=0;scan_queue<=0;published<=0;
  end else begin
   if(filtered_frame_start)begin present_count<=0;feature_count<=0;shape_count<=0;end
   else begin
    if(component_strobe && component_present && present_count!=15)present_count<=present_count+1'b1;
    if(feature_strobe && feature_valid && feature_count!=15)feature_count<=feature_count+1'b1;
    if(shape_strobe && shape_valid && shape_count!=15)shape_count<=shape_count+1'b1;
   end
   if(component_scan_done)begin scan_slot<=debug_slot_overflow;scan_queue<=debug_queue_overflow;end
   if(commit_pending)published<={debug_wide_runs,debug_reclaimed,debug_emitted,
    debug_allocations,debug_slot_drops,present_count,feature_count,shape_count,
    scan_queue,scan_slot,selection_overflow,scan_overflow};
  end
 end
 assign O_diag_frame=published;
end else begin:g_no_servo_usb_diag
 assign O_diag_frame=96'd0;
end endgenerate
endmodule
