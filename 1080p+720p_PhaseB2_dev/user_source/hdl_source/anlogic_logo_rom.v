// Lossless block deduplication of the original 25-bit Anlogic logo.
// RGB888 and transparency are exact. Three synchronous ROM clocks;
// the caller absorbs its old address register, preserving the three OSD stages.
module anlogic_logo_rom(input wire I_clk,input wire [14:0] I_addr,output reg [24:0] O_pixel);
 wire [8:0] packed_block;
 reg [4:0] pixel_offset;
 always @(posedge I_clk)pixel_offset<=I_addr[4:0];
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(9),.DATA_WIDTH_B(9),
  .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),.DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
  .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.CLKMODE("ASYNC"),
  .INIT_FILE("anlogic_logo_block_map.dath"),.FILL_ALL("000000000"),.IMPLEMENT("20K(FAST)")) u_block_map(
  .dia(9'd0),.dib(9'd0),.addra(I_addr[14:5]),.addrb(10'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),
  .bea(1'b0),.beb(1'b0),.ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),
  .doa(packed_block),.dob(),.ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 wire [13:0] packed_addr={packed_block,pixel_offset};
 wire [9:0] bank_data[0:4];
 reg [2:0] bank_select;
 always @(posedge I_clk) bank_select<=packed_addr[13:11];
 wire [9:0] palette_index=bank_data[bank_select];
 reg [24:0] palette_mem[0:579] /* synthesis rom_style=bram */;
 initial $readmemh("anlogic_logo_palette.hex",palette_mem);
 always @(posedge I_clk) O_pixel<=palette_mem[palette_index];
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(10),.DATA_WIDTH_B(10),
  .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .CLKMODE("ASYNC"),.INIT_FILE("anlogic_logo_index_0.dath"),.FILL_ALL("0000000000"),.IMPLEMENT("20K(FAST)")) u_index_0(
  .dia(10'd0),.dib(10'd0),.addra(packed_addr[10:0]),.addrb(11'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),
  .ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bank_data[0]),.dob(),
  .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(10),.DATA_WIDTH_B(10),
  .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .CLKMODE("ASYNC"),.INIT_FILE("anlogic_logo_index_1.dath"),.FILL_ALL("0000000000"),.IMPLEMENT("20K(FAST)")) u_index_1(
  .dia(10'd0),.dib(10'd0),.addra(packed_addr[10:0]),.addrb(11'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),
  .ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bank_data[1]),.dob(),
  .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(10),.DATA_WIDTH_B(10),
  .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .CLKMODE("ASYNC"),.INIT_FILE("anlogic_logo_index_2.dath"),.FILL_ALL("0000000000"),.IMPLEMENT("20K(FAST)")) u_index_2(
  .dia(10'd0),.dib(10'd0),.addra(packed_addr[10:0]),.addrb(11'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),
  .ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bank_data[2]),.dob(),
  .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(10),.DATA_WIDTH_B(10),
  .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .CLKMODE("ASYNC"),.INIT_FILE("anlogic_logo_index_3.dath"),.FILL_ALL("0000000000"),.IMPLEMENT("20K(FAST)")) u_index_3(
  .dia(10'd0),.dib(10'd0),.addra(packed_addr[10:0]),.addrb(11'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),
  .ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bank_data[3]),.dob(),
  .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(10),.DATA_WIDTH_B(10),
  .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),.DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
  .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .CLKMODE("ASYNC"),.INIT_FILE("anlogic_logo_index_4.dath"),.FILL_ALL("0000000000"),.IMPLEMENT("20K(FAST)")) u_index_4(
  .dia(10'd0),.dib(10'd0),.addra(packed_addr[10:0]),.addrb(11'd0),
  .clka(I_clk),.clkb(I_clk),.cea(1'b1),.ceb(1'b0),.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),
  .ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(bank_data[4]),.dob(),
  .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
endmodule
