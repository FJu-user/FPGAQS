`timescale 1ns/1ps
// Explicit ERAM: no frame-wide reset, asynchronous read, or register RAM.
module road_route_memory #(parameter W=4, A=12)(
 input wire wclk,rclk, input wire we, input wire [A-1:0] wa,ra,
 input wire [W-1:0] wd, output wire [W-1:0] q);
`ifdef ROAD_SIM
 reg [W-1:0] mem[0:(1<<A)-1]; reg [W-1:0] qr;
 always @(posedge wclk)if(we)mem[wa]<=wd;
 always @(posedge rclk)qr<=mem[ra];
 assign q=qr;
`else
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(W),.DATA_WIDTH_B(W),
 .ADDR_WIDTH_A(A),.ADDR_WIDTH_B(A),.DATA_DEPTH_A(1<<A),.DATA_DEPTH_B(1<<A),
 .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
 .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),.CLKMODE("ASYNC"),
 .SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),
 .RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),
 .INIT_FILE("NONE"),.FILL_ALL("NONE")) ram(
 .dia(wd),.dib({W{1'b0}}),.addra(wa),.addrb(ra),.cea(1'b1),.ceb(1'b1),
 .ocea(1'b0),.oceb(1'b0),.clka(wclk),.clkb(rclk),.wea(we),.web(1'b0),
 .bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(q),
 .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule
