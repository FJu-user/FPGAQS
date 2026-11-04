`timescale 1ns/1ps
// RGB888 -> exclusive 3-bit colour label. 0 background, 1 red, 2 green,
// 3 blue, 4 yellow. Three clocks of latency; all sidebands follow RGB.
// Register extrema, then chroma/eligibility, then hue decisions to meet the
// 149.343 MHz pixel clock without adding latency to the display path.
module color_detect #(
    parameter [7:0] P_BRIGHT_MIN       = 8'd64,
    parameter [7:0] P_RED_MIN          = 8'd80,
    parameter [7:0] P_GREEN_MIN        = 8'd80,
    parameter [7:0] P_BLUE_MIN         = 8'd80,
    parameter [7:0] P_DOMINANCE_MARGIN = 8'd40,
    parameter [7:0] P_CHROMA_MIN = 8'd16,
    parameter integer P_RUNTIME_CONFIG = 0,
    parameter integer P_ALLOW_DARK = 0,
    parameter integer P_CAMERA_CALIBRATION = 0,
    parameter [11:0] P_ROI_X_MIN=0, P_ROI_X_MAX=4095,
    parameter [11:0] P_ROI_Y_MIN=0, P_ROI_Y_MAX=4095
) (
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_start,
    input  wire        I_frame_end,
    input  wire        I_line_start,
    input  wire        I_line_end,
    input  wire [7:0]  I_bright_min,
    input  wire [7:0]  I_chroma_min,

    output reg  [23:0] O_rgb,
    output reg         O_de,
    output reg         O_hs,
    output reg         O_vs,
    output reg  [11:0] O_x,
    output reg  [11:0] O_y,
    output reg         O_frame_start,
    output reg         O_frame_end,
    output reg         O_line_start,
    output reg         O_line_end,

    output reg  [2:0]  O_color_code,
    output reg         O_binary,
    output reg         O_red_mask,
    output reg         O_green_mask,
    output reg         O_yellow_mask,
    output reg         O_blue_mask,
    output reg [2:0]   O_weak_color_code
);


wire [7:0] r = I_rgb[23:16], g = I_rgb[15:8], b = I_rgb[7:0];
wire [7:0] max_rg_now = r > g ? r : g;
wire [7:0] min_rg_now = r < g ? r : g;
reg [7:0] r1,g1,b1,max_rg1,min_rg1,value1,minimum1;
reg [7:0] bright1,chroma_min1;
reg roi1;
reg [7:0] r2,g2,b2,max_rg2,min_rg2,chroma2;
reg eligible2,dark2,weak_eligible2;
reg [54:0] pixel1,pixel2;
wire [7:0] chroma_now = value1 - minimum1;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        r1<=0;g1<=0;b1<=0;max_rg1<=0;min_rg1<=0;value1<=0;minimum1<=0;
        bright1<=0;chroma_min1<=0;roi1<=0;
        r2<=0;g2<=0;b2<=0;max_rg2<=0;min_rg2<=0;chroma2<=0;eligible2<=0;dark2<=0;weak_eligible2<=0;
        pixel1<=0;pixel2<=0;
    end else begin
        r1<=r;g1<=g;b1<=b;max_rg1<=max_rg_now;min_rg1<=min_rg_now;
        value1 <= max_rg_now > b ? max_rg_now : b;
        minimum1 <= min_rg_now < b ? min_rg_now : b;
        bright1 <= P_RUNTIME_CONFIG ? I_bright_min : P_BRIGHT_MIN;
        chroma_min1 <= P_RUNTIME_CONFIG ? I_chroma_min : P_CHROMA_MIN;
        roi1 <= I_de && I_x>=P_ROI_X_MIN && I_x<=P_ROI_X_MAX &&
                       I_y>=P_ROI_Y_MIN && I_y<=P_ROI_Y_MAX;
        pixel1 <= {I_rgb,I_de,I_hs,I_vs,I_x,I_y,I_frame_start,I_frame_end,I_line_start,I_line_end};
        pixel2<=pixel1;
        r2<=r1;g2<=g1;b2<=b1;max_rg2<=max_rg1;min_rg2<=min_rg1;chroma2<=chroma_now;
        // Strongly chromatic dark surfaces retain hue below the normal noise
        // floor. Weakly saturated pixels still need the original brightness.
        eligible2<=P_CAMERA_CALIBRATION ?
            (roi1 && value1>=(bright1>>1) && chroma_now>=chroma_min1 &&
             ({2'd0,chroma_now}<<2)>={2'd0,value1}) :
            (roi1 && chroma_now>=chroma_min1 && chroma_now>=(value1>>3) &&
            ((value1>=bright1) ||
             (P_ALLOW_DARK && value1>=(bright1>>1) && chroma_now>=(value1>>2))));
        weak_eligible2<=P_CAMERA_CALIBRATION && roi1 && value1>=20 && chroma_now>=8 &&
            ({4'd0,chroma_now}<<4)>=(({4'd0,value1}<<1)+{4'd0,value1});
        dark2<=P_ALLOW_DARK && value1<bright1;
    end
end
// The existing half-brightness dark branch uses the same exposure scaling
// for absolute hue dominance. Its chroma and relative saturation guards still
// apply; normal-brightness tinted backgrounds keep the full margin.
wire [8:0] relative_margin = {1'b0,chroma2} >> 2;
wire [8:0] absolute_margin = P_CAMERA_CALIBRATION ? 9'd6 : dark2 ? ({1'b0,P_DOMINANCE_MARGIN} >> 1) :
    {1'b0,P_DOMINANCE_MARGIN};
wire [8:0] hue_margin = relative_margin>absolute_margin ? relative_margin : absolute_margin;
wire yellow_hit = eligible2 &&
    ({1'b0,min_rg2} > {1'b0,b2} + hue_margin) &&
    (P_CAMERA_CALIBRATION ?
     (({1'b0,max_rg2}-{1'b0,min_rg2})<<1)<={1'b0,chroma2} :
     ({1'b0,max_rg2} - {1'b0,min_rg2} <= (({1'b0,chroma2} >> 1)+({1'b0,chroma2} >> 2))));
wire [8:0] green_minus_red={1'b0,g2}-{1'b0,r2};
wire [8:0] green_minus_blue={1'b0,g2}-{1'b0,b2};
wire calibrated_green_sector=({2'd0,green_minus_blue}<<2)>=
    (({2'd0,green_minus_red}<<1)+{2'd0,green_minus_red});
wire calibrated_weak_green_sector=({1'b0,green_minus_blue}<<1)>={1'b0,green_minus_red};
wire red_hit = eligible2 && !yellow_hit &&
    ({1'b0,r2} > {1'b0,g2}+hue_margin) &&
    (P_CAMERA_CALIBRATION ? ({1'b0,r2}>{1'b0,b2}+hue_margin) : r2>b2);
wire green_hit = eligible2 && !yellow_hit &&
    ({1'b0,g2} > {1'b0,r2}+hue_margin) &&
    (P_CAMERA_CALIBRATION ? (({1'b0,g2}>{1'b0,b2}+hue_margin)&&calibrated_green_sector) : g2>b2);
wire blue_hit = eligible2 && !yellow_hit &&
    ({1'b0,b2} > {1'b0,max_rg2}+hue_margin);
reg [2:0] code;
wire [8:0] weak_margin=relative_margin>9'd4 ? relative_margin : 9'd4;
wire weak_yellow=weak_eligible2 && ({1'b0,min_rg2}>{1'b0,b2}+weak_margin) &&
    (({1'b0,max_rg2}-{1'b0,min_rg2})<<1)<={1'b0,chroma2};
reg [2:0] weak_code;
always @* begin
    code=0;
    if(yellow_hit) code=4;
    else if(red_hit) code=1;
    else if(green_hit) code=2;
    else if(blue_hit) code=3;
    weak_code=0;
    if(weak_yellow)weak_code=4;
    else if(weak_eligible2 && ({1'b0,r2}>{1'b0,g2}+weak_margin) && ({1'b0,r2}>{1'b0,b2}+weak_margin))weak_code=1;
    else if(weak_eligible2 && ({1'b0,g2}>{1'b0,r2}+weak_margin) && ({1'b0,g2}>{1'b0,b2}+weak_margin) && calibrated_weak_green_sector)weak_code=2;
    else if(weak_eligible2 && ({1'b0,b2}>{1'b0,max_rg2}+weak_margin))weak_code=3;
end
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        {O_rgb,O_de,O_hs,O_vs,O_x,O_y,O_frame_start,O_frame_end,O_line_start,O_line_end}<=0;
        O_color_code<=0;O_binary<=0;
        O_red_mask<=0;O_green_mask<=0;O_blue_mask<=0;O_yellow_mask<=0;
        O_weak_color_code<=0;
    end else begin
        {O_rgb,O_de,O_hs,O_vs,O_x,O_y,O_frame_start,O_frame_end,O_line_start,O_line_end}<=pixel2;
        O_color_code<=code;O_binary<=code!=0;
        O_red_mask<=code==1;O_green_mask<=code==2;O_blue_mask<=code==3;O_yellow_mask<=code==4;
        O_weak_color_code<=weak_code;
    end
end
// Per-channel minima remain for source compatibility. Core dominance, shared
// brightness and chroma are separate from bounded weak-body growth.
endmodule

