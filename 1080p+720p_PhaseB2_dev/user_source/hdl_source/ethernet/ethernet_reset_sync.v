`timescale 1ns/1ps
// Common asynchronous assertion; release after two destination clock edges.
// Domains may release at different times, but must share the assertion cause.
module ethernet_reset_sync (
 input wire clk,
 input wire async_reset_n,
 output wire reset_n
);
 (* ASYNC_REG="TRUE" *) reg [1:0] release_pipe;
 always @(posedge clk or negedge async_reset_n)
  if(!async_reset_n) release_pipe <= 2'b00;
  else release_pipe <= {release_pipe[0],1'b1};
 assign reset_n = release_pipe[1];
endmodule

// Private IO reset release, deliberately NOT merged with fabric reset.
// TD SWUG106: preserve on scalar registers prevents equivalent FF merging.
// Active-high output drives HD_ODDR.rst directly (no shared inverter).
// Caller selects the other PLL phase, midway between destination DDR edges.
// Related-clock Q -> IO reset recovery/removal paths MUST remain timed.
module ethernet_io_reset_sync (
 input wire clk,async_reset_n,
 output wire reset
);
 (* ASYNC_REG="TRUE", preserve="true" *) reg io_meta_q;
 (* ASYNC_REG="TRUE", preserve="true" *) reg io_reset_q;
 always @(posedge clk or negedge async_reset_n)
  if(!async_reset_n) begin io_meta_q<=1'b1;io_reset_q<=1'b1;end
  else begin io_meta_q<=1'b0;io_reset_q<=io_meta_q;end
 assign reset=io_reset_q;
endmodule
