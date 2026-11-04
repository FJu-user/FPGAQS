`timescale 1ns/1ps
// PRESENT confirms admission to the unchanged recognition input. Keep the
// former local-display identity/overlay delay (20+3 clocks) for the status ABI.
module compute_frame_present(
 input wire clk,rst_n,input wire [11:0] active_width,active_height,
 input wire de,vs,output wire frame_present
);
 wire frame_start;
 video_stream_context context_counter(.I_clk(clk),.I_rst_n(rst_n),
  .I_active_width(active_width),.I_active_height(active_height),.I_de(de),.I_vs(vs),
  .O_frame_start(frame_start),.O_x(),.O_y(),.O_frame_end(),.O_line_start(),.O_line_end());
 reg [22:0] present_pipe;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)present_pipe<=23'd0;
  else present_pipe<={present_pipe[21:0],frame_start};
 assign frame_present=present_pipe[22];
endmodule
