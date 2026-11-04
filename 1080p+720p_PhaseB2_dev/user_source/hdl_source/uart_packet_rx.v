`timescale 1ns/1ps
// CRC-gated two-bank queue: one bank drains to DDR while the other receives.
// Full queues drop whole frames; Go-Back-N recovers without overwriting pixels.
module uart_packet_rx #(parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,rst_n,input wire [7:0] byte_data,input wire byte_valid,byte_error,
 output wire packet_valid,input wire packet_release,output reg packet_error,
 output wire [7:0] command,flags,output wire [31:0] session,packet_sequence,
 output wire [15:0] length,output wire [31:0] packet_crc,
 input wire [10:0] rd_addr,output wire [7:0] rd_data
);
 reg [7:0] hdr[0:15];reg [127:0] saved_header[0:1];
 reg [31:0] saved_crc[0:1];reg [1:0] occupied;reg read_bank,write_bank;
 reg [11:0] count;reg in_frame,escaped,bad,have_bank;
 reg [31:0] crc,received_crc,timer;reg [15:0] hcrc;
 reg ram_we,ram_bank;reg [10:0] ram_addr;reg [7:0] ram_data;
 wire [7:0] decoded=escaped ? byte_data^8'h20:byte_data;
 wire [15:0] receiving_length={hdr[13],hdr[12]};
 wire [7:0] data0,data1;
 assign packet_valid=occupied[read_bank];
 assign command=saved_header[read_bank][15:8];
 assign flags=saved_header[read_bank][23:16];
 assign session=saved_header[read_bank][63:32];
 assign packet_sequence=saved_header[read_bank][95:64];
 assign length=saved_header[read_bank][111:96];
 assign packet_crc=saved_crc[read_bank];
 assign rd_data=read_bank ? data1:data0;
 function [31:0] crc32_next;
 input [31:0] c;input [7:0] d;integer i;reg [31:0] v;
 begin v=c^{24'd0,d};for(i=0;i<8;i=i+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc32_next=v;end
 endfunction
 function [15:0] crc16_next;
 input [15:0] c;input [7:0] d;integer i;reg [15:0] v;
 begin v=c^{d,8'd0};for(i=0;i<8;i=i+1) v=v[15]?(v<<1)^16'h1021:v<<1;crc16_next=v;end
 endfunction
 clahe_hist_ram #(.ADDR_WIDTH(11),.DATA_WIDTH(8),.DEPTH(2048)) bank0(
  .I_clk(clk),.I_wr_en(ram_we && !ram_bank),.I_wr_addr(ram_addr),.I_wr_data(ram_data),
  .I_rd_addr(rd_addr),.O_rd_data(data0));
 clahe_hist_ram #(.ADDR_WIDTH(11),.DATA_WIDTH(8),.DEPTH(2048)) bank1(
  .I_clk(clk),.I_wr_en(ram_we && ram_bank),.I_wr_addr(ram_addr),.I_wr_data(ram_data),
  .I_rd_addr(rd_addr),.O_rd_data(data1));
 integer n;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   count<=0;in_frame<=0;escaped<=0;bad<=0;have_bank<=0;
   crc<=32'hffffffff;received_crc<=0;hcrc<=16'hffff;timer<=0;packet_error<=0;
   occupied<=0;read_bank<=0;write_bank<=0;
   ram_we<=0;ram_bank<=0;ram_addr<=0;ram_data<=0;
   saved_header[0]<=0;saved_header[1]<=0;saved_crc[0]<=0;saved_crc[1]<=0;
   for(n=0;n<16;n=n+1) hdr[n]<=0;
  end else begin
   ram_we<=0;packet_error<=0;
   if(packet_release && occupied[read_bank]) begin
    occupied[read_bank]<=0;read_bank<=~read_bank;
   end
   if(byte_error || (in_frame && count!=0 && timer==TIMEOUT_CYCLES-1)) begin
    in_frame<=0;count<=0;escaped<=0;have_bank<=0;packet_error<=1;timer<=0;
   end else if(byte_valid) begin
    timer<=0;
    if(byte_data==8'h7e) begin
     if(in_frame && count!=0) begin
      if(!bad && have_bank && !escaped && count==20+receiving_length && received_crc==~crc) begin
       occupied[write_bank]<=1;saved_crc[write_bank]<=received_crc;
       for(n=0;n<16;n=n+1) saved_header[write_bank][n*8+:8]<=hdr[n];
       write_bank<=~write_bank;
      end else packet_error<=1;
     end
     // Reserve at first non-delimiter byte, after write_bank has advanced.
     in_frame<=1;escaped<=0;bad<=0;have_bank<=0;count<=0;
     crc<=32'hffffffff;received_crc<=0;hcrc<=16'hffff;
    end else if(in_frame && !bad) begin
     if(count==0 && !have_bank) begin
      if(occupied[write_bank]) begin bad<=1;packet_error<=1;end
      else have_bank<=1;
     end
     if(have_bank || (count==0 && !occupied[write_bank])) begin
      if(byte_data==8'h7d && !escaped) escaped<=1;
      else begin
       escaped<=0;
       if(count<16) begin
        hdr[count[3:0]]<=decoded;crc<=crc32_next(crc,decoded);
        if(count<14) hcrc<=crc16_next(hcrc,decoded);
        if(count==15 && ({decoded,hdr[14]}!=hcrc || hdr[0]!=1 || hdr[3]!=0 || receiving_length>1536)) bad<=1;
       end else if(count<16+receiving_length) begin
        ram_we<=1;ram_bank<=write_bank;ram_addr<=count-16;ram_data<=decoded;
        crc<=crc32_next(crc,decoded);
       end else if(count<20+receiving_length) received_crc<={decoded,received_crc[31:8]};
       else bad<=1;
       if(count<1557) count<=count+1;else bad<=1;
      end
     end
    end
   end else if(in_frame && count!=0 && timer<TIMEOUT_CYCLES) timer<=timer+1;
  end
 end
endmodule
