`timescale 1ns / 1ns

// Shadow controls become active only on the first active pixel of a frame.
// The combinational SOF selection makes the new values visible to that very
// first pixel, while the registers hold them stable for the rest of the frame.
module algorithm_ctrl_commit (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_frame_start,
    input  wire        I_mode_1080,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire [4:0]  I_shadow_mode,
    input  wire [7:0]  I_shadow_threshold,
    input  wire [7:0]  I_shadow_strength,
    input  wire        I_shadow_valid,
    input  wire        I_soft_reset_commit,
    output wire [4:0]  O_active_mode,
    output wire [7:0]  O_active_threshold,
    output wire [7:0]  O_active_strength,
    output wire [7:0]  O_config_epoch
);

reg        mode_1080_q;
reg [11:0] width_q;
reg [11:0] height_q;
reg [4:0]  active_mode_q;
reg [7:0]  active_threshold_q;
reg [7:0]  active_strength_q;
reg [7:0]  config_epoch_q;

wire config_changed = (I_mode_1080       != mode_1080_q) ||
                      (I_active_width     != width_q) ||
                      (I_active_height    != height_q) ||
                      (I_shadow_mode      != active_mode_q) ||
                      (I_shadow_threshold != active_threshold_q) ||
                      (I_shadow_strength  != active_strength_q);

wire commit_controls = I_frame_start && I_shadow_valid;
assign O_active_mode      = I_soft_reset_commit ? 5'd0 :
                            commit_controls ? I_shadow_mode : active_mode_q;
assign O_active_threshold = I_soft_reset_commit ? 8'd128 :
                            commit_controls ? I_shadow_threshold : active_threshold_q;
assign O_active_strength  = I_soft_reset_commit ? 8'd0 :
                            commit_controls ? I_shadow_strength : active_strength_q;
assign O_config_epoch     = (I_soft_reset_commit ||
                             (commit_controls && config_changed)) ?
                            (config_epoch_q + 8'd1) : config_epoch_q;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        mode_1080_q       <= 1'b0;
        width_q           <= 12'd0;
        height_q          <= 12'd0;
        active_mode_q     <= 5'd0;
        active_threshold_q<= 8'd128;
        active_strength_q <= 8'd0;
        config_epoch_q    <= 8'd0;
    end else if(I_soft_reset_commit) begin
        mode_1080_q        <= I_mode_1080;
        width_q            <= I_active_width;
        height_q           <= I_active_height;
        active_mode_q      <= 5'd0;
        active_threshold_q <= 8'd128;
        active_strength_q  <= 8'd0;
        config_epoch_q     <= config_epoch_q + 8'd1;
    end else if(commit_controls) begin
        mode_1080_q        <= I_mode_1080;
        width_q            <= I_active_width;
        height_q           <= I_active_height;
        active_mode_q      <= I_shadow_mode;
        active_threshold_q <= I_shadow_threshold;
        active_strength_q  <= I_shadow_strength;
        if(config_changed)
            config_epoch_q <= config_epoch_q + 8'd1;
    end
end

endmodule
