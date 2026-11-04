`timescale 1ns / 1ns

// PH1P35-native two-line grayscale store.
//
// Each 8x2048 bank fits in one ERAM20K. Before a location is updated,
// O_row_m2 and O_row_m1 are the pixels at the same x coordinate from rows
// y-2 and y-1. Port B supplies the inherent one-clock synchronous read used
// by spatial_filter_v1.
module gray_line_buffer_eram (
    input  wire        I_clk,
    input  wire        I_wr_en,
    input  wire [10:0] I_wr_addr,
    input  wire [10:0] I_rd_addr,
    input  wire [7:0]  I_current_gray,
    output wire [7:0]  O_row_m2,
    output wire [7:0]  O_row_m1
);

wire [7:0] unused_m2_doa;
wire [7:0] unused_m1_doa;

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
    .MODE("DP"),
    .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"),
    .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
    .CLKMODE("ASYNC"), .SSROVERCE("DISABLE"),
    .OREGSET_A("RESET"), .OREGSET_B("RESET"),
    .RESETMODE_A("ASYNC"), .RESETMODE_B("ASYNC"),
    .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"),
    .INIT_FILE("NONE"), .FILL_ALL("NONE")
) u_row_m2_eram (
    .dia(O_row_m1), .dib(8'd0),
    .addra(I_wr_addr), .addrb(I_rd_addr),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk),
    .wea(I_wr_en), .web(1'b0), .bea(1'b0), .beb(1'b0),
    .rsta(1'b0), .rstb(1'b0),
    .doa(unused_m2_doa), .dob(O_row_m2),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
    .MODE("DP"),
    .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"),
    .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
    .CLKMODE("ASYNC"), .SSROVERCE("DISABLE"),
    .OREGSET_A("RESET"), .OREGSET_B("RESET"),
    .RESETMODE_A("ASYNC"), .RESETMODE_B("ASYNC"),
    .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"),
    .INIT_FILE("NONE"), .FILL_ALL("NONE")
) u_row_m1_eram (
    .dia(I_current_gray), .dib(8'd0),
    .addra(I_wr_addr), .addrb(I_rd_addr),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk),
    .wea(I_wr_en), .web(1'b0), .bea(1'b0), .beb(1'b0),
    .rsta(1'b0), .rstb(1'b0),
    .doa(unused_m1_doa), .dob(O_row_m1),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

endmodule
