`timescale 1ns / 1ns

// KEY2: 16 -> 8 -> 32 -> 16. Persistent state lives in the 100 MHz domain.
// A bundled-data mailbox holds both size bits until the pixel domain ACKs.
// Repeated snapshots also recover automatically after a pixel-only reset.
module key2_mosaic_size_control #(
    parameter integer MOTION_OVERLAY = 0,
    parameter integer DEBOUNCE_BITS = 21
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_key2_n,
    input wire I_reset_toggle,
    input wire [4:0] I_mode_sys,
    output reg O_motion_overlay_pixel,
    input wire I_pixel_clk,
    input wire I_pixel_rst_n,
    output reg [1:0] O_size_shadow,
    output reg [7:0] O_strength_pixel,
    output reg O_valid_pixel
);
(* ASYNC_REG = "TRUE" *) reg key_meta, key_sync;
reg [DEBOUNCE_BITS-1:0] count;
reg stable_n, stable_d, reset_seen;
reg [2:0] payload;
reg motion_overlay_shadow;
reg request;
(* ASYNC_REG = "TRUE" *) reg ack_meta, ack_sync;
(* ASYNC_REG = "TRUE" *) reg req_meta, req_sync;
reg acknowledge;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        key_meta <= 1'b1;
        key_sync <= 1'b1;
        count <= 0;
        stable_n <= 1'b1;
        stable_d <= 1'b1;
        reset_seen <= 1'b0;
        O_size_shadow <= 2'd0;
        motion_overlay_shadow <= 1'b0;
    end else begin
        key_meta <= I_key2_n;
        key_sync <= key_meta;
        stable_d <= stable_n;
        reset_seen <= I_reset_toggle;
        if(key_sync == stable_n) count <= 0;
        else if(&count) begin
            stable_n <= key_sync;
            count <= 0;
        end else count <= count + 1'b1;

        if(reset_seen != I_reset_toggle || (MOTION_OVERLAY && I_mode_sys != 5'd13))
            motion_overlay_shadow <= 1'b0;
        else if(MOTION_OVERLAY && stable_d && !stable_n)
            motion_overlay_shadow <= ~motion_overlay_shadow;

        if(reset_seen != I_reset_toggle) O_size_shadow <= 2'd0;
        else if(stable_d && !stable_n && !(MOTION_OVERLAY && I_mode_sys == 5'd13)) begin
            case(O_size_shadow)
                2'd0: O_size_shadow <= 2'd1;
                2'd1: O_size_shadow <= 2'd2;
                default: O_size_shadow <= 2'd0;
            endcase
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        ack_meta <= 1'b0;
        ack_sync <= 1'b0;
        payload <= 3'd0;
        request <= 1'b0;
    end else begin
        ack_meta <= acknowledge;
        ack_sync <= ack_meta;
        if(ack_sync == request) begin
            payload <= {motion_overlay_shadow,O_size_shadow};
            request <= ~request;
        end
    end
end

always @(posedge I_pixel_clk or negedge I_pixel_rst_n) begin
    if(!I_pixel_rst_n) begin
        req_meta <= 1'b0;
        req_sync <= 1'b0;
        acknowledge <= 1'b0;
        O_strength_pixel <= 8'd0;
        O_motion_overlay_pixel <= 1'b0;
        O_valid_pixel <= 1'b0;
    end else begin
        req_meta <= request;
        req_sync <= req_meta;
        if(req_sync != acknowledge) begin
            // Payload has been held through two request synchronizer stages.
            O_strength_pixel <= {6'd0, payload[1:0]};
            O_motion_overlay_pixel <= MOTION_OVERLAY ? payload[2] : 1'b0;
            O_valid_pixel <= 1'b1;
            acknowledge <= req_sync;
        end
    end
end
endmodule
