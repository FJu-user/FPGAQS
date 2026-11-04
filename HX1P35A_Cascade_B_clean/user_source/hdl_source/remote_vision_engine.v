`timescale 1ns/1ps
module remote_vision_engine #(
 parameter integer P_SERVO_USB_DIAG=0
)(
 input wire clk,rst_n,enable,input wire [4:0] mode,input wire [31:0] control_epoch,
 input wire [23:0] rgb,input wire de,hs,vs,preview_source,
 input wire [31:0] image_id,generation,
 output wire [255:0] objects,output wire [3:0] count,output wire overflow,valid,
 output wire [31:0] source_id,result_epoch,
 output wire [95:0] diagnostic);
 wire [95:0] old_diagnostic;
 wire [255:0] old_objects,road_objects;wire [3:0] old_count;
 wire old_overflow,old_valid,road_valid;wire [31:0] old_id,old_epoch,road_id,road_epoch;
 mode17_vision_engine #(.P_SERVO_USB_DIAG(P_SERVO_USB_DIAG)) original(.clk(clk),.rst_n(rst_n),.enable(enable && mode==17),.control_epoch(control_epoch),
 .rgb(rgb),.de(de),.hs(hs),.vs(vs),.preview_source(preview_source),.image_id(image_id),.generation(generation),
 .objects(old_objects),.count(old_count),.overflow(old_overflow),.valid(old_valid),.source_id(old_id),.result_epoch(old_epoch),.diagnostic(old_diagnostic));
 road_planner road(.clk(clk),.rst_n(rst_n),.enable(enable && mode==18),.control_epoch(control_epoch),
 .rgb(rgb),.de(de),.vs(vs),.preview_source(preview_source),.image_id(image_id),.generation(generation),
 .objects(road_objects),.valid(road_valid),.source_id(road_id),.result_epoch(road_epoch));
 wire [255:0] road_wire;
 genvar ri;
 generate for(ri=0;ri<4;ri=ri+1)begin:g_route_transport
  wire [59:0] p=road_objects[ri*60+:60];
  assign road_wire[ri*64+:64]={p[59:53],1'b0,p[52:42],1'b0,p[41:31],1'b0,p[30:20],1'b0,p[19:0]};
 end endgenerate
 assign diagnostic=mode==18?96'd0:old_diagnostic;
 assign objects=mode==18?road_wire:old_objects;
 assign count=mode==18?4'd0:old_count;
 assign overflow=mode==18?1'b0:old_overflow;
 assign valid=mode==18?road_valid:old_valid;
 assign source_id=mode==18?road_id:old_id;
 assign result_epoch=mode==18?road_epoch:old_epoch;
endmodule
