`timescale 1ns / 1ns

// PH1P35-native 512 x 18 CLAHE histogram store.
// Port A is the single write port; port B is a synchronous read port.
module clahe_hist_ram #(
    parameter integer ADDR_WIDTH = 9,
    parameter integer DATA_WIDTH = 18,
    parameter integer DEPTH = 512
) (
    input  wire                  I_clk,
    input  wire                  I_wr_en,
    input  wire [ADDR_WIDTH-1:0] I_wr_addr,
    input  wire [DATA_WIDTH-1:0] I_wr_data,
    input  wire [ADDR_WIDTH-1:0] I_rd_addr,
    output wire [DATA_WIDTH-1:0] O_rd_data
);

wire [DATA_WIDTH-1:0] unused_doa;

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(DATA_WIDTH), .DATA_WIDTH_B(DATA_WIDTH),
    .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
    .DATA_DEPTH_A(DEPTH), .DATA_DEPTH_B(DEPTH),
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
) u_hist_eram (
    .dia(I_wr_data), .dib({DATA_WIDTH{1'b0}}),
    .addra(I_wr_addr), .addrb(I_rd_addr),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk),
    .wea(I_wr_en), .web(1'b0), .bea(1'b0), .beb(1'b0),
    .rsta(1'b0), .rstb(1'b0),
    .doa(unused_doa), .dob(O_rd_data),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

endmodule

