`timescale 1ns / 1ns

// Low-resource centre-weighted automatic exposure controller for SC500CS.
//
// The camera-domain statistic bus is held for a complete frame.  A toggle is
// synchronized into the 24 MHz configuration domain and the bus is sampled
// through two registers (bundled-data CDC).  Exposure is adjusted only once
// per four accepted frames and only outside a wide dead band, preventing the
// visible pumping caused by fast scene-dependent feedback.
module ae_set (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [3:0]  I_btn,
    input  wire        I_mode_1080,
    input  wire [23:0] I_frame_luma_sum,
    input  wire [15:0] I_frame_sample_count,
    input  wire        I_frame_stats_toggle,
    input  wire        I_ae_cfg_done,
    input  wire        I_cam_cfg_done,
    output wire        O_ae_req,
    output wire [15:0] O_ae,
    output wire [15:0] O_ag
);

localparam [15:0] AE_MIN       = 16'd256;
localparam [15:0] AE_MAX_720   = 16'd1990;
localparam [15:0] AE_MAX_1080  = 16'd2246;
localparam [15:0] AE_STEP      = 16'd32;
localparam [15:0] AG_MIN       = 16'd16;
localparam [15:0] AG_INITIAL_720  = 16'd80;
localparam [15:0] AG_INITIAL_1080 = 16'd48;
localparam [15:0] AG_MAX       = 16'd89;
localparam [15:0] AG_STEP      = 16'd2;

wire [15:0] ae_mode_max = I_mode_1080 ? AE_MAX_1080 : AE_MAX_720;
wire [15:0] ag_mode_initial = I_mode_1080 ? AG_INITIAL_1080 :
                                               AG_INITIAL_720;

// The statistic payload is stable for roughly one video frame before the next
// toggle.  The two data registers therefore settle well before new_stats is
// acted upon in this much slower clock domain.
reg        stats_toggle_meta;
reg        stats_toggle_sync;
reg        stats_toggle_sync_d;
reg [23:0] stats_sum_meta;
reg [23:0] stats_sum_sync;
reg [15:0] stats_count_meta;
reg [15:0] stats_count_sync;

wire new_stats = stats_toggle_sync ^ stats_toggle_sync_d;
wire [23:0] dark_threshold = ({8'd0,stats_count_sync} << 6) +
                             ({8'd0,stats_count_sync} << 5); // mean < 96
wire [23:0] bright_threshold = ({8'd0,stats_count_sync} << 7); // mean > 128

always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        stats_toggle_meta   <= 1'b0;
        stats_toggle_sync   <= 1'b0;
        stats_toggle_sync_d <= 1'b0;
        stats_sum_meta      <= 24'd0;
        stats_sum_sync      <= 24'd0;
        stats_count_meta    <= 16'd0;
        stats_count_sync    <= 16'd0;
    end else begin
        stats_toggle_meta   <= I_frame_stats_toggle;
        stats_toggle_sync   <= stats_toggle_meta;
        stats_toggle_sync_d <= stats_toggle_sync;
        stats_sum_meta      <= I_frame_luma_sum;
        stats_sum_sync      <= stats_sum_meta;
        stats_count_meta    <= I_frame_sample_count;
        stats_count_sync    <= stats_count_meta;
    end
end

reg [1:0]  frame_update_div;
reg [15:0] r_ae_set;
reg [15:0] r_ag_set;
reg        target_initialized;

always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        frame_update_div <= 2'd0;
        r_ae_set         <= AE_MAX_720;
        r_ag_set         <= AG_INITIAL_720;
        target_initialized <= 1'b0;
    end else begin
        // Mode is already stable when the path reset is released.  Initialize
        // from its legal maximum without making an asynchronous reset depend
        // on a cross-domain mode signal.
        if(!target_initialized) begin
            target_initialized <= 1'b1;
            r_ae_set            <= ae_mode_max;
            r_ag_set            <= ag_mode_initial;
        end else if(r_ae_set > ae_mode_max) begin
            r_ae_set <= ae_mode_max;
        end else if(new_stats && (stats_count_sync >= 16'd128)) begin
            frame_update_div <= frame_update_div + 1'b1;
            if(frame_update_div == 2'd3) begin
                if(stats_sum_sync < dark_threshold) begin
                    // Prefer exposure time (lower noise); add analogue gain
                    // only after the mode-specific legal exposure is reached.
                    if(r_ae_set < ae_mode_max) begin
                        if(r_ae_set > (ae_mode_max-AE_STEP))
                            r_ae_set <= ae_mode_max;
                        else
                            r_ae_set <= r_ae_set + AE_STEP;
                    end else if(r_ag_set < AG_MAX) begin
                        if(r_ag_set > (AG_MAX-AG_STEP))
                            r_ag_set <= AG_MAX;
                        else
                            r_ag_set <= r_ag_set + AG_STEP;
                    end
                end else if(stats_sum_sync > bright_threshold) begin
                    // Remove noisy gain before shortening exposure.
                    if(r_ag_set > AG_MIN) begin
                        if(r_ag_set < (AG_MIN+AG_STEP))
                            r_ag_set <= AG_MIN;
                        else
                            r_ag_set <= r_ag_set - AG_STEP;
                    end else if(r_ae_set > AE_MIN) begin
                        if(r_ae_set < (AE_MIN+AE_STEP))
                            r_ae_set <= AE_MIN;
                        else
                            r_ae_set <= r_ae_set - AE_STEP;
                    end
                end
            end
        end
    end
end

// Serialize target changes through the existing sensor-I2C request handshake.
// Initial output registers are deliberately different from the targets so the
// first completed camera configuration is followed by one known AE/AG write.
reg [15:0] r_ae;
reg [15:0] r_ag;
reg        r_ae_req;

assign O_ae     = r_ae;
assign O_ag     = r_ag;
assign O_ae_req = r_ae_req;

always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        r_ae_req <= 1'b0;
        r_ae     <= 16'd0;
        r_ag     <= AG_INITIAL_1080;
    end else if(r_ae_req) begin
        r_ae_req <= 1'b0;
    end else if(((r_ae != r_ae_set) || (r_ag != r_ag_set)) &&
                I_cam_cfg_done && I_ae_cfg_done) begin
        r_ae     <= r_ae_set;
        r_ag     <= r_ag_set;
        r_ae_req <= 1'b1;
    end
end

// KEY3/KEY4 belong to algorithm control at top level.  Retain the legacy port
// only to avoid unnecessary interface churn in auxiliary builds.
wire [3:0] unused_btn = I_btn;

endmodule
