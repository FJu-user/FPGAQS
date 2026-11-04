`timescale 1ns / 1ns

// Merged Mode 13: migration of the active ronghe Mode 1 (source Mode28).
//
// The source Mode28 algorithm is an 8x8 block luminance mean, a previous
// block mean, an adaptive temporal IIR, a fixed IIR reference, and a local
// two-frame motion hold.  This target implementation keeps those semantics,
// gates all history by I_frame_is_new, uses dynamic 1280/720 and 1920/1080
// block grids, and presents a fixed 13-cycle pixel transaction.
//
// I_strength[3:2] selects page 0/1/2. I_strength[1:0] selects source
// strength 1/2/3; zero is mapped to preset 1 for the reset-compatible board
// default.
module temporal_motion_v1 #(
    parameter integer REGION_OVERLAY = 0,
    parameter integer MAX_BLOCK_COLS = 240,
    parameter integer ADDR_W         = 15,
    parameter integer RAM_DEPTH      = 32768
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_start,
    input  wire        I_frame_end,
    input  wire        I_frame_is_new,
    input  wire [4:0]  I_algorithm_mode,
    input  wire [7:0]  I_strength,
    input  wire        I_soft_reset,
    input  wire        I_overlay_enable,
    output wire [23:0] O_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [7:0]  O_motion_score
);

    localparam integer PIPE_STAGES = 12;

    function [7:0] luma8;
        input [23:0] rgb;
        reg signed [10:0] r_s, g_s, b_s;
        reg signed [12:0] y_s;
        begin
            r_s = {1'b0,rgb[23:16]};
            g_s = {1'b0,rgb[15:8]};
            b_s = {1'b0,rgb[7:0]};
            y_s = g_s + ((r_s-g_s) >>> 2) + ((b_s-g_s) >>> 4);
            if(y_s < 0) luma8 = 8'd0;
            else if(y_s > 255) luma8 = 8'hff;
            else luma8 = y_s[7:0];
        end
    endfunction

    function [7:0] lp_step;
        input [7:0] old_v;
        input [7:0] target_v;
        input [2:0] shift_v;
        reg signed [10:0] d;
        reg signed [10:0] step_v;
        reg signed [12:0] n;
        begin
            d = $signed({1'b0,target_v}) - $signed({1'b0,old_v});
            if(d < 0) step_v = -((-d) >>> shift_v);
            else step_v = d >>> shift_v;
            n = $signed({1'b0,old_v}) + step_v;
            if(n < 0) lp_step = 8'd0;
            else if(n > 255) lp_step = 8'hff;
            else lp_step = n[7:0];
        end
    endfunction

    function signed [12:0] stable_block_delta;
        input signed [12:0] delta_v;
        reg signed [13:0] reduced_v;
        begin
            if(delta_v > 13'sd4)
                reduced_v = ($signed(delta_v) - 14'sd4) >>> 1;
            else if(delta_v < -13'sd4)
                reduced_v = -(((-$signed(delta_v)) - 14'sd4) >>> 1);
            else
                reduced_v = 14'sd0;
            if(reduced_v > 14'sd10)
                stable_block_delta = 13'sd10;
            else if(reduced_v < -14'sd10)
                stable_block_delta = -13'sd10;
            else
                stable_block_delta = reduced_v[12:0];
        end
    endfunction

    function [7:0] sat_add_delta;
        input [7:0] base_v;
        input signed [12:0] delta_v;
        reg signed [13:0] n;
        begin
            n = $signed({1'b0,base_v}) + delta_v;
            if(n < 0) sat_add_delta = 8'd0;
            else if(n > 255) sat_add_delta = 8'hff;
            else sat_add_delta = n[7:0];
        end
    endfunction

    function [23:0] motion_palette;
        input [7:0] score;
        begin
            if(score < 8'd8) motion_palette = 24'h04103c;
            else if(score < 8'd32) motion_palette = 24'h04b0d0;
            else if(score < 8'd72) motion_palette = 24'hd0d008;
            else if(score < 8'd128) motion_palette = 24'hff9004;
            else motion_palette = 24'hf01010;
        end
    endfunction

    wire mode_enable = (I_algorithm_mode == 5'd13);
    wire mode_1080 = (I_active_width >= 12'd1920);
    wire [1:0] selected_page = (I_strength[3:2] <= 2'd2) ? I_strength[3:2] : 2'd0;
    wire [1:0] selected_strength = (I_strength[1:0] == 2'd0) ? 2'd1 : I_strength[1:0];
    wire in_roi = mode_enable && I_de && (I_x < I_active_width) &&
                  (I_y < I_active_height);

    // Register the RGB-to-luma result before it enters the block accumulators.
    // The coordinate/control tag is delayed with it so the accumulator still
    // consumes exactly the same pixel transaction.
    reg [7:0] current_luma_d;
    reg [11:0] acc_x, acc_y, acc_active_width, acc_active_height;
    reg acc_de, acc_frame_is_new, acc_frame_end, acc_mode_enable;
    reg acc_soft_reset, acc_history_ready;

    wire [8:0] block_x_wide = I_x[11:3];
    wire [7:0] block_y = I_y[10:3];
    wire [7:0] block_col = (block_x_wide < MAX_BLOCK_COLS) ?
                           block_x_wide[7:0] : 8'd0;
    wire [14:0] block_y_ext = {7'd0,block_y};
    wire [14:0] block_x_ext = {6'd0,block_x_wide};
    wire [14:0] block_addr_720 = (block_y_ext << 7) +
                                 (block_y_ext << 5) + block_x_ext;
    wire [14:0] block_addr_1080 = (block_y_ext << 7) +
                                  (block_y_ext << 6) +
                                  (block_y_ext << 5) +
                                  (block_y_ext << 4) + block_x_ext;
    wire [ADDR_W-1:0] block_addr = mode_1080 ? block_addr_1080[ADDR_W-1:0] :
                                                    block_addr_720[ADDR_W-1:0];

    wire acc_mode_1080 = (acc_active_width >= 12'd1920);
    wire [8:0] acc_block_x_wide = acc_x[11:3];
    wire [7:0] acc_block_y = acc_y[10:3];
    wire [7:0] acc_block_col = (acc_block_x_wide < MAX_BLOCK_COLS) ?
                                acc_block_x_wide[7:0] : 8'd0;
    wire [14:0] acc_block_y_ext = {7'd0,acc_block_y};
    wire [14:0] acc_block_x_ext = {6'd0,acc_block_x_wide};
    wire [14:0] acc_block_addr_720 = (acc_block_y_ext << 7) +
                                      (acc_block_y_ext << 5) + acc_block_x_ext;
    wire [14:0] acc_block_addr_1080 = (acc_block_y_ext << 7) +
                                       (acc_block_y_ext << 6) +
                                       (acc_block_y_ext << 5) +
                                       (acc_block_y_ext << 4) + acc_block_x_ext;
    wire [ADDR_W-1:0] acc_block_addr = acc_mode_1080 ?
                                       acc_block_addr_1080[ADDR_W-1:0] :
                                       acc_block_addr_720[ADDR_W-1:0];

    // One partial sum per block column. A completed block is emitted at its
    // bottom-right pixel. The frame_is_new gate freezes this state on a
    // duplicated 1080p display frame.
    wire [13:0] column_sum_q;
    reg [13:0] column_sum_active;
    reg [13:0] row_sum;
    wire [7:0] current_luma = current_luma_d;
    wire [13:0] row_sum_plus_pixel = row_sum + {6'd0,current_luma};
    // Read the partial sum once at the first pixel of each 8-pixel block and
    // carry it through the block.  The former expression indexed the whole
    // 240-entry array on every pixel and TD built a wide LUT mux in the
    // 149.343 MHz path.  At y[2:0]==0 the previous-row contribution is zero;
    // this also makes the first row independent of RAM power-up contents.
    wire [13:0] block_column_base = (acc_y[2:0] == 3'd0) ?
                                     14'd0 : column_sum_active;
    wire [13:0] block_sum = block_column_base + row_sum_plus_pixel;
    wire acc_in_roi = acc_mode_enable && acc_de &&
                      (acc_x < acc_active_width) &&
                      (acc_y < acc_active_height);
    wire block_event = acc_in_roi && acc_frame_is_new &&
                       (acc_x[2:0] == 3'd7) && (acc_y[2:0] == 3'd7);
    wire [7:0] block_average = block_sum[13:6];

    // Same write edge/data and read capture as the former resettable table.
    // The table is native DRAM plus resettable validity, not 3360 data FFs.
    wire column_sum_wr_en = !acc_soft_reset && acc_mode_enable &&
                            acc_de && acc_frame_is_new && (acc_x[2:0] == 3'd7);
    wire [13:0] column_sum_wr_data = (acc_y[2:0] == 3'd0) ? row_sum_plus_pixel :
                                    (acc_y[2:0] == 3'd7) ? 14'd0 : block_sum;
    motion_column_cache_v1 #(.COLS(MAX_BLOCK_COLS)) u_column_cache (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_rd_addr(acc_block_col),
        .I_wr_addr(acc_block_col), .I_wr_data(column_sum_wr_data),
        .I_wr_en(column_sum_wr_en), .O_rd_data(column_sum_q)
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            row_sum <= 14'd0;
            column_sum_active <= 14'd0;
        end else if(acc_soft_reset || !acc_mode_enable) begin
            row_sum <= 14'd0;
            column_sum_active <= 14'd0;
        end else if(acc_de && acc_frame_is_new) begin
            if(acc_x[2:0] == 3'd0) begin
                row_sum <= {6'd0,current_luma};
                // The array read is now paid once per block, rather than
                // being repeated in the per-pixel block_sum cone.
                if(acc_y[2:0] == 3'd0)
                    column_sum_active <= 14'd0;
                else
                    column_sum_active <= column_sum_q;
            end else
                row_sum <= row_sum_plus_pixel;
        end
    end

    // A single packed word keeps previous mean, adaptive filtered mean, fixed
    // reference, and local hold in one target-native ERAM. Bit layout is
    // {filtered[7:0], previous[7:0], fixed[7:0], hold[1:0]}.
    wire [25:0] state_q;
    reg  [25:0] state_d;
    reg  [ADDR_W-1:0] state_wr_addr;
    reg  state_wr_en;
    temporal_motion_banked_state_v1 #(.ADDR_W(ADDR_W), .DEPTH(RAM_DEPTH))
    u_state_ram (
        .I_clk(I_clk), .I_rd_addr(block_addr), .I_wr_addr(state_wr_addr),
        .I_wr_data(state_d), .I_wr_en(state_wr_en), .O_rd_data(state_q)
    );

    reg history_ready;
    reg seed_frame_seen;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            current_luma_d <= 8'd0;
            acc_x <= 12'd0;
            acc_y <= 12'd0;
            acc_active_width <= 12'd0;
            acc_active_height <= 12'd0;
            acc_de <= 1'b0;
            acc_frame_is_new <= 1'b0;
            acc_frame_end <= 1'b0;
            acc_mode_enable <= 1'b0;
            acc_soft_reset <= 1'b0;
            acc_history_ready <= 1'b0;
        end else begin
            current_luma_d <= luma8(I_rgb);
            acc_x <= I_x;
            acc_y <= I_y;
            acc_active_width <= I_active_width;
            acc_active_height <= I_active_height;
            acc_de <= I_de;
            acc_frame_is_new <= I_frame_is_new;
            acc_frame_end <= I_frame_end;
            acc_mode_enable <= mode_enable;
            acc_soft_reset <= I_soft_reset;
            acc_history_ready <= history_ready;
        end
    end

    reg [7:0] current_diff;
    reg [7:0] next_filtered;
    reg [7:0] next_fixed;
    reg [7:0] score_now;
    reg [7:0] next_block_score;
    reg [2:0] filter_shift;
    reg motion_now;
    reg dilated_motion;

    reg               event_valid;
    reg [ADDR_W-1:0] event_addr;
    reg [7:0] event_average;
    reg [25:0] event_state_q;
    reg               event_history_ready;

    always @(*) begin
        current_diff = (event_average >= event_state_q[17:10]) ?
                       (event_average - event_state_q[17:10]) :
                       (event_state_q[17:10] - event_average);
        case(selected_strength)
            2'd1: filter_shift = 3'd3;
            2'd2: filter_shift = 3'd4;
            default: filter_shift = 3'd5;
        endcase
        motion_now = event_history_ready &&
                     (current_diff >= ((selected_strength == 2'd2) ? 8'd16 :
                                      (selected_strength == 2'd1) ? 8'd20 : 8'd28));
        dilated_motion = motion_now ||
                         (event_history_ready && (event_state_q[1:0] != 2'd0));
        if(dilated_motion)
            next_filtered = event_average;
        else
            next_filtered = lp_step(event_state_q[25:18], event_average, filter_shift);
        next_fixed = lp_step(event_state_q[9:2], event_average, filter_shift);
        if(!event_history_ready) begin
            current_diff = 8'd0;
            motion_now = 1'b0;
            dilated_motion = 1'b0;
            next_filtered = event_average;
            next_fixed = event_average;
        end
        score_now = (current_diff > 8'd63) ? 8'hff : {current_diff[5:0],2'b00};
        if(dilated_motion && (score_now < 8'd32)) score_now = 8'd32;
        next_block_score = score_now;
        state_wr_en = event_valid;
        state_wr_addr = event_addr;
        state_d = {next_filtered,event_average,next_fixed,
                   (!event_history_ready) ? 2'd0 :
                   motion_now ? 2'd2 :
                   (event_state_q[1:0] != 2'd0) ? event_state_q[1:0] - 1'b1 : 2'd0};
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            history_ready <= 1'b0;
            seed_frame_seen <= 1'b0;
            event_valid <= 1'b0;
            event_addr <= {ADDR_W{1'b0}};
            event_average <= 8'd0;
            event_state_q <= 26'd0;
            event_history_ready <= 1'b0;
        end else begin
            // The accumulator is fed by the one-cycle luma/tag pipeline.
            // At this edge state_q is the synchronous RAM value for the
            // delayed accumulator pixel, so the completed-block transaction
            // can be captured directly without another stale address cycle.
            event_valid <= block_event;
            if(block_event) begin
                event_addr <= acc_block_addr;
                event_average <= block_average;
                event_state_q <= state_q;
                event_history_ready <= acc_history_ready;
            end

            if(acc_soft_reset || !acc_mode_enable) begin
                history_ready <= 1'b0;
                seed_frame_seen <= 1'b0;
            end else if(acc_frame_end && acc_frame_is_new) begin
                if(seed_frame_seen)
                    history_ready <= 1'b1;
                else
                    seed_frame_seen <= 1'b1;
            end
        end
    end

    // Keep a complete pixel transaction beside the synchronous ERAM response.
    // PH1P_LOGIC_ERAM with REGMODE_B=NOREG still changes dob on the clock
    // edge. After that edge state_q is the word for the same address whose
    // pixel was captured into p_*, so processed_rgb is sampled one edge later
    // with the correct block state. The explicit event tag above is reserved
    // for the write path, where the completed block average is delayed.
    reg [7:0] event_bx, event_by;
    reg region_frame_end, region_frame_new;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            event_bx <= 0; event_by <= 0;
            region_frame_end <= 0; region_frame_new <= 0;
        end else begin
            if(block_event) begin event_bx <= acc_block_col; event_by <= acc_block_y; end
            region_frame_end <= acc_frame_end;
            region_frame_new <= acc_frame_is_new;
        end
    end
    reg p_overlay;
    reg [23:0] p_rgb;
    reg [11:0] p_x, p_y, p_active_width;
    reg p_de, p_hs, p_vs, p_enable, p_in_roi, p_history_ready;
    wire region_border, region_text;
    generate if(REGION_OVERLAY) begin: region
        motion_region_overlay_v1 u_motion_region (
            .I_clk(I_clk), .I_rst_n(I_rst_n),
            .I_enable(mode_enable), .I_soft_reset(I_soft_reset),
            .I_frame_start(I_frame_start), .I_frame_end(region_frame_end),
            .I_frame_is_new(region_frame_new),
            .I_event_valid(event_valid), .I_motion(dilated_motion),
            .I_block_x(event_bx), .I_block_y(event_by),
            .I_overlay(p_enable && p_de && p_overlay),
            .I_active_width(p_active_width), .I_x(p_x), .I_y(p_y),
            .O_border(region_border), .O_text(region_text),
            .O_box_valid(), .O_x_min(), .O_x_max(), .O_y_min(), .O_y_max(), .O_event_bcd()
        );
    end else begin: no_region
        assign region_border = 1'b0;
        assign region_text = 1'b0;
    end endgenerate
    reg [1:0] p_page;
    wire [7:0] display_previous = state_q[17:10];
    wire [7:0] display_filtered = state_q[25:18];
    wire [7:0] display_fixed = state_q[9:2];
    wire [1:0] display_hold = state_q[1:0];
    wire display_motion = p_history_ready && (display_hold != 2'd0);
    wire [7:0] display_motion_score = (display_hold == 2'd3) ? 8'd160 :
                                       (display_hold == 2'd2) ? 8'd96 :
                                       (display_hold == 2'd1) ? 8'd40 : 8'd0;
    wire signed [12:0] decoded_filter_delta = p_history_ready ?
        ($signed({1'b0,display_filtered}) -
         $signed({1'b0,display_previous})) : 13'sd0;
    wire signed [12:0] decoded_fixed_delta = p_history_ready ?
        ($signed({1'b0,display_fixed}) -
         $signed({1'b0,display_previous})) : 13'sd0;
    wire signed [12:0] q_filter_delta = stable_block_delta(decoded_filter_delta);
    wire signed [12:0] q_fixed_delta = stable_block_delta(decoded_fixed_delta);
    wire [11:0] display_split_x = p_active_width >> 1;

    reg [23:0] processed_rgb;
    always @(*) begin
        processed_rgb = p_rgb;
        if(p_enable && p_de) begin
            if(p_overlay) processed_rgb = p_rgb;
            else if(p_page == 2'd0) begin
                processed_rgb = display_motion ? motion_palette(display_motion_score) :
                                24'h04103c;
            end else if(p_in_roi && p_page == 2'd1 && (p_x < display_split_x)) begin
                processed_rgb = {
                    sat_add_delta(p_rgb[23:16],q_fixed_delta),
                    sat_add_delta(p_rgb[15:8], q_fixed_delta),
                    sat_add_delta(p_rgb[7:0],  q_fixed_delta)
                };
            end else if(p_in_roi && ((p_page == 2'd2) ||
                                     (p_x >= display_split_x))) begin
                processed_rgb = {
                    display_motion ? p_rgb[23:16] :
                        sat_add_delta(p_rgb[23:16],q_filter_delta),
                    display_motion ? p_rgb[15:8] :
                        sat_add_delta(p_rgb[15:8], q_filter_delta),
                    display_motion ? p_rgb[7:0] :
                        sat_add_delta(p_rgb[7:0], q_filter_delta)
                };
            end
        end
    end

    reg [23:0] rgb_pipe [0:PIPE_STAGES-1];
    reg de_pipe [0:PIPE_STAGES-1];
    reg hs_pipe [0:PIPE_STAGES-1];
    reg vs_pipe [0:PIPE_STAGES-1];
    reg [7:0] score_pipe [0:PIPE_STAGES-1];
    integer pipe_index;
    reg [7:0] block_score;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            p_rgb <= 24'd0;
            p_x <= 12'd0; p_y <= 12'd0; p_active_width <= 12'd0;
            p_de <= 1'b0; p_hs <= 1'b0; p_vs <= 1'b0;
            p_enable <= 1'b0; p_in_roi <= 1'b0; p_history_ready <= 1'b0;
            p_page <= 2'd0;
            p_overlay <= 1'b0;
            block_score <= 8'd0;
            for(pipe_index=0; pipe_index<PIPE_STAGES; pipe_index=pipe_index+1) begin
                rgb_pipe[pipe_index] <= 24'd0;
                de_pipe[pipe_index] <= 1'b0;
                hs_pipe[pipe_index] <= 1'b0;
                vs_pipe[pipe_index] <= 1'b0;
                score_pipe[pipe_index] <= 8'd0;
            end
        end else begin
            p_rgb <= I_rgb;
            p_x <= I_x; p_y <= I_y; p_active_width <= I_active_width;
            p_de <= I_de; p_hs <= I_hs; p_vs <= I_vs;
            p_enable <= mode_enable; p_in_roi <= in_roi;
            p_history_ready <= history_ready;
            p_page <= selected_page;
            p_overlay <= REGION_OVERLAY ? I_overlay_enable : 1'b0;
            rgb_pipe[0] <= processed_rgb;
            de_pipe[0] <= p_de;
            hs_pipe[0] <= p_hs;
            vs_pipe[0] <= p_vs;
            score_pipe[0] <= block_score;
            for(pipe_index=1; pipe_index<PIPE_STAGES; pipe_index=pipe_index+1) begin
                rgb_pipe[pipe_index] <= rgb_pipe[pipe_index-1];
                de_pipe[pipe_index] <= de_pipe[pipe_index-1];
                hs_pipe[pipe_index] <= hs_pipe[pipe_index-1];
                vs_pipe[pipe_index] <= vs_pipe[pipe_index-1];
                score_pipe[pipe_index] <= score_pipe[pipe_index-1];
            end
            // Registered masks cover the existing next RGB stage: no extra latency.
            if(region_text) rgb_pipe[1] <= 24'hffff00;
            else if(region_border) rgb_pipe[1] <= 24'h00ff00;
            if(event_valid)
                block_score <= next_block_score;
        end
    end

    assign O_rgb = rgb_pipe[PIPE_STAGES-1];
    assign O_de = de_pipe[PIPE_STAGES-1];
    assign O_hs = hs_pipe[PIPE_STAGES-1];
    assign O_vs = vs_pipe[PIPE_STAGES-1];
    assign O_motion_score = score_pipe[PIPE_STAGES-1];
endmodule

// Target-native single-clock dual-port temporal RAM wrapper. The state word
// is packed so one ERAM instance carries all per-block history fields.
module temporal_motion_ram_v1 #(
    parameter integer DATA_WIDTH = 26,
    parameter integer ADDR_W = 15,
    parameter integer DEPTH = 32768
) (
    input  wire                    I_clk,
    input  wire [ADDR_W-1:0]       I_rd_addr,
    input  wire [ADDR_W-1:0]       I_wr_addr,
    input  wire [DATA_WIDTH-1:0]   I_wr_data,
    input  wire                    I_wr_en,
    output wire [DATA_WIDTH-1:0]   O_rd_data
);
    wire [DATA_WIDTH-1:0] unused_doa;
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(DATA_WIDTH), .DATA_WIDTH_B(DATA_WIDTH),
        .ADDR_WIDTH_A(ADDR_W), .ADDR_WIDTH_B(ADDR_W),
        .DATA_DEPTH_A(DEPTH), .DATA_DEPTH_B(DEPTH),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"), .ECC_ENCODE("DISABLE"),
        .ECC_DECODE("DISABLE"), .CLKMODE("ASYNC"),
        .SSROVERCE("DISABLE"), .OREGSET_A("RESET"), .OREGSET_B("RESET"),
        .RESETMODE_A("ASYNC"), .RESETMODE_B("ASYNC"),
        .ASYNC_RESET_RELEASE_A("ASYNC"), .ASYNC_RESET_RELEASE_B("ASYNC"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_temporal_ram (
        .dia(I_wr_data), .dib({DATA_WIDTH{1'b0}}),
        .addra(I_wr_addr), .addrb(I_rd_addr),
        .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
        .clka(I_clk), .clkb(I_clk), .wea(I_wr_en), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0),
        .doa(unused_doa), .dob(O_rd_data),
        .ecc_sbiterr(), .ecc_dbiterr()
    );
endmodule

// Full 26-bit state is preserved. The ten board-live bits are adjacent
// so each 4096-word bank uses two physical 5-bit ERAM lanes instead of ten
// 32768-deep one-bit lanes. Read latency remains exactly one clock edge.
module temporal_motion_banked_state_v1 #(
    parameter integer ADDR_W = 15,
    parameter integer DEPTH = 32768
) (
    input wire I_clk,
    input wire [ADDR_W-1:0] I_rd_addr, I_wr_addr,
    input wire [25:0] I_wr_data,
    input wire I_wr_en,
    output wire [25:0] O_rd_data
);
    generate if(ADDR_W > 12 && DEPTH == (2**ADDR_W)) begin: banked
        localparam integer BANKS = 2**(ADDR_W-12);
        wire [25:0] packed_data = {I_wr_data[25:18], I_wr_data[9:2],
                                  I_wr_data[17:10], I_wr_data[1:0]};
        wire [25:0] q [0:BANKS-1];
        reg [ADDR_W-13:0] read_bank;
        always @(posedge I_clk) read_bank <= I_rd_addr[ADDR_W-1:12];
        genvar b;
        for(b=0; b<BANKS; b=b+1) begin: banks
            temporal_motion_ram_v1 #(.DATA_WIDTH(26), .ADDR_W(12), .DEPTH(4096)) store (
                .I_clk(I_clk), .I_rd_addr(I_rd_addr[11:0]),
                .I_wr_addr(I_wr_addr[11:0]), .I_wr_data(packed_data),
                .I_wr_en(I_wr_en && I_wr_addr[ADDR_W-1:12] == b), .O_rd_data(q[b])
            );
        end
        wire [25:0] selected = q[read_bank];
        assign O_rd_data = {selected[25:18], selected[9:2],
                            selected[17:10], selected[1:0]};
    end else begin: original_shape
        temporal_motion_ram_v1 #(.DATA_WIDTH(26), .ADDR_W(ADDR_W), .DEPTH(DEPTH)) store (
            .I_clk(I_clk), .I_rd_addr(I_rd_addr), .I_wr_addr(I_wr_addr),
            .I_wr_data(I_wr_data), .I_wr_en(I_wr_en), .O_rd_data(O_rd_data)
        );
    end endgenerate
endmodule
