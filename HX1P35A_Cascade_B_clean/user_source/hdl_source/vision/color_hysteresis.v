`timescale 1ns/1ps
// One scanline of hue/distance state, two pixel clocks of latency. A weak
// pixel can inherit a matching core hue only within a bounded path length.
module color_hysteresis #(parameter IMAGE_WIDTH=1280,MAX_DISTANCE=63,USE_ERAM=0,CALIBRATED_WEAK=0)(
input wire clk,rst_n,input wire[23:0] rgb,input wire de,hs,vs,
input wire[11:0] x,y,input wire fs,fe,ls,le,foreground,input wire[2:0] core_color,
input wire[2:0] calibrated_weak_color,
output reg[23:0] out_rgb,output reg out_de,out_hs,out_vs,
output reg[11:0] out_x,out_y,output reg out_fs,out_fe,out_ls,out_le,
output reg[2:0] out_color,output reg out_core
);
wire[8:0] north;
reg[8:0] north_center,north_west,west;
reg[54:0] pixel_s1;
reg[2:0] core_s1,weak_s1;
reg fg_s1,previous_line_valid,north_valid_s1;
wire[23:0] rgb_s1;wire de_s1,hs_s1,vs_s1,fs_s1,fe_s1,ls_s1,le_s1;
wire[11:0] x_s1,y_s1;
assign {rgb_s1,de_s1,hs_s1,vs_s1,x_s1,y_s1,fs_s1,fe_s1,ls_s1,le_s1}=pixel_s1;
wire[7:0] r=rgb[23:16],g=rgb[15:8],b=rgb[7:0];
wire[7:0] max_rg=(r>g)?r:g,min_rg=(r<g)?r:g;
wire[7:0] value=(max_rg>b)?max_rg:b,minimum=(min_rg<b)?min_rg:b;
wire[7:0] chroma=value-minimum;
wire[8:0] margin={1'b0,chroma}>>2;
wire eligible=de&&foreground&&value>=16&&chroma>=8&&chroma>=(value>>4);
wire yellow=eligible&&({1'b0,min_rg}>{1'b0,b}+margin)&&
 ({1'b0,max_rg}-{1'b0,min_rg}<=({1'b0,chroma}>>1)+margin);
reg[2:0] weak_hue;
always @*begin
 weak_hue=0;
 if(yellow)weak_hue=4;
 else if(eligible&&{1'b0,r}>{1'b0,g}+margin&&{1'b0,r}+margin>={1'b0,b})weak_hue=1;
 else if(eligible&&{1'b0,g}>{1'b0,r}+margin&&{1'b0,g}+margin>={1'b0,b})weak_hue=2;
 else if(eligible&&{1'b0,b}>{1'b0,max_rg}+margin)weak_hue=3;
end
wire west_ok=!ls_s1&&!fs_s1&&west[2:0]==weak_s1&&west[8:3]<MAX_DISTANCE;
wire north_ok=north_valid_s1&&north[2:0]==weak_s1&&north[8:3]<MAX_DISTANCE;
wire center_ok=north_valid_s1&&!ls_s1&&north_center[2:0]==weak_s1&&north_center[8:3]<MAX_DISTANCE;
wire nw_ok=north_valid_s1&&!ls_s1&&north_west[2:0]==weak_s1&&north_west[8:3]<MAX_DISTANCE;
wire[5:0] d0=(west_ok)?west[8:3]:6'd63,d1=north_ok?north[8:3]:6'd63;
wire[5:0] d2=center_ok?north_center[8:3]:6'd63,d3=nw_ok?north_west[8:3]:6'd63;
wire[5:0] d01=(d0<d1)?d0:d1,d23=(d2<d3)?d2:d3;
wire[5:0] nearest=(d01<d23)?d01:d23;
wire inherited=weak_s1!=0&&(west_ok||north_ok||center_ok||nw_ok);
wire[2:0] hue=(fg_s1&&de_s1)?((core_s1!=0)?core_s1:inherited?weak_s1:3'd0):3'd0;
wire[8:0] label=(hue==0)?9'd0:(core_s1!=0)?{6'd0,hue}:{nearest+6'd1,hue};
// Same one-clock north read in both implementations. B has free ERAM;
// the physical variant replaces a distributed 1280x9 scanline only.
generate if(USE_ERAM)begin:g_eram
 wire [8:0] north_data;wire [11:0] read_x=x+12'd1;
 reg read_valid;
 always @(posedge clk)if(de)read_valid<=x+1<IMAGE_WIDTH;
 wire [8:0] unused_doa;
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(9),.DATA_WIDTH_B(9),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
 .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),.ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
 .CLKMODE("ASYNC"),.SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) u_scanline(
 .dia(label),.dib(9'd0),.addra(x_s1[10:0]),.addrb(read_x[10:0]),.cea(1'b1),.ceb(de),.ocea(1'b0),.oceb(1'b0),
 .clka(clk),.clkb(clk),.wea(rst_n&&de_s1&&x_s1<IMAGE_WIDTH),.web(1'b0),.bea(1'b0),.beb(1'b0),
 .rsta(1'b0),.rstb(1'b0),.doa(unused_doa),.dob(north_data),.ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
 assign north=read_valid?north_data:9'd0;
end else begin:g_distributed
 reg[8:0] line_state[0:IMAGE_WIDTH-1];reg[8:0] north_q;
 always @(posedge clk)begin
  if(de)begin if(x+1<IMAGE_WIDTH)north_q<=line_state[x+1];else north_q<=0;end
  if(rst_n&&de_s1&&x_s1<IMAGE_WIDTH)line_state[x_s1]<=label;
 end
 assign north=north_q;
end endgenerate
always @(posedge clk)begin
 if(de)begin
  if(ls||fs)begin north_center<=0;north_west<=0;end
  else begin north_center<=north;north_west<=north_center;end
 end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  pixel_s1<=0;core_s1<=0;weak_s1<=0;fg_s1<=0;previous_line_valid<=0;north_valid_s1<=0;west<=0;
  {out_rgb,out_de,out_hs,out_vs,out_x,out_y,out_fs,out_fe,out_ls,out_le}<=0;
  out_color<=0;out_core<=0;
 end else begin
  pixel_s1<={rgb,de,hs,vs,x,y,fs,fe,ls,le};
  core_s1<=core_color;weak_s1<=CALIBRATED_WEAK?calibrated_weak_color:weak_hue;fg_s1<=foreground;
  north_valid_s1<=previous_line_valid&&y!=0&&!fs;
  if(fs)previous_line_valid<=0;
  if(le&&de)previous_line_valid<=1;
  if(de_s1)west<=label;
  {out_rgb,out_de,out_hs,out_vs,out_x,out_y,out_fs,out_fe,out_ls,out_le}<=pixel_s1;
  out_color<=fg_s1&&de_s1?((hue!=0)?hue:3'd5):3'd0;
  out_core<=fg_s1&&de_s1&&core_s1!=0;
 end
end
endmodule
