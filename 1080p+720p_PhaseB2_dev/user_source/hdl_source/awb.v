`timescale 1ns / 1ns

// Deterministic ISP colour stage with the original camera-to-DDR timing
// contract preserved.
//
// The camera FIFO is reset from a frame-start token that historically arrives
// well before the first post-ISP valid beat.  Removing the original 50-beat
// AWB delay made data reach the FIFO before that cross-domain reset completed;
// the first words of every frame were discarded, producing split/stair-step
// pictures (especially at 1080p).  This implementation keeps that proven lead
// time.  Colour correction uses slowly updated frame statistics, coarse
// shift/add gains and a fixed-latency pixel pipeline; there are no per-pixel
// dividers or general multipliers.
module awb #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [11:0] I_img_width,
    input  wire [11:0] I_img_height,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output wire        I_tready,
    output wire        O_tlast,
    output wire        O_tuser,
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    output reg  [23:0] O_frame_luma_sum,
    output reg  [15:0] O_frame_sample_count,
    output reg         O_frame_stats_toggle,
    input  wire        O_tready
);

// Nine coarse gains from 1.000 to 1.500 in 1/16 steps.  Every choice is made
// only from shifts/adds; no per-pixel divider or general multiplier is used.
// Algebraically identical to the nine original cases: truncate each
// fractional term BEFORE adding. Share three conditional adders instead of
// building independent add trees for every gain selection.
function [7:0] apply_coarse_gain;
    input [7:0] value;
    input [3:0] gain_index;
    reg [8:0] scaled,partial_lo;
    reg [6:0] partial_hi;
    begin
        partial_lo = {1'b0,value} + (gain_index[0] ? {5'd0,value[7:4]} : 9'd0);
        partial_hi = (gain_index[1] ? {2'd0,value[7:3]} : 7'd0) +
                     (gain_index[2] ? {1'd0,value[7:2]} : 7'd0);
        // Balanced add tree: at most two carry-propagating levels. All legal
        // and default selections are <=382, so nine bits are exact.
        scaled = gain_index[3] ? ({1'b0,value}+{2'd0,value[7:1]}) :
                                (partial_lo+{2'd0,partial_hi});
        apply_coarse_gain = scaled[8] ? 8'hff : scaled[7:0];
    end
endfunction

function [23:0] adaptive_white_balance;
    input [23:0] rgb;
    input [3:0] gain_r_index;
    input [3:0] gain_b_index;
    begin
        adaptive_white_balance = {apply_coarse_gain(rgb[23:16],gain_r_index),
                                  rgb[15:8],
                                  apply_coarse_gain(rgb[7:0],gain_b_index)};
    end
endfunction

function [7:0] luma_approx;
    input [23:0] rgb;
    reg [9:0] sum;
    begin
        sum = {2'b00,rgb[23:18]} +
              {1'b0,rgb[15:9]} +
              {2'b00,rgb[7:2]};
        luma_approx = sum[7:0];
    end
endfunction

function [7:0] shadow_lift;
    input [7:0] value;
    reg [7:0] distance;
    reg [9:0] mapped;
    begin
        if(value < 8'd64) begin
            mapped = {2'b00,value} + ({2'b00,value} >> 1);
        end else if(value < 8'd192) begin
            distance = value - 8'd64;
            mapped = 10'd96 + {2'b00,distance} -
                     ({2'b00,distance} >> 4);
        end else begin
            distance = value - 8'd192;
            mapped = 10'd216 + (({2'b00,distance} +
                                  ({2'b00,distance} << 2) + 10'd4) >> 3);
        end
        shadow_lift = (mapped > 10'd255) ? 8'hff : mapped[7:0];
    end
endfunction

// The old shadow_lift(Y)-Y is always 0..32. These three identities
// preserve its integer rounding for EVERY 8-bit Y, with six result bits.
function [5:0] brightness_delta;
    input [23:0] rgb;
    reg [7:0] y;
    reg [7:0] three_distance_plus3;
    begin
        y = luma_approx(rgb);
        three_distance_plus3 = {2'd0,y[5:0]} + {1'd0,y[5:0],1'b0} + 8'd3;
        if(y<8'd64) brightness_delta={1'b0,y[5:1]};
        else if(y<8'd192) brightness_delta=6'd36-{2'd0,y[7:4]};
        else brightness_delta=6'd24-{1'b0,three_distance_plus3[7:3]};
    end
endfunction

function [7:0] saturated_add;
    input [7:0] base;
    input [5:0] delta;
    reg [8:0] result;
    begin
        result={1'b0,base}+{3'd0,delta};
        saturated_add=result[8]?8'hff:result[7:0];
    end
endfunction

function [23:0] apply_delta;
    input [23:0] rgb;
    input [5:0] delta;
    begin
        apply_delta = {saturated_add(rgb[23:16],delta),
                       saturated_add(rgb[15:8],delta),
                       saturated_add(rgb[7:0],delta)};
    end
endfunction

reg [95:0] data_s1;
reg [95:0] wb_s2;
reg [95:0] wb_s3;
reg [95:0] corrected_s4;
reg        valid_s1;
reg        valid_s2;
reg        valid_s3;
reg        valid_s4;
reg [5:0] delta0_s3;
reg [5:0] delta1_s3;
reg [5:0] delta2_s3;
reg [5:0] delta3_s3;

// Frame-statistics white balance.  Only one pixel from every eighth 96-bit
// word and every eighth line in the central half-frame is examined.  Pixels
// with a large channel spread are ignored so a coloured object cannot quickly
// drag the white balance.  Gains move at most one 1/16 step every four frames.
reg [3:0] awb_gain_r_index;
reg [3:0] awb_gain_b_index;
reg [1:0] awb_update_div;
reg [9:0] stat_word_x;
reg [11:0] stat_y;
reg [23:0] stat_r_sum;
reg [23:0] stat_g_sum;
reg [23:0] stat_b_sum;
reg [23:0] stat_luma_sum;
reg [15:0] stat_sample_count;
reg [15:0] stat_neutral_count;

wire [9:0] stat_words_per_line = I_img_width[11:2];
wire [9:0] stat_x_margin = stat_words_per_line >> 2;
wire [11:0] stat_y_margin = I_img_height >> 2;
wire stat_in_center = (stat_word_x >= stat_x_margin) &&
                      (stat_word_x < (stat_words_per_line-stat_x_margin)) &&
                      (stat_y >= stat_y_margin) &&
                      (stat_y < (I_img_height-stat_y_margin));
wire stat_subsample = (stat_word_x[2:0] == 3'd0) &&
                      (stat_y[2:0] == 3'd0);
wire [23:0] stat_raw_pixel = I_tdata[23:0];
wire [23:0] stat_wb_pixel = adaptive_white_balance(stat_raw_pixel,
                                                    awb_gain_r_index,
                                                    awb_gain_b_index);
wire [7:0] stat_raw_max_rg = (stat_raw_pixel[23:16] > stat_raw_pixel[15:8]) ?
                              stat_raw_pixel[23:16] : stat_raw_pixel[15:8];
wire [7:0] stat_raw_max = (stat_raw_max_rg > stat_raw_pixel[7:0]) ?
                           stat_raw_max_rg : stat_raw_pixel[7:0];
wire [7:0] stat_raw_min_rg = (stat_raw_pixel[23:16] < stat_raw_pixel[15:8]) ?
                              stat_raw_pixel[23:16] : stat_raw_pixel[15:8];
wire [7:0] stat_raw_min = (stat_raw_min_rg < stat_raw_pixel[7:0]) ?
                           stat_raw_min_rg : stat_raw_pixel[7:0];
wire stat_neutral_chroma = ((stat_raw_max-stat_raw_min) <= 8'd48);

// Isolate coarse gain selection from the statistic accumulators.  The sampled
// pixel is registered first, so the 120 MHz path never contains gain select,
// luma calculation and a wide accumulator in one cycle.
reg        stat_sample_valid_s1;
reg        stat_sample_neutral_s1;
reg [23:0] stat_sample_wb_s1;
wire [7:0] stat_sample_luma_s1 = luma_approx(stat_sample_wb_s1);

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        awb_gain_r_index    <= 4'd2;
        awb_gain_b_index    <= 4'd2;
        awb_update_div      <= 2'd0;
        stat_word_x         <= 10'd0;
        stat_y              <= 12'd0;
        stat_r_sum          <= 24'd0;
        stat_g_sum          <= 24'd0;
        stat_b_sum          <= 24'd0;
        stat_luma_sum       <= 24'd0;
        stat_sample_count   <= 16'd0;
        stat_neutral_count  <= 16'd0;
        O_frame_luma_sum    <= 24'd0;
        O_frame_sample_count<= 16'd0;
        O_frame_stats_toggle<= 1'b0;
        stat_sample_valid_s1  <= 1'b0;
        stat_sample_neutral_s1<= 1'b0;
        stat_sample_wb_s1     <= 24'd0;
    end else if(I_tuser) begin
        stat_word_x <= 10'd0;
        stat_y      <= 12'd0;
        stat_sample_valid_s1 <= 1'b0;

        // AE receives all central, subsampled pixels.  Keeping this population
        // separate from the neutral-only AWB set prevents a coloured scene
        // from starving exposure control.
        if(stat_sample_count >= 16'd128) begin
            O_frame_luma_sum     <= stat_luma_sum;
            O_frame_sample_count <= stat_sample_count;
            O_frame_stats_toggle <= ~O_frame_stats_toggle;
        end

        if(stat_neutral_count >= 16'd128) begin
            awb_update_div <= awb_update_div + 1'b1;
            if(awb_update_div == 2'd3) begin
                if((stat_r_sum + (stat_r_sum >> 5)) < stat_g_sum) begin
                    if(awb_gain_r_index < 4'd8)
                        awb_gain_r_index <= awb_gain_r_index + 1'b1;
                end else if(stat_r_sum > (stat_g_sum + (stat_g_sum >> 5))) begin
                    if(awb_gain_r_index > 4'd0)
                        awb_gain_r_index <= awb_gain_r_index - 1'b1;
                end

                if((stat_b_sum + (stat_b_sum >> 5)) < stat_g_sum) begin
                    if(awb_gain_b_index < 4'd8)
                        awb_gain_b_index <= awb_gain_b_index + 1'b1;
                end else if(stat_b_sum > (stat_g_sum + (stat_g_sum >> 5))) begin
                    if(awb_gain_b_index > 4'd0)
                        awb_gain_b_index <= awb_gain_b_index - 1'b1;
                end
            end
        end

        stat_r_sum        <= 24'd0;
        stat_g_sum        <= 24'd0;
        stat_b_sum        <= 24'd0;
        stat_luma_sum     <= 24'd0;
        stat_sample_count <= 16'd0;
        stat_neutral_count<= 16'd0;
    end else begin
        stat_sample_valid_s1 <= I_tvalid && stat_in_center && stat_subsample;
        if(I_tvalid && stat_in_center && stat_subsample) begin
            stat_sample_wb_s1      <= stat_wb_pixel;
            stat_sample_neutral_s1 <= stat_neutral_chroma;
        end

        if(stat_sample_valid_s1) begin
            stat_luma_sum     <= stat_luma_sum + stat_sample_luma_s1;
            stat_sample_count <= stat_sample_count + 1'b1;

            if(stat_sample_neutral_s1 &&
               (stat_sample_luma_s1 >= 8'd24) &&
               (stat_sample_luma_s1 <= 8'd232)) begin
                stat_r_sum         <= stat_r_sum + stat_sample_wb_s1[23:16];
                stat_g_sum         <= stat_g_sum + stat_sample_wb_s1[15:8];
                stat_b_sum         <= stat_b_sum + stat_sample_wb_s1[7:0];
                stat_neutral_count <= stat_neutral_count + 1'b1;
            end
        end

        if(I_tvalid) begin
            if(stat_word_x == stat_words_per_line-1'b1) begin
                stat_word_x <= 10'd0;
                if(stat_y == I_img_height-1'b1)
                    stat_y <= 12'd0;
                else
                    stat_y <= stat_y + 1'b1;
            end else begin
                stat_word_x <= stat_word_x + 1'b1;
            end
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        data_s1      <= 96'd0;
        wb_s2        <= 96'd0;
        wb_s3        <= 96'd0;
        corrected_s4 <= 96'd0;
        valid_s1     <= 1'b0;
        valid_s2     <= 1'b0;
        valid_s3     <= 1'b0;
        valid_s4     <= 1'b0;
        delta0_s3    <= 6'd0;
        delta1_s3    <= 6'd0;
        delta2_s3    <= 6'd0;
        delta3_s3    <= 6'd0;
    end else begin
        // Stage 1: isolate the demosaic output.
        data_s1  <= I_tdata;
        valid_s1 <= I_tvalid;

        // Stage 2: slowly adapting R/B white balance, shifts/adds only.
        wb_s2[23:0]  <= adaptive_white_balance(data_s1[23:0],
                                               awb_gain_r_index,
                                               awb_gain_b_index);
        wb_s2[47:24] <= adaptive_white_balance(data_s1[47:24],
                                               awb_gain_r_index,
                                               awb_gain_b_index);
        wb_s2[71:48] <= adaptive_white_balance(data_s1[71:48],
                                               awb_gain_r_index,
                                               awb_gain_b_index);
        wb_s2[95:72] <= adaptive_white_balance(data_s1[95:72],
                                               awb_gain_r_index,
                                               awb_gain_b_index);
        valid_s2 <= valid_s1;

        // Stage 3: compute one luma lift per pixel. RGB is registered beside
        // it, so the high-rate 1080p path does not contain the whole function.
        wb_s3     <= wb_s2;
        delta0_s3 <= brightness_delta(wb_s2[23:0]);
        delta1_s3 <= brightness_delta(wb_s2[47:24]);
        delta2_s3 <= brightness_delta(wb_s2[71:48]);
        delta3_s3 <= brightness_delta(wb_s2[95:72]);
        valid_s3  <= valid_s2;

        // Stage 4: common per-pixel delta preserves colour differences unless
        // a channel reaches saturation.
        corrected_s4[23:0]  <= apply_delta(wb_s3[23:0],delta0_s3);
        corrected_s4[47:24] <= apply_delta(wb_s3[47:24],delta1_s3);
        corrected_s4[71:48] <= apply_delta(wb_s3[71:48],delta2_s3);
        corrected_s4[95:72] <= apply_delta(wb_s3[95:72],delta3_s3);
        valid_s4 <= valid_s3;
    end
end

wire [95:0] delayed_data;
wire        delayed_valid;
wire        delayed_frame_start_unused;

// Preserve the original 50-valid-beat lead between SOF and image data. This
// gives video_in enough time to synchronize SOF into the DDR domain and reset
// its asynchronous FIFO before the first word is written.
awb_line_delay #(
    .IMG_HEIGHT  (IMG_HEIGHT),
    .IMG_WIDTH   (IMG_WIDTH),
    .DATA_WIDTH  (96),
    .DELAY_CYCLE (50)
) u_camera_fifo_guard_delay (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .I_img_width  (I_img_width),
    .I_img_height (I_img_height),
    .I_tuser      (I_tuser),
    .I_valid      (valid_s4),
    .I_data       (corrected_s4),
    .O_valid      (delayed_valid),
    .O_data       (delayed_data),
    .O_tuser      (delayed_frame_start_unused)
);

reg delayed_valid_d;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
        delayed_valid_d <= 1'b0;
    else
        delayed_valid_d <= delayed_valid;
end

assign I_tready = O_tready;
assign O_tdata  = delayed_data;
assign O_tvalid = delayed_valid;
// Deliberately early, matching the board-proven pre-fix FIFO-reset contract.
assign O_tuser  = I_tuser;
assign O_tlast  = delayed_valid_d && !delayed_valid;

// I_tlast is not consumed by video_in; reference it to keep lint clean.
wire unused_tlast = I_tlast;

endmodule

// Keep this helper in the same source file as awb.  TD otherwise treats the
// delay as a black box when a separately added HDL/IP file has not been
// committed into the project file set currently held by the GUI.
//
// The active video width is 1280/4 = 320 or 1920/4 = 480 words, so a
// 512-entry inferred true-dual-port RAM is sufficient for both modes.  The
// read side starts DELAY_CYCLE clocks after the first word of every line and
// completes during horizontal blanking, matching the original board design's
// early-SOF/data-late contract.
module awb_line_delay #(
    parameter IMG_HEIGHT  = 1080,
    parameter IMG_WIDTH   = 1920,
    parameter DATA_WIDTH  = 96,
    parameter DELAY_CYCLE = 50
) (
    input                         I_clk,
    input                         I_rst_n,
    input      [11:0]             I_img_width,
    input      [11:0]             I_img_height,
    input                         I_tuser,
    input                         I_valid,
    input      [DATA_WIDTH-1:0]   I_data,
    output                        O_valid,
    output     [DATA_WIDTH-1:0]   O_data,
    output                        O_tuser
);

localparam RAM_ADDR_WIDTH = 9;
localparam RAM_DEPTH      = 512;

reg [DATA_WIDTH-1:0] line_mem [0:RAM_DEPTH-1];
reg [RAM_ADDR_WIDTH-1:0] wr_addr;
reg [RAM_ADDR_WIDTH-1:0] rd_addr;
reg [DATA_WIDTH-1:0]     input_data_d;
reg [DATA_WIDTH-1:0]     output_data_r;
reg                      input_valid_d;
reg                      read_valid;
reg                      read_valid_d;
reg [9:0]                h_count;
reg [11:0]               v_count;
reg [9:0]                read_count;

wire [9:0] words_per_line = I_img_width[11:2];

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        input_data_d  <= {DATA_WIDTH{1'b0}};
        input_valid_d <= 1'b0;
    end else begin
        input_data_d  <= I_data;
        input_valid_d <= I_valid;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser) begin
        h_count <= 10'd0;
        v_count <= 12'd0;
    end else if(input_valid_d) begin
        if(h_count == words_per_line - 1'b1) begin
            h_count <= 10'd0;
            if(v_count == I_img_height - 1'b1)
                v_count <= 12'd0;
            else
                v_count <= v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser)
        read_valid <= 1'b0;
    else if(h_count == DELAY_CYCLE - 3)
        read_valid <= 1'b1;
    else if(read_count == words_per_line - 1'b1)
        read_valid <= 1'b0;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser)
        read_count <= 10'd0;
    else if(read_count == words_per_line)
        read_count <= 10'd0;
    else if(read_valid)
        read_count <= read_count + 1'b1;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser)
        wr_addr <= {RAM_ADDR_WIDTH{1'b0}};
    else if(input_valid_d) begin
        if(wr_addr == words_per_line - 1'b1)
            wr_addr <= {RAM_ADDR_WIDTH{1'b0}};
        else
            wr_addr <= wr_addr + 1'b1;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser)
        rd_addr <= {RAM_ADDR_WIDTH{1'b0}};
    else if(read_valid) begin
        if(rd_addr == words_per_line - 1'b1)
            rd_addr <= {RAM_ADDR_WIDTH{1'b0}};
        else
            rd_addr <= rd_addr + 1'b1;
    end
end

// One write port and one synchronous read port.  Keeping both accesses in one
// clocked block gives deterministic read-before-write behavior and allows TD
// synthesis to infer embedded RAM instead of 512x96 flip-flops.
always @(posedge I_clk) begin
    if(input_valid_d)
        line_mem[wr_addr] <= input_data_d;
    output_data_r <= line_mem[rd_addr];
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || I_tuser)
        read_valid_d <= 1'b0;
    else
        read_valid_d <= read_valid;
end

assign O_valid = read_valid_d;
assign O_data  = output_data_r;
assign O_tuser = (v_count == 0) && (read_count == 1);

// Parameters retained for interface/documentation compatibility.
wire unused_parameters = (IMG_HEIGHT == 0) || (IMG_WIDTH == 0);

endmodule
