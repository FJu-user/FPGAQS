`timescale 1ns/1ps
// Poll four records from one frozen B result bank. The camera display never
// waits for this client. No result survives a mode/resolution/path change.
module remote_vision_client #(
 parameter CLOCK_HZ=100000000, POLL_CYCLES=5000000, TIMEOUT_CYCLES=25000000
)(input wire clk,rst_n,path_run,mode1080,input wire [4:0] mode,
 output wire want_tx,output wire [103:0] tx_message,output reg tx_valid,input wire tx_ready,
 input wire rx_valid,input wire [31:0] rx_session,rx_sequence,input wire [191:0] rx_payload,
 output reg [255:0] objects,output reg [3:0] count,output reg overflow,result_valid,
 output reg [31:0] source_id,output reg [31:0] config_epoch);
 localparam GAP=0,SEND=1,ACCEPT=2,DRAIN=3,WAIT_ACK=4;
 reg [2:0] state;reg [7:0] signature;
 reg [31:0] timer,age,wire_epoch,sequence_number,wire_sequence;reg [4:0] wire_mode;
 reg [255:0] staging;reg [31:0] bank_id;reg [3:0] bank_count;reg bank_overflow;
 wire enabled=path_run && mode==17;
 wire [7:0] sig={path_run,mode1080,1'b0,mode};
 wire [1:0] slot=wire_sequence[1:0];
 wire match=rx_valid && rx_session==wire_epoch && rx_sequence==wire_sequence;
 wire [63:0] compact=rx_payload[111:48];
 assign want_tx=state==SEND || state==ACCEPT || state==DRAIN;
 assign tx_message={8'd69,wire_epoch,wire_sequence,27'd0,wire_mode};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=GAP;signature<=0;timer<=0;age<=0;config_epoch<=1;wire_epoch<=0;
   sequence_number<=0;wire_sequence<=0;wire_mode<=0;tx_valid<=0;objects<=0;staging<=0;count<=0;overflow<=0;
   result_valid<=0;source_id<=0;bank_id<=0;bank_count<=0;bank_overflow<=0;end
  else begin
   if(age<CLOCK_HZ*2)age<=age+1'b1;else result_valid<=0;
   case(state)
    GAP:begin tx_valid<=0;
     if(enabled)begin if(timer>=POLL_CYCLES-1)begin
      timer<=0;wire_epoch<=config_epoch;wire_mode<=mode;wire_sequence<={sequence_number[31:2],2'd0};state<=SEND;
     end else timer<=timer+1'b1;end else timer<=0;
    end
    SEND:if(tx_ready)begin tx_valid<=1;state<=ACCEPT;end
    ACCEPT:begin tx_valid<=0;state<=DRAIN;end
    DRAIN:if(tx_ready)begin timer<=0;state<=WAIT_ACK;end
    WAIT_ACK:begin
     if(!enabled || config_epoch!=wire_epoch)begin timer<=0;state<=GAP;end
     else if(match)begin
      if(rx_payload[7:0]!=0 || (slot!=0 && (rx_payload[47:16]!=bank_id || rx_payload[15:8]!={3'd0,bank_overflow,bank_count})))begin
       sequence_number<=sequence_number+4;state<=GAP;timer<=0;
      end else begin
       staging[slot*64+:64]<=compact;
       if(slot==0)begin bank_id<=rx_payload[47:16];bank_count<=rx_payload[11:8];bank_overflow<=rx_payload[12];end
       if(slot==3)begin
        objects<={compact,staging[191:0]};count<=bank_count;overflow<=bank_overflow;
        source_id<=bank_id;result_valid<=bank_id!=source_id || age<CLOCK_HZ*2;
        if(bank_id!=source_id)age<=0;
        sequence_number<=sequence_number+4;state<=GAP;timer<=0;
       end else begin wire_sequence<=wire_sequence+1'b1;state<=SEND;end
      end
     end else if(timer>=TIMEOUT_CYCLES-1)begin sequence_number<=sequence_number+4;timer<=0;state<=GAP;end
     else timer<=timer+1'b1;
    end
    default:state<=GAP;
   endcase
   if(signature!=sig)begin
    signature<=sig;config_epoch<=config_epoch+1'b1;result_valid<=0;age<=0;staging<=0;
    if(state==GAP)timer<=POLL_CYCLES-1;
   end
  end
 end
endmodule
