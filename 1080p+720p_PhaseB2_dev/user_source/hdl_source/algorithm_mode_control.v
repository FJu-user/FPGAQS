`timescale 1ns / 1ns

// Board-key controller for the shared algorithm demonstration chain.
// KEY3 advances Mode 0..16. KEY4 requests an algorithm reset and returns the
// shadow mode to Mode 0. The downstream commit block applies it at SOF.
module algorithm_mode_control #(
    parameter integer MAX_MODE=16,
    parameter integer DEBOUNCE_BITS = 21
) (
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_key3_n,
    input  wire       I_key4_n,
    input wire I_remote_set,
    input wire [4:0] I_remote_mode,
    output reg [4:0]  O_shadow_mode,
    output reg        O_algorithm_reset_toggle
);

(* ASYNC_REG = "TRUE" *) reg key3_sync_1;
(* ASYNC_REG = "TRUE" *) reg key3_sync_2;
(* ASYNC_REG = "TRUE" *) reg key4_sync_1;
(* ASYNC_REG = "TRUE" *) reg key4_sync_2;

reg [DEBOUNCE_BITS-1:0] key3_count;
reg [DEBOUNCE_BITS-1:0] key4_count;
reg key3_stable_n;
reg key4_stable_n;
reg key3_stable_d;
reg key4_stable_d;

wire key3_press = key3_stable_d && !key3_stable_n;
wire key4_press = key4_stable_d && !key4_stable_n;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        key3_sync_1 <= 1'b1;
        key3_sync_2 <= 1'b1;
        key4_sync_1 <= 1'b1;
        key4_sync_2 <= 1'b1;
    end else begin
        key3_sync_1 <= I_key3_n;
        key3_sync_2 <= key3_sync_1;
        key4_sync_1 <= I_key4_n;
        key4_sync_2 <= key4_sync_1;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        key3_count    <= {DEBOUNCE_BITS{1'b0}};
        key4_count    <= {DEBOUNCE_BITS{1'b0}};
        key3_stable_n <= 1'b1;
        key4_stable_n <= 1'b1;
        key3_stable_d <= 1'b1;
        key4_stable_d <= 1'b1;
    end else begin
        key3_stable_d <= key3_stable_n;
        key4_stable_d <= key4_stable_n;

        if(key3_sync_2 == key3_stable_n) begin
            key3_count <= {DEBOUNCE_BITS{1'b0}};
        end else if(&key3_count) begin
            key3_stable_n <= key3_sync_2;
            key3_count    <= {DEBOUNCE_BITS{1'b0}};
        end else begin
            key3_count <= key3_count + {{(DEBOUNCE_BITS-1){1'b0}},1'b1};
        end

        if(key4_sync_2 == key4_stable_n) begin
            key4_count <= {DEBOUNCE_BITS{1'b0}};
        end else if(&key4_count) begin
            key4_stable_n <= key4_sync_2;
            key4_count    <= {DEBOUNCE_BITS{1'b0}};
        end else begin
            key4_count <= key4_count + {{(DEBOUNCE_BITS-1){1'b0}},1'b1};
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_shadow_mode          <= 5'd0;
        O_algorithm_reset_toggle <= 1'b0;
    end else begin
        // RESET has priority if both keys are pressed together.
        if(key4_press) begin
            O_shadow_mode             <= 5'd0;
            // A toggle is an event token that remains observable across a
            // stopped or resetting HDMI pixel clock.  A one-cycle pulse in
            // this clock domain could be lost during a display-mode switch.
            O_algorithm_reset_toggle <= ~O_algorithm_reset_toggle;
        end else if(I_remote_set && I_remote_mode<=MAX_MODE) begin
            O_shadow_mode<=I_remote_mode;
        end else if(key3_press) begin
            case(O_shadow_mode)
                5'd0:  O_shadow_mode <= 5'd1;
                5'd1:  O_shadow_mode <= 5'd2;
                5'd2:  O_shadow_mode <= 5'd3;
                5'd3:  O_shadow_mode <= 5'd4;
                5'd4:  O_shadow_mode <= 5'd5;
                5'd5:  O_shadow_mode <= 5'd6;
                5'd6:  O_shadow_mode <= 5'd7;
                5'd7:  O_shadow_mode <= 5'd8;
                5'd8:  O_shadow_mode <= 5'd9;
                5'd9:  O_shadow_mode <= 5'd10;
                5'd10: O_shadow_mode <= 5'd11;
                5'd11: O_shadow_mode <= 5'd12;
                5'd12: O_shadow_mode <= 5'd13;
                5'd13: O_shadow_mode <= 5'd14;
                5'd14: O_shadow_mode <= 5'd15;
                5'd15: O_shadow_mode <= 5'd16;
                5'd16: O_shadow_mode <= MAX_MODE>=17?5'd17:5'd0;
                5'd17: O_shadow_mode <= MAX_MODE>=18?5'd18:5'd0;
                default: O_shadow_mode <= 5'd0;
            endcase
        end
    end
end

endmodule
