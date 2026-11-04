`timescale 1ns / 1ns

// Current Mode12: colour-preserving CLAHE-Lite V2.
//
// Statistics use one shared PH1P35 ERAM (16 tiles x 32 bins).  LUT mapping
// uses four mirrored ERAMs so four neighbouring values are available every
// pixel clock.  All histogram maintenance is a background multi-cycle FSM;
// the independent seven-stage pixel path remains one pixel/clock.
module clahe_lite_v2 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input wire I_context_reset,
    input  wire        I_mode_1080,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire [23:0] I_rgb,
    input  wire [7:0]  I_luma,
    input  wire        I_de,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_end,
    input  wire        I_frame_is_new,
    output reg  [23:0] O_rgb,
    output reg         O_de
);

localparam [3:0] S_BOOT_CLEAR    = 4'd0;
localparam [3:0] S_COLLECT       = 4'd1;
localparam [3:0] S_COLLECT_FLUSH = 4'd2;
localparam [3:0] S_CLIP_READ     = 4'd3;
localparam [3:0] S_CLIP_EVAL     = 4'd4;
localparam [3:0] S_CLIP_ACCUM    = 4'd5;
localparam [3:0] S_CDF_READ      = 4'd6;
localparam [3:0] S_CDF_ACCUM     = 4'd7;
localparam [3:0] S_CDF_SCALE_A   = 4'd8;
localparam [3:0] S_CDF_SCALE_B   = 4'd9;
localparam [3:0] S_CDF_WRITE     = 4'd10;
localparam [3:0] S_CLEAR         = 4'd11;

localparam integer HIST_DEPTH = 512;
localparam integer TILE_COUNT = 16;
localparam [17:0] CLIP_720  = 18'd2304;
localparam [17:0] CLIP_1080 = 18'd5184;

reg [3:0] state;
reg [8:0] scan_addr;
reg       cfg_mode_1080;
reg [11:0] cfg_width;
reg [11:0] cfg_height;
reg       active_bank;
reg       build_bank;
reg       pending_ready;
reg       lut_valid;
reg [17:0] tile_excess [0:TILE_COUNT-1];

wire frame_start_in = I_de && (I_x == 12'd0) && (I_y == 12'd0);
wire real_pixel = I_de && I_frame_is_new;
wire mode_for_input = frame_start_in ? I_mode_1080 : cfg_mode_1080;

function [1:0] tile_x_of;
    input [11:0] px;
    input        mode1080;
    begin
        if(mode1080) begin
            if(px < 12'd480)       tile_x_of = 2'd0;
            else if(px < 12'd960)  tile_x_of = 2'd1;
            else if(px < 12'd1440) tile_x_of = 2'd2;
            else                   tile_x_of = 2'd3;
        end else begin
            if(px < 12'd320)       tile_x_of = 2'd0;
            else if(px < 12'd640)  tile_x_of = 2'd1;
            else if(px < 12'd960)  tile_x_of = 2'd2;
            else                   tile_x_of = 2'd3;
        end
    end
endfunction

function [1:0] tile_y_of;
    input [11:0] py;
    input        mode1080;
    begin
        if(mode1080) begin
            if(py < 12'd270)       tile_y_of = 2'd0;
            else if(py < 12'd540)  tile_y_of = 2'd1;
            else if(py < 12'd810)  tile_y_of = 2'd2;
            else                   tile_y_of = 2'd3;
        end else begin
            if(py < 12'd180)       tile_y_of = 2'd0;
            else if(py < 12'd360)  tile_y_of = 2'd1;
            else if(py < 12'd540)  tile_y_of = 2'd2;
            else                   tile_y_of = 2'd3;
        end
    end
endfunction

// -------------------------------------------------------------------------
// Histogram ERAM: synchronous read plus a one-entry write-forward path.
// The bypass is required when adjacent pixels hit the same tile/bin address.
// -------------------------------------------------------------------------
wire [1:0] input_tile_x = tile_x_of(I_x, mode_for_input);
wire [1:0] input_tile_y = tile_y_of(I_y, mode_for_input);
wire [8:0] input_hist_addr = {input_tile_y, input_tile_x, I_luma[7:3]};

reg        collect_valid_q;
reg [8:0]  collect_addr_q;
reg        last_collect_write_valid;
reg [8:0]  last_collect_write_addr;
reg [17:0] last_collect_write_data;

wire [8:0] hist_rd_addr = ((state == S_COLLECT) && real_pixel) ?
                          input_hist_addr : scan_addr;
wire [17:0] hist_rd_data;
wire collect_write = ((state == S_COLLECT) ||
                      (state == S_COLLECT_FLUSH)) && collect_valid_q;
wire [17:0] collect_base =
    (last_collect_write_valid &&
     (last_collect_write_addr == collect_addr_q)) ?
    last_collect_write_data : hist_rd_data;
wire [18:0] collect_plus_one = {1'b0,collect_base} + 19'd1;
wire [17:0] collect_write_data = collect_plus_one[18] ?
                                 18'h3ffff : collect_plus_one[17:0];

wire [17:0] clip_limit = cfg_mode_1080 ? CLIP_1080 : CLIP_720;
wire [17:0] clip_value = (hist_rd_data > clip_limit) ?
                         clip_limit : hist_rd_data;
wire [17:0] clip_excess_value = (hist_rd_data > clip_limit) ?
                                (hist_rd_data - clip_limit) : 18'd0;
reg [17:0] clip_value_q;
reg [17:0] clip_excess_q;
wire hist_clear_write = (state == S_BOOT_CLEAR) || (state == S_CLEAR);
wire hist_clip_write = (state == S_CLIP_ACCUM);
wire hist_wr_en = hist_clear_write || hist_clip_write || collect_write;
wire [8:0] hist_wr_addr = hist_clear_write ? scan_addr :
                          hist_clip_write ? scan_addr : collect_addr_q;
wire [17:0] hist_wr_data = hist_clear_write ? 18'd0 :
                            hist_clip_write ? clip_value_q : collect_write_data;

clahe_hist_ram #(.ADDR_WIDTH(9), .DATA_WIDTH(18), .DEPTH(HIST_DEPTH))
u_clahe_hist_ram (
    .I_clk(I_clk), .I_wr_en(hist_wr_en),
    .I_wr_addr(hist_wr_addr), .I_wr_data(hist_wr_data),
    .I_rd_addr(hist_rd_addr), .O_rd_data(hist_rd_data)
);

// -------------------------------------------------------------------------
// Background CDF/LUT builder.  Clip deliberately consumes three clocks:
// synchronous ERAM read, clip evaluation, accumulation/write.  CDF/LUT then
// uses separate read, accumulate, two scale and write states.
// No pixel coordinate or histogram read can reach a LUT write in one cycle.
// -------------------------------------------------------------------------
wire [3:0] scan_tile = scan_addr[8:5];
wire [4:0] scan_bin = scan_addr[4:0];
wire [17:0] excess_share = tile_excess[scan_tile] >> 5;
wire [17:0] redistributed_count = hist_rd_data + excess_share +
    ((scan_bin < tile_excess[scan_tile][4:0]) ? 18'd1 : 18'd0);
reg [17:0] cdf_acc;
wire [18:0] cdf_base = (scan_bin == 5'd0) ? 19'd0 : {1'b0,cdf_acc};
wire [18:0] cdf_sum = cdf_base + {1'b0,redistributed_count};
wire [17:0] cdf_next = cdf_sum[18] ? 18'h3ffff : cdf_sum[17:0];

reg [17:0] cdf_scale_input;
reg [26:0] scale_partial;
reg [26:0] scale_extra;
reg [26:0] lut_product_q;
wire [10:0] lut_scaled_q16 = lut_product_q[26:16];
wire [7:0] lut_write_value = (lut_scaled_q16 > 11'd255) ?
                             8'd255 : lut_scaled_q16[7:0];
wire lut_wr_en = (state == S_CDF_WRITE);

// -------------------------------------------------------------------------
// Seven-stage pixel mapper.
// S0 coordinate capture; S1 ERAM request/weight capture; S2 ERAM output;
// S3 horizontal multipliers; S4 horizontal add; S5 vertical multiplier;
// S6 vertical add; S7 colour reconstruction at O_rgb.
// -------------------------------------------------------------------------
reg [23:0] rgb_s0;
reg [7:0]  luma_s0;
reg [11:0] x_s0, y_s0;
reg        mode_s0, de_s0;

// Pixel coordinate pipeline:
//   Stage A: compare/subtract only (tile boundaries and fractions)
//   Stage B: fixed reciprocal weights (DSP-friendly constant multiply)
//   Stage C: LUT address formation and ERAM request
//   Stage D: ERAM output capture
// This keeps coordinate compares, subtraction and weight arithmetic out of one
// 149.343 MHz period while preserving one-pixel-per-clock throughput.
reg [1:0] tile_x_a_l, tile_x_a_r, tile_y_a_t, tile_y_a_b;
reg [11:0] x_frac_a, y_frac_a;
reg mode_a;
reg [7:0] luma_a;
reg [23:0] rgb_a;
reg de_a, valid_a;

always @* begin
    tile_x_a_l = 2'd0; tile_x_a_r = 2'd0; x_frac_a = 12'd0;
    tile_y_a_t = 2'd0; tile_y_a_b = 2'd0; y_frac_a = 12'd0;
    if(mode_s0) begin
        if(x_s0 < 12'd240) begin tile_x_a_l=0; tile_x_a_r=0; x_frac_a=0; end
        else if(x_s0 < 12'd720) begin tile_x_a_l=0; tile_x_a_r=1; x_frac_a=x_s0-12'd240; end
        else if(x_s0 < 12'd1200) begin tile_x_a_l=1; tile_x_a_r=2; x_frac_a=x_s0-12'd720; end
        else if(x_s0 < 12'd1680) begin tile_x_a_l=2; tile_x_a_r=3; x_frac_a=x_s0-12'd1200; end
        else begin tile_x_a_l=3; tile_x_a_r=3; x_frac_a=0; end
        if(y_s0 < 12'd135) begin tile_y_a_t=0; tile_y_a_b=0; y_frac_a=0; end
        else if(y_s0 < 12'd405) begin tile_y_a_t=0; tile_y_a_b=1; y_frac_a=y_s0-12'd135; end
        else if(y_s0 < 12'd675) begin tile_y_a_t=1; tile_y_a_b=2; y_frac_a=y_s0-12'd405; end
        else if(y_s0 < 12'd945) begin tile_y_a_t=2; tile_y_a_b=3; y_frac_a=y_s0-12'd675; end
        else begin tile_y_a_t=3; tile_y_a_b=3; y_frac_a=0; end
    end else begin
        if(x_s0 < 12'd160) begin tile_x_a_l=0; tile_x_a_r=0; x_frac_a=0; end
        else if(x_s0 < 12'd480) begin tile_x_a_l=0; tile_x_a_r=1; x_frac_a=x_s0-12'd160; end
        else if(x_s0 < 12'd800) begin tile_x_a_l=1; tile_x_a_r=2; x_frac_a=x_s0-12'd480; end
        else if(x_s0 < 12'd1120) begin tile_x_a_l=2; tile_x_a_r=3; x_frac_a=x_s0-12'd800; end
        else begin tile_x_a_l=3; tile_x_a_r=3; x_frac_a=0; end
        if(y_s0 < 12'd90) begin tile_y_a_t=0; tile_y_a_b=0; y_frac_a=0; end
        else if(y_s0 < 12'd270) begin tile_y_a_t=0; tile_y_a_b=1; y_frac_a=y_s0-12'd90; end
        else if(y_s0 < 12'd450) begin tile_y_a_t=1; tile_y_a_b=2; y_frac_a=y_s0-12'd270; end
        else if(y_s0 < 12'd630) begin tile_y_a_t=2; tile_y_a_b=3; y_frac_a=y_s0-12'd450; end
        else begin tile_y_a_t=3; tile_y_a_b=3; y_frac_a=0; end
    end
end

reg [1:0] tile_x_b_l, tile_x_b_r, tile_y_b_t, tile_y_b_b;
reg [11:0] x_frac_b, y_frac_b;
reg [7:0] wx_b, wy_b, luma_b;
reg [23:0] rgb_b;
reg de_b, valid_b;
wire [20:0] x_weight_product = x_frac_b * (mode_a ? 9'd136 : 9'd205);
wire [20:0] y_weight_product = y_frac_b * (mode_a ? 9'd243 : 9'd364);
wire [7:0] wx_b_comb = x_weight_product[15:8];
wire [7:0] wy_b_comb = y_weight_product[15:8];

wire [8:0] addr_00 = {tile_y_b_t, tile_x_b_l, luma_b[7:3]};
wire [8:0] addr_10 = {tile_y_b_t, tile_x_b_r, luma_b[7:3]};
wire [8:0] addr_01 = {tile_y_b_b, tile_x_b_l, luma_b[7:3]};
wire [8:0] addr_11 = {tile_y_b_b, tile_x_b_r, luma_b[7:3]};

reg [7:0] wx_c, wy_c, luma_c;
reg [23:0] rgb_c;
reg de_c, valid_c;

wire [7:0] lut_00, lut_10, lut_01, lut_11;
clahe_lut_ram #(.ADDR_WIDTH(9), .DEPTH(512)) u_clahe_lut_ram (
    .I_clk(I_clk), .I_wr_en(lut_wr_en), .I_wr_bank(build_bank),
    .I_wr_addr(scan_addr), .I_wr_data(lut_write_value),
    .I_active_bank(active_bank),
    .I_addr_00(addr_00), .I_addr_10(addr_10),
    .I_addr_01(addr_01), .I_addr_11(addr_11),
    .O_lut_00(lut_00), .O_lut_10(lut_10),
    .O_lut_01(lut_01), .O_lut_11(lut_11)
);

reg [7:0] lut00_s2, lut10_s2, lut01_s2, lut11_s2;
reg [7:0] wx_s2, wy_s2, luma_s2;
reg [23:0] rgb_s2;
reg de_s2, valid_s2;

wire signed [8:0] top_diff_s2 = $signed({1'b0,lut10_s2}) -
                                $signed({1'b0,lut00_s2});
wire signed [8:0] bot_diff_s2 = $signed({1'b0,lut11_s2}) -
                                $signed({1'b0,lut01_s2});
wire signed [17:0] top_product_comb =
    top_diff_s2 * $signed({1'b0,wx_s2});
wire signed [17:0] bot_product_comb =
    bot_diff_s2 * $signed({1'b0,wx_s2});

reg signed [17:0] top_product_s3, bot_product_s3;
reg [7:0] top_base_s3, bot_base_s3, wy_s3, luma_s3;
reg [23:0] rgb_s3;
reg de_s3, valid_s3;
wire signed [9:0] top_offset_s3 = top_product_s3 >>> 8;
wire signed [9:0] bot_offset_s3 = bot_product_s3 >>> 8;
wire signed [9:0] top_interp_comb =
    $signed({2'b00,top_base_s3}) + top_offset_s3;
wire signed [9:0] bot_interp_comb =
    $signed({2'b00,bot_base_s3}) + bot_offset_s3;

reg signed [9:0] top_s4, bot_s4;
reg [7:0] wy_s4, luma_s4;
reg [23:0] rgb_s4;
reg de_s4, valid_s4;
wire signed [10:0] vert_diff_s4 =
    $signed({bot_s4[9],bot_s4}) - $signed({top_s4[9],top_s4});
wire signed [19:0] vert_product_comb =
    vert_diff_s4 * $signed({1'b0,wy_s4});

reg signed [19:0] vert_product_s5;
reg signed [9:0] top_base_s5;
reg [7:0] luma_s5;
reg [23:0] rgb_s5;
reg de_s5, valid_s5;
wire signed [10:0] vert_offset_s5 = vert_product_s5 >>> 8;
wire signed [10:0] mapped_sum_s5 =
    $signed({top_base_s5[9],top_base_s5}) + vert_offset_s5;
wire [7:0] mapped_clamped_s5 = (mapped_sum_s5 < 0) ? 8'd0 :
                               (mapped_sum_s5 > 11'sd255) ? 8'd255 :
                               mapped_sum_s5[7:0];

reg [7:0] mapped_y_s6, luma_s6;
reg [23:0] rgb_s6;
reg de_s6, valid_s6;
wire signed [9:0] y_delta_s6 = $signed({1'b0,mapped_y_s6}) -
                               $signed({1'b0,luma_s6});

function [7:0] sat_add;
    input [7:0] base;
    input signed [9:0] delta;
    reg signed [10:0] sum;
    begin
        sum = $signed({3'b000,base}) + $signed({delta[9],delta});
        if(sum < 0) sat_add = 8'd0;
        else if(sum > 11'sd255) sat_add = 8'd255;
        else sat_add = sum[7:0];
    end
endfunction

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        rgb_s0 <= 0; luma_s0 <= 0; x_s0 <= 0; y_s0 <= 0;
        mode_s0 <= 0; de_s0 <= 0;
        tile_x_b_l <= 0; tile_x_b_r <= 0; tile_y_b_t <= 0; tile_y_b_b <= 0;
        x_frac_b <= 0; y_frac_b <= 0; mode_a <= 0;
        luma_b <= 0; rgb_b <= 0; de_b <= 0; valid_b <= 0;
        wx_c <= 0; wy_c <= 0; luma_c <= 0; rgb_c <= 0;
        de_c <= 0; valid_c <= 0;
        lut00_s2 <= 0; lut10_s2 <= 0; lut01_s2 <= 0; lut11_s2 <= 0;
        wx_s2 <= 0; wy_s2 <= 0; luma_s2 <= 0; rgb_s2 <= 0;
        de_s2 <= 0; valid_s2 <= 0;
        top_product_s3 <= 0; bot_product_s3 <= 0;
        top_base_s3 <= 0; bot_base_s3 <= 0; wy_s3 <= 0; luma_s3 <= 0;
        rgb_s3 <= 0; de_s3 <= 0; valid_s3 <= 0;
        top_s4 <= 0; bot_s4 <= 0; wy_s4 <= 0; luma_s4 <= 0;
        rgb_s4 <= 0; de_s4 <= 0; valid_s4 <= 0;
        vert_product_s5 <= 0; top_base_s5 <= 0; luma_s5 <= 0;
        rgb_s5 <= 0; de_s5 <= 0; valid_s5 <= 0;
        mapped_y_s6 <= 0; luma_s6 <= 0; rgb_s6 <= 0;
        de_s6 <= 0; valid_s6 <= 0;
        O_rgb <= 0; O_de <= 0;
    end else if(I_context_reset) begin
        rgb_s0 <= 0; luma_s0 <= 0; x_s0 <= 0; y_s0 <= 0;
        mode_s0 <= 0; de_s0 <= 0;
        tile_x_b_l <= 0; tile_x_b_r <= 0; tile_y_b_t <= 0; tile_y_b_b <= 0;
        x_frac_b <= 0; y_frac_b <= 0; mode_a <= 0;
        luma_b <= 0; rgb_b <= 0; de_b <= 0; valid_b <= 0;
        wx_c <= 0; wy_c <= 0; luma_c <= 0; rgb_c <= 0;
        de_c <= 0; valid_c <= 0;
        lut00_s2 <= 0; lut10_s2 <= 0; lut01_s2 <= 0; lut11_s2 <= 0;
        wx_s2 <= 0; wy_s2 <= 0; luma_s2 <= 0; rgb_s2 <= 0;
        de_s2 <= 0; valid_s2 <= 0;
        top_product_s3 <= 0; bot_product_s3 <= 0;
        top_base_s3 <= 0; bot_base_s3 <= 0; wy_s3 <= 0; luma_s3 <= 0;
        rgb_s3 <= 0; de_s3 <= 0; valid_s3 <= 0;
        top_s4 <= 0; bot_s4 <= 0; wy_s4 <= 0; luma_s4 <= 0;
        rgb_s4 <= 0; de_s4 <= 0; valid_s4 <= 0;
        vert_product_s5 <= 0; top_base_s5 <= 0; luma_s5 <= 0;
        rgb_s5 <= 0; de_s5 <= 0; valid_s5 <= 0;
        mapped_y_s6 <= 0; luma_s6 <= 0; rgb_s6 <= 0;
        de_s6 <= 0; valid_s6 <= 0;
        O_rgb <= 0; O_de <= 0;
    end else begin
        rgb_s0 <= I_rgb; luma_s0 <= I_luma; x_s0 <= I_x; y_s0 <= I_y;
        mode_s0 <= I_mode_1080; de_s0 <= I_de;

        // Stage A register: only tile comparisons/subtractions are before
        // this boundary.
        tile_x_b_l <= tile_x_a_l; tile_x_b_r <= tile_x_a_r;
        tile_y_b_t <= tile_y_a_t; tile_y_b_b <= tile_y_a_b;
        x_frac_b <= x_frac_a; y_frac_b <= y_frac_a;
        mode_a <= mode_s0;
        luma_b <= luma_s0; rgb_b <= rgb_s0;
        de_b <= de_s0; valid_b <= lut_valid;

        // Stage B register: fixed reciprocal weights are isolated from
        // coordinate compares. Stage C addresses below now launch ERAM.
        wx_c <= wx_b_comb; wy_c <= wy_b_comb;
        luma_c <= luma_b; rgb_c <= rgb_b;
        de_c <= de_b; valid_c <= valid_b;

        // Stage D register: the synchronous ERAM output corresponds to the
        // address launched by the preceding stage-C cycle.
        lut00_s2 <= lut_00; lut10_s2 <= lut_10;
        lut01_s2 <= lut_01; lut11_s2 <= lut_11;
        wx_s2 <= wx_c; wy_s2 <= wy_c; luma_s2 <= luma_c;
        rgb_s2 <= rgb_c; de_s2 <= de_c; valid_s2 <= valid_c;

        top_product_s3 <= top_product_comb;
        bot_product_s3 <= bot_product_comb;
        top_base_s3 <= lut00_s2; bot_base_s3 <= lut01_s2;
        wy_s3 <= wy_s2; luma_s3 <= luma_s2; rgb_s3 <= rgb_s2;
        de_s3 <= de_s2; valid_s3 <= valid_s2;

        top_s4 <= top_interp_comb; bot_s4 <= bot_interp_comb;
        wy_s4 <= wy_s3; luma_s4 <= luma_s3; rgb_s4 <= rgb_s3;
        de_s4 <= de_s3; valid_s4 <= valid_s3;

        vert_product_s5 <= vert_product_comb; top_base_s5 <= top_s4;
        luma_s5 <= luma_s4; rgb_s5 <= rgb_s4;
        de_s5 <= de_s4; valid_s5 <= valid_s4;

        mapped_y_s6 <= mapped_clamped_s5;
        luma_s6 <= luma_s5; rgb_s6 <= rgb_s5;
        de_s6 <= de_s5; valid_s6 <= valid_s5;

        O_de <= de_s6;
        if(valid_s6)
            O_rgb <= {sat_add(rgb_s6[23:16],y_delta_s6),
                      sat_add(rgb_s6[15:8], y_delta_s6),
                      sat_add(rgb_s6[7:0],  y_delta_s6)};
        else
            O_rgb <= rgb_s6;
    end
end

// Counters remain visible to the focused testbench as repeat-frame evidence.
reg [31:0] hist_update_count;
reg [31:0] lut_generation_count;

integer tile_index;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        state <= S_BOOT_CLEAR;
        scan_addr <= 9'd0;
        cfg_mode_1080 <= 1'b0;
        cfg_width <= 12'd1280;
        cfg_height <= 12'd720;
        active_bank <= 1'b0;
        build_bank <= 1'b1;
        pending_ready <= 1'b0;
        lut_valid <= 1'b0;
        collect_valid_q <= 1'b0;
        collect_addr_q <= 9'd0;
        last_collect_write_valid <= 1'b0;
        last_collect_write_addr <= 9'd0;
        last_collect_write_data <= 18'd0;
        cdf_acc <= 18'd0;
        cdf_scale_input <= 18'd0;
        scale_partial <= 27'd0;
        scale_extra <= 27'd0;
        lut_product_q <= 27'd0;
        hist_update_count <= 32'd0;
        lut_generation_count <= 32'd0;
        for(tile_index=0; tile_index<TILE_COUNT; tile_index=tile_index+1)
            tile_excess[tile_index] <= 18'd0;
    end else if(I_context_reset) begin
        state <= S_BOOT_CLEAR;
        scan_addr <= 9'd0;
        cfg_mode_1080 <= 1'b0;
        cfg_width <= 12'd1280;
        cfg_height <= 12'd720;
        active_bank <= 1'b0;
        build_bank <= 1'b1;
        pending_ready <= 1'b0;
        lut_valid <= 1'b0;
        collect_valid_q <= 1'b0;
        collect_addr_q <= 9'd0;
        last_collect_write_valid <= 1'b0;
        last_collect_write_addr <= 9'd0;
        last_collect_write_data <= 18'd0;
        cdf_acc <= 18'd0;
        cdf_scale_input <= 18'd0;
        scale_partial <= 27'd0;
        scale_extra <= 27'd0;
        lut_product_q <= 27'd0;
        hist_update_count <= 32'd0;
        lut_generation_count <= 32'd0;
        for(tile_index=0; tile_index<TILE_COUNT; tile_index=tile_index+1)
            tile_excess[tile_index] <= 18'd0;
    end else begin
        if(frame_start_in) begin
            cfg_mode_1080 <= I_mode_1080;
            cfg_width <= I_active_width;
            cfg_height <= I_active_height;
            if(I_frame_is_new && pending_ready) begin
                active_bank <= build_bank;
                pending_ready <= 1'b0;
            end
        end

        if(state == S_COLLECT) begin
            collect_valid_q <= real_pixel;
            if(real_pixel)
                collect_addr_q <= input_hist_addr;
        end else begin
            collect_valid_q <= 1'b0;
        end

        if(collect_write) begin
            last_collect_write_valid <= 1'b1;
            last_collect_write_addr <= collect_addr_q;
            last_collect_write_data <= collect_write_data;
            hist_update_count <= hist_update_count + 32'd1;
        end else if((state != S_COLLECT) && (state != S_COLLECT_FLUSH)) begin
            last_collect_write_valid <= 1'b0;
        end

        case(state)
            S_BOOT_CLEAR: begin
                if(scan_addr == 9'd511) begin
                    scan_addr <= 9'd0;
                    state <= S_COLLECT;
                end else scan_addr <= scan_addr + 9'd1;
            end

            S_COLLECT: begin
                if(I_de && I_frame_end && I_frame_is_new) begin
                    state <= S_COLLECT_FLUSH;
                    scan_addr <= 9'd0;
                    cdf_acc <= 18'd0;
                    build_bank <= ~active_bank;
                    for(tile_index=0; tile_index<TILE_COUNT;
                        tile_index=tile_index+1)
                        tile_excess[tile_index] <= 18'd0;
                end
            end

            S_COLLECT_FLUSH: begin
                // The final pixel's synchronous histogram response is written
                // on this edge before the background clip pass begins.
                state <= S_CLIP_READ;
                scan_addr <= 9'd0;
            end

            S_CLIP_READ: state <= S_CLIP_EVAL;

            S_CLIP_EVAL: begin
                clip_value_q <= clip_value;
                clip_excess_q <= clip_excess_value;
                state <= S_CLIP_ACCUM;
            end

            S_CLIP_ACCUM: begin
                if(scan_bin == 5'd0)
                    tile_excess[scan_tile] <= clip_excess_q;
                else
                    tile_excess[scan_tile] <=
                        tile_excess[scan_tile] + clip_excess_q;
                if(scan_addr == 9'd511) begin
                    scan_addr <= 9'd0;
                    cdf_acc <= 18'd0;
                    state <= S_CDF_READ;
                end else begin
                    scan_addr <= scan_addr + 9'd1;
                    state <= S_CLIP_READ;
                end
            end

            S_CDF_READ: state <= S_CDF_ACCUM;

            S_CDF_ACCUM: begin
                cdf_acc <= cdf_next;
                cdf_scale_input <= cdf_next;
                state <= S_CDF_SCALE_A;
            end

            S_CDF_SCALE_A: begin
                if(cfg_mode_1080) begin
                    // 129 = 128 + 1.
                    scale_partial <= ({9'd0,cdf_scale_input} << 7);
                    scale_extra <= {9'd0,cdf_scale_input};
                end else begin
                    // 290 = 256 + 32 + 2.
                    scale_partial <= ({9'd0,cdf_scale_input} << 8) +
                                     ({9'd0,cdf_scale_input} << 5);
                    scale_extra <= ({9'd0,cdf_scale_input} << 1);
                end
                state <= S_CDF_SCALE_B;
            end

            S_CDF_SCALE_B: begin
                lut_product_q <= scale_partial + scale_extra;
                state <= S_CDF_WRITE;
            end

            S_CDF_WRITE: begin
                if(scan_addr == 9'd511) begin
                    scan_addr <= 9'd0;
                    cdf_acc <= 18'd0;
                    pending_ready <= 1'b1;
                    lut_valid <= 1'b1;
                    lut_generation_count <= lut_generation_count + 32'd1;
                    state <= S_CLEAR;
                end else begin
                    scan_addr <= scan_addr + 9'd1;
                    state <= S_CDF_READ;
                end
            end

            S_CLEAR: begin
                if(scan_addr == 9'd511) begin
                    scan_addr <= 9'd0;
                    state <= S_COLLECT;
                end else scan_addr <= scan_addr + 9'd1;
            end

            default: begin
                state <= S_BOOT_CLEAR;
                scan_addr <= 9'd0;
            end
        endcase
    end
end

endmodule

