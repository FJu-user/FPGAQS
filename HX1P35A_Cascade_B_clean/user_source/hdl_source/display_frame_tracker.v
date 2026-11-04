`timescale 1ns / 1ns

// DDR-domain record of the buffer that the display reader actually selected.
// The sequence advances only when that bank changes; repeated display frames
// therefore retain the same sequence number.
module display_frame_tracker (
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_display_frame_start,
    input  wire [1:0] I_read_bank,
    output reg  [1:0] O_active_read_bank,
    output reg  [7:0] O_display_frame_seq,
    output reg        O_frame_info_toggle
);

reg [1:0] previous_read_bank;
reg       have_previous_bank;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_active_read_bank  <= 2'd0;
        O_display_frame_seq <= 8'd0;
        O_frame_info_toggle <= 1'b0;
        previous_read_bank  <= 2'd0;
        have_previous_bank  <= 1'b0;
    end else if(I_display_frame_start) begin
        O_active_read_bank  <= I_read_bank;
        // Toggle every displayed frame.  The sequence number below tells the
        // pixel domain whether the camera image is new or merely repeated.
        O_frame_info_toggle <= ~O_frame_info_toggle;
        if(!have_previous_bank || (I_read_bank != previous_read_bank))
            O_display_frame_seq <= O_display_frame_seq + 8'd1;
        previous_read_bank <= I_read_bank;
        have_previous_bank <= 1'b1;
    end
end

endmodule

