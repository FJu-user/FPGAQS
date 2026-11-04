`timescale 1ns / 1ps

// Low-resource horizontal isolated-pixel suppressor.
//
// For each active centre pixel C, keep C only when the immediately adjacent
// left or right pixel has the same non-background colour code:
//
//     keep(C) = C && ((L == C) || (R == C))
//
// Consequently, a one-pixel colour spike is removed while every pixel in a
// horizontal run of length two or greater is preserved.  Comparisons are
// colour-aware: adjacent red and green pixels do not validate each other.
// I_binary must agree with I_color_code (background=0, colour=non-zero).
//
// I_line_start/I_line_end and I_frame_start/I_frame_end are used as hard
// neighbour barriers.  The final pixel of one row can never become the left
// neighbour of the first pixel of the following row, even when the source
// presents the two rows on consecutive clocks without horizontal blanking.
//
// All O_* sidebands and O_rgb refer to the same filtered centre pixel.
// Latency is exactly one rising edge from this module's input, throughput is
// one pixel/clock, and only two pixels of registers plus equality logic are
// used.  No line RAM, block RAM, multiplier, divider or DSP is inferred.
module binary_filter #(parameter COLOR_AWARE=1, FILL_NEUTRAL=0) (
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
    input  wire [2:0]  I_color_code,
    input  wire        I_binary,

    output wire [23:0] O_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [11:0] O_x,
    output wire [11:0] O_y,
    output wire        O_frame_start,
    output wire        O_frame_end,
    output wire        O_line_start,
    output wire        O_line_end,
    output wire [2:0]  O_color_code,
    output wire        O_binary
);

localparam [2:0] COLOR_BACKGROUND = 2'd0;

// Centre pixel: the transaction that is emitted on the next clock.
reg [23:0] center_rgb;
reg        center_de;
reg        center_hs;
reg        center_vs;
reg [11:0] center_x;
reg [11:0] center_y;
reg        center_frame_start;
reg        center_frame_end;
reg        center_line_start;
reg        center_line_end;
reg [2:0]  center_color_code;
reg        center_binary;

// Only the fields needed to qualify the left neighbour are retained.
reg        left_de;
reg        left_frame_end;
reg        left_line_end;
reg [2:0]  left_color_code;
reg        left_binary;

wire left_is_same = left_de && left_binary &&
                    !left_line_end && !left_frame_end &&
                    !center_line_start && !center_frame_start &&
                    (!COLOR_AWARE || left_color_code == center_color_code);

wire right_is_same = I_de && I_binary &&
                     !I_line_start && !I_frame_start &&
                     !center_line_end && !center_frame_end &&
                     (!COLOR_AWARE || I_color_code == center_color_code);

wire keep_center = center_de && center_binary &&
                   (center_color_code != COLOR_BACKGROUND) &&
                   (left_is_same || right_is_same);
// Close exactly one background pixel between equal colours. Never replace
// a pixel of another colour, or connect across a line/frame boundary.
wire fill_hole = (COLOR_AWARE || FILL_NEUTRAL) && center_de &&
    (!center_binary || (FILL_NEUTRAL && center_color_code==5)) &&
    left_de && left_binary && left_color_code>=1 && left_color_code<=4 &&
    I_de && I_binary && left_color_code == I_color_code &&
    !left_line_end && !left_frame_end && !center_line_start &&
    !center_frame_start && !center_line_end && !center_frame_end &&
    !I_line_start && !I_frame_start;

// Sidebands come from the registered centre pixel.  The decision itself is
// combinational over L/C/R, so no otherwise-redundant output register stage
// is added after the one-pixel look-ahead register.
assign O_rgb          = center_rgb;
assign O_de           = center_de;
assign O_hs           = center_hs;
assign O_vs           = center_vs;
assign O_x            = center_x;
assign O_y            = center_y;
assign O_frame_start  = center_frame_start;
assign O_frame_end    = center_frame_end;
assign O_line_start   = center_line_start;
assign O_line_end     = center_line_end;
assign O_color_code   = fill_hole ? left_color_code :
                        keep_center ? center_color_code : COLOR_BACKGROUND;
assign O_binary       = keep_center || fill_hole;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        center_rgb          <= 24'd0;
        center_de           <= 1'b0;
        center_hs           <= 1'b0;
        center_vs           <= 1'b0;
        center_x            <= 12'd0;
        center_y            <= 12'd0;
        center_frame_start  <= 1'b0;
        center_frame_end    <= 1'b0;
        center_line_start   <= 1'b0;
        center_line_end     <= 1'b0;
        center_color_code   <= COLOR_BACKGROUND;
        center_binary       <= 1'b0;

        left_de             <= 1'b0;
        left_frame_end      <= 1'b0;
        left_line_end       <= 1'b0;
        left_color_code     <= COLOR_BACKGROUND;
        left_binary         <= 1'b0;

    end else begin
        left_de         <= center_de;
        left_frame_end  <= center_frame_end;
        left_line_end   <= center_line_end;
        left_color_code <= center_color_code;
        left_binary     <= center_binary;

        center_rgb          <= I_rgb;
        center_de           <= I_de;
        center_hs           <= I_hs;
        center_vs           <= I_vs;
        center_x            <= I_x;
        center_y            <= I_y;
        center_frame_start  <= I_frame_start;
        center_frame_end    <= I_frame_end;
        center_line_start   <= I_line_start;
        center_line_end     <= I_line_end;
        center_color_code   <= I_color_code;
        center_binary       <= I_binary;
    end
end

endmodule
