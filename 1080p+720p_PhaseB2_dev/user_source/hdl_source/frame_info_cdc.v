`timescale 1ns / 1ns

// Bundled-data CDC for display-frame identity.  The DDR-side payload is
// changed only at display frame start and remains stable throughout vertical
// blanking; the pixel side consumes it at the first active pixel.
module frame_info_cdc (
    input  wire       I_pixel_clk,
    input  wire       I_pixel_rst_n,
    input  wire [1:0] I_read_bank_ddr,
    input  wire [7:0] I_frame_seq_ddr,
    input  wire       I_info_toggle_ddr,
    output wire [1:0] O_read_bank_pixel,
    output wire [7:0] O_frame_seq_pixel,
    output wire       O_info_toggle_pixel
);

(* ASYNC_REG = "TRUE" *) reg [1:0] bank_sync_1;
(* ASYNC_REG = "TRUE" *) reg [1:0] bank_sync_2;
(* ASYNC_REG = "TRUE" *) reg [7:0] seq_sync_1;
(* ASYNC_REG = "TRUE" *) reg [7:0] seq_sync_2;
(* ASYNC_REG = "TRUE" *) reg       toggle_sync_1;
(* ASYNC_REG = "TRUE" *) reg       toggle_sync_2;

always @(posedge I_pixel_clk or negedge I_pixel_rst_n) begin
    if(!I_pixel_rst_n) begin
        bank_sync_1   <= 2'd0;
        bank_sync_2   <= 2'd0;
        seq_sync_1    <= 8'd0;
        seq_sync_2    <= 8'd0;
        toggle_sync_1 <= 1'b0;
        toggle_sync_2 <= 1'b0;
    end else begin
        bank_sync_1   <= I_read_bank_ddr;
        bank_sync_2   <= bank_sync_1;
        seq_sync_1    <= I_frame_seq_ddr;
        seq_sync_2    <= seq_sync_1;
        toggle_sync_1 <= I_info_toggle_ddr;
        toggle_sync_2 <= toggle_sync_1;
    end
end

assign O_read_bank_pixel  = bank_sync_2;
assign O_frame_seq_pixel  = seq_sync_2;
assign O_info_toggle_pixel = toggle_sync_2;

endmodule

