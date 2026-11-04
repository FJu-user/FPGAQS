`timescale 1ns / 1ns

// Shared lightweight multi-mode algorithm chain.
// Mode 0: original RGB
// Mode 1: BT.601-style weighted luma displayed as gray
// Mode 2: luma tone curve, then signed saturated delta applied to RGB
// Mode 3: frame-adaptive threshold binary image
// Mode 4: shared-window Sobel magnitude
// Mode 5: 3x3 Gaussian local adaptive binary image
// Mode 6: strict 3x3 erosion of Mode-5 mask
// Mode 7: opening = Mode-6 erosion followed by strict 3x3 dilation
// Mode 8: shared-window 3x3 gray median filter
// Mode 9: colour-preserving Gamma 1/2.2 correction
// Mode 10: colour-preserving preceding-frame histogram equalization
// Mode 11: 8-level/channel colour quantization with shared Sobel black edges
// Mode 12: colour-preserving CLAHE-Lite V2 on the shared BT.601 luma
// Mode 13: migrated ronghe Mode1/Mode28 8x8 motion-adaptive temporal IIR
// Mode 14: migrated ronghe Mode2/Mode16 max-channel Sobel sharpening
// Mode 15: full-screen 8/16/32-pixel sample-and-hold Mosaic
// Mode 16: migrated ronghe Mode3 bilateral filter (median + sigma LUT)
//
// Every branch has a twenty-cycle fixed latency and one-pixel-per-clock flow.
module pixel_chain_v1 #(parameter MOTION_OVERLAY=0) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire        I_mode_1080,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_start,
    input  wire        I_frame_end,
    input  wire        I_line_start,
    input  wire        I_line_end,
    input  wire [1:0]  I_display_bank,
    input  wire [7:0]  I_frame_seq,
    input  wire        I_frame_is_new,
    input  wire        I_new_frame_pulse,
    input  wire [4:0]  I_algorithm_mode,
    input  wire [7:0]  I_threshold,
    input  wire [7:0]  I_strength,
    input  wire [7:0]  I_config_epoch,
    input  wire        I_soft_reset,
    input wire I_context_reset,
    input wire I_motion_overlay,
    // Phase B2 mask-source contract. The current board path drives LOCAL_MASK
    // (all zeros below); future Color Detection may drive an aligned external
    // mask without adding a second morphology chain.
    input  wire        I_mask_source_sel,
    input  wire        I_external_mask,
    input  wire        I_external_mask_valid,
    output reg  [23:0] O_rgb,
    output wire [23:0] O_raw_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [11:0] O_x,
    output wire [11:0] O_y,
    output wire        O_frame_start,
    output wire        O_frame_end,
    output wire        O_line_start,
    output wire        O_line_end,
    output wire [1:0]  O_display_bank,
    output wire [7:0]  O_frame_seq,
    output wire        O_frame_is_new,
    output wire        O_new_frame_pulse,
    output wire [4:0]  O_algorithm_mode,
    output wire [7:0]  O_threshold,
    output wire [7:0]  O_strength,
    output wire [7:0]  O_config_epoch
);

function [7:0] tone_curve;
    input [7:0] value;
    reg [7:0] distance;
    reg [9:0] mapped;
    begin
        // Monotonic LUT-equivalent curve: lift shadows, gently compress the
        // middle range and protect highlights. Endpoints remain 0 and 255.
        if(value < 8'd64) begin
            mapped = {2'b00,value} + ({2'b00,value} >> 1);
        end else if(value < 8'd192) begin
            distance = value - 8'd64;
            mapped = 10'd96 + {2'b00,distance} - ({2'b00,distance} >> 4);
        end else begin
            distance = value - 8'd192;
            mapped = 10'd216 + (({2'b00,distance} +
                                  ({2'b00,distance} << 2) + 10'd4) >> 3);
        end
        if(mapped > 10'd255)
            tone_curve = 8'hff;
        else
            tone_curve = mapped[7:0];
    end
endfunction

function [7:0] saturated_add;
    input [7:0] base;
    input signed [8:0] delta;
    reg signed [9:0] result;
    begin
        // Extend both operands before addition.  A 9-bit signed expression
        // would otherwise wrap when a saturated colour channel is bright.
        result = $signed({2'b00,base}) + $signed({delta[8],delta});
        if(result < 0)
            saturated_add = 8'h00;
        else if(result > 10'sd255)
            saturated_add = 8'hff;
        else
            saturated_add = result[7:0];
    end
endfunction

wire [7:0] red_in   = I_rgb[23:16];
wire [7:0] green_in = I_rgb[15:8];
wire [7:0] blue_in  = I_rgb[7:0];

(* dsp_style="yes" *) reg [15:0] red_term_s1;
(* dsp_style="yes" *) reg [15:0] green_term_s1;
(* dsp_style="yes" *) reg [15:0] blue_term_s1;
reg [23:0] rgb_s1;
reg [4:0]  mode_s1;
reg [7:0]  threshold_s1;
reg [7:0]  strength_s1;

reg [7:0]  luma_s2;
reg [23:0] rgb_s2;
reg [4:0]  mode_s2;
reg [7:0]  threshold_s2;
reg [7:0]  strength_s2;

reg [7:0]  luma_s3;
reg [7:0]  tone_s3;
reg [7:0]  binary_s3;
reg [23:0] rgb_s3;
reg [4:0]  mode_s3;

reg [23:0] base_rgb_s4;
reg [4:0]  base_mode_s4;

// The exact BT.601 luma becomes valid after stage 2.  Carry just the spatial
// coordinates and valid bit by the same two clocks into the shared window.
reg        spatial_de_s1, spatial_de_s2;
reg [11:0] spatial_x_s1, spatial_x_s2;
reg [11:0] spatial_y_s1, spatial_y_s2;
reg        spatial_frame_end_s1, spatial_frame_end_s2;
reg        spatial_frame_is_new_s1, spatial_frame_is_new_s2;
reg        spatial_soft_reset_s1, spatial_soft_reset_s2;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        spatial_de_s1 <= 1'b0;
        spatial_de_s2 <= 1'b0;
        spatial_x_s1 <= 12'd0;
        spatial_x_s2 <= 12'd0;
        spatial_y_s1 <= 12'd0;
        spatial_y_s2 <= 12'd0;
        spatial_frame_end_s1 <= 1'b0;
        spatial_frame_end_s2 <= 1'b0;
        spatial_frame_is_new_s1 <= 1'b0;
        spatial_frame_is_new_s2 <= 1'b0;
        spatial_soft_reset_s1 <= 1'b0;
        spatial_soft_reset_s2 <= 1'b0;
    end else begin
        spatial_de_s1 <= I_de;
        spatial_de_s2 <= spatial_de_s1;
        spatial_x_s1 <= I_x;
        spatial_x_s2 <= spatial_x_s1;
        spatial_y_s1 <= I_y;
        spatial_y_s2 <= spatial_y_s1;
        spatial_frame_end_s1 <= I_frame_end;
        spatial_frame_end_s2 <= spatial_frame_end_s1;
        spatial_frame_is_new_s1 <= I_frame_is_new;
        spatial_frame_is_new_s2 <= spatial_frame_is_new_s1;
        spatial_soft_reset_s1 <= I_soft_reset;
        spatial_soft_reset_s2 <= spatial_soft_reset_s1;
    end
end

// Mode 3 uses a sparse full-frame mean from the preceding frame. This keeps
// the threshold constant inside a frame, adapts to dark faces and costs only
// adders/counters (no histogram RAM, multiplier or divider).
reg [20:0] luma_sample_sum;
reg [13:0] luma_sample_count;
reg [7:0]  adaptive_threshold;
wire [9:0] approx_luma_sum = {2'b00,red_in[7:2]} +
                             {1'b0,green_in[7:1]} +
                             {2'b00,blue_in[7:2]};
wire [7:0] approx_luma = approx_luma_sum[7:0];
wire sample_pixel = I_de && (I_x[3:0] == 4'd0) &&
                    (I_y[3:0] == 4'd0);
// 1080p contributes about 8160 samples, so /8192 is sufficient. 720p
// contributes 3600 samples; multiplying by 1.125 then /4096 approximates
// /3641. Both errors are below about 1.2 percent without a divider.
wire [21:0] low_res_scaled = {1'b0,luma_sample_sum} +
                             ({1'b0,luma_sample_sum} >> 3);
wire [7:0] measured_threshold = (luma_sample_count > 14'd4096) ?
                                luma_sample_sum[20:13] :
                                low_res_scaled[19:12];
wire [7:0] bounded_threshold = (measured_threshold < 8'd40) ? 8'd40 :
                               (measured_threshold > 8'd176) ? 8'd176 :
                               measured_threshold;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        luma_sample_sum    <= 21'd0;
        luma_sample_count  <= 14'd0;
        adaptive_threshold <= 8'd128;
    end else if(I_soft_reset) begin
        luma_sample_sum    <= 21'd0;
        luma_sample_count  <= 14'd0;
        adaptive_threshold <= I_threshold;
    end else if(I_frame_start) begin
        if(luma_sample_count != 14'd0)
            adaptive_threshold <= bounded_threshold;
        luma_sample_sum   <= 21'd0;
        luma_sample_count <= 14'd0;
    end else if(sample_pixel) begin
        luma_sample_sum   <= luma_sample_sum + {13'd0,approx_luma};
        luma_sample_count <= luma_sample_count + 14'd1;
    end
end

wire signed [8:0] tone_delta = $signed({1'b0,tone_s3}) -
                               $signed({1'b0,luma_s3});
wire [23:0] tone_rgb = {
    saturated_add(rgb_s3[23:16], tone_delta),
    saturated_add(rgb_s3[15:8],  tone_delta),
    saturated_add(rgb_s3[7:0],   tone_delta)
};

// Mode 11 quantization is pure bit selection. It is captured by the existing
// stage-4 base RGB register, so the quantized colour and shared Sobel result
// both reach the final mode mux at stage 13 without another pipeline or RAM.
wire [23:0] cartoon_quantized_rgb_s3;
cartoon_quantizer_v1 u_cartoon_quantizer_v1 (
    .I_rgb(rgb_s3),
    .O_rgb(cartoon_quantized_rgb_s3)
);

// Mode 12 CLAHE reuses the common registered BT.601 luma/RGB stage.  The
// donor algorithm core is unchanged; only its already-measured C13 tap is
// admitted to the BASE twenty-cycle tail below.
wire [23:0] clahe_rgb_s2;
wire        clahe_de_s2;
clahe_lite_v2 u_clahe_lite_v2 (
    .I_clk           (I_clk),
    .I_rst_n         (I_rst_n),
    .I_context_reset (I_context_reset),
    .I_mode_1080     (I_mode_1080),
    .I_active_width  (I_active_width),
    .I_active_height (I_active_height),
    .I_rgb           (rgb_s2),
    .I_luma          (luma_s2),
    .I_de            (spatial_de_s2),
    .I_x             (spatial_x_s2),
    .I_y             (spatial_y_s2),
    .I_frame_end     (spatial_frame_end_s2),
    .I_frame_is_new  (spatial_frame_is_new_s2),
    .O_rgb           (clahe_rgb_s2),
    .O_de            (clahe_de_s2)
);

// Mode 15 Mosaic also starts from the common C2 transaction.  It remains a
// block-row cache only; no line buffer or frame memory is introduced.
wire [23:0] mosaic_rgb_s2;
wire        mosaic_de_s2;
wire        mosaic_hs_s2;
wire        mosaic_vs_s2;
wire [11:0] mosaic_x_s2;
wire [11:0] mosaic_y_s2;
mosaic_v1 #(.MAX_BLOCKS(240)) u_mosaic_v1 (
    .I_clk      (I_clk),
    .I_rst_n    (I_rst_n),
    .I_rgb      (rgb_s2),
    .I_de       (spatial_de_s2),
    .I_hs       (1'b0),
    .I_vs       (1'b0),
    .I_x        (spatial_x_s2),
    .I_y        (spatial_y_s2),
    .I_strength (strength_s2),
    .O_rgb      (mosaic_rgb_s2),
    .O_de       (mosaic_de_s2),
    .O_hs       (mosaic_hs_s2),
    .O_vs       (mosaic_vs_s2),
    .O_x        (mosaic_x_s2),
    .O_y        (mosaic_y_s2)
);

wire [23:0] temporal_motion_rgb;
wire        temporal_motion_de;
wire        temporal_motion_hs;
wire        temporal_motion_vs;
wire [7:0]  temporal_motion_score;
temporal_motion_v1 #(.REGION_OVERLAY(MOTION_OVERLAY)) u_temporal_motion_v1 (
    .I_overlay_enable(I_motion_overlay),
    .I_clk            (I_clk),
    .I_rst_n          (I_rst_n),
    .I_active_width   (I_active_width),
    .I_active_height  (I_active_height),
    .I_rgb            (I_rgb),
    .I_de             (I_de),
    .I_hs             (I_hs),
    .I_vs             (I_vs),
    .I_x              (I_x),
    .I_y              (I_y),
    .I_frame_start    (I_frame_start),
    .I_frame_end      (I_frame_end),
    .I_frame_is_new   (I_frame_is_new),
    .I_algorithm_mode (I_algorithm_mode),
    .I_strength       (I_strength),
    .I_soft_reset     (I_soft_reset),
    .O_rgb            (temporal_motion_rgb),
    .O_de             (temporal_motion_de),
    .O_hs             (temporal_motion_hs),
    .O_vs             (temporal_motion_vs),
    .O_motion_score   (temporal_motion_score)
);

wire [23:0] sobel_sharpen_rgb;
wire        sobel_sharpen_de;
wire        sobel_sharpen_hs;
wire        sobel_sharpen_vs;
sobel_sharpen_v1 #(.MAX_WIDTH(1920)) u_sobel_sharpen_v1 (
    .I_clk           (I_clk),
    .I_rst_n         (I_rst_n),
    .I_rgb           (I_rgb),
    .I_de            (I_de),
    .I_hs            (I_hs),
    .I_vs            (I_vs),
    .I_active_width  (I_active_width),
    .I_active_height (I_active_height),
    .I_x             (I_x),
    .I_y             (I_y),
    .O_rgb           (sobel_sharpen_rgb),
    .O_de            (sobel_sharpen_de),
    .O_hs            (sobel_sharpen_hs),
    .O_vs            (sobel_sharpen_vs)
);

wire [23:0] bilateral_filter_rgb;
wire        bilateral_filter_de;
wire        bilateral_filter_hs;
wire        bilateral_filter_vs;
bilateral_filter_v1 #(.MAX_WIDTH(1920)) u_bilateral_filter_v1 (
    .I_clk           (I_clk),
    .I_rst_n         (I_rst_n),
    .I_rgb           (I_rgb),
    .I_de            (I_de),
    .I_hs            (I_hs),
    .I_vs            (I_vs),
    .I_active_width  (I_active_width),
    .I_active_height (I_active_height),
    .I_x             (I_x),
    .I_y             (I_y),
    .O_rgb           (bilateral_filter_rgb),
    .O_de            (bilateral_filter_de),
    .O_hs            (bilateral_filter_hs),
    .O_vs            (bilateral_filter_vs)
);

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        red_term_s1   <= 16'd0;
        green_term_s1 <= 16'd0;
        blue_term_s1  <= 16'd0;
        rgb_s1        <= 24'd0;
        mode_s1       <= 5'd0;
        threshold_s1  <= 8'd128;
        strength_s1   <= 8'd0;
        luma_s2       <= 8'd0;
        rgb_s2        <= 24'd0;
        mode_s2       <= 5'd0;
        threshold_s2  <= 8'd128;
        strength_s2   <= 8'd0;
        luma_s3       <= 8'd0;
        tone_s3       <= 8'd0;
        binary_s3     <= 8'd0;
        rgb_s3        <= 24'd0;
        mode_s3       <= 5'd0;
        base_rgb_s4   <= 24'd0;
        base_mode_s4  <= 5'd0;
    end else begin
        // Exact unsigned products retain the original stage-1 registers.
        red_term_s1   <= red_in * 8'd77;
        green_term_s1 <= green_in * 8'd150;
        blue_term_s1  <= blue_in * 8'd29;
        rgb_s1       <= I_rgb;
        mode_s1      <= I_algorithm_mode;
        threshold_s1 <= (I_algorithm_mode == 5'd3) ?
                        adaptive_threshold : I_threshold;
        strength_s1  <= I_strength;

        // Stage 2: rounded weighted luma.
        luma_s2 <= ({1'b0,red_term_s1} + {1'b0,green_term_s1} +
                    {1'b0,blue_term_s1} + 17'd128) >> 8;
        rgb_s2       <= rgb_s1;
        mode_s2      <= mode_s1;
        threshold_s2 <= threshold_s1;
        strength_s2  <= strength_s1;

        // Stage 3: tone and threshold branches.
        luma_s3   <= luma_s2;
        tone_s3   <= tone_curve(luma_s2);
        binary_s3 <= (luma_s2 >= threshold_s2) ? 8'hff : 8'h00;
        rgb_s3    <= rgb_s2;
        mode_s3   <= mode_s2;

        // Stage 4: preserve the Step-1 branch result.  It is delayed below to
        // match the longer shared spatial path without changing its pixels.
        case(mode_s3)
            5'd1: base_rgb_s4 <= {luma_s3,luma_s3,luma_s3};
            5'd2: base_rgb_s4 <= tone_rgb;
            5'd3: base_rgb_s4 <= {binary_s3,binary_s3,binary_s3};
            5'd11: base_rgb_s4 <= cartoon_quantized_rgb_s3;
            default: base_rgb_s4 <= rgb_s3;
        endcase
        base_mode_s4 <= mode_s3;
    end
end

// Stage-2 shared spatial hardware.  One gray window and one one-bit mask
// window serve every new mode; runtime mode selection does not replicate RAM.
wire [7:0] spatial_sobel;
wire       spatial_local_binary;
wire       spatial_eroded;
wire       spatial_opened;
wire [7:0] spatial_median;
wire       spatial_valid;

spatial_filter_v1 #(
    .MAX_WIDTH(1920)
) u_spatial_filter_v1 (
    .I_clk            (I_clk),
    .I_rst_n          (I_rst_n),
    .I_gray           (luma_s2),
    .I_de             (spatial_de_s2),
    .I_x              (spatial_x_s2),
    .I_y              (spatial_y_s2),
    .I_sobel_threshold(threshold_s2),
    .I_mask_source_sel(I_mask_source_sel),
    .I_external_mask  (I_external_mask),
    .I_external_mask_valid(I_external_mask_valid),
    .O_sobel          (spatial_sobel),
    .O_local_binary   (spatial_local_binary),
    .O_eroded         (spatial_eroded),
    .O_opened         (spatial_opened),
    .O_median         (spatial_median),
    .O_valid          (spatial_valid)
);

// Gamma and global histogram mapping are colour-preserving luma transforms.
// Histogram statistics are updated only for a new camera frame, so the
// duplicated 1080p display frame does not get counted twice.
wire [23:0] gamma_rgb_s3;
wire [23:0] hist_rgb_s3;
wire tone_valid_s3;
luma_tone_modes_v1 u_luma_tone_modes_v1 (
    .I_clk(I_clk), .I_rst_n(I_rst_n),
    .I_soft_reset(spatial_soft_reset_s2),
    .I_rgb(rgb_s2), .I_luma(luma_s2), .I_de(spatial_de_s2),
    .I_x(spatial_x_s2), .I_y(spatial_y_s2),
    .I_frame_end(spatial_frame_end_s2),
    .I_frame_is_new(spatial_frame_is_new_s2),
    .O_gamma_rgb(gamma_rgb_s3), .O_hist_rgb(hist_rgb_s3),
    .O_valid(tone_valid_s3)
);

// Step-1 output is ready after four cycles; nine registers align it to the
// thirteen-cycle internal spatial contract. A shared seven-cycle tail brings
// every branch to the current twenty-cycle transaction. Mode travels beside RGB
// so frame-boundary mode commits cannot select pixels from another transaction.
reg [23:0] base_rgb_d1, base_rgb_d2, base_rgb_d3;
reg [23:0] base_rgb_d4, base_rgb_d5, base_rgb_d6;
reg [23:0] base_rgb_d7, base_rgb_d8, base_rgb_d9;
reg [4:0]  base_mode_d1, base_mode_d2, base_mode_d3;
reg [4:0]  base_mode_d4, base_mode_d5, base_mode_d6;
reg [4:0]  base_mode_d7, base_mode_d8, base_mode_d9;
reg [23:0] clahe_d1, clahe_d2, clahe_d3;
reg [23:0] mosaic_d1, mosaic_d2, mosaic_d3, mosaic_d4;
reg [23:0] mosaic_d5, mosaic_d6, mosaic_d7, mosaic_d8;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        base_rgb_d1 <= 24'd0; base_rgb_d2 <= 24'd0;
        base_rgb_d3 <= 24'd0; base_rgb_d4 <= 24'd0;
        base_rgb_d5 <= 24'd0; base_rgb_d6 <= 24'd0;
        base_rgb_d7 <= 24'd0; base_rgb_d8 <= 24'd0;
        base_rgb_d9 <= 24'd0;
        base_mode_d1 <= 5'd0; base_mode_d2 <= 5'd0;
        base_mode_d3 <= 5'd0; base_mode_d4 <= 5'd0;
        base_mode_d5 <= 5'd0; base_mode_d6 <= 5'd0;
        base_mode_d7 <= 5'd0; base_mode_d8 <= 5'd0;
        base_mode_d9 <= 5'd0;
        clahe_d1 <= 24'd0; clahe_d2 <= 24'd0; clahe_d3 <= 24'd0;
        mosaic_d1 <= 24'd0; mosaic_d2 <= 24'd0;
        mosaic_d3 <= 24'd0; mosaic_d4 <= 24'd0;
        mosaic_d5 <= 24'd0; mosaic_d6 <= 24'd0;
        mosaic_d7 <= 24'd0; mosaic_d8 <= 24'd0;
    end else begin
        base_rgb_d1 <= base_rgb_s4;
        base_rgb_d2 <= base_rgb_d1;
        base_rgb_d3 <= base_rgb_d2;
        base_rgb_d4 <= base_rgb_d3;
        base_rgb_d5 <= base_rgb_d4;
        base_rgb_d6 <= base_rgb_d5;
        base_rgb_d7 <= base_rgb_d6;
        base_rgb_d8 <= base_rgb_d7;
        base_rgb_d9 <= base_rgb_d8;
        base_mode_d1 <= base_mode_s4;
        base_mode_d2 <= base_mode_d1;
        base_mode_d3 <= base_mode_d2;
        base_mode_d4 <= base_mode_d3;
        base_mode_d5 <= base_mode_d4;
        base_mode_d6 <= base_mode_d5;
        base_mode_d7 <= base_mode_d6;
        base_mode_d8 <= base_mode_d7;
        base_mode_d9 <= base_mode_d8;
        clahe_d1 <= clahe_rgb_s2;
        clahe_d2 <= clahe_d1;
        clahe_d3 <= clahe_d2;
        mosaic_d1 <= mosaic_rgb_s2;
        mosaic_d2 <= mosaic_d1;
        mosaic_d3 <= mosaic_d2;
        mosaic_d4 <= mosaic_d3;
        mosaic_d5 <= mosaic_d4;
        mosaic_d6 <= mosaic_d5;
        mosaic_d7 <= mosaic_d6;
        mosaic_d8 <= mosaic_d7;
    end
end

// The tone mapper is ready after three clocks from its luma input.  Eight
// more registers align it with the opening/median spatial path.
reg [23:0] gamma_d1, gamma_d2, gamma_d3, gamma_d4;
reg [23:0] gamma_d5, gamma_d6, gamma_d7, gamma_d8;
reg [23:0] hist_d1, hist_d2, hist_d3, hist_d4;
reg [23:0] hist_d5, hist_d6, hist_d7, hist_d8;
reg [7:0] tone_valid_pipe;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gamma_d1 <= 24'd0; gamma_d2 <= 24'd0; gamma_d3 <= 24'd0; gamma_d4 <= 24'd0;
        gamma_d5 <= 24'd0; gamma_d6 <= 24'd0; gamma_d7 <= 24'd0; gamma_d8 <= 24'd0;
        hist_d1 <= 24'd0; hist_d2 <= 24'd0; hist_d3 <= 24'd0; hist_d4 <= 24'd0;
        hist_d5 <= 24'd0; hist_d6 <= 24'd0; hist_d7 <= 24'd0; hist_d8 <= 24'd0;
        tone_valid_pipe <= 8'd0;
    end else begin
        gamma_d1 <= gamma_rgb_s3; gamma_d2 <= gamma_d1;
        gamma_d3 <= gamma_d2; gamma_d4 <= gamma_d3;
        gamma_d5 <= gamma_d4; gamma_d6 <= gamma_d5;
        gamma_d7 <= gamma_d6; gamma_d8 <= gamma_d7;
        hist_d1 <= hist_rgb_s3; hist_d2 <= hist_d1;
        hist_d3 <= hist_d2; hist_d4 <= hist_d3;
        hist_d5 <= hist_d4; hist_d6 <= hist_d5;
        hist_d7 <= hist_d6; hist_d8 <= hist_d7;
        tone_valid_pipe <= {tone_valid_pipe[6:0],tone_valid_s3};
    end
end

// Retain every existing branch bit-for-bit at C13.  CLAHE and Mosaic use the
// donor taps that were measured at this same boundary; add the shared seven
// clocks only after this pipelined mode mux to reach the BASE C20 contract.
reg [23:0] legacy_rgb_s13;
always @(*) begin
    case(base_mode_d9)
        5'd4: legacy_rgb_s13 = spatial_valid ?
                       {spatial_sobel,spatial_sobel,spatial_sobel} : 24'd0;
        5'd5: legacy_rgb_s13 = (spatial_valid && spatial_local_binary) ?
                       24'hffffff : 24'h000000;
        5'd6: legacy_rgb_s13 = (spatial_valid && spatial_eroded) ?
                       24'hffffff : 24'h000000;
        5'd7: legacy_rgb_s13 = (spatial_valid && spatial_opened) ?
                       24'hffffff : 24'h000000;
        5'd8: legacy_rgb_s13 = spatial_valid ?
                       {spatial_median,spatial_median,spatial_median} : 24'd0;
        5'd9: legacy_rgb_s13 = tone_valid_pipe[7] ? gamma_d8 : 24'd0;
        5'd10: legacy_rgb_s13 = tone_valid_pipe[7] ? hist_d8 : 24'd0;
        5'd11: legacy_rgb_s13 = (spatial_valid && (|spatial_sobel)) ?
                        24'h000000 : base_rgb_d9;
        5'd12: legacy_rgb_s13 = clahe_d2;
        5'd13: legacy_rgb_s13 = temporal_motion_rgb;
        5'd14: legacy_rgb_s13 = sobel_sharpen_rgb;
        5'd15: legacy_rgb_s13 = mosaic_d8;
        default: legacy_rgb_s13 = base_rgb_d9;
    endcase
end

reg [23:0] legacy_rgb_tail[0:6];
integer tail_i;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) for(tail_i=0;tail_i<7;tail_i=tail_i+1) legacy_rgb_tail[tail_i]<=0;
    else begin
        legacy_rgb_tail[0]<=legacy_rgb_s13;
        for(tail_i=1;tail_i<7;tail_i=tail_i+1) legacy_rgb_tail[tail_i]<=legacy_rgb_tail[tail_i-1];
    end
end
// Final C20 selection is a single explicit Mode0..16 table.  Modes0..15
// arrive through the registered C13 mux and shared seven-cycle tail; the
// already-verified Bilateral core natively arrives at C20.
wire [23:0] delayed_rgb_unused;
always @(*) begin
    case(O_algorithm_mode)
        5'd0:  O_rgb = legacy_rgb_tail[6];
        5'd1:  O_rgb = legacy_rgb_tail[6];
        5'd2:  O_rgb = legacy_rgb_tail[6];
        5'd3:  O_rgb = legacy_rgb_tail[6];
        5'd4:  O_rgb = legacy_rgb_tail[6];
        5'd5:  O_rgb = legacy_rgb_tail[6];
        5'd6:  O_rgb = legacy_rgb_tail[6];
        5'd7:  O_rgb = legacy_rgb_tail[6];
        5'd8:  O_rgb = legacy_rgb_tail[6];
        5'd9:  O_rgb = legacy_rgb_tail[6];
        5'd10: O_rgb = legacy_rgb_tail[6];
        5'd11: O_rgb = legacy_rgb_tail[6];
        5'd12: O_rgb = legacy_rgb_tail[6];
        5'd13: O_rgb = legacy_rgb_tail[6];
        5'd14: O_rgb = legacy_rgb_tail[6];
        5'd15: O_rgb = legacy_rgb_tail[6];
        5'd16: O_rgb = bilateral_filter_rgb;
        5'd17: O_rgb = delayed_rgb_unused;
        5'd18: O_rgb = delayed_rgb_unused;
        default: O_rgb = legacy_rgb_tail[6];
    endcase
end

assign O_raw_rgb=delayed_rgb_unused;
video_stream_delay #(.LATENCY(20)) u_transaction_delay (
    .I_clk(I_clk), .I_rst_n(I_rst_n),
    .I_rgb(I_rgb), .I_de(I_de), .I_hs(I_hs), .I_vs(I_vs),
    .I_x(I_x), .I_y(I_y),
    .I_frame_start(I_frame_start), .I_frame_end(I_frame_end),
    .I_line_start(I_line_start), .I_line_end(I_line_end),
    .I_display_bank(I_display_bank), .I_frame_seq(I_frame_seq),
    .I_frame_is_new(I_frame_is_new),
    .I_new_frame_pulse(I_new_frame_pulse),
    .I_algorithm_mode(I_algorithm_mode), .I_threshold(I_threshold),
    .I_strength(I_strength), .I_config_epoch(I_config_epoch),
    .O_rgb(delayed_rgb_unused), .O_de(O_de), .O_hs(O_hs), .O_vs(O_vs),
    .O_x(O_x), .O_y(O_y),
    .O_frame_start(O_frame_start), .O_frame_end(O_frame_end),
    .O_line_start(O_line_start), .O_line_end(O_line_end),
    .O_display_bank(O_display_bank), .O_frame_seq(O_frame_seq),
    .O_frame_is_new(O_frame_is_new),
    .O_new_frame_pulse(O_new_frame_pulse),
    .O_algorithm_mode(O_algorithm_mode), .O_threshold(O_threshold),
    .O_strength(O_strength), .O_config_epoch(O_config_epoch)
);

endmodule
