`timescale 1ns/1ps
// Sandbox native same-clock RAM. Port A writes or pre-reads; B reads.
// No memory/output reset. The caller owns initialization and collision masks.
module storage_dp #(parameter WIDTH=8,ADDR=9,DEPTH=512)(
 input wire clk,we,read_en,input wire[ADDR-1:0]wa,ra,
 input wire[WIDTH-1:0]wd,output wire[WIDTH-1:0]qa,qb
);
PH1P_LOGIC_ERAM #(
 .DATA_WIDTH_A(WIDTH),.DATA_WIDTH_B(WIDTH),
 .ADDR_WIDTH_A(ADDR),.ADDR_WIDTH_B(ADDR),.DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),
 .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
 .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),.CLKMODE("SYNC"),.SSROVERCE("DISABLE"),
 .OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")
)u_ram(
 .dia(wd),.dib({WIDTH{1'b0}}),.addra(wa),.addrb(ra),.cea(1'b1),.ceb(read_en),
 .ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),.wea(we),.web(1'b0),.bea(1'b0),.beb(1'b0),
 .rsta(1'b0),.rstb(1'b0),.doa(qa),.dob(qb),.ecc_sbiterr(),.ecc_dbiterr(),
 .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
endmodule
