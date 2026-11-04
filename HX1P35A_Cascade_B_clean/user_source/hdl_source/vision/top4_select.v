`timescale 1ns/1ps
// Four ranked records held directly in four register slots. Moving complete
// records removes the old payload-slot indirection and its replicated RAM
// read muxes. Default streaming behaviour is cycle/bit equivalent.
module top4_select #(parameter GEOMETRY=0, PREFER_COLOR=0, PREFER_CLOSED=0, IMAGE_WIDTH=1280, IMAGE_HEIGHT=720, RETAIN_RESULTS=0, MASK_PEEK=1, MERGE_FRAGMENTS=0)(
 input wire clk,rst_n,clear,strobe,last,valid,
 input wire [2:0] color,shape,input wire [20:0] area,
 input wire [11:0] xmin,ymin,xmax,ymax,
 output reg out_strobe,out_last,output reg [2:0] out_index,
 output reg [75:0] out_record,output reg truncated,
 input wire [143:0] geometry,
 input wire emit_ready,output reg [143:0] out_geometry,
 input wire [1:0] peek_index,peek2_index,
 output wire [75:0] peek_record,peek2_record,
 input wire patch_valid,input wire [1:0] patch_index,input wire [75:0] patch_record
);
 // Fusion qualifies every internal peek use with bit 75. Its unused payload
 // need not be zeroed when invalid; remove that wide masking fanout there.
 // The default preserves the public masked-peek contract and exact cycles.
 localparam PAYLOAD=75+(GEOMETRY?2:0);
 reg [PAYLOAD-1:0] d0,d1,d2,d3;reg [3:0] live;
 wire [75:0] best[0:3];
 assign best[0]={live[0],d0[74:0]};assign best[1]={live[1],d1[74:0]};
 assign best[2]={live[2],d2[74:0]};assign best[3]={live[3],d3[74:0]};
 assign peek_record=MASK_PEEK?(live[peek_index]?best[peek_index]:76'd0):best[peek_index];
 assign peek2_record=MASK_PEEK?(live[peek2_index]?best[peek2_index]:76'd0):best[peek2_index];
 wire [75:0] incoming={valid,color,shape,area,xmin,ymin,xmax,ymax};
 wire [PAYLOAD-1:0] incoming_payload={(d3>>75),incoming[74:0]};
 wire [PAYLOAD-1:0] payloads[0:3];
 assign payloads[0]=d0;assign payloads[1]=d1;assign payloads[2]=d2;assign payloads[3]=d3;
 function [143:0] union_geometry;
  input [143:0] a,b;
  reg [17:0] ap,bp;reg signed[10:0] av,bv;integer j;
  begin
   union_geometry=a;
   for(j=0;j<8;j=j+1)begin
    ap=a[j*18+:18];bp=b[j*18+:18];av=0;bv=0;
    case(j)
     0:begin av=-$signed({2'b0,ap[17:9]});bv=-$signed({2'b0,bp[17:9]});end
     1:begin av=$signed({2'b0,ap[8:0]})-$signed({2'b0,ap[17:9]});bv=$signed({2'b0,bp[8:0]})-$signed({2'b0,bp[17:9]});end
     2:begin av=$signed({2'b0,ap[8:0]});bv=$signed({2'b0,bp[8:0]});end
     3:begin av=$signed({2'b0,ap[8:0]})+$signed({2'b0,ap[17:9]});bv=$signed({2'b0,bp[8:0]})+$signed({2'b0,bp[17:9]});end
     4:begin av=$signed({2'b0,ap[17:9]});bv=$signed({2'b0,bp[17:9]});end
     5:begin av=$signed({2'b0,ap[17:9]})-$signed({2'b0,ap[8:0]});bv=$signed({2'b0,bp[17:9]})-$signed({2'b0,bp[8:0]});end
     6:begin av=-$signed({2'b0,ap[8:0]});bv=-$signed({2'b0,bp[8:0]});end
     7:begin av=-$signed({2'b0,ap[8:0]})-$signed({2'b0,ap[17:9]});bv=-$signed({2'b0,bp[8:0]})-$signed({2'b0,bp[17:9]});end
    endcase
    if(bv>av)union_geometry[j*18+:18]=bp;
   end
  end
 endfunction
 wire [143:0] duplicate_geometry;
 wire [1:0] duplicate_tag=GEOMETRY?(payloads[duplicate_slot]>>75):2'd0;
 wire [1:0] output_tag=GEOMETRY?(payloads[idx]>>75):2'd0;
 wire [1:0] new_tag=GEOMETRY?(d3>>75):2'd0;
 wire [143:0] output_geometry;
 generate if(GEOMETRY)begin:g_geometry_table
  reg [143:0] table_data[0:3];
  wire [1:0] read_tag=emitting?output_tag:duplicate_tag;
  wire [143:0] read_geometry=table_data[read_tag];
  assign duplicate_geometry=read_geometry;
  assign output_geometry=read_geometry;
  always @(posedge clk)if(rst_n&&!clear&&strobe&&!emitting&&valid)begin
   if(duplicate_found && MERGE_FRAGMENTS && !same_bounds)table_data[duplicate_tag]<=union_geometry(read_geometry,geometry);
   else if(insert0||insert1||insert2||insert3)table_data[new_tag]<=geometry;
  end
 end else begin:g_no_geometry_table
  assign duplicate_geometry=144'd0;assign output_geometry=144'd0;
 end endgenerate
 wire [PAYLOAD-1:0] merged_payload={duplicate_tag,merged_record};
 reg emitting;reg [1:0] idx;reg duplicate_found;reg [1:0] duplicate_slot;
 integer k;
 // Preserve legacy classified targets, including spheres at the image edge.
 // Prefer closed silhouettes over unclassified clipped background regions.
 function closed;
  input [75:0] a;
  begin closed=a[71:69]!=0 || (a[47:36]!=0 && a[35:24]!=0 && a[23:12]<IMAGE_WIDTH-1 && a[11:0]<IMAGE_HEIGHT-1);end
 endfunction
 function better;
  input [75:0] a,b;
  begin better=a[75] && (!b[75] ||
   (PREFER_COLOR && a[74:72]!=0 && b[74:72]==0) ||
   ((!PREFER_COLOR || (a[74:72]!=0)==(b[74:72]!=0)) &&
    ((PREFER_CLOSED && closed(a) && !closed(b)) ||
     ((!PREFER_CLOSED || closed(a)==closed(b)) &&
      (a[68:48]>b[68:48] || (a[68:48]==b[68:48] &&
       (a[47:36]<b[47:36] || (a[47:36]==b[47:36] && a[35:24]<b[35:24]))))))));end
 endfunction
 always @*begin
  duplicate_found=0;duplicate_slot=0;
  for(k=0;k<4;k=k+1)if(live[k] && best[k][74:72]==color &&
   ((best[k][47:36]==xmin && best[k][35:24]==ymin && best[k][23:0]=={xmax,ymax}) ||
    (MERGE_FRAGMENTS && color!=0 &&
     xmin<=best[k][23:12] && xmax>=best[k][47:36] && ymin<=best[k][11:0] && ymax>=best[k][35:24] &&
     (({1'b0,xmin}+13'd8>={1'b0,best[k][47:36]} && {1'b0,xmax}<={1'b0,best[k][23:12]}+13'd8) ||
      ({1'b0,best[k][47:36]}+13'd8>={1'b0,xmin} && {1'b0,best[k][23:12]}<={1'b0,xmax}+13'd8)))))begin duplicate_found=1;duplicate_slot=k;end
 end
 wire insert0=valid&&!duplicate_found&&better(incoming,best[0]);
 wire insert1=valid&&!duplicate_found&&!insert0&&better(incoming,best[1]);
 wire insert2=valid&&!duplicate_found&&!insert0&&!insert1&&better(incoming,best[2]);
 wire insert3=valid&&!duplicate_found&&!insert0&&!insert1&&!insert2&&better(incoming,best[3]);
 wire [75:0] duplicate_record=best[duplicate_slot];
 wire same_bounds=duplicate_record[47:0]==incoming[47:0];
 wire [21:0] merged_area={1'b0,area}+{1'b0,duplicate_record[68:48]};
 wire [74:0] merged_record={color,
  area>=duplicate_record[68:48]?shape:duplicate_record[71:69],
  merged_area[21]?21'h1fffff:merged_area[20:0],
  xmin<duplicate_record[47:36]?xmin:duplicate_record[47:36],
  ymin<duplicate_record[35:24]?ymin:duplicate_record[35:24],
  xmax>duplicate_record[23:12]?xmax:duplicate_record[23:12],
  ymax>duplicate_record[11:0]?ymax:duplicate_record[11:0]};
 wire merged_before0=better({1'b1,merged_record},best[0]);
 wire merged_before1=better({1'b1,merged_record},best[1]);
 wire merged_before2=better({1'b1,merged_record},best[2]);
 always @(posedge clk)begin
  if(!rst_n||clear)begin
   if(GEOMETRY)begin d0[PAYLOAD-1 -:2]<=0;d1[PAYLOAD-1 -:2]<=1;d2[PAYLOAD-1 -:2]<=2;d3[PAYLOAD-1 -:2]<=3;end
  end else begin
  if(strobe&&!emitting)begin
   if(valid&&duplicate_found)begin
    if(MERGE_FRAGMENTS && !same_bounds)case(duplicate_slot)
     0:d0<=merged_payload;
     1:if(merged_before0)begin d0<=merged_payload;d1<=d0;end else d1<=merged_payload;
     2:if(merged_before0)begin d0<=merged_payload;d1<=d0;d2<=d1;end
       else if(merged_before1)begin d1<=merged_payload;d2<=d1;end else d2<=merged_payload;
     3:if(merged_before0)begin d0<=merged_payload;d1<=d0;d2<=d1;d3<=d2;end
       else if(merged_before1)begin d1<=merged_payload;d2<=d1;d3<=d2;end
       else if(merged_before2)begin d2<=merged_payload;d3<=d2;end else d3<=merged_payload;
    endcase
    else if(duplicate_record[71:69]==0 && shape!=0)case(duplicate_slot)
     0:d0[71:69]<=shape;1:d1[71:69]<=shape;2:d2[71:69]<=shape;3:d3[71:69]<=shape;
    endcase
   end else if(insert0)begin d0<=incoming_payload;d1<=d0;d2<=d1;d3<=d2;end
   else if(insert1)begin d1<=incoming_payload;d2<=d1;d3<=d2;end
   else if(insert2)begin d2<=incoming_payload;d3<=d2;end
   else if(insert3)d3<=incoming_payload;
  end
  // Retained population tables may be patched by the fusion pass only after
  // emission. No extra copy of four colour/geometry records is required.
  if(RETAIN_RESULTS && patch_valid)case(patch_index)
   0:d0[74:0]<=patch_record[74:0];1:d1[74:0]<=patch_record[74:0];2:d2[74:0]<=patch_record[74:0];3:d3[74:0]<=patch_record[74:0];
  endcase
 end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin live<=0;emitting<=0;idx<=0;out_strobe<=0;out_last<=0;out_index<=0;out_record<=0;truncated<=0;end
  else if(clear)begin live<=0;emitting<=0;idx<=0;out_strobe<=0;out_last<=0;truncated<=0;end
  else begin
   out_strobe<=0;out_last<=0;
   if(strobe&&!emitting)begin
    if(valid&&!duplicate_found)begin
     if(live[3])truncated<=1;
     if(insert0)live<={live[2:0],1'b1};
     else if(insert1)live[3:1]<={live[2:1],1'b1};
     else if(insert2)live[3:2]<={live[2],1'b1};
     else if(insert3)live[3]<=1;
    end
    if(last)begin emitting<=1;idx<=0;end
   end
   if(emitting && (!GEOMETRY || (emit_ready && !out_strobe)))begin
    out_strobe<=1;out_last<=idx==3;out_index<={1'b0,idx};out_record<=live[idx]?best[idx]:76'd0;
    out_geometry<=output_geometry;
    if(idx==3)begin emitting<=0;if(!RETAIN_RESULTS)live<=0;end else idx<=idx+1'b1;
   end
   if(RETAIN_RESULTS && patch_valid)live[patch_index]<=patch_record[75];
  end
 end
endmodule
