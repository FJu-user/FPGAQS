`timescale 1ns/1ps
// Refine four ranked silhouettes using eight support points on the 320x180
// source grid. One shared pair of small multipliers serves all cross products,
// polygon areas and edge lengths. No image memory or clock domain is added.
// ready is sampled by top4_select, with one register-flight bubble there.
module shape_geometry #(parameter IMAGE_WIDTH=1280,IMAGE_HEIGHT=720)(
 input wire clk,rst_n,clear,strobe,last,input wire [2:0] index,
 input wire [75:0] record_in,input wire [143:0] geometry,
 output wire ready,output reg out_strobe,out_last,output reg[2:0] out_index,
 output reg [75:0] record_out
);
 localparam IDLE=0,SCAN=1,TURN_MUL=2,TURN_CROSS=3,LIMIT_MUL=4,
  TURN_TEST=5,NEXT=6,EDGE=7,AREA_MUL=8,AREA_ACC=9,LENGTH_MUL=10,
  LENGTH_ACC=11,EDGE_NEXT=12,PUBLISH=13,BOX_MUL=14,BOX_ACC=15;
 reg[3:0] state;
 reg[17:0] points[0:7];reg[7:0] live;
 reg[2:0] previous_link[0:7],next_link[0:7];
 reg[3:0] population;reg[2:0] cursor,pass,vertex;
 reg changed,saved_last;reg[2:0]saved_index;reg[75:0]saved_record;
 reg[5:0] epsilon,short_limit;
 reg signed[10:0] ax,ay,bx,by;
 reg signed[21:0] product_a,product_b;
 reg[21:0] turn_abs;
 reg[10:0] short_a,short_b;
 reg signed[21:0] twice_area;
 reg[21:0] support_twice;
 reg measuring_support;
 reg[21:0] min_length,max_length;
 reg[22:0] opposite_even,opposite_odd;
 reg[17:0] quad[0:3];
 assign ready=state==IDLE;
 wire[2:0] previous_id=previous_link[cursor],next_id=next_link[cursor];
 wire[17:0] p=points[previous_id],q=points[cursor],r=points[next_id];
 wire signed[10:0] dx=$signed({2'd0,r[8:0]})-$signed({2'd0,p[8:0]});
 wire signed[10:0] dy=$signed({2'd0,r[17:9]})-$signed({2'd0,p[17:9]});
 wire signed[10:0] qx=$signed({2'd0,q[8:0]})-$signed({2'd0,p[8:0]});
 wire signed[10:0] qy=$signed({2'd0,q[17:9]})-$signed({2'd0,p[17:9]});
 function[10:0] absolute;input signed[10:0]v;begin absolute=v<0?-v:v;end endfunction
 wire[10:0] chord=absolute(dx)+absolute(dy);
 wire signed[10:0] rx=$signed({2'd0,r[8:0]})-$signed({2'd0,q[8:0]});
 wire signed[10:0] ry=$signed({2'd0,r[17:9]})-$signed({2'd0,q[17:9]});
 wire signed[22:0] cross_value=$signed(product_a)-$signed(product_b);
 wire remove_point=population>3 &&
  (short_a<=short_limit || short_b<=short_limit || turn_abs<=$unsigned(product_a));
 wire[12:0] source_width=({1'b0,record_in[23:12]}-{1'b0,record_in[47:36]}+13'd1)>>2;
 wire[12:0] source_height=({1'b0,record_in[11:0]}-{1'b0,record_in[35:24]}+13'd1)>>2;
 wire[13:0] extent=source_width+source_height;
 wire[21:0] polygon_twice=twice_area<0?-twice_area:twice_area;
 wire[25:0] polygon_pixels={4'd0,polygon_twice}<<3;
 wire[25:0] object_pixels={5'd0,saved_record[68:48]};
 wire[12:0] saved_width={1'b0,saved_record[23:12]}-{1'b0,saved_record[47:36]}+13'd1;
 wire[12:0] saved_height={1'b0,saved_record[11:0]}-{1'b0,saved_record[35:24]}+13'd1;
 // Support points describe sample centres, whereas area/bounds include each
 // 4x4 source cell. Bound that rasterization difference by a one-cell band.
 wire[25:0] boundary_band=({13'd0,saved_width}+{13'd0,saved_height})<<2;
 wire[25:0] covered_polygon=polygon_pixels+boundary_band;
 // A few highlight holes may remove colour samples from an otherwise closed
 // card. A polygon must still explain at least 75% of its enclosed area.
 // Simplification must retain the original support hull. A concave cross
 // can otherwise lose its arms and become a plausible inner rectangle.
 wire[25:0] support_pixels={4'd0,support_twice}<<3;
 wire preserves_hull=({3'd0,covered_polygon}<<3)>=
  (({3'd0,support_pixels}<<3)-{3'd0,support_pixels});
 wire credible=preserves_hull && polygon_pixels!=0 &&
  (({2'd0,polygon_pixels}<<1)+{2'd0,polygon_pixels}<=({2'd0,object_pixels}<<2)) &&
  (({3'd0,covered_polygon}<<2)>=(({3'd0,object_pixels}<<1)+{3'd0,object_pixels}));
 // Acute tips lose more area than quadrilaterals on the 4x4 sample grid.
 // Keep >=75% of the support hull for triangles, plus the same cell band.
 wire preserves_triangle=({2'd0,covered_polygon}<<2)>=
  (({2'd0,support_pixels}<<1)+{2'd0,support_pixels});
 wire triangle_credible=preserves_triangle && polygon_pixels!=0 &&
  (({2'd0,polygon_pixels}<<1)+{2'd0,polygon_pixels}<=({2'd0,object_pixels}<<2)) &&
  (({3'd0,covered_polygon}<<3)>=(({3'd0,object_pixels}<<2)+{3'd0,object_pixels}));
 reg[21:0] box_area;
 wire[21:0] center_box=box_area-({9'd0,saved_width}<<2)-({9'd0,saved_height}<<2)+22'd16;
 wire near_round=(saved_width<=saved_height+(saved_height>>2)) &&
  (saved_height<=saved_width+(saved_width>>2));
 wire round_outline=population>=5 && near_round &&
  ({5'd0,polygon_pixels}<<5)>=(({5'd0,center_box}<<4)+({5'd0,center_box}<<1)+{5'd0,center_box}) &&
  ({3'd0,polygon_pixels}<<3)<=(({3'd0,center_box}<<3)-({3'd0,center_box}>>1));
 wire signed[10:0] mid_x=$signed({2'd0,quad[0][8:0]})+$signed({2'd0,quad[2][8:0]})-
  $signed({2'd0,quad[1][8:0]})-$signed({2'd0,quad[3][8:0]});
 wire signed[10:0] mid_y=$signed({2'd0,quad[0][17:9]})+$signed({2'd0,quad[2][17:9]})-
  $signed({2'd0,quad[1][17:9]})-$signed({2'd0,quad[3][17:9]});
 wire parallelogram=absolute(mid_x)+absolute(mid_y)<={3'd0,short_limit,1'b0};
 wire[22:0] short_pair=opposite_even<opposite_odd?opposite_even:opposite_odd;
 wire[22:0] long_pair=opposite_even>opposite_odd?opposite_even:opposite_odd;
 // Opposite-edge pairs tolerate one shortened segmented corner. Comparing
 // the shortest single edge made an otherwise square card look rectangular.
 // The squared-length ratio is 13/20; use shifts and additions, no divider.
 wire square_edges=(({5'd0,short_pair}<<4)+({5'd0,short_pair}<<2))>=
  (({5'd0,long_pair}<<3)+({5'd0,long_pair}<<2)+{5'd0,long_pair});
 // A region cut by the image edge has no closed polygon. Keep the previous
 // classifier's edge/circle policy, but do not invent a new polygon there.
 wire closed_outline=saved_record[47:36]!=0 && saved_record[35:24]!=0 &&
  saved_record[23:12]<IMAGE_WIDTH-1 && saved_record[11:0]<IMAGE_HEIGHT-1;
 always @(posedge clk)begin
  product_a<=ax*ay;product_b<=bx*by;
 end
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;out_strobe<=0;out_last<=0;out_index<=0;record_out<=0;end
  else if(clear)begin state<=IDLE;out_strobe<=0;out_last<=0;end
  else begin
   out_strobe<=0;out_last<=0;
   case(state)
    IDLE:if(strobe)begin
     saved_record<=record_in;saved_last<=last;saved_index<=index;
     for(i=0;i<8;i=i+1)begin
      points[i]<=geometry[i*18+:18];previous_link[i]<=(i+7)%8;next_link[i]<=(i+1)%8;
     end
     live<=8'hff;population<=8;cursor<=0;pass<=0;changed<=0;
     epsilon<=extent>>5;short_limit<=extent>>3;
     ax<=source_width;ay<=source_height;bx<=0;by<=0;
     if(record_in[75] && record_in[68:48]>=1024)state<=BOX_MUL;else state<=PUBLISH;
    end
    BOX_MUL:state<=BOX_ACC;
    BOX_ACC:begin
     box_area<=product_a<<4;twice_area<=0;vertex<=0;measuring_support<=1;state<=EDGE;
    end
    SCAN:if(live[cursor])begin
     ax<=dx;ay<=qy;bx<=dy;by<=qx;
     short_a<=absolute(qx)+absolute(qy);short_b<=absolute(rx)+absolute(ry);
     state<=TURN_MUL;
    end else state<=NEXT;
    TURN_MUL:state<=TURN_CROSS;
    TURN_CROSS:begin
     turn_abs<=cross_value<0?-cross_value:cross_value;
     ax<=$signed({5'd0,epsilon});ay<=$signed(chord);bx<=0;by<=0;state<=LIMIT_MUL;
    end
    LIMIT_MUL:state<=TURN_TEST;
    TURN_TEST:begin
     if(remove_point)begin
      live[cursor]<=0;population<=population-1'b1;changed<=1;
      previous_link[next_id]<=previous_id;next_link[previous_id]<=next_id;
     end
     state<=NEXT;
    end
    NEXT:if(cursor==7)begin
     cursor<=0;
     if(changed && pass<7 && population>3)begin changed<=0;pass<=pass+1'b1;state<=SCAN;end
     else begin twice_area<=0;min_length<=22'h3fffff;max_length<=0;opposite_even<=0;opposite_odd<=0;vertex<=0;state<=EDGE;end
    end else begin cursor<=cursor+1'b1;state<=SCAN;end
    EDGE:if(live[cursor])begin
     ax<=$signed({2'd0,q[8:0]});ay<=$signed({2'd0,r[17:9]});
     bx<=$signed({2'd0,q[17:9]});by<=$signed({2'd0,r[8:0]});state<=AREA_MUL;
    end else state<=EDGE_NEXT;
    AREA_MUL:state<=AREA_ACC;
    AREA_ACC:begin
     twice_area<=twice_area+cross_value;
     if(vertex<4)quad[vertex[1:0]]<=q;vertex<=vertex+1'b1;
     ax<=rx;ay<=rx;bx<=ry;by<=ry;state<=measuring_support?EDGE_NEXT:LENGTH_MUL;
    end
    LENGTH_MUL:state<=LENGTH_ACC;
    LENGTH_ACC:begin
     if(vertex[0])opposite_even<=opposite_even+$unsigned(product_a+product_b);
     else opposite_odd<=opposite_odd+$unsigned(product_a+product_b);
     if($unsigned(product_a+product_b)<min_length)min_length<=product_a+product_b;
     if($unsigned(product_a+product_b)>max_length)max_length<=product_a+product_b;
     state<=EDGE_NEXT;
    end
    EDGE_NEXT:if(cursor==7)begin
     if(measuring_support)begin
      support_twice<=twice_area<0?-twice_area:twice_area;
      measuring_support<=0;cursor<=0;state<=SCAN;
     end else state<=PUBLISH;
    end else begin cursor<=cursor+1'b1;state<=EDGE;end
    PUBLISH:begin
     record_out<=saved_record;out_strobe<=1;out_last<=saved_last;out_index<=saved_index;
     if(saved_record[75] && saved_record[68:48]>=1024 && closed_outline)begin
      // A legacy profile is a ranking hint, not a substitute for a closed,
      // consistent silhouette. Do not retain its label after rejection.
      record_out[71:69]<=3'd0;
      if(population==3 && triangle_credible)record_out[71:69]<=3'd2;
      else if(population==4 && parallelogram && credible)record_out[71:69]<=square_edges?3'd4:3'd3;
      // A glare-truncated apex leaves one short fourth side. Parallel-sided
      // rectangles stay in the branch above; rounded outlines keep >=6 points.
      else if(population==4 && !parallelogram && triangle_credible &&
       ({2'd0,min_length}<<2)<=max_length &&
       ({3'd0,object_pixels}<<3)<=(({3'd0,box_area}<<2)+({3'd0,box_area}<<1)))
       record_out[71:69]<=3'd2;
     end
     if(saved_record[75] && saved_record[68:48]>=1024 && closed_outline && credible && round_outline)record_out[71:69]<=3'd1;
     state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
