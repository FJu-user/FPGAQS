`timescale 1ns/1ps
// Maintained SW2 level: high requests the peer IMAGE preview, low restores
// the legacy KEY1/UART/Ethernet source intent. No edge-triggered toggling.
module cascade_view_switch #(parameter DEBOUNCE_BITS=21)(
 input wire clk,rst_n,sw2,
 output reg view_image
);
 (* ASYNC_REG="TRUE" *) reg [1:0] sw_sync;
 reg [DEBOUNCE_BITS-1:0] stable_count;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin sw_sync<=0;stable_count<=0;view_image<=0;end
  else begin
   sw_sync<={sw_sync[0],sw2};
   if(sw_sync[1]==view_image)stable_count<=0;
   else if(&stable_count)begin view_image<=sw_sync[1];stable_count<=0;end
   else stable_count<=stable_count+1'b1;
  end
 end
endmodule
