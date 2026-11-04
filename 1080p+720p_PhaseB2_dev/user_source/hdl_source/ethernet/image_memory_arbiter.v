`timescale 1ns/1ps
// Whole-upload ownership, not beat-by-beat ownership. Only one transport can
// allocate/use the shared BACK slot. The unchanged DDR service still protects FRONT.
module image_memory_arbiter (
 input wire clk,rst_n,
 input wire [155:0] uart_data,input wire uart_valid,output wire uart_ready,
 output reg uart_error,output reg [383:0] uart_reply,
 input wire [155:0] eth_data,input wire eth_valid,output wire eth_ready,
 output reg eth_error,output reg [383:0] eth_reply,
 output reg [155:0] mem_data,output reg mem_valid,input wire mem_ready,
 input wire mem_error,input wire [383:0] mem_reply,
 output wire [1:0] upload_owner
);
 localparam IDLE=0,SEND=1,ACCEPT=2,WAIT_MEM=3,RETURN=4;
 reg [2:0] state;reg [1:0] owner;reg selected;
 assign upload_owner=owner; // 0:none 1:UART 2:Ethernet
 assign uart_ready=state==IDLE && owner!=2;
 assign eth_ready=state==IDLE && owner!=1;
 wire allocation=mem_data[154:153]==3 && mem_data[7:0]==0;
 wire release_upload=(mem_data[154:153]==2) ||
                      (mem_data[154:153]==3 && mem_data[7:0]==1);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;owner<=0;selected<=0;mem_data<=0;mem_valid<=0;
   uart_error<=0;eth_error<=0;uart_reply<=0;eth_reply<=0;
  end else case(state)
   IDLE: if(uart_valid && uart_ready) begin mem_data<=uart_data;selected<=0;state<=SEND;end
         else if(eth_valid && eth_ready) begin mem_data<=eth_data;selected<=1;state<=SEND;end
   SEND: if(mem_ready) begin mem_valid<=1;state<=ACCEPT;end
   ACCEPT: begin mem_valid<=0;state<=WAIT_MEM;end
   WAIT_MEM: if(mem_ready) begin
    if(selected) begin eth_error<=mem_error;eth_reply<=mem_reply;end
    else begin uart_error<=mem_error;uart_reply<=mem_reply;end
    if(allocation && !mem_error) owner<=selected?2:1;
    if(release_upload && !mem_error) owner<=0;
    state<=RETURN;
   end
   RETURN: state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
