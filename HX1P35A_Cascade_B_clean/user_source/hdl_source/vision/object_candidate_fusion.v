`timescale 1ns/1ps
// Rank both independent populations, fuse closed geometry with its contained
// colour evidence, suppress interior highlights, then publish four objects.
module object_candidate_fusion(
input wire clk,rst_n,clear,strobe,last,valid,input wire[2:0] color,shape,
input wire[20:0] area,input wire[11:0] xmin,ymin,xmax,ymax,
output wire out_strobe,out_last,output wire[2:0] out_index,
output wire[75:0] out_record,output wire truncated
);
wire cs,cl,gs,gl,ct,gt,ft;wire[2:0] ci,gi;wire[75:0] cr,gr;
wire [75:0] c_read,g_read;
wire [1:0] c_read_index,g_read_index;
wire fusion_write;wire [75:0] fused_record;
reg [1:0] gc,cc;
top4_select #(.RETAIN_RESULTS(1),.MASK_PEEK(0)) colors(.clk(clk),.rst_n(rst_n),.clear(clear),.strobe(strobe),.last(last),.valid(valid&&color!=0),
.color(color),.shape(shape),.area(area),.xmin(xmin),.ymin(ymin),.xmax(xmax),.ymax(ymax),
.out_strobe(cs),.out_last(cl),.out_index(ci),.out_record(cr),.truncated(ct),
.peek_index(c_read_index),.peek2_index(2'd0),.peek_record(c_read),.peek2_record(),
.patch_valid(1'b0),.patch_index(2'd0),.patch_record(76'd0));
top4_select #(.RETAIN_RESULTS(1),.MASK_PEEK(0)) geometry(.clk(clk),.rst_n(rst_n),.clear(clear),.strobe(strobe),.last(last),.valid(valid&&color==0),
.color(color),.shape(shape),.area(area),.xmin(xmin),.ymin(ymin),.xmax(xmax),.ymax(ymax),
.out_strobe(gs),.out_last(gl),.out_index(gi),.out_record(gr),.truncated(gt),
.peek_index(g_read_index),.peek2_index(2'd0),.peek_record(g_read),.peek2_record(),
.patch_valid(fusion_write),.patch_index(gc),.patch_record(fused_record));
reg[3:0] suppress_c,suppress_g;
reg seen_c,seen_g;reg[2:0] state;reg[3:0] hits;
reg inside_color;reg[22:0] maximum_area;reg[2:0] maximum_color;
reg[22:0] color_votes[0:3];
wire[22:0] updated_vote=color_votes[cw[73:72]-2'd1]+{2'b0,cw[68:48]};
integer vote_index;
reg[2:0] maximum_shape;
reg[22:0] total_color_area;
reg[75:0] gw,cw;reg[2:0] emit_index;
reg confident_outline;
reg [47:0] first_outline_box;
reg [2:0] first_outline_color;
reg have_outline, separated_outlines;
wire separate_outline=have_outline && cw[74:72]!=first_outline_color &&
 (({1'b0,cw[47:36]}>{1'b0,first_outline_box[23:12]}+2) ||
  ({1'b0,first_outline_box[47:36]}>{1'b0,cw[23:12]}+2) ||
  ({1'b0,cw[35:24]}>{1'b0,first_outline_box[11:0]}+2) ||
  ({1'b0,first_outline_box[35:24]}>{1'b0,cw[11:0]}+2));
wire[14:0] cw_width={3'b0,cw[23:12]}-{3'b0,cw[47:36]}+15'd1;
wire[14:0] cw_height={3'b0,cw[11:0]}-{3'b0,cw[35:24]}+15'd1;
wire[14:0] gw_width={3'b0,gw[23:12]}-{3'b0,gw[47:36]}+15'd1;
wire[14:0] gw_height={3'b0,gw[11:0]}-{3'b0,gw[35:24]}+15'd1;
wire same_outline=({1'b0,cw[47:36]}+2>={1'b0,gw[47:36]}) &&
    ({1'b0,gw[47:36]}+2>={1'b0,cw[47:36]}) &&
    ({1'b0,cw[35:24]}+2>={1'b0,gw[35:24]}) &&
    ({1'b0,gw[35:24]}+2>={1'b0,cw[35:24]}) &&
    ({1'b0,cw[23:12]}+2>={1'b0,gw[23:12]}) &&
    ({1'b0,gw[23:12]}+2>={1'b0,cw[23:12]}) &&
    ({1'b0,cw[11:0]}+2>={1'b0,gw[11:0]}) &&
    ({1'b0,gw[11:0]}+2>={1'b0,cw[11:0]});
// A clipped weak-colour mask can lack a shape while its independently closed
// foreground has one. Permit bounded recovery only with >=3/4 extent on BOTH
// axes. A much larger neutral background must not replace the colour box.
wire recover_outline=cw[71:69]==0 && gw[71:69]!=0 &&
    (cw_width<<2)>=(gw_width<<1)+gw_width &&
    (cw_height<<2)>=(gw_height<<1)+gw_height;
wire outline_supported=!recover_outline && (cw[71:69]!=0 || !same_outline) &&
    (cw_width<<3)>=(gw_width<<1)+gw_width &&
    (cw_height<<3)>=(gw_height<<1)+gw_height;
assign c_read_index=(state==6)?emit_index[1:0]:cc;
assign g_read_index=(state==6)?emit_index[1:0]:gc;

wire single_hit=hits!=0 && ((hits&(hits-4'd1))==0);
// A confirmed coloured outline can sit inside a larger shadow of a different
// shape. Retain it when it has substantial extent in both axes; tiny colour
// patches still use the independent geometric outline.
wire keep_color_bounds=(single_hit && confident_outline) || separated_outlines;
// Colour evidence must cover a substantial part of the solid geometry before
// it can replace the colour candidates. Otherwise preserve their own boxes;
// the independent geometry can still be published with a white outline.
wire coverage_supported=total_color_area >=
    ({2'b0,gw[68:48]} >> 2);
assign fusion_write=state==5 && gw[75] && hits!=0 && !keep_color_bounds && coverage_supported;
wire color_credible=(maximum_area>=total_color_area-(total_color_area>>2)) &&
    (total_color_area>={2'b0,(gw[68:48]>>3)});
assign fused_record={gw[75],color_credible?maximum_color:3'd0,gw[71:0]};
function contains;
input[75:0] a,b;
begin contains=a[75]&&b[75]&&
 ({1'b0,a[47:36]}<={1'b0,b[47:36]}+2)&&({1'b0,a[35:24]}<={1'b0,b[35:24]}+2)&&
 ({1'b0,a[23:12]}+2>={1'b0,b[23:12]})&&({1'b0,a[11:0]}+2>={1'b0,b[11:0]});end
endfunction
wire final_strobe=state==6;
wire[75:0] final_record=(emit_index<4)?
 (suppress_c[emit_index[1:0]]?76'd0:c_read):
 (suppress_g[emit_index[1:0]]?76'd0:g_read);
top4_select #(.PREFER_COLOR(1)) final_rank(.clk(clk),.rst_n(rst_n),.clear(clear),
.strobe(final_strobe),.last(emit_index==7),.valid(final_record[75]),
.color(final_record[74:72]),.shape(final_record[71:69]),.area(final_record[68:48]),
.xmin(final_record[47:36]),.ymin(final_record[35:24]),.xmax(final_record[23:12]),.ymax(final_record[11:0]),
.out_strobe(out_strobe),.out_last(out_last),.out_index(out_index),.out_record(out_record),.truncated(ft));
assign truncated=ct|gt|ft;
always @(posedge clk or negedge rst_n)begin
if(!rst_n)begin
 for(vote_index=0;vote_index<4;vote_index=vote_index+1)color_votes[vote_index]<=0;
end else if(clear||state==1)begin
 for(vote_index=0;vote_index<4;vote_index=vote_index+1)color_votes[vote_index]<=0;
end else if(state==3 && !suppress_c[cc] && contains(gw,cw))
 color_votes[cw[73:72]-2'd1]<=updated_vote;
end
always @(posedge clk or negedge rst_n)begin
if(!rst_n)begin state<=0;seen_c<=0;seen_g<=0;gc<=0;cc<=0;hits<=0;inside_color<=0;maximum_area<=0;maximum_color<=0;maximum_shape<=0;total_color_area<=0;suppress_c<=0;suppress_g<=0;gw<=0;cw<=0;emit_index<=0;confident_outline<=0;first_outline_box<=0;first_outline_color<=0;have_outline<=0;separated_outlines<=0;end
else if(clear)begin state<=0;seen_c<=0;seen_g<=0;suppress_c<=0;suppress_g<=0;end
else begin
if(cs&&cl)seen_c<=1;if(gs&&gl)seen_g<=1;
case(state)
0:if(seen_c&&seen_g)begin state<=7;gc<=0;cc<=0;seen_c<=0;seen_g<=0;end
// Eliminate identical same-colour records before considering neutral fusion.
// Different hues and spatially distinct silhouettes remain independent.
7:begin
 // colors.top4_select has no patch writer and rejects every live
 // duplicate on insertion (same color and bbox). Thus this condition
 // was unreachable. Retain all 16 scan cycles, removing only its second
 // wide read port/comparator; output publication latency is unchanged.
 if(cc==3)begin
  cc<=0;
  if(gc==3)begin gc<=0;state<=1;end else gc<=gc+1'b1;
 end else cc<=cc+1'b1;
end
1:begin gw<=g_read;cc<=0;hits<=0;inside_color<=0;maximum_area<=0;maximum_color<=0;maximum_shape<=0;total_color_area<=0;confident_outline<=0;have_outline<=0;separated_outlines<=0;state<=2;end
2:begin cw<=c_read;state<=3;end
3:begin
 if(!suppress_c[cc] && contains(gw,cw))begin
  hits[cc]<=1;
  begin
   if(!have_outline)begin first_outline_box<=cw[47:0];first_outline_color<=cw[74:72];end
   have_outline<=1;
   if(separate_outline)separated_outlines<=1;
  end
  if(outline_supported)confident_outline<=1;
  total_color_area<=total_color_area+cw[68:48];
  // Vote by hue, not by fragment: highlight/shadow splits of one red object
  // must combine their red evidence before the independent colour decision.
  if(updated_vote>maximum_area)begin maximum_area<=updated_vote;maximum_color<=cw[74:72];maximum_shape<=cw[71:69];end
 end
 if(contains(cw,gw))inside_color<=1;
 if(cc==3)state<=5;else begin cc<=cc+1'b1;state<=2;end
end
5:begin
 if(gw[75])begin
  if(keep_color_bounds)suppress_g[gc]<=1;
  else if(hits!=0 && coverage_supported)suppress_c<=suppress_c|hits;
  else if(inside_color)suppress_g[gc]<=1;
 end
 if(gc==3)begin state<=6;emit_index<=0;end
 else begin gc<=gc+1'b1;state<=1;end
end
6:if(emit_index==7)state<=0;else emit_index<=emit_index+1'b1;
default:state<=0;
endcase
end
end
endmodule
