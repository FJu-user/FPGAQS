`timescale 1ns/1ns

// A union box is a motion-region hint, not a connected-component/person count.
// All statistics consume the existing completed-block stream. No frame/line
// RAM, multiplication, division, or per-pixel counters are added.
module motion_region_overlay_v1 #(
    parameter integer MIN_BLOCKS = 4,
    parameter integer QUIET_FRAMES = 3
) (
    input wire I_clk, I_rst_n, I_enable, I_soft_reset,
    input wire I_frame_start, I_frame_end, I_frame_is_new,
    input wire I_event_valid, I_motion,
    input wire [7:0] I_block_x, I_block_y,
    input wire I_overlay,
    input wire [11:0] I_active_width,
    input wire [11:0] I_x, I_y,
    output reg O_border, O_text,
    output reg O_box_valid,
    output reg [7:0] O_x_min, O_x_max, O_y_min, O_y_max,
    output reg [15:0] O_event_bcd
);
    localparam integer HIT_W = $clog2(MIN_BLOCKS+1);
    localparam integer QUIET_W = $clog2(QUIET_FRAMES+1);
    reg [HIT_W-1:0] hits;
    reg [7:0] x_min, x_max, y_min, y_max;
    reg pending_valid;
    reg [7:0] pending_x_min, pending_x_max, pending_y_min, pending_y_max;
    reg [15:0] event_bcd;
    reg in_event;
    reg [QUIET_W-1:0] quiet_count;

    wire hit = I_event_valid && I_motion;
    wire [HIT_W-1:0] hits_next = hit && (hits < MIN_BLOCKS) ? hits+1'b1 : hits;
    wire [7:0] x_min_next = hit && ((hits == 0) || I_block_x < x_min) ? I_block_x : x_min;
    wire [7:0] x_max_next = hit && ((hits == 0) || I_block_x > x_max) ? I_block_x : x_max;
    wire [7:0] y_min_next = hit && ((hits == 0) || I_block_y < y_min) ? I_block_y : y_min;
    wire [7:0] y_max_next = hit && ((hits == 0) || I_block_y > y_max) ? I_block_y : y_max;
    wire frame_motion = hits_next >= MIN_BLOCKS;

    function [15:0] increment_bcd;
        input [15:0] value;
        begin
            increment_bcd = value;
            if(value != 16'h9999) begin
                if(value[3:0] != 9) increment_bcd[3:0] = value[3:0]+1'b1;
                else begin
                    increment_bcd[3:0] = 0;
                    if(value[7:4] != 9) increment_bcd[7:4] = value[7:4]+1'b1;
                    else begin
                        increment_bcd[7:4] = 0;
                        if(value[11:8] != 9) increment_bcd[11:8] = value[11:8]+1'b1;
                        else begin
                            increment_bcd[11:8] = 0;
                            increment_bcd[15:12] = value[15:12]+1'b1;
                        end
                    end
                end
            end
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            hits <= 0;
            x_min <= 0; x_max <= 0; y_min <= 0; y_max <= 0;
            pending_valid <= 0;
            pending_x_min <= 0; pending_x_max <= 0;
            pending_y_min <= 0; pending_y_max <= 0;
            event_bcd <= 0; in_event <= 0; quiet_count <= 0;
            O_box_valid <= 0; O_event_bcd <= 0;
            O_x_min <= 0; O_x_max <= 0; O_y_min <= 0; O_y_max <= 0;
        end else if(I_soft_reset || !I_enable) begin
            hits <= 0;
            pending_valid <= 0;
            event_bcd <= 0; in_event <= 0; quiet_count <= 0;
            O_box_valid <= 0; O_event_bcd <= 0;
        end else begin
            // Only SOF publishes results, so box and decimal digits are
            // constant over the whole displayed frame, including repeats.
            if(I_frame_start) begin
                O_box_valid <= pending_valid;
                O_x_min <= pending_x_min; O_x_max <= pending_x_max;
                O_y_min <= pending_y_min; O_y_max <= pending_y_max;
                O_event_bcd <= event_bcd;
            end
            if(hit) begin
                hits <= hits_next;
                x_min <= x_min_next; x_max <= x_max_next;
                y_min <= y_min_next; y_max <= y_max_next;
            end
            if(I_frame_end && I_frame_is_new) begin
                pending_valid <= frame_motion;
                pending_x_min <= x_min_next; pending_x_max <= x_max_next;
                pending_y_min <= y_min_next; pending_y_max <= y_max_next;
                hits <= 0;
                if(frame_motion) begin
                    quiet_count <= 0;
                    in_event <= 1;
                    if(!in_event) event_bcd <= increment_bcd(event_bcd);
                end else if(in_event) begin
                    if(quiet_count == QUIET_FRAMES-1) begin
                        in_event <= 0;
                        quiet_count <= 0;
                    end else quiet_count <= quiet_count+1'b1;
                end
            end
        end
    end

    function [34:0] glyph;
        input [7:0] c;
        begin
            case(c)
                "0":glyph=35'b01110_10001_10011_10101_11001_10001_01110;
                "1":glyph=35'b00100_01100_00100_00100_00100_00100_01110;
                "2":glyph=35'b01110_10001_00001_00010_00100_01000_11111;
                "3":glyph=35'b11110_00001_00001_01110_00001_00001_11110;
                "4":glyph=35'b00010_00110_01010_10010_11111_00010_00010;
                "5":glyph=35'b11111_10000_10000_11110_00001_00001_11110;
                "6":glyph=35'b01110_10000_10000_11110_10001_10001_01110;
                "7":glyph=35'b11111_00001_00010_00100_01000_01000_01000;
                "8":glyph=35'b01110_10001_10001_01110_10001_10001_01110;
                "9":glyph=35'b01110_10001_10001_01111_00001_00001_01110;
                "E":glyph=35'b11111_10000_10000_11110_10000_10000_11111;
                "V":glyph=35'b10001_10001_10001_10001_10001_01010_00100;
                "T":glyph=35'b11111_00100_00100_00100_00100_00100_00100;
                ":":glyph=35'b00000_00100_00100_00000_00100_00100_00000;
                default:glyph=0;
            endcase
        end
    endfunction
    // Right-aligned 128-pixel label, below the resolution label (y<32).
    // The width already belongs to the p_* pixel transaction.
    wire [11:0] text_x_start = I_active_width-12'd144;
    wire [11:0] text_x = I_x-text_x_start;
    wire [11:0] text_y = I_y-12'd48;
    reg [7:0] text_char;
    reg [34:0] glyph_bits;
    reg text_on;
    always @(*) begin
        case(text_x[6:4])
            0:text_char="E";
            1:text_char="V";
            2:text_char="T";
            3:text_char=":";
            4:text_char={4'h3,O_event_bcd[15:12]};
            5:text_char={4'h3,O_event_bcd[11:8]};
            6:text_char={4'h3,O_event_bcd[7:4]};
            7:text_char={4'h3,O_event_bcd[3:0]};
        endcase
        glyph_bits = glyph(text_char);
        text_on = 0;
        if(I_x >= text_x_start && text_x < 12'd128 &&
           I_y >= 48 && I_y < 62 && text_x[3:0] < 10)
            text_on = glyph_bits[34-(text_y[3:1]*5)-text_x[3:1]];
    end
    wire in_box = O_box_valid && I_x[11:3] >= {1'b0,O_x_min} &&
                  I_x[11:3] <= {1'b0,O_x_max} &&
                  I_y[11:3] >= {1'b0,O_y_min} && I_y[11:3] <= {1'b0,O_y_max};
    wire on_edge = (I_x[11:3] == {1'b0,O_x_min} && I_x[2:0] < 2) ||
                   (I_x[11:3] == {1'b0,O_x_max} && I_x[2:0] >= 6) ||
                   (I_y[11:3] == {1'b0,O_y_min} && I_y[2:0] < 2) ||
                   (I_y[11:3] == {1'b0,O_y_max} && I_y[2:0] >= 6);
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin O_border <= 0; O_text <= 0; end
        else begin
            O_border <= I_overlay && in_box && on_edge;
            O_text <= I_overlay && text_on;
        end
    end
endmodule

