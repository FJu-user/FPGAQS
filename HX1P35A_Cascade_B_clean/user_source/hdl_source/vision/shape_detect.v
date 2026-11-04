`timescale 1ns / 1ns

// Division-free regular-shape classifier.
// Shape code: 0 unknown, 1 circle, 2 triangle, 3 rectangle.
// Latency: two clocks, throughput: one component record per clock.
//
// Stage 1 forms shift/add cross-products and the aspect-ratio flag. Stage 2
// performs only comparisons and classification, keeping the blanking-time
// result path short at the 149.343 MHz HDMI pixel clock.
module shape_detect #(parameter USE_PROFILE=0,COMPACT_TRIANGLES=0,ROUND_PROFILE_REFINE=0) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_strobe,
    input  wire        I_last,
    input  wire [2:0]  I_index,
    input  wire        I_valid,
    input  wire [2:0]  I_color,
    input  wire [20:0] I_area,
    input  wire [11:0] I_xmin,
    input  wire [11:0] I_ymin,
    input  wire [11:0] I_xmax,
    input  wire [11:0] I_ymax,
    input  wire [11:0] I_width,
    input  wire [11:0] I_height,
    input  wire [23:0] I_bbox_area,
    input  wire [12:0] I_first_width, I_last_width, I_max_width,
    input  wire [11:0] I_peak_y,

    output reg         O_strobe,
    output reg         O_last,
    output reg  [2:0]  O_index,
    output reg         O_valid,
    output reg  [2:0]  O_color,
    output reg  [2:0]  O_shape,
    output reg  [20:0] O_area,
    output reg  [11:0] O_xmin,
    output reg  [11:0] O_ymin,
    output reg  [11:0] O_xmax,
    output reg  [11:0] O_ymax
);

localparam [2:0] SHAPE_UNKNOWN   = 3'd0;
localparam [2:0] SHAPE_CIRCLE    = 3'd1;
localparam [2:0] SHAPE_TRIANGLE  = 3'd2;
localparam [2:0] SHAPE_SQUARE = 3'd4;
localparam [2:0] SHAPE_RECTANGLE = 3'd3;

// Recover a circular main body with a narrow same-hue appendage. Use the
// measured maximum scanline and its plateau centre, never image coordinates.
wire [25:0] profile_square=I_max_width*I_max_width;
wire [28:0] profile5=({3'd0,profile_square}<<2)+{3'd0,profile_square};
wire [28:0] profile7=({3'd0,profile_square}<<3)-{3'd0,profile_square};
wire [28:0] profile_area8={8'd0,I_area}<<3;
wire round_body_refine=ROUND_PROFILE_REFINE && I_color>=1 && I_color<=4 && I_max_width>=32 &&
 (({2'd0,I_first_width}<<2)<(({2'd0,I_max_width}<<1)+{2'd0,I_max_width})) &&
 (({2'd0,I_last_width}<<2)<(({2'd0,I_max_width}<<1)+{2'd0,I_max_width})) &&
 ({2'd0,I_height}>{1'b0,I_max_width}+({1'b0,I_max_width}>>3)) &&
 ({2'd0,I_height}<=({1'b0,I_max_width}<<1)) &&
 ({2'd0,I_width}<={1'b0,I_max_width}+({1'b0,I_max_width}>>3)) &&
 profile_area8>=profile5 && profile_area8<=profile7;
wire [12:0] profile_extent=I_max_width+13'd4;
wire tail_above=({1'b0,I_peak_y}-{1'b0,I_ymin})>({1'b0,I_ymax}-{1'b0,I_peak_y});
wire [12:0] top_from_bottom={1'b0,I_ymax}+13'd1-profile_extent;
wire [12:0] bottom_from_top={1'b0,I_ymin}+profile_extent-13'd1;
wire [11:0] refined_ymin=round_body_refine && tail_above && top_from_bottom>{1'b0,I_ymin}?top_from_bottom[11:0]:I_ymin;
wire [11:0] refined_ymax=round_body_refine && !tail_above && bottom_from_top<{1'b0,I_ymax}?bottom_from_top[11:0]:I_ymax;
wire [23:0] classification_bbox=round_body_refine?profile_square[23:0]:I_bbox_area;

wire [26:0] area_x4_now = ({6'd0,I_area} << 2);
wire [26:0] area_x8_now = ({6'd0,I_area} << 3);
wire [26:0] area_x16_now = ({6'd0,I_area} << 4);
wire [26:0] bbox_x3_now = ({3'd0,classification_bbox} << 1) +
                          {3'd0,classification_bbox};
wire [26:0] bbox_x5_now = ({3'd0,classification_bbox} << 2) +
                          {3'd0,classification_bbox};
wire [26:0] bbox_x7_now = ({3'd0,classification_bbox} << 3) -
                          {3'd0,classification_bbox};
wire [26:0] bbox_x11_now = ({3'd0,classification_bbox} << 3) +
                           ({3'd0,classification_bbox} << 1) +
                           {3'd0,classification_bbox};
wire [14:0] width_x5_now  = ({3'd0,I_width} << 2) + {3'd0,I_width};
wire [14:0] height_x5_now = ({3'd0,I_height} << 2) + {3'd0,I_height};
wire [14:0] width_x4_now  = ({3'd0,I_width} << 2);
wire [14:0] height_x4_now = ({3'd0,I_height} << 2);

reg        strobe_s1;
reg        last_s1;
reg [2:0]  index_s1;
reg        valid_s1;
reg [2:0]  color_s1;
reg [20:0] area_s1;
reg [11:0] xmin_s1, ymin_s1, xmax_s1, ymax_s1;
reg [26:0] area_x4_s1, area_x8_s1, area_x16_s1;
reg [26:0] bbox_x3_s1, bbox_x5_s1, bbox_x7_s1, bbox_x11_s1;
reg        near_square_s1;
reg square_aspect_s1;
reg triangle_aspect_s1;
wire [14:0] width_x3_now=({3'd0,I_width}<<1)+{3'd0,I_width};
wire [14:0] height_x3_now=({3'd0,I_height}<<1)+{3'd0,I_height};
reg rectangle_profile_s1, triangle_profile_s1, circle_profile_s1;
reg dense_profile_s1, color_region_s1;
wire [14:0] fw4 = {2'b0,I_first_width} << 2;
wire [14:0] lw4 = {2'b0,I_last_width} << 2;
wire [14:0] mw3 = ({2'b0,I_max_width} << 1) + I_max_width;
wire [14:0] mw2 = {2'b0,I_max_width} << 1;
wire [12:0] peak_offset = {1'b0,I_peak_y}-{1'b0,I_ymin};

reg [2:0] classified_shape;
always @(*) begin
    classified_shape = SHAPE_UNKNOWN;
    if(valid_s1 && (bbox_x3_s1 != 27'd0)) begin
        // Triangle: 37.5%..62.5% bbox fill.
        // High occupancy and a broad measured scanline tolerate a few narrow
        // edge rows from antialiasing/exposure, without treating circles as boxes.
        if(USE_PROFILE && dense_profile_s1 && (area_x8_s1 >= bbox_x7_s1))
            classified_shape = square_aspect_s1 ? SHAPE_SQUARE : SHAPE_RECTANGLE;
        else if(rectangle_profile_s1 && (area_x4_s1 >= bbox_x3_s1) && USE_PROFILE)
            classified_shape = square_aspect_s1 ? SHAPE_SQUARE : SHAPE_RECTANGLE;
        else if(triangle_profile_s1 && (!COMPACT_TRIANGLES || triangle_aspect_s1) && (area_x8_s1 >= bbox_x3_s1) &&
           (area_x8_s1 <= bbox_x5_s1))
            classified_shape = SHAPE_TRIANGLE;
        // Circle: 68.75%..87.5% fill and aspect ratio about 0.8..1.25.
        else if(circle_profile_s1 && near_square_s1 && (area_x8_s1 >= bbox_x5_s1) &&
                (area_x8_s1 <= bbox_x7_s1))
            classified_shape = SHAPE_CIRCLE;
        // A solid rectangle, including a square, normally fills >=75%.
        else if(rectangle_profile_s1 && (area_x4_s1 >= bbox_x3_s1))
            classified_shape = square_aspect_s1 ? SHAPE_SQUARE : SHAPE_RECTANGLE;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        strobe_s1 <= 1'b0;
        last_s1 <= 1'b0;
        index_s1 <= 3'd0;
        valid_s1 <= 1'b0;
        color_s1 <= 3'd0;
        area_s1 <= 21'd0;
        xmin_s1 <= 13'd0; ymin_s1 <= 13'd0;
        xmax_s1 <= 13'd0; ymax_s1 <= 13'd0;
        area_x4_s1 <= 27'd0; area_x8_s1 <= 27'd0;
        area_x16_s1 <= 27'd0;
        bbox_x3_s1 <= 27'd0; bbox_x5_s1 <= 27'd0; bbox_x7_s1 <= 27'd0;
        bbox_x11_s1 <= 27'd0;
        near_square_s1 <= 1'b0; square_aspect_s1<=0;triangle_aspect_s1<=0;
        rectangle_profile_s1<=0; triangle_profile_s1<=0; circle_profile_s1<=0;
        dense_profile_s1<=0; color_region_s1<=0;
    end else begin
        strobe_s1 <= I_strobe;
        last_s1 <= I_last;
        index_s1 <= I_index;
        valid_s1 <= I_valid && (I_bbox_area != 24'd0);
        color_s1 <= I_color;
        area_s1 <= I_area;
        xmin_s1 <= I_xmin; ymin_s1 <= refined_ymin;
        xmax_s1 <= I_xmax; ymax_s1 <= refined_ymax;
        area_x4_s1 <= area_x4_now;
        area_x8_s1 <= area_x8_now;
        area_x16_s1 <= area_x16_now;
        bbox_x3_s1 <= bbox_x3_now;
        bbox_x5_s1 <= bbox_x5_now;
        bbox_x7_s1 <= bbox_x7_now;
        bbox_x11_s1 <= bbox_x11_now;
        triangle_aspect_s1 <= width_x3_now>={3'd0,I_height} && height_x3_now>={3'd0,I_width};
        square_aspect_s1 <= ({1'b0,I_width}+({1'b0,I_width}>>3) >= {1'b0,I_height}) &&
                            ({1'b0,I_height}+({1'b0,I_height}>>3) >= {1'b0,I_width});
        near_square_s1 <= round_body_refine || ((width_x5_now >= height_x4_now) &&
                          (height_x5_now >= width_x4_now));
        dense_profile_s1 <= ({2'b0,I_max_width}<<2) >=
            (({3'b0,I_width}<<1)+{3'b0,I_width});
        // Shape UNKNOWN may still carry colour, but a sparse wire/background
        // envelope is not a credible solid colour region. No shape is required.
        color_region_s1 <= (area_x4_now >= {3'b0,I_bbox_area}) &&
            ({3'b0,I_width} <= height_x4_now) &&
            ({3'b0,I_height} <= width_x4_now);
        rectangle_profile_s1 <= !USE_PROFILE ||
            (fw4 >= mw3 && lw4 >= mw3);
        triangle_profile_s1 <= !USE_PROFILE ||
            // Require a broad base opposite the narrow apex, with the peak
            // at that base. Two narrow ends plus low fill are ambiguous:
            // a damaged sphere can have exactly that profile. Keep UNKNOWN.
            ((fw4 <= mw2 && lw4 >= mw3 &&
              peak_offset >= (({1'b0,I_height}>>1)+({1'b0,I_height}>>2))) ||
             (lw4 <= mw2 && fw4 >= mw3 &&
              peak_offset < ({1'b0,I_height}>>2)));
        circle_profile_s1 <= !USE_PROFILE ||
            (fw4 < mw3 && lw4 < mw3 &&
             peak_offset >= ({1'b0,I_height} >> 2) &&
             peak_offset <= (({1'b0,I_height} >> 1)+({1'b0,I_height} >> 2)));
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_strobe <= 1'b0;
        O_last <= 1'b0;
        O_index <= 3'd0;
        O_valid <= 1'b0;
        O_color <= 3'd0;
        O_shape <= SHAPE_UNKNOWN;
        O_area <= 21'd0;
        O_xmin <= 13'd0; O_ymin <= 13'd0;
        O_xmax <= 13'd0; O_ymax <= 13'd0;
    end else begin
        O_strobe <= strobe_s1;
        O_last <= last_s1;
        O_index <= index_s1;
        O_valid <= valid_s1 && (((color_s1!=0) && color_region_s1) ||
                                (classified_shape != SHAPE_UNKNOWN));
        O_color <= color_s1;
        O_shape <= classified_shape;
        O_area <= area_s1;
        O_xmin <= xmin_s1; O_ymin <= ymin_s1;
        O_xmax <= xmax_s1; O_ymax <= ymax_s1;
    end
end

endmodule
