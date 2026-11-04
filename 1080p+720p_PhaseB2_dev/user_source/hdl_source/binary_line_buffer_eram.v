`timescale 1ns/1ps
// Packed two-row 1-bit memory: a single native PH1P35 ERAM20K.
// Same one-clock enabled read as the previous distributed [1:0] array.
// Writes remain one clock behind reads. RAM and output are NOT reset.
// Use the project's already-proven 8x2048 DP configuration; six data bits
// are zero/unused. One logical word is {previous_row_bit,current_row_bit}.
// Both ports use the same pixel clock; select the native SYNC clock mode.
module binary_line_buffer_eram (
 input wire I_clk,I_wr_en,I_rd_en,
 input wire [10:0] I_wr_addr,I_rd_addr,
 input wire [1:0] I_wr_data,
 output wire [1:0] O_rd_data
);
wire [7:0] unused_write_output,read_output;
assign O_rd_data=read_output[1:0];
PH1P_LOGIC_ERAM #(
 .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),
 .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
 .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
 .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
 .IMPLEMENT("20K(FAST)"),
 .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
 .CLKMODE("SYNC"),.SSROVERCE("DISABLE"),
 .OREGSET_A("RESET"),.OREGSET_B("RESET"),
 .RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),
 .INIT_FILE("NONE"),.FILL_ALL("NONE")
) u_binary_rows_eram (
 .dia({6'd0,I_wr_data}),.dib(8'd0),
 .addra(I_wr_addr),.addrb(I_rd_addr),
 .cea(1'b1),.ceb(I_rd_en),.ocea(1'b0),.oceb(1'b0),
 .clka(I_clk),.clkb(I_clk),
 .wea(I_wr_en),.web(1'b0),.bea(1'b0),.beb(1'b0),
 .rsta(1'b0),.rstb(1'b0),
 .doa(unused_write_output),.dob(read_output),
 .ecc_sbiterr(),.ecc_dbiterr(),
 .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
);
endmodule
