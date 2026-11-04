`timescale 1ns / 1ns

// Shared Step-2 spatial core for both 1280x720 and 1920x1080 display modes.
//
// The implementation is deliberately causal: each 3x3 result is displayed
// one source pixel down/right from the mathematical centre.  That keeps the
// HDMI transaction on its original raster timing (no full-line delay of
// DE/HS/VS). The spatial result is internally ready at thirteen cycles; the
// pixel-chain tail extends the complete transaction to twenty cycles.
//
// The two previous 8-bit rows use two explicit PH1P35 ERAM20K blocks.
// Each packed binary-mask two-row store now uses one native ERAM, removing
// distributed-RAM packing constraints without adding any pixel clock latency.
module spatial_filter_v1 #(
    parameter integer MAX_WIDTH = 1920,
    parameter [7:0] LOCAL_BIAS   = 8'd4,
    parameter [7:0] LOCAL_FLOOR  = 8'd40,
    parameter [7:0] LOCAL_CEIL   = 8'd216
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [7:0]  I_gray,
    input  wire        I_de,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire [7:0]  I_sobel_threshold,
    // Mask source is sampled at the first active pixel and held for the frame.
    // 0 selects the existing local adaptive mask; 1 selects the future
    // external/color-mask stream. Both sources enter the same mask pipeline.
    input  wire        I_mask_source_sel,
    input  wire        I_external_mask,
    input  wire        I_external_mask_valid,
    output wire [7:0]  O_sobel,
    output wire        O_local_binary,
    output wire        O_eroded,
    output wire        O_opened,
    output wire [7:0]  O_median,
    output wire        O_valid
);

function [7:0] min3;
    input [7:0] a, b, c;
    begin
        min3 = (a <= b && a <= c) ? a : ((b <= c) ? b : c);
    end
endfunction

function [7:0] max3;
    input [7:0] a, b, c;
    begin
        max3 = (a >= b && a >= c) ? a : ((b >= c) ? b : c);
    end
endfunction

function [7:0] median3;
    input [7:0] a, b, c;
    begin
        median3 = ((a >= b && a <= c) || (a <= b && a >= c)) ? a :
                  ((b >= a && b <= c) || (b <= a && b >= c)) ? b : c;
    end
endfunction

// -------------------------------------------------------------------------
// Stage 1/2: explicit two-line ERAM store and horizontal 3-tap shifts.
// Before row y is written, gray_row_m2_rd and gray_row_m1_rd contain rows
// y-2 and y-1 at the same x coordinate.
// -------------------------------------------------------------------------
wire [7:0] gray_row_m2_rd;
wire [7:0] gray_row_m1_rd;
reg [7:0]  gray_d1;
reg [11:0] gray_addr_d1;
reg [11:0] x_d1;
reg [11:0] y_d1;
reg        de_d1;
reg [7:0]  threshold_d1;
reg        mask_source_active;
reg        external_mask_d1, external_mask_d2, external_mask_d3;
reg        external_mask_d4, external_mask_d5;
reg        external_mask_valid_d1, external_mask_valid_d2;
reg        external_mask_valid_d3, external_mask_valid_d4;
reg        external_mask_valid_d5;

gray_line_buffer_eram u_gray_line_buffer_eram (
    .I_clk(I_clk),
    .I_wr_en(de_d1),
    .I_wr_addr(gray_addr_d1[10:0]),
    .I_rd_addr(I_x[10:0]),
    .I_current_gray(gray_d1),
    .O_row_m2(gray_row_m2_rd),
    .O_row_m1(gray_row_m1_rd)
);

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gray_d1      <= 8'd0;
        gray_addr_d1 <= 12'd0;
        x_d1         <= 12'd0;
        y_d1         <= 12'd0;
        de_d1        <= 1'b0;
        threshold_d1 <= 8'd0;
        mask_source_active <= 1'b0;
        external_mask_d1 <= 1'b0; external_mask_d2 <= 1'b0;
        external_mask_d3 <= 1'b0; external_mask_d4 <= 1'b0;
        external_mask_d5 <= 1'b0;
        external_mask_valid_d1 <= 1'b0;
        external_mask_valid_d2 <= 1'b0;
        external_mask_valid_d3 <= 1'b0;
        external_mask_valid_d4 <= 1'b0;
        external_mask_valid_d5 <= 1'b0;
    end else begin
        gray_d1      <= I_gray;
        gray_addr_d1 <= I_x;
        x_d1         <= I_x;
        y_d1         <= I_y;
        de_d1        <= I_de;
        threshold_d1 <= I_sobel_threshold;
        // The source control is a frame-committed sideband, not a pixel-rate
        // combinational select. The first active pixel defines the source for
        // the complete frame, including all repeated 1080p display pixels.
        if(I_de && (I_x == 12'd0) && (I_y == 12'd0))
            mask_source_active <= I_mask_source_sel;
        external_mask_d1 <= I_external_mask;
        external_mask_d2 <= external_mask_d1;
        external_mask_d3 <= external_mask_d2;
        external_mask_d4 <= external_mask_d3;
        external_mask_d5 <= external_mask_d4;
        external_mask_valid_d1 <= I_external_mask_valid;
        external_mask_valid_d2 <= external_mask_valid_d1;
        external_mask_valid_d3 <= external_mask_valid_d2;
        external_mask_valid_d4 <= external_mask_valid_d3;
        external_mask_valid_d5 <= external_mask_valid_d4;
    end
end

reg [7:0] p11, p12, p13;
reg [7:0] p21, p22, p23;
reg [7:0] p31, p32, p33;
reg [11:0] x_s2;
reg [11:0] y_s2;
reg        de_s2;
reg        window_valid_s2;
reg [7:0]  threshold_s2;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        p11 <= 8'd0; p12 <= 8'd0; p13 <= 8'd0;
        p21 <= 8'd0; p22 <= 8'd0; p23 <= 8'd0;
        p31 <= 8'd0; p32 <= 8'd0; p33 <= 8'd0;
        x_s2 <= 12'd0;
        y_s2 <= 12'd0;
        de_s2 <= 1'b0;
        window_valid_s2 <= 1'b0;
        threshold_s2 <= 8'd0;
    end else begin
        x_s2 <= x_d1;
        y_s2 <= y_d1;
        de_s2 <= de_d1;
        window_valid_s2 <= de_d1 && (x_d1 >= 12'd2) &&
                          (y_d1 >= 12'd2);
        threshold_s2 <= threshold_d1;

        if(de_d1) begin
            if(x_d1 == 12'd0) begin
                p11 <= 8'd0; p12 <= 8'd0; p13 <= gray_row_m2_rd;
                p21 <= 8'd0; p22 <= 8'd0; p23 <= gray_row_m1_rd;
                p31 <= 8'd0; p32 <= 8'd0; p33 <= gray_d1;
            end else begin
                p11 <= p12; p12 <= p13; p13 <= gray_row_m2_rd;
                p21 <= p22; p22 <= p23; p23 <= gray_row_m1_rd;
                p31 <= p32; p32 <= p33; p33 <= gray_d1;
            end
        end
    end
end

// -------------------------------------------------------------------------
// Stage 3: Sobel positive/negative sums and 1-2-1 Gaussian row sums.
// This is the useful mathematical part retained from ronghe; all buffering,
// widths, control timing and RAM inference are native to this project.
// -------------------------------------------------------------------------
reg [9:0] gx_pos_s3, gx_neg_s3;
reg [9:0] gy_pos_s3, gy_neg_s3;
reg [9:0] gaussian_top_s3;
reg [10:0] gaussian_mid_s3;
reg [9:0] gaussian_bottom_s3;
reg [7:0] center_s3;
reg [7:0] med_r1_lo_s3, med_r1_mid_s3, med_r1_hi_s3;
reg [7:0] med_r2_lo_s3, med_r2_mid_s3, med_r2_hi_s3;
reg [7:0] med_r3_lo_s3, med_r3_mid_s3, med_r3_hi_s3;
reg [11:0] x_s3, y_s3;
reg de_s3, window_valid_s3;
reg [7:0] threshold_s3;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gx_pos_s3 <= 10'd0; gx_neg_s3 <= 10'd0;
        gy_pos_s3 <= 10'd0; gy_neg_s3 <= 10'd0;
        gaussian_top_s3 <= 10'd0;
        gaussian_mid_s3 <= 11'd0;
        gaussian_bottom_s3 <= 10'd0;
        center_s3 <= 8'd0;
        med_r1_lo_s3 <= 8'd0; med_r1_mid_s3 <= 8'd0; med_r1_hi_s3 <= 8'd0;
        med_r2_lo_s3 <= 8'd0; med_r2_mid_s3 <= 8'd0; med_r2_hi_s3 <= 8'd0;
        med_r3_lo_s3 <= 8'd0; med_r3_mid_s3 <= 8'd0; med_r3_hi_s3 <= 8'd0;
        x_s3 <= 12'd0; y_s3 <= 12'd0;
        de_s3 <= 1'b0; window_valid_s3 <= 1'b0;
        threshold_s3 <= 8'd0;
    end else begin
        gx_pos_s3 <= {2'b00,p13} + {1'b0,p23,1'b0} + {2'b00,p33};
        gx_neg_s3 <= {2'b00,p11} + {1'b0,p21,1'b0} + {2'b00,p31};
        gy_pos_s3 <= {2'b00,p11} + {1'b0,p12,1'b0} + {2'b00,p13};
        gy_neg_s3 <= {2'b00,p31} + {1'b0,p32,1'b0} + {2'b00,p33};

        gaussian_top_s3 <= {2'b00,p11} + {1'b0,p12,1'b0} + {2'b00,p13};
        gaussian_mid_s3 <= {2'b00,p21,1'b0} + {1'b0,p22,2'b00} +
                           {2'b00,p23,1'b0};
        gaussian_bottom_s3 <= {2'b00,p31} + {1'b0,p32,1'b0} +
                              {2'b00,p33};
        center_s3 <= p22;
        med_r1_lo_s3 <= min3(p11,p12,p13);
        med_r1_mid_s3 <= median3(p11,p12,p13);
        med_r1_hi_s3 <= max3(p11,p12,p13);
        med_r2_lo_s3 <= min3(p21,p22,p23);
        med_r2_mid_s3 <= median3(p21,p22,p23);
        med_r2_hi_s3 <= max3(p21,p22,p23);
        med_r3_lo_s3 <= min3(p31,p32,p33);
        med_r3_mid_s3 <= median3(p31,p32,p33);
        med_r3_hi_s3 <= max3(p31,p32,p33);
        x_s3 <= x_s2; y_s3 <= y_s2;
        de_s3 <= de_s2;
        window_valid_s3 <= window_valid_s2;
        threshold_s3 <= threshold_s2;
    end
end

// Stage 4: absolute Sobel components and exact /16 Gaussian total.
reg [9:0] gx_abs_s4, gy_abs_s4;
reg [11:0] gaussian_total_s4;
reg [7:0] center_s4;
reg [7:0] med_a_s4, med_b_s4, med_c_s4;
reg [11:0] x_s4, y_s4;
reg de_s4, window_valid_s4;
reg [7:0] threshold_s4;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gx_abs_s4 <= 10'd0; gy_abs_s4 <= 10'd0;
        gaussian_total_s4 <= 12'd0;
        center_s4 <= 8'd0;
        med_a_s4 <= 8'd0; med_b_s4 <= 8'd0; med_c_s4 <= 8'd0;
        x_s4 <= 12'd0; y_s4 <= 12'd0;
        de_s4 <= 1'b0; window_valid_s4 <= 1'b0;
        threshold_s4 <= 8'd0;
    end else begin
        gx_abs_s4 <= (gx_pos_s3 >= gx_neg_s3) ?
                     (gx_pos_s3-gx_neg_s3) : (gx_neg_s3-gx_pos_s3);
        gy_abs_s4 <= (gy_pos_s3 >= gy_neg_s3) ?
                     (gy_pos_s3-gy_neg_s3) : (gy_neg_s3-gy_pos_s3);
        gaussian_total_s4 <= {2'b00,gaussian_top_s3} +
                             {1'b0,gaussian_mid_s3} +
                             {2'b00,gaussian_bottom_s3};
        center_s4 <= center_s3;
        med_a_s4 <= max3(med_r1_lo_s3,med_r2_lo_s3,med_r3_lo_s3);
        med_b_s4 <= median3(med_r1_mid_s3,med_r2_mid_s3,med_r3_mid_s3);
        med_c_s4 <= min3(med_r1_hi_s3,med_r2_hi_s3,med_r3_hi_s3);
        x_s4 <= x_s3; y_s4 <= y_s3;
        de_s4 <= de_s3;
        window_valid_s4 <= window_valid_s3;
        threshold_s4 <= threshold_s3;
    end
end

// Stage 5: register Sobel/local-threshold intermediate arithmetic.  Final
// clamps and comparisons are deliberately left for stage 6 so the 149.343
// MHz path does not contain max/min, add, saturation and threshold compare in
// one combinational chain.
wire [9:0] gradient_max_s4 = (gx_abs_s4 >= gy_abs_s4) ?
                              gx_abs_s4 : gy_abs_s4;
wire [9:0] gradient_min_s4 = (gx_abs_s4 >= gy_abs_s4) ?
                              gy_abs_s4 : gx_abs_s4;
wire [10:0] gradient_approx_s4 = {1'b0,gradient_max_s4} +
                                  ({1'b0,gradient_min_s4} >> 1);
wire [7:0] local_mean_s4 = (gaussian_total_s4 + 12'd8) >> 4;
// Blend local illumination with the frame-stable user threshold.  The old
// mean-8 rule is appropriate for document backgrounds but classified about
// 99 percent of the observed natural scene as white.  This 1:1 blend keeps
// local adaptation while anchoring the mask to a useful global brightness.
wire [8:0] local_mix_sum_s4 = {1'b0,local_mean_s4} +
                              {1'b0,threshold_s4} + 9'd1;
wire [7:0] local_mix_mean_s4 = local_mix_sum_s4[8:1];
wire [8:0] local_biased_threshold_s4 = {1'b0,local_mix_mean_s4} +
                                        {1'b0,LOCAL_BIAS};
wire [7:0] local_raw_threshold_s4 =
    local_biased_threshold_s4[8] ? 8'hff :
                                   local_biased_threshold_s4[7:0];

reg [10:0] gradient_approx_s5;
reg [7:0] local_raw_threshold_s5;
reg [7:0] center_s5;
reg [7:0] threshold_s5;
reg       window_valid_s5;
reg [7:0] median_s5;
reg [11:0] x_s5, y_s5;
reg de_s5;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gradient_approx_s5 <= 11'd0;
        local_raw_threshold_s5 <= 8'd0;
        center_s5 <= 8'd0;
        threshold_s5 <= 8'd0;
        window_valid_s5 <= 1'b0;
        median_s5 <= 8'd0;
        x_s5 <= 12'd0; y_s5 <= 12'd0;
        de_s5 <= 1'b0;
    end else begin
        gradient_approx_s5 <= gradient_approx_s4;
        local_raw_threshold_s5 <= local_raw_threshold_s4;
        center_s5 <= center_s4;
        threshold_s5 <= threshold_s4;
        window_valid_s5 <= window_valid_s4;
        median_s5 <= window_valid_s4 ? median3(med_a_s4,med_b_s4,med_c_s4) : 8'd0;
        x_s5 <= x_s4; y_s5 <= y_s4;
        de_s5 <= de_s4;
    end
end

// -------------------------------------------------------------------------
// Stage 6/7: packed two-line 1-bit store and 3x3 mask window.
// -------------------------------------------------------------------------
wire [1:0] mask_line_rd;
reg       mask_d6;
reg [11:0] mask_addr_d6;
reg [11:0] x_d6, y_d6;
reg de_d6;

wire [7:0] gradient_sat_s5 = (gradient_approx_s5 > 11'd255) ?
                              8'hff : gradient_approx_s5[7:0];
wire [7:0] sobel_effective_threshold_s5 =
    ((threshold_s5 >> 2) < 8'd24) ? 8'd24 : (threshold_s5 >> 2);
wire [7:0] gradient_display_s5 = (gradient_sat_s5 > 8'd127) ?
                                  8'hff : (gradient_sat_s5 << 1);
wire [7:0] local_threshold_s5 =
    (local_raw_threshold_s5 < LOCAL_FLOOR) ? LOCAL_FLOOR :
    (local_raw_threshold_s5 > LOCAL_CEIL)  ? LOCAL_CEIL  :
                                             local_raw_threshold_s5;
wire local_binary_next_s5 = window_valid_s5 &&
                            (center_s5 >= local_threshold_s5);
// The external mask is delayed to the same C5 decision point as the local
// adaptive mask. When selected but invalid, it contributes zero rather than
// stale data; this makes the future color-mask contract explicit.
wire external_mask_s5 = external_mask_valid_d5 && external_mask_d5;
wire selected_mask_s5 = mask_source_active ?
                            external_mask_s5 : local_binary_next_s5;

binary_line_buffer_eram u_mask_line_buffer_eram (
    .I_clk(I_clk), .I_rd_en(de_s5), .I_rd_addr(x_s5[10:0]),
    .I_wr_en(de_d6), .I_wr_addr(mask_addr_d6[10:0]),
    .I_wr_data({mask_line_rd[0],mask_d6}), .O_rd_data(mask_line_rd)
);

reg [7:0] sobel_s6;
reg local_binary_s6;
reg [7:0] median_s6;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        mask_d6 <= 1'b0;
        mask_addr_d6 <= 12'd0;
        x_d6 <= 12'd0; y_d6 <= 12'd0;
        de_d6 <= 1'b0;
        sobel_s6 <= 8'd0;
        local_binary_s6 <= 1'b0;
        median_s6 <= 8'd0;
    end else begin
        mask_d6 <= selected_mask_s5;
        mask_addr_d6 <= x_s5;
        x_d6 <= x_s5; y_d6 <= y_s5;
        de_d6 <= de_s5;
        sobel_s6 <= (window_valid_s5 &&
                     (gradient_sat_s5 >= sobel_effective_threshold_s5)) ?
                     gradient_display_s5 : 8'd0;
        local_binary_s6 <= selected_mask_s5;
        median_s6 <= median_s5;
    end
end

reg m11, m12, m13;
reg m21, m22, m23;
reg m31, m32, m33;
reg mask_window_valid_s7;
reg de_s7;
reg [7:0] sobel_s7;
reg [7:0] sobel_left_s7;
reg [7:0] sobel_previous_active;
reg local_binary_s7;
reg [7:0] median_s7;
reg [11:0] x_s7, y_s7;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        m11 <= 1'b0; m12 <= 1'b0; m13 <= 1'b0;
        m21 <= 1'b0; m22 <= 1'b0; m23 <= 1'b0;
        m31 <= 1'b0; m32 <= 1'b0; m33 <= 1'b0;
        mask_window_valid_s7 <= 1'b0;
        de_s7 <= 1'b0;
        sobel_s7 <= 8'd0;
        sobel_left_s7 <= 8'd0;
        sobel_previous_active <= 8'd0;
        local_binary_s7 <= 1'b0;
        median_s7 <= 8'd0;
        x_s7 <= 12'd0; y_s7 <= 12'd0;
    end else begin
        de_s7 <= de_d6;
        sobel_s7 <= sobel_s6;
        if(de_d6) begin
            sobel_left_s7 <= (x_d6 == 12'd0) ? 8'd0 :
                                                       sobel_previous_active;
            sobel_previous_active <= sobel_s6;
        end else begin
            sobel_left_s7 <= 8'd0;
            sobel_previous_active <= 8'd0;
        end
        local_binary_s7 <= local_binary_s6;
        median_s7 <= median_s6;
        x_s7 <= x_d6; y_s7 <= y_d6;
        mask_window_valid_s7 <= de_d6 && (x_d6 >= 12'd4) &&
                                (y_d6 >= 12'd4);

        if(de_d6) begin
            if(x_d6 == 12'd0) begin
                m11 <= 1'b0; m12 <= 1'b0; m13 <= mask_line_rd[1];
                m21 <= 1'b0; m22 <= 1'b0; m23 <= mask_line_rd[0];
                m31 <= 1'b0; m32 <= 1'b0; m33 <= mask_d6;
            end else begin
                m11 <= m12; m12 <= m13; m13 <= mask_line_rd[1];
                m21 <= m22; m22 <= m23; m23 <= mask_line_rd[0];
                m31 <= m32; m32 <= m33; m33 <= mask_d6;
            end
        end
    end
end

// Stage 8: strict 3x3 erosion plus aligned display branches.
reg [7:0] sobel_s8;
reg local_binary_s8;
reg eroded_s8;
reg de_s8;
reg [7:0] median_s8;
reg [11:0] x_s8, y_s8;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        sobel_s8 <= 8'd0;
        local_binary_s8 <= 1'b0;
        eroded_s8 <= 1'b0;
        de_s8 <= 1'b0;
        median_s8 <= 8'd0;
        x_s8 <= 12'd0; y_s8 <= 12'd0;
    end else begin
        // Two-pixel horizontal max makes the live edge display easier to see
        // without spending another 1920-pixel line buffer.  It intentionally
        // does not alter the binary/morphology path.
        sobel_s8 <= (sobel_s7 >= sobel_left_s7) ?
                    sobel_s7 : sobel_left_s7;
        local_binary_s8 <= local_binary_s7;
        eroded_s8 <= mask_window_valid_s7 &&
                     m11 && m12 && m13 && m21 && m22 && m23 &&
                     m31 && m32 && m33;
        de_s8 <= de_s7;
        median_s8 <= median_s7;
        x_s8 <= x_s7; y_s8 <= y_s7;
    end
end

// True opening: feed the registered erosion result into a second 3x3 line
// window and perform dilation there.  This adds three clocks and one one-bit
// two-line RAM; every other branch is padded to the same final stage.
wire opened_s11;
wire opened_valid_s11;
opening_filter_v1 #(.MAX_WIDTH(MAX_WIDTH)) u_opening_filter_v1 (
    .I_clk(I_clk), .I_rst_n(I_rst_n),
    .I_bit(eroded_s8), .I_de(de_s8), .I_x(x_s8), .I_y(y_s8),
    .O_opened(opened_s11), .O_valid(opened_valid_s11)
);

reg [7:0] sobel_d9, sobel_d10, sobel_d11;
reg local_d9, local_d10, local_d11;
reg eroded_d9, eroded_d10, eroded_d11;
reg [7:0] median_d9, median_d10, median_d11;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        sobel_d9 <= 8'd0; sobel_d10 <= 8'd0; sobel_d11 <= 8'd0;
        local_d9 <= 1'b0; local_d10 <= 1'b0; local_d11 <= 1'b0;
        eroded_d9 <= 1'b0; eroded_d10 <= 1'b0; eroded_d11 <= 1'b0;
        median_d9 <= 8'd0; median_d10 <= 8'd0; median_d11 <= 8'd0;
    end else begin
        sobel_d9 <= sobel_s8; sobel_d10 <= sobel_d9; sobel_d11 <= sobel_d10;
        local_d9 <= local_binary_s8; local_d10 <= local_d9; local_d11 <= local_d10;
        eroded_d9 <= eroded_s8; eroded_d10 <= eroded_d9; eroded_d11 <= eroded_d10;
        median_d9 <= median_s8; median_d10 <= median_d9; median_d11 <= median_d10;
    end
end

assign O_sobel        = sobel_d11;
assign O_local_binary = local_d11;
assign O_eroded       = eroded_d11;
assign O_opened       = opened_s11;
assign O_median       = median_d11;
assign O_valid        = opened_valid_s11;

endmodule
