`timescale 1ns / 1ns

// Frame-blanking component feature extractor.
//
// One raw connected-component record may be accepted on every clock. Width,
// height and bbox area are produced two clocks later. The only multiplier is
// width*height; TD can map it to one DSP shared in time by all components.
module feature_extract #(
    parameter [20:0] MIN_AREA = 21'd256,
    parameter [11:0] MIN_DIM  = 12'd12,
    parameter [11:0] MAX_WIDTH = 12'd4095,
    parameter [11:0] MAX_HEIGHT = 12'd4095
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_strobe,
    input  wire        I_last,
    input  wire [2:0]  I_index,
    input  wire        I_active,
    input  wire [2:0]  I_color,
    input  wire [20:0] I_area,
    input  wire [11:0] I_xmin,
    input  wire [11:0] I_ymin,
    input  wire [11:0] I_xmax,
    input  wire [11:0] I_ymax,

    output reg         O_strobe,
    output reg         O_last,
    output reg  [2:0]  O_index,
    output reg         O_valid,
    output reg  [2:0]  O_color,
    output reg  [20:0] O_area,
    output reg  [11:0] O_xmin,
    output reg  [11:0] O_ymin,
    output reg  [11:0] O_xmax,
    output reg  [11:0] O_ymax,
    output reg  [11:0] O_width,
    output reg  [11:0] O_height,
    output reg  [23:0] O_bbox_area
);

wire bbox_ordered = (I_xmax >= I_xmin) && (I_ymax >= I_ymin);
wire [12:0] width_now  = (I_active && bbox_ordered) ?
    ({1'b0,I_xmax} - {1'b0,I_xmin} + 13'd1) : 13'd0;
wire [12:0] height_now = (I_active && bbox_ordered) ?
    ({1'b0,I_ymax} - {1'b0,I_ymin} + 13'd1) : 13'd0;

reg        strobe_s1;
reg        last_s1;
reg [2:0]  index_s1;
reg        valid_s1;
reg [2:0]  color_s1;
reg [20:0] area_s1;
reg [11:0] xmin_s1, ymin_s1, xmax_s1, ymax_s1;
reg [11:0] width_s1, height_s1;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        strobe_s1 <= 1'b0;
        last_s1 <= 1'b0;
        index_s1 <= 3'd0;
        valid_s1 <= 1'b0;
        color_s1 <= 2'd0;
        area_s1 <= 21'd0;
        xmin_s1 <= 12'd0; ymin_s1 <= 12'd0;
        xmax_s1 <= 12'd0; ymax_s1 <= 12'd0;
        width_s1 <= 12'd0; height_s1 <= 12'd0;
    end else begin
        strobe_s1 <= I_strobe;
        last_s1 <= I_last;
        index_s1 <= I_index;
        color_s1 <= I_color;
        area_s1 <= I_area;
        xmin_s1 <= I_xmin; ymin_s1 <= I_ymin;
        xmax_s1 <= I_xmax; ymax_s1 <= I_ymax;
        width_s1 <= width_now[11:0];
        height_s1 <= height_now[11:0];
        valid_s1 <= I_active && bbox_ordered &&
                    (I_area >= MIN_AREA) &&
                    (width_now >= {1'b0,MIN_DIM}) &&
                    (height_now >= {1'b0,MIN_DIM}) &&
                    (width_now <= {1'b0,MAX_WIDTH}) &&
                    (height_now <= {1'b0,MAX_HEIGHT});
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_strobe <= 1'b0;
        O_last <= 1'b0;
        O_index <= 3'd0;
        O_valid <= 1'b0;
        O_color <= 2'd0;
        O_area <= 21'd0;
        O_xmin <= 12'd0; O_ymin <= 12'd0;
        O_xmax <= 12'd0; O_ymax <= 12'd0;
        O_width <= 12'd0; O_height <= 12'd0;
        O_bbox_area <= 24'd0;
    end else begin
        O_strobe <= strobe_s1;
        O_last <= last_s1;
        O_index <= index_s1;
        O_valid <= valid_s1;
        O_color <= color_s1;
        O_area <= area_s1;
        O_xmin <= xmin_s1; O_ymin <= ymin_s1;
        O_xmax <= xmax_s1; O_ymax <= ymax_s1;
        O_width <= width_s1;
        O_height <= height_s1;
        O_bbox_area <= width_s1 * height_s1;
    end
end

endmodule

