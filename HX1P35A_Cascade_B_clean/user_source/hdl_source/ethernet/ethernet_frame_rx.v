`timescale 1ns/1ps
// Single CRC-gated Ethernet frame slot. The producer cannot overwrite a frame
// until the system-domain consumer releases it. Overflow drops a whole frame.
module ethernet_frame_rx (
 input wire rx_clk,sys_clk,rst_n,
 input wire [7:0] rx_data,input wire rx_valid,rx_error,
 output wire frame_valid,output wire [11:0] frame_length,
 input wire frame_release,input wire [10:0] rd_addr,output wire [7:0] rd_data,
 output reg [31:0] crc_errors,dropped_frames
);
 wire rx_reset_n,sys_reset_n;
 ethernet_reset_sync u_rx_reset_sync(.clk(rx_clk),.async_reset_n(rst_n),.reset_n(rx_reset_n));
 ethernet_reset_sync u_sys_reset_sync(.clk(sys_clk),.async_reset_n(rst_n),.reset_n(sys_reset_n));
 reg [1:0] state;
 reg [3:0] preamble;
 reg [11:0] count,published_length;
 reg [31:0] crc;
 reg bad,publish_toggle,release_toggle;
 (* ASYNC_REG="TRUE" *) reg [1:0] release_sync,publish_sync;
 reg ram_we;reg [10:0] ram_addr;reg [7:0] ram_data;
 wire occupied=publish_toggle!=release_sync[1];
 assign frame_valid=publish_sync[1]!=release_toggle;
 assign frame_length=published_length; // bundled with publish_toggle, held until release
 function [31:0] crc_next(input [31:0] c,input [7:0] d);
  integer k;reg [31:0] v;
  begin v=c^{24'd0,d};for(k=0;k<8;k=k+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_next=v;end
 endfunction
 always @(posedge sys_clk or negedge sys_reset_n)
  if(!sys_reset_n) begin publish_sync<=0;release_toggle<=0;end
  else begin
   publish_sync<={publish_sync[0],publish_toggle};
   if(frame_release && frame_valid) release_toggle<=publish_sync[1];
  end
 always @(posedge rx_clk or negedge rx_reset_n) begin
  if(!rx_reset_n) begin
   state<=0;preamble<=0;count<=0;crc<=32'hffffffff;bad<=0;
   publish_toggle<=0;published_length<=0;release_sync<=0;
   ram_we<=0;ram_addr<=0;ram_data<=0;crc_errors<=0;dropped_frames<=0;
  end else begin
   release_sync<={release_sync[0],release_toggle};ram_we<=0;
   case(state)
    0: if(rx_valid) begin
     if(rx_data==8'h55 && !rx_error) begin preamble<=1;state<=1;end
     else state<=3;
    end
    1: if(!rx_valid) begin state<=0;preamble<=0;end
       else if(rx_error) state<=3;
       else if(rx_data==8'h55 && preamble<7) preamble<=preamble+1'b1;
       else if(rx_data==8'hd5 && preamble==7) begin
        count<=0;crc<=32'hffffffff;bad<=0;
        if(occupied) begin state<=3;dropped_frames<=dropped_frames+1'b1;end
        else state<=2;
       end else state<=3;
    2: if(rx_valid) begin
     crc<=crc_next(crc,rx_data);bad<=bad|rx_error;
     if(count<2048) begin ram_we<=1;ram_addr<=count[10:0];ram_data<=rx_data;end
     else bad<=1;
     if(count<4095) count<=count+1'b1;else bad<=1;
    end else begin
     state<=0;
     if(!bad && count>=64 && count<=1518 && crc==32'hdebb20e3) begin
      published_length<=count;publish_toggle<=~publish_toggle;
     end else begin crc_errors<=crc_errors+1'b1;end
    end
    3: if(!rx_valid) state<=0;
    default: state<=0;
   endcase
  end
 end
 // 2048 x 8 = 16384 bits: explicitly one PH1P35 ERAM, independent clocks.
 PH1P_LOGIC_ERAM #(
  .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
  .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("DP"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
  .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
  .CLKMODE("ASYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")
 ) u_rx_eram (
  .dia(ram_data),.dib(8'd0),.addra(ram_addr),.addrb(rd_addr),
  .clka(rx_clk),.clkb(sys_clk),.cea(1'b1),.ceb(1'b1),.wea(ram_we),.web(1'b0),
  .bea(1'b0),.beb(1'b0),.ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0),
  .doa(),.dob(rd_data),.ecc_sbiterr(),.ecc_dbiterr(),
  .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
 );
endmodule
