`timescale 1ns / 1ns

// Carries persistent algorithm controls from the always-running 100 MHz
// domain into the selected HDMI pixel-clock domain.  The mode bus is stable
// except for debounced key events; two samples plus a settle cycle are used
// before it is declared valid.  KEY4 is represented by a toggle so it cannot
// disappear while the destination clock is stopped.
module algorithm_control_cdc (
    input  wire       I_pixel_clk,
    input  wire       I_pixel_rst_n,
    input  wire [4:0] I_mode_sys,
    input  wire       I_reset_toggle_sys,
    output reg  [4:0] O_mode_pixel,
    output reg        O_mode_valid,
    output reg        O_reset_event
);

(* ASYNC_REG = "TRUE" *) reg [4:0] mode_meta;
(* ASYNC_REG = "TRUE" *) reg [4:0] mode_sync;
(* ASYNC_REG = "TRUE" *) reg       reset_meta;
(* ASYNC_REG = "TRUE" *) reg       reset_sync;
reg [2:0] valid_pipe;
reg       reset_seen;

always @(posedge I_pixel_clk or negedge I_pixel_rst_n) begin
    if(!I_pixel_rst_n) begin
        mode_meta    <= 5'd0;
        mode_sync    <= 5'd0;
        reset_meta   <= 1'b0;
        reset_sync   <= 1'b0;
        valid_pipe   <= 3'b000;
        O_mode_pixel <= 5'd0;
        O_mode_valid <= 1'b0;
        O_reset_event<= 1'b0;
        reset_seen   <= 1'b0;
    end else begin
        mode_meta  <= I_mode_sys;
        mode_sync  <= mode_meta;
        reset_meta <= I_reset_toggle_sys;
        reset_sync <= reset_meta;
        valid_pipe <= {valid_pipe[1:0],1'b1};

        O_reset_event <= 1'b0;
        if(!valid_pipe[2]) begin
            // Establish a baseline after a pixel-domain restart.  The mode
            // survives; the restart itself already clears algorithm history.
            reset_seen <= reset_sync;
        end else begin
            O_mode_pixel <= mode_sync;
            O_mode_valid <= 1'b1;
            if(reset_sync != reset_seen) begin
                reset_seen    <= reset_sync;
                O_reset_event <= 1'b1;
            end
        end
    end
end

endmodule
