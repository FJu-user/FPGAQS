`timescale 1ns / 1ns

// Mode 13: migration of the active ronghe Mode 2 (source image_process
// -> sobel_sharpen_proc).
//
// Source semantics retained here:
//   1. grayscale = max(R,G,B),
//   2. 3x3 Sobel Gx/Gy with the {-1,0,+1}/{-1,-2,-1} kernels,
//   3. L1 magnitude |Gx|+|Gy|,
//   4. add the magnitude to the window centre and saturate at 255,
//   5. replicate the result to R/G/B.
//
// The target display path is causal, so the 3x3 window is displayed one
// source pixel down/right from its mathematical centre, matching the existing
// spatial_filter_v1 contract.  Border transactions use the centre pixel,
// matching the source edge-flag path.  The result and its valid/timing bundle
// are delayed to exactly thirteen clocks from the input transaction.
module sobel_sharpen_v1 #(
    parameter integer MAX_WIDTH = 1920
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    output wire [23:0] O_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs
);

    function [7:0] max_rgb;
        input [23:0] rgb;
        begin
            if ((rgb[23:16] >= rgb[15:8]) &&
                (rgb[23:16] >= rgb[7:0]))
                max_rgb = rgb[23:16];
            else if (rgb[15:8] >= rgb[7:0])
                max_rgb = rgb[15:8];
            else
                max_rgb = rgb[7:0];
        end
    endfunction

    function [7:0] sat_add_gradient;
        input [7:0] center_value;
        input [11:0] gradient_value;
        reg [12:0] sum_value;
        begin
            sum_value = {5'd0, center_value} + {1'b0, gradient_value};
            sat_add_gradient = (sum_value > 13'd255) ? 8'hff :
                               sum_value[7:0];
        end
    endfunction

    wire [7:0] gray_in = max_rgb(I_rgb);

    // The line store is the same target-native two-row ERAM used by the
    // existing spatial core.  It is a separate instance because Mode13 uses
    // the source's max-channel grayscale rather than the shared BT.601 luma.
    wire [7:0] row_m2_rd;
    wire [7:0] row_m1_rd;
    reg  [7:0] gray_d1;
    reg  [10:0] addr_d1;
    reg  [11:0] x_d1, y_d1;
    reg  de_d1;
    reg  hs_d1, vs_d1;

    gray_line_buffer_eram u_mode13_gray_line_buffer (
        .I_clk         (I_clk),
        .I_wr_en       (de_d1),
        .I_wr_addr     (addr_d1),
        .I_rd_addr     (I_x[10:0]),
        .I_current_gray(gray_d1),
        .O_row_m2      (row_m2_rd),
        .O_row_m1      (row_m1_rd)
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            gray_d1 <= 8'd0;
            addr_d1 <= 11'd0;
            x_d1    <= 12'd0;
            y_d1    <= 12'd0;
            de_d1   <= 1'b0;
            hs_d1   <= 1'b0;
            vs_d1   <= 1'b0;
        end else begin
            gray_d1 <= gray_in;
            addr_d1 <= I_x[10:0];
            x_d1    <= I_x;
            y_d1    <= I_y;
            de_d1   <= I_de;
            hs_d1   <= I_hs;
            vs_d1   <= I_vs;
        end
    end

    // Causal 3x3 window.  p22 is the mathematical centre; the tagged
    // coordinate remains the current stream coordinate, as in the shared
    // spatial core, so no full-line timing buffer is added.
    reg [7:0] p11, p12, p13;
    reg [7:0] p21, p22, p23;
    reg [7:0] p31, p32, p33;
    reg [11:0] x_s2, y_s2;
    reg de_s2, hs_s2, vs_s2;
    reg valid_s2;
    reg border_s2;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            p11 <= 8'd0; p12 <= 8'd0; p13 <= 8'd0;
            p21 <= 8'd0; p22 <= 8'd0; p23 <= 8'd0;
            p31 <= 8'd0; p32 <= 8'd0; p33 <= 8'd0;
            x_s2 <= 12'd0; y_s2 <= 12'd0;
            de_s2 <= 1'b0; hs_s2 <= 1'b0; vs_s2 <= 1'b0;
            valid_s2 <= 1'b0;
            border_s2 <= 1'b1;
        end else begin
            x_s2 <= x_d1;
            y_s2 <= y_d1;
            de_s2 <= de_d1;
            hs_s2 <= hs_d1;
            vs_s2 <= vs_d1;
            valid_s2 <= de_d1 && (x_d1 < I_active_width) &&
                        (y_d1 < I_active_height);
            border_s2 <= (x_d1 < 12'd2) || (y_d1 < 12'd2) ||
                         (x_d1 >= (I_active_width  - 12'd1)) ||
                         (y_d1 >= (I_active_height - 12'd1));

            if (de_d1) begin
                if (x_d1 == 12'd0) begin
                    p11 <= 8'd0;       p12 <= 8'd0;       p13 <= row_m2_rd;
                    p21 <= 8'd0;       p22 <= 8'd0;       p23 <= row_m1_rd;
                    p31 <= 8'd0;       p32 <= 8'd0;       p33 <= gray_d1;
                end else begin
                    p11 <= p12; p12 <= p13; p13 <= row_m2_rd;
                    p21 <= p22; p22 <= p23; p23 <= row_m1_rd;
                    p31 <= p32; p32 <= p33; p33 <= gray_d1;
                end
            end else begin
                p11 <= 8'd0; p12 <= 8'd0; p13 <= 8'd0;
                p21 <= 8'd0; p22 <= 8'd0; p23 <= 8'd0;
                p31 <= 8'd0; p32 <= 8'd0; p33 <= 8'd0;
            end
        end
    end

    // C3: Sobel signed sums and centre sample.
    reg [9:0] gx_pos_s3, gx_neg_s3;
    reg [9:0] gy_pos_s3, gy_neg_s3;
    reg [7:0] center_s3;
    reg       valid_s3, border_s3;
    reg       hs_s3, vs_s3;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            gx_pos_s3 <= 10'd0; gx_neg_s3 <= 10'd0;
            gy_pos_s3 <= 10'd0; gy_neg_s3 <= 10'd0;
            center_s3 <= 8'd0;
            valid_s3  <= 1'b0;
            border_s3 <= 1'b1;
            hs_s3     <= 1'b0;
            vs_s3     <= 1'b0;
        end else begin
            gx_pos_s3 <= {2'b00,p13} + {1'b0,p23,1'b0} + {2'b00,p33};
            gx_neg_s3 <= {2'b00,p11} + {1'b0,p21,1'b0} + {2'b00,p31};
            gy_pos_s3 <= {2'b00,p31} + {1'b0,p32,1'b0} + {2'b00,p33};
            gy_neg_s3 <= {2'b00,p11} + {1'b0,p12,1'b0} + {2'b00,p13};
            center_s3 <= p22;
            valid_s3  <= valid_s2;
            border_s3 <= border_s2;
            hs_s3     <= hs_s2;
            vs_s3     <= vs_s2;
        end
    end

    // C4: absolute Sobel components.
    reg [9:0] gx_abs_s4, gy_abs_s4;
    reg [7:0] center_s4;
    reg       valid_s4, border_s4;
    reg       hs_s4, vs_s4;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            gx_abs_s4 <= 10'd0; gy_abs_s4 <= 10'd0;
            center_s4 <= 8'd0;
            valid_s4  <= 1'b0;
            border_s4 <= 1'b1;
            hs_s4     <= 1'b0;
            vs_s4     <= 1'b0;
        end else begin
            gx_abs_s4 <= (gx_pos_s3 >= gx_neg_s3) ?
                         (gx_pos_s3 - gx_neg_s3) :
                         (gx_neg_s3 - gx_pos_s3);
            gy_abs_s4 <= (gy_pos_s3 >= gy_neg_s3) ?
                         (gy_pos_s3 - gy_neg_s3) :
                         (gy_neg_s3 - gy_pos_s3);
            center_s4 <= center_s3;
            valid_s4  <= valid_s3;
            border_s4 <= border_s3;
            hs_s4     <= hs_s3;
            vs_s4     <= vs_s3;
        end
    end

    // C5: L1 magnitude and saturated sharpen result.
    wire [10:0] gradient_sum_s4 = {1'b0,gx_abs_s4} + {1'b0,gy_abs_s4};
    reg [7:0] result_s5;
    reg       valid_s5;
    reg       hs_s5, vs_s5;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            result_s5 <= 8'd0;
            valid_s5  <= 1'b0;
            hs_s5     <= 1'b0;
            vs_s5     <= 1'b0;
        end else begin
            result_s5 <= border_s4 ? center_s4 :
                         sat_add_gradient(center_s4, gradient_sum_s4);
            valid_s5  <= valid_s4;
            hs_s5     <= hs_s4;
            vs_s5     <= vs_s4;
        end
    end

    // C6..C13: pad the arithmetic result to the thirteen-cycle internal
    // contract. pixel_chain_v1 adds the shared seven-cycle tail so RGB and
    // all transaction sidebands leave the complete chain at twenty cycles.
    reg [7:0] rgb_pipe [0:7];
    reg       de_pipe  [0:7];
    reg       hs_pipe  [0:7];
    reg       vs_pipe  [0:7];
    integer pipe_i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (pipe_i = 0; pipe_i < 8; pipe_i = pipe_i + 1) begin
                rgb_pipe[pipe_i] <= 8'd0;
                de_pipe[pipe_i]  <= 1'b0;
                hs_pipe[pipe_i]  <= 1'b0;
                vs_pipe[pipe_i]  <= 1'b0;
            end
        end else begin
            rgb_pipe[0] <= valid_s5 ? result_s5 : 8'd0;
            de_pipe[0]  <= valid_s5;
            hs_pipe[0]  <= valid_s5 ? hs_s5 : 1'b0;
            vs_pipe[0]  <= valid_s5 ? vs_s5 : 1'b0;
            for (pipe_i = 1; pipe_i < 8; pipe_i = pipe_i + 1) begin
                rgb_pipe[pipe_i] <= rgb_pipe[pipe_i-1];
                de_pipe[pipe_i]  <= de_pipe[pipe_i-1];
                hs_pipe[pipe_i]  <= hs_pipe[pipe_i-1];
                vs_pipe[pipe_i]  <= vs_pipe[pipe_i-1];
            end
        end
    end

    assign O_rgb = {rgb_pipe[7], rgb_pipe[7], rgb_pipe[7]};
    assign O_de  = de_pipe[7];
    assign O_hs  = hs_pipe[7];
    assign O_vs  = vs_pipe[7];

endmodule
