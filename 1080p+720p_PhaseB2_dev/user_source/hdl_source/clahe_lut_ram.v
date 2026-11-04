`timescale 1ns / 1ns

// PH1P35-native dual-bank, four-read CLAHE LUT.
// Four 1024 x 8 replicas are written together and independently read.  The
// physical address MSB selects active/pending bank; each replica fits one
// ERAM20K and avoids the former 256-DRAM-LUT four-port implementation.
module clahe_lut_ram #(
    parameter integer ADDR_WIDTH = 9,
    parameter integer DEPTH = 512
) (
    input  wire                  I_clk,
    input  wire                  I_wr_en,
    input  wire                  I_wr_bank,
    input  wire [ADDR_WIDTH-1:0] I_wr_addr,
    input  wire [7:0]            I_wr_data,
    input  wire                  I_active_bank,
    input  wire [ADDR_WIDTH-1:0] I_addr_00,
    input  wire [ADDR_WIDTH-1:0] I_addr_10,
    input  wire [ADDR_WIDTH-1:0] I_addr_01,
    input  wire [ADDR_WIDTH-1:0] I_addr_11,
    output wire [7:0]            O_lut_00,
    output wire [7:0]            O_lut_10,
    output wire [7:0]            O_lut_01,
    output wire [7:0]            O_lut_11
);

localparam integer PHYS_ADDR_WIDTH = ADDR_WIDTH + 1;
localparam integer PHYS_DEPTH = DEPTH * 2;
wire [PHYS_ADDR_WIDTH-1:0] wr_addr = {I_wr_bank, I_wr_addr};
wire [PHYS_ADDR_WIDTH-1:0] rd_addr_00 = {I_active_bank, I_addr_00};
wire [PHYS_ADDR_WIDTH-1:0] rd_addr_10 = {I_active_bank, I_addr_10};
wire [PHYS_ADDR_WIDTH-1:0] rd_addr_01 = {I_active_bank, I_addr_01};
wire [PHYS_ADDR_WIDTH-1:0] rd_addr_11 = {I_active_bank, I_addr_11};
wire [7:0] unused_doa_00, unused_doa_10, unused_doa_01, unused_doa_11;

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(PHYS_ADDR_WIDTH), .ADDR_WIDTH_B(PHYS_ADDR_WIDTH),
    .DATA_DEPTH_A(PHYS_DEPTH), .DATA_DEPTH_B(PHYS_DEPTH),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"), .ECC_ENCODE("DISABLE"),
    .ECC_DECODE("DISABLE"), .CLKMODE("ASYNC"),
    .SSROVERCE("DISABLE"), .OREGSET_A("RESET"),
    .OREGSET_B("RESET"), .RESETMODE_A("ASYNC"),
    .RESETMODE_B("ASYNC"), .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"), .INIT_FILE("NONE"),
    .FILL_ALL("NONE")
) u_lut00_eram (
    .dia(I_wr_data), .dib(8'd0), .addra(wr_addr), .addrb(rd_addr_00),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk), .wea(I_wr_en), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(unused_doa_00), .dob(O_lut_00),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(PHYS_ADDR_WIDTH), .ADDR_WIDTH_B(PHYS_ADDR_WIDTH),
    .DATA_DEPTH_A(PHYS_DEPTH), .DATA_DEPTH_B(PHYS_DEPTH),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"), .ECC_ENCODE("DISABLE"),
    .ECC_DECODE("DISABLE"), .CLKMODE("ASYNC"),
    .SSROVERCE("DISABLE"), .OREGSET_A("RESET"),
    .OREGSET_B("RESET"), .RESETMODE_A("ASYNC"),
    .RESETMODE_B("ASYNC"), .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"), .INIT_FILE("NONE"),
    .FILL_ALL("NONE")
) u_lut10_eram (
    .dia(I_wr_data), .dib(8'd0), .addra(wr_addr), .addrb(rd_addr_10),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk), .wea(I_wr_en), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(unused_doa_10), .dob(O_lut_10),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(PHYS_ADDR_WIDTH), .ADDR_WIDTH_B(PHYS_ADDR_WIDTH),
    .DATA_DEPTH_A(PHYS_DEPTH), .DATA_DEPTH_B(PHYS_DEPTH),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"), .ECC_ENCODE("DISABLE"),
    .ECC_DECODE("DISABLE"), .CLKMODE("ASYNC"),
    .SSROVERCE("DISABLE"), .OREGSET_A("RESET"),
    .OREGSET_B("RESET"), .RESETMODE_A("ASYNC"),
    .RESETMODE_B("ASYNC"), .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"), .INIT_FILE("NONE"),
    .FILL_ALL("NONE")
) u_lut01_eram (
    .dia(I_wr_data), .dib(8'd0), .addra(wr_addr), .addrb(rd_addr_01),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk), .wea(I_wr_en), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(unused_doa_01), .dob(O_lut_01),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

PH1P_LOGIC_ERAM #(
    .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
    .ADDR_WIDTH_A(PHYS_ADDR_WIDTH), .ADDR_WIDTH_B(PHYS_ADDR_WIDTH),
    .DATA_DEPTH_A(PHYS_DEPTH), .DATA_DEPTH_B(PHYS_DEPTH),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .IMPLEMENT("20K(FAST)"), .ECC_ENCODE("DISABLE"),
    .ECC_DECODE("DISABLE"), .CLKMODE("ASYNC"),
    .SSROVERCE("DISABLE"), .OREGSET_A("RESET"),
    .OREGSET_B("RESET"), .RESETMODE_A("ASYNC"),
    .RESETMODE_B("ASYNC"), .ASYNC_RESET_RELEASE_A("ASYNC"),
    .ASYNC_RESET_RELEASE_B("ASYNC"), .INIT_FILE("NONE"),
    .FILL_ALL("NONE")
) u_lut11_eram (
    .dia(I_wr_data), .dib(8'd0), .addra(wr_addr), .addrb(rd_addr_11),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(I_clk), .clkb(I_clk), .wea(I_wr_en), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(unused_doa_11), .dob(O_lut_11),
    .ecc_sbiterr(), .ecc_dbiterr(),
    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
);

endmodule

