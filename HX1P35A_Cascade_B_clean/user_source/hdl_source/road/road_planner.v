`timescale 1ns/1ps
// 80x45 four-neighbour BFS on the actual A preview. One RAM access per step.
// Result d4: status[9:8], runs[14:10], goal x[21:15], goal y[27:22].
// Up to 26 bytes {direction[1:0],length[5:0]}, newest byte at bit 32.
// Decode from byte (runs-1) down to zero, walking goal back to start.
module road_planner #(parameter SEAM_BRIDGE=1)(
 input wire clk,rst_n,enable, input wire [31:0] control_epoch,
 input wire [23:0] rgb,input wire de,vs,preview_source,
 input wire [31:0] image_id,generation,
 output reg [255:0] objects,output reg valid,
 output reg [31:0] source_id,result_epoch);
 function [11:0] addr;input [6:0] x;input [5:0] y;
 begin addr=({6'd0,y}<<6)+({6'd0,y}<<4)+{5'd0,x};end endfunction
 wire [11:0] x,y;wire fs,fe;
 video_stream_context u_context(.I_clk(clk),.I_rst_n(rst_n),
 .I_active_width(12'd1280),.I_active_height(12'd720),.I_de(de),.I_vs(vs),
 .O_x(x),.O_y(y),.O_frame_start(fs),.O_frame_end(fe),.O_line_start(),.O_line_end());
 wire [7:0] r=rgb[23:16],g=rgb[15:8],b=rgb[7:0];
 wire [7:0] hi=(r>g)?((r>b)?r:b):((g>b)?g:b);
 wire [7:0] lo=(r<g)?((r<b)?r:b):((g<b)?g:b);
 reg [7:0] dark_threshold;
 wire black=hi<dark_threshold && hi-lo<48;
 wire red=r>95 && {1'b0,r}>{1'b0,g}+9'd38 && {1'b0,r}>{1'b0,b}+9'd32;
 wire blue=b>65 && {1'b0,b}>{1'b0,r}+9'd35 &&
   {1'b0,b,1'b0}>({2'd0,r}+{1'b0,r,1'b0}) && {1'b0,b}>{1'b0,g}+9'd12;
 wire purple=r>65 && b>65 && {1'b0,r}>{1'b0,g}+9'd30 && {1'b0,b}>{1'b0,g}+9'd30;
 wire white=lo>dark_threshold && hi-lo<65;
 reg capture,armed,seen;reg [31:0] epoch_q,seen_generation,frame_id,frame_epoch;
 reg enable_q;
 wire clear=!enable || enable!=enable_q || control_epoch!=epoch_q;
 wire [6:0] gx=x[10:4];wire [5:0] gy=y[9:4];
 wire sample_row=y[1:0]==2;
 reg [4:0] cb,cr,cu,cp,cw;
 reg [11:0] sum_r,sum_g,sum_b;
 wire [63:0] stats_q;
 wire stats_we=capture && de && sample_row && x[3:0]==15;
 wire [63:0] stats_wd={3'd0,sum_b,sum_g,sum_r,cw,cp,cu,cr,cb};
 genvar si;generate for(si=0;si<2;si=si+1)begin:stat_bank
  road_ram #(.W(32),.A(9)) stats(clk,stats_we,{2'd0,gx},{2'd0,gx},stats_wd[si*32+:32],stats_q[si*32+:32]);
 end endgenerate
 wire map_we=stats_we && y[3:0]==14;
 wire grass={1'b0,sum_g}>{1'b0,sum_r}+13'd64 && {1'b0,sum_g}>{1'b0,sum_b}+13'd80 &&
    {1'b0,sum_g,1'b0}>({2'd0,sum_r}+{2'd0,sum_b}+14'd192);
 wire [7:0] map_wd={cw>=12 && !grass,(cu[4]?2'd3:cu[3:2]),cw>=8 && !grass,cp>=2,cu>=2,cr>=2,((cb>=6 && !grass) || cu>=2 || cp>=2)};
 reg [11:0] mr;wire [7:0] mq;
 reg marker_we;reg [11:0] marker_addr;reg [3:0] marker_wd;
 road_ram #(.W(4)) map_lo(clk,map_we || marker_we,map_we?addr(gx,gy):marker_addr,mr,map_we?map_wd[3:0]:marker_wd,mq[3:0]);
 reg marker_hi_we;reg [3:0] marker_hi_wd;
 road_ram #(.W(4)) map_hi(clk,map_we || marker_hi_we,map_we?addr(gx,gy):marker_addr,mr,map_we?map_wd[7:4]:marker_hi_wd,mq[7:4]);
 function [6:0] chroma;input [11:0] a,c;reg signed [12:0] difference;
 begin difference=$signed({1'b0,a})-$signed({1'b0,c});
  if(difference>13'sd252)chroma=7'd63;
  else if(difference< -13'sd256)chroma=7'b1000000;
  else chroma=difference>>>2;
 end endfunction
 wire [11:0] max_sum=sum_r>sum_g?(sum_r>sum_b?sum_r:sum_b):(sum_g>sum_b?sum_g:sum_b);
 wire [23:0] meta_wd={(cr>=2 || cu>=2 || cp>=2),max_sum[11:4],chroma(sum_r,sum_g),chroma(sum_b,sum_g),(grass && cw<8)};
 wire [23:0] meta_q;
 genvar mi;generate for(mi=0;mi<6;mi=mi+1)begin:meta_bank
  road_ram #(.W(4)) metadata(clk,map_we,addr(gx,gy),mr,meta_wd[mi*4+:4],meta_q[mi*4+:4]);
 end endgenerate
 always @(posedge clk) if(capture && de && sample_row)begin
  if(x[3:0]==2)begin
   cb<=(y[3:0]==2?5'd0:stats_q[4:0])+black;
   cr<=(y[3:0]==2?5'd0:stats_q[9:5])+red;
   cu<=(y[3:0]==2?5'd0:stats_q[14:10])+blue;
   cp<=(y[3:0]==2?5'd0:stats_q[19:15])+purple;
   cw<=(y[3:0]==2?5'd0:stats_q[24:20])+white;
   sum_r<=(y[3:0]==2?12'd0:stats_q[36:25])+r;
   sum_g<=(y[3:0]==2?12'd0:stats_q[48:37])+g;
   sum_b<=(y[3:0]==2?12'd0:stats_q[60:49])+b;
  end else if(x[1:0]==2)begin cb<=cb+black;cr<=cr+red;cu<=cu+blue;cp<=cp+purple;cw<=cw+white;
   sum_r<=sum_r+r;sum_g<=sum_g+g;sum_b<=sum_b+b;
  end
 end
 reg swe;reg [11:0] sw,sr;reg [3:0] sd;wire [3:0] sq;
 road_ram #(.W(4)) search(clk,swe,sw,sr,sd,sq);
 reg distance_we;reg [11:0] distance_wa,distance_ra,distance_wd;wire [11:0] distance_q;
 genvar di;generate for(di=0;di<3;di=di+1)begin:distance_bank
  road_ram #(.W(4)) distance_ram(clk,distance_we,distance_wa,distance_ra,distance_wd[di*4+:4],distance_q[di*4+:4]);
 end endgenerate
 reg qwe;reg [11:0] qw,qr;reg [15:0] qd;wire [15:0] qq;
 genvar qi;generate for(qi=0;qi<4;qi=qi+1)begin:qbank
  road_ram #(.W(4)) queue(clk,qwe,qw,qr,qd[qi*4+:4],qq[qi*4+:4]);
 end endgenerate
 localparam IDLE=0,CAPTURE=1,INIT=2,INIT_GOT=3,SCAN=4,SCAN_GOT=5,
  NEIGH=6,NEIGH_GOT=7,MARK=8,RED_WHITE=9,RED_WHITE_GOT=10,
  RED_ROAD=11,RED_ROAD_GOT=12,RED_WIDTH=13,RED_WIDTH_GOT=14,
  FOLLOW=15,FOLLOW_GOT=16,LEFT=17,LEFT_GOT=18,RIGHT=19,RIGHT_GOT=20,
  BLOCK=21,SIDE_DONE=22,NEXT_SCAN=23,SEED=24,SEED_GOT=25,
  POP=26,QWAIT=27,QGOT=28,NB=29,NB_GOT=30,NEXT_NB=31,
  TRACE=32,TRACE_GOT=33,PUBLISH=34,RWAIT=35,SWAIT=36,
  INIT_L1=37,INIT_L2=38,INIT_R1=39,INIT_R2=40,INIT_STORE=41,
  CAL_START=42,CAL_SCAN=43,REF2=44,REF2_GOT=45,ENDPOINT_START=46,ENDPOINT_START_GOT=47,
  ENDPOINT_GOAL=48,ENDPOINT_GOAL_GOT=49,SEED_READ=50,CACHE=51,CACHE_GOT=52,
  SELECT=53,SELECT_WAIT=54,SELECT_GOT=55,SELECT_NEIGH=56,SELECT_NEIGH_GOT=57,SELECT_PICK=58,NEXT_SELECT=59,
  BFS_CURRENT=60,BFS_CURRENT_GOT=61,GREEN_STEP=62,GREEN_GOT=63,GREEN_NEXT=64,GRAY_STEP=65,GRAY_GOT=66;
 reg [6:0] state,ret;
 reg [6:0] ax,sx,tx,cx,nx,start_x,goal_x,rx,rl,rr,initial_l,initial_r,probe;
 reg [5:0] ay,sy,ty,cy,ny,start_y,goal_y,ry;
 reg start_ok,goal_ok,near_black,red_duplicate;
 reg [1:0] start_score;reg init_open;
 reg [7:0] cell_data;reg [1:0] direction;
 reg side_down;reg [3:0] limit_width;
 reg [12:0] head,tail;
 reg [1:0] status,run_dir;reg [5:0] run_len;reg [4:0] run_count;
 reg [207:0] runs;reg [21:0] watchdog;
 reg [15:0] histogram[0:15];reg [3:0] hist_index,hist_peak;
 reg [15:0] hist_peak_count;
 wire hist_better=histogram[hist_index]>hist_peak_count;
 wire [3:0] chosen_peak=hist_better?hist_index:hist_peak;
 wire [15:0] chosen_count=hist_better?histogram[hist_index]:hist_peak_count;
 wire [7:0] chosen_level=chosen_count>=128?{chosen_peak,4'b1000}:8'd192;
 wire [7:0] chosen_dark_raw=(chosen_level>>1)+(chosen_level>>3);
 wire [7:0] chosen_dark=chosen_dark_raw>145?8'd145:(chosen_dark_raw<48?8'd48:chosen_dark_raw);
 reg [5:0] grass_min_y,grass_max_y;reg [6:0] grass_min_x,grass_max_x;reg [12:0] grass_count;
 reg [7:0] cell_luma,ref_luma;reg signed [6:0] cell_rg,cell_bg,ref_rg,ref_bg;
 reg ref_ok,start_strong,goal_strong;reg signed [7:0] start_position,goal_position;
 reg [5:0] goal_score,start_quality;
 reg cell_green,signal_green,current_green;reg [1:0] signal_extent;reg [2:0] signal_step;
 reg [11:0] current_distance;
 reg traffic_pass,cell_strong_any;reg [1:0] candidate_colour;
 reg [2:0] support_direction;reg [3:0] blue_support,purple_support;
 reg blue_horizontal,blue_vertical;
 wire reference_road=mq[0] && !meta_q[23];
 wire [7:0] reference_luma=meta_q[22:15];
 wire signed [8:0] local_rg=$signed({{2{cell_rg[6]}},cell_rg})-$signed({{2{ref_rg[6]}},ref_rg});
 wire signed [8:0] local_bg=$signed({{2{cell_bg[6]}},cell_bg})-$signed({{2{ref_bg[6]}},ref_bg});
 wire [5:0] roi_top=grass_min_y>8?grass_min_y-6'd8:6'd0;
 wire [7:0] roi_right={1'b0,grass_max_x}+8'd8;
 wire [7:0] grass_middle_x={1'b0,grass_min_x}+{1'b0,grass_max_x};
 wire [6:0] grass_middle_y={1'b0,grass_min_y}+{1'b0,grass_max_y};
 wire blue_region=grass_count<16 || ({ax,1'b0}<=grass_middle_x+8'd8 && {ay,1'b0}+7'd8>=grass_middle_y);
 wire purple_region=grass_count<16 || ({ax,1'b0}+8'd8>=grass_middle_x && {ay,1'b0}<=grass_middle_y+7'd8);
 wire local_ok=ref_ok && near_black && grass_count>=16 && ay>=roi_top && {1'b0,ax}<=roi_right &&
   cell_luma>=32 && cell_luma<224 && {1'b0,cell_luma}>={1'b0,ref_luma}+9'd2;
 wire colour_contrast=!cell_data[4] || local_rg>=40 || local_rg<= -40 || local_bg>=40 || local_bg<= -40;
 wire weak_blue=!cell_strong_any && blue_region && cell_bg>=7'sd4 && local_ok && colour_contrast && local_bg>=(cell_luma<64?9'sd8:9'sd16) && local_bg>=local_rg+9'sd8;
 wire weak_purple=!cell_strong_any && purple_region && cell_rg>=7'sd4 && cell_bg>=7'sd4 && local_ok && colour_contrast && local_rg>=8 && local_bg>=8 &&
   local_rg<=local_bg+9'sd28 && local_bg<=local_rg+9'sd28;
 wire weak_red=local_ok && cell_rg>=7'sd8 && !cell_data[4] && local_rg>=24 && local_rg>=local_bg+9'sd24;
 wire [1:0] weak_blue_score=local_bg>=48?2'd3:local_bg>=32?2'd2:2'd1;
 wire signed [9:0] purple_quality=local_rg+local_bg;
 wire [5:0] weak_goal_score=purple_quality>252?6'd63:purple_quality[7:2];
 wire signed [7:0] blue_position=$signed({2'b00,ay})-$signed({1'b0,ax});
 wire signed [7:0] purple_position=$signed({1'b0,ax})-$signed({2'b00,ay});
 wire blue_preferred=cell_data[2] && cell_strong_any && cell_data[6:5]!=0;
 wire start_preferred=start_strong && start_score!=0;
 wire [5:0] blue_select_quality={blue_support,2'b00}+{4'd0,cell_data[6:5]};
 wire signed [6:0] purple_absolute=cell_rg<cell_bg?cell_rg:cell_bg;
 wire [1:0] purple_absolute_score=purple_absolute[6]?2'd0:purple_absolute[5:4];
 wire [5:0] purple_select_quality={purple_support,2'b00}+{4'd0,purple_absolute_score};
 wire neighbour_green=current_green || mq[6];
 wire gray_lamp=!meta_q[0] && $signed(meta_q[14:8])>= -7'sd24 && $signed(meta_q[14:8])<=7'sd24 &&
   $signed(meta_q[7:1])>= -7'sd24 && $signed(meta_q[7:1])<=7'sd24 &&
   {1'b0,meta_q[22:15]}>={1'b0,ref_luma}+9'd8 && meta_q[22:15]<224 &&
   {1'b0,meta_q[22:15]}<={1'b0,dark_threshold}+9'd48;
 integer histogram_i;
 task read_map;input [6:0] px;input [5:0] py;input [6:0] back;
 begin mr<=addr(px,py);ret<=back;state<=RWAIT;end endtask
 task read_search;input [6:0] px;input [5:0] py;input [6:0] back;
 begin sr<=addr(px,py);mr<=addr(px,py);distance_ra<=addr(px,py);ret<=back;state<=SWAIT;end endtask
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;ret<=0;capture<=0;armed<=0;seen<=0;epoch_q<=0;enable_q<=0;seen_generation<=0;
   frame_id<=0;frame_epoch<=0;objects<=0;valid<=0;source_id<=0;result_epoch<=0;
   swe<=0;qwe<=0;sw<=0;sr<=0;sd<=0;qw<=0;qr<=0;qd<=0;mr<=0;
   distance_we<=0;distance_wa<=0;distance_ra<=0;distance_wd<=0;current_distance<=0;
   cell_green<=0;signal_green<=0;current_green<=0;signal_extent<=0;signal_step<=0;
   ax<=0;ay<=0;sx<=0;sy<=0;tx<=0;ty<=0;cx<=0;cy<=0;nx<=0;ny<=0;
   start_x<=0;start_y<=0;goal_x<=0;goal_y<=0;start_ok<=0;goal_ok<=0;start_score<=0;init_open<=0;
   rx<=0;ry<=0;rl<=0;rr<=0;initial_l<=0;initial_r<=0;probe<=0;limit_width<=0;
   near_black<=0;red_duplicate<=0;cell_data<=0;direction<=0;side_down<=0;
   head<=0;tail<=0;status<=0;run_dir<=0;run_len<=0;run_count<=0;runs<=0;watchdog<=0;
   marker_we<=0;marker_addr<=0;marker_wd<=0;dark_threshold<=120;
   traffic_pass<=0;cell_strong_any<=0;marker_hi_we<=0;marker_hi_wd<=0;candidate_colour<=0;
   support_direction<=0;blue_support<=0;purple_support<=0;
   blue_horizontal<=0;blue_vertical<=0;
   hist_index<=5;hist_peak<=5;hist_peak_count<=0;grass_min_y<=44;grass_max_y<=0;grass_min_x<=79;grass_max_x<=0;grass_count<=0;
   cell_luma<=0;ref_luma<=255;cell_rg<=0;cell_bg<=0;ref_rg<=0;ref_bg<=0;ref_ok<=0;
   start_strong<=0;goal_strong<=0;start_position<= -128;goal_position<= -128;goal_score<=0;start_quality<=0;
   for(histogram_i=0;histogram_i<16;histogram_i=histogram_i+1)histogram[histogram_i]<=0;
  end else begin
   epoch_q<=control_epoch;enable_q<=enable;swe<=0;qwe<=0;marker_we<=0;marker_hi_we<=0;distance_we<=0;
   if(capture && de && sample_row && x[1:0]==2 && hi>=80 && hi-lo<64)histogram[hi[7:4]]<=histogram[hi[7:4]]+1'b1;
   if(map_we && grass && cw<8)begin
    if(gy<grass_min_y)grass_min_y<=gy;
    if(gy>grass_max_y)grass_max_y<=gy;
    if(gx<grass_min_x)grass_min_x<=gx;
    if(gx>grass_max_x)grass_max_x<=gx;
    grass_count<=grass_count+1'b1;
   end
   if(enable && generation!=seen_generation)armed<=1;
   if(state>IDLE && state!=CAPTURE)watchdog<=watchdog+1'b1;
   case(state)
    IDLE:if(fs && enable && preview_source && armed && (!seen || generation!=seen_generation))begin
     capture<=1;seen<=1;seen_generation<=generation;frame_id<=image_id;frame_epoch<=control_epoch;
     // Keep the last complete publication while the next image is processed.
     // Mode/epoch changes still clear valid through the context guard below.
     watchdog<=0;state<=CAPTURE;
     grass_min_y<=44;grass_max_y<=0;grass_min_x<=79;grass_max_x<=0;grass_count<=0;traffic_pass<=0;
     for(histogram_i=0;histogram_i<16;histogram_i=histogram_i+1)histogram[histogram_i]<=0;
    end
    CAPTURE:if(fe)begin capture<=0;ax<=0;ay<=0;start_ok<=0;goal_ok<=0;start_score<=0;
     start_strong<=0;goal_strong<=0;start_position<= -128;goal_position<= -128;goal_score<=0;start_quality<=0;
     status<=0;run_len<=0;run_count<=0;runs<=0;state<=CAL_START;end
    CAL_START:begin hist_index<=5;hist_peak<=5;hist_peak_count<=0;state<=CAL_SCAN;end
    CAL_SCAN:begin
     if(hist_better)begin hist_peak<=hist_index;hist_peak_count<=histogram[hist_index];end
     if(hist_index==15)begin
      dark_threshold<=chosen_dark;
      if({1'b0,chosen_dark}>{1'b0,dark_threshold}+9'd12 || {1'b0,dark_threshold}>{1'b0,chosen_dark}+9'd12)state<=IDLE;
      else state<=INIT;
     end else hist_index<=hist_index+1'b1;
    end
    RWAIT:state<=ret;
    SWAIT:state<=ret;
    INIT:read_map(ax,ay,INIT_GOT);
    INIT_GOT:begin
     init_open<=mq[0];cell_data<=mq;
     if(SEAM_BRIDGE && !mq[0] && mq[7] && ax>=2 && ax<78)read_map(ax-1'b1,ay,INIT_L1);
     else state<=INIT_STORE;
    end
    INIT_L1:if(mq[0])read_map(ax-2'd2,ay,INIT_L2);else state<=INIT_STORE;
    INIT_L2:if(mq[0])read_map(ax+1'b1,ay,INIT_R1);else state<=INIT_STORE;
    INIT_R1:if(mq[0])read_map(ax+2'd2,ay,INIT_R2);else state<=INIT_STORE;
    INIT_R2:begin init_open<=mq[0];state<=INIT_STORE;end
    INIT_STORE:begin
     swe<=1;sw<=addr(ax,ay);sd<={3'd0,init_open};
     if(traffic_pass)begin marker_hi_we<=1;marker_addr<=addr(ax,ay);marker_hi_wd<={cell_data[7],1'b0,cell_data[5:4]};end
     if(ax==79)begin ax<=0;if(ay==44)begin ay<=0;state<=SCAN;end else begin ay<=ay+1'b1;state<=INIT;end end
     else begin ax<=ax+1'b1;state<=INIT;end
    end
    SCAN:read_map(ax,ay,SCAN_GOT);
    SCAN_GOT:begin
     cell_data<=mq;near_black<=0;red_duplicate<=0;direction<=0;
     cell_luma<=meta_q[22:15];cell_rg<=meta_q[14:8];cell_bg<=meta_q[7:1];ref_luma<=255;ref_ok<=0;
     cell_strong_any<=meta_q[23];
     cell_green<=meta_q[0];
     if(traffic_pass ? (mq[1] || meta_q[0]) : (|mq[3:1] || (meta_q[22:15]>=32 && meta_q[22:15]<224)))state<=NEIGH;else state<=NEXT_SCAN;
    end
    NEIGH:case(direction)
     0:if(ax>0)read_map(ax-1'b1,ay,NEIGH_GOT);else state<=NEXT_NB;
     1:if(ax<79)read_map(ax+1'b1,ay,NEIGH_GOT);else state<=NEXT_NB;
     2:if(ay>0)read_map(ax,ay-1'b1,NEIGH_GOT);else state<=NEXT_NB;
     3:if(ay<44)read_map(ax,ay+1'b1,NEIGH_GOT);else state<=NEXT_NB;
    endcase
    NEIGH_GOT:begin
     if(reference_road)begin
      near_black<=1;
      if(!ref_ok || reference_luma<ref_luma)begin ref_ok<=1;ref_luma<=reference_luma;ref_rg<=meta_q[14:8];ref_bg<=meta_q[7:1];end
     end
     if((direction==0 || direction==2) && mq[1])red_duplicate<=1;
     if(direction==3)begin direction<=0;state<=traffic_pass?MARK:REF2;end else begin direction<=direction+1'b1;state<=NEIGH;end
    end
    // NEXT_NB also handles an out-of-bounds marker neighbour.
    NEXT_NB:if(tail==0)begin
     if(direction==3)begin direction<=0;state<=traffic_pass?MARK:REF2;end else begin direction<=direction+1'b1;state<=NEIGH;end
    end else begin
     if(direction==3)state<=POP;else begin direction<=direction+1'b1;state<=NB;end
    end
    REF2:case(direction)
     0:if(ax>=2)read_map(ax-2'd2,ay,REF2_GOT);else begin direction<=1;end
     1:if(ax<78)read_map(ax+2'd2,ay,REF2_GOT);else begin direction<=2;end
     2:if(ay>=2)read_map(ax,ay-2'd2,REF2_GOT);else begin direction<=3;end
     3:if(ay<43)read_map(ax,ay+2'd2,REF2_GOT);else state<=MARK;
    endcase
    REF2_GOT:begin
     if(reference_road && (!ref_ok || reference_luma<ref_luma))begin ref_ok<=1;ref_luma<=reference_luma;ref_rg<=meta_q[14:8];ref_bg<=meta_q[7:1];end
     if(direction==3)state<=MARK;else begin direction<=direction+1'b1;state<=REF2;end
    end
    MARK:begin
     if(traffic_pass)begin
      if(cell_data[1] && !red_duplicate && ax<79)begin signal_green<=0;rx<=ax+1'b1;ry<=ay;state<=RED_WHITE;end
      else if(cell_green && near_black && ref_ok && ax<79)begin
       direction<=0;signal_extent<=1;signal_step<=1;state<=GREEN_STEP;
      end
      else state<=NEXT_SCAN;
     end else begin
      if(weak_red && !cell_data[1])begin marker_we<=1;marker_addr<=addr(ax,ay);marker_wd<=cell_data[3:0]|4'b0010;end
      candidate_colour<={(cell_data[3] && near_black && purple_region) || weak_purple,(cell_data[2] && near_black && blue_region) || weak_blue};
      if(weak_blue)begin marker_hi_we<=1;marker_addr<=addr(ax,ay);marker_hi_wd<={cell_data[7],weak_blue_score,cell_data[4]};end
      state<=CACHE;
     end
    end
    CACHE:read_search(ax,ay,CACHE_GOT);
    CACHE_GOT:begin swe<=1;sw<=addr(ax,ay);sd<={candidate_colour,1'b0,sq[0]};state<=NEXT_SCAN;end
    SELECT:begin mr<=addr(ax,ay);sr<=addr(ax,ay);state<=SELECT_WAIT;end
    SELECT_WAIT:state<=SELECT_GOT;
    SELECT_GOT:begin
     candidate_colour<=sq[3:2];cell_data<=mq;cell_strong_any<=meta_q[23];
     cell_rg<=meta_q[14:8];cell_bg<=meta_q[7:1];
     blue_support<=0;purple_support<=0;support_direction<=0;
     blue_horizontal<=0;blue_vertical<=0;
     if(sq[3:2]!=0)state<=SELECT_NEIGH;else state<=NEXT_SELECT;
    end
    SELECT_NEIGH:begin
     case(support_direction)
      0:if(ax>0)read_search(ax-1'b1,ay,SELECT_NEIGH_GOT);else support_direction<=1;
      1:if(ax<79)read_search(ax+1'b1,ay,SELECT_NEIGH_GOT);else support_direction<=2;
      2:if(ay>0)read_search(ax,ay-1'b1,SELECT_NEIGH_GOT);else support_direction<=3;
      3:if(ay<44)read_search(ax,ay+1'b1,SELECT_NEIGH_GOT);else support_direction<=4;
      4:if(ax>0 && ay>0)read_search(ax-1'b1,ay-1'b1,SELECT_NEIGH_GOT);else support_direction<=5;
      5:if(ax<79 && ay>0)read_search(ax+1'b1,ay-1'b1,SELECT_NEIGH_GOT);else support_direction<=6;
      6:if(ax>0 && ay<44)read_search(ax-1'b1,ay+1'b1,SELECT_NEIGH_GOT);else support_direction<=7;
      7:if(ax<79 && ay<44)read_search(ax+1'b1,ay+1'b1,SELECT_NEIGH_GOT);else state<=SELECT_PICK;
     endcase
    end
    SELECT_NEIGH_GOT:begin
     if(sq[2])blue_support<=blue_support+1'b1;
     if(sq[2] && support_direction<2)blue_horizontal<=1;
     if(sq[2] && support_direction>=2 && support_direction<4)blue_vertical<=1;
     if(sq[3])purple_support<=purple_support+1'b1;
     if(support_direction==7)state<=SELECT_PICK;else begin support_direction<=support_direction+1'b1;state<=SELECT_NEIGH;end
    end
    SELECT_PICK:begin
     if(candidate_colour[0] && ((cell_data[2] && cell_strong_any) || (blue_support>=2 && blue_horizontal && blue_vertical)) &&
        ((!start_ok) || (blue_preferred && (!start_preferred || cell_data[6:5]>start_score)) ||
         (!blue_preferred && !start_preferred && (blue_select_quality>start_quality ||
          (blue_select_quality==start_quality && blue_position>start_position)))))begin
      start_x<=ax;start_y<=ay;start_ok<=1;start_strong<=cell_data[2] && cell_strong_any;
      start_position<=blue_position;start_score<=cell_data[6:5];start_quality<=blue_select_quality;
     end
     if(candidate_colour[1] && ((cell_data[3] && cell_strong_any) || purple_support>=1) &&
        ((!goal_ok) || (cell_data[3] && cell_strong_any && !goal_strong) ||
         (!(cell_data[3] && cell_strong_any) && !goal_strong && (purple_select_quality>goal_score ||
          (purple_select_quality==goal_score && purple_position>goal_position)))))begin
      goal_x<=ax;goal_y<=ay;goal_ok<=1;goal_strong<=cell_data[3] && cell_strong_any;goal_position<=purple_position;
      goal_score<=purple_select_quality;
     end
     state<=NEXT_SELECT;
    end
    NEXT_SELECT:if(ax==79)begin ax<=0;if(ay==44)begin ay<=0;traffic_pass<=1;state<=ENDPOINT_START;end
      else begin ay<=ay+1'b1;state<=SELECT;end end else begin ax<=ax+1'b1;state<=SELECT;end
    GREEN_STEP:case(direction)
     0:if(ax>=signal_step)read_map(ax-signal_step,ay,GREEN_GOT);else state<=GREEN_NEXT;
     1:if({1'b0,ax}+signal_step<80)read_map(ax+signal_step,ay,GREEN_GOT);else state<=GREEN_NEXT;
     2:if(ay>=signal_step)read_map(ax,ay-signal_step,GREEN_GOT);else state<=GREEN_NEXT;
     3:if({1'b0,ay}+signal_step<45)read_map(ax,ay+signal_step,GREEN_GOT);else state<=GREEN_NEXT;
    endcase
    GREEN_GOT:if(!meta_q[0])state<=GREEN_NEXT;
      else if(signal_extent==3)state<=NEXT_SCAN;
      else begin signal_extent<=signal_extent+1'b1;signal_step<=signal_step+1'b1;state<=GREEN_STEP;end
    GREEN_NEXT:begin
     signal_step<=1;
     if(direction==3)begin direction<=0;state<=GRAY_STEP;end
     else begin if(direction==1)signal_extent<=1;direction<=direction+1'b1;state<=GREEN_STEP;end
    end
    GRAY_STEP:if(ay<signal_step)state<=NEXT_SCAN;
      else case(direction)
       0:read_map(ax,ay-signal_step,GRAY_GOT);
       1:if(ax>0)read_map(ax-1'b1,ay-signal_step,GRAY_GOT);else direction<=2;
       2:if(ax<79)read_map(ax+1'b1,ay-signal_step,GRAY_GOT);else begin
        direction<=0;if(signal_step==5)state<=NEXT_SCAN;else signal_step<=signal_step+1'b1;
       end
      endcase
    GRAY_GOT:if(gray_lamp)begin signal_green<=1;rx<=ax+1'b1;ry<=ay;state<=RED_WHITE;end
      else if(direction!=2)begin direction<=direction+1'b1;state<=GRAY_STEP;end
      else begin direction<=0;if(signal_step==5)state<=NEXT_SCAN;else begin signal_step<=signal_step+1'b1;state<=GRAY_STEP;end end
    RED_WHITE:if(rx>=80 || rx>ax+12)state<=NEXT_SCAN;else read_map(rx,ay,RED_WHITE_GOT);
    RED_WHITE_GOT:if(!mq[0] && (mq[4] || (!meta_q[0] && !meta_q[23])))state<=RED_ROAD;
      else begin rx<=rx+1'b1;state<=RED_WHITE;end
    RED_ROAD:if(rx>=80 || rx>ax+12)state<=NEXT_SCAN;else read_map(rx,ay,RED_ROAD_GOT);
    RED_ROAD_GOT:if(mq[0])begin initial_l<=rx;state<=RED_WIDTH;end else begin rx<=rx+1'b1;state<=RED_ROAD;end
    RED_WIDTH:if(rx==79)begin initial_r<=rx;state<=FOLLOW;side_down<=0;cx<=({1'b0,initial_l}+{1'b0,rx})>>1;cy<=ay;limit_width<=rx-initial_l+2;end
      else read_map(rx+1'b1,ay,RED_WIDTH_GOT);
    RED_WIDTH_GOT:if(mq[0])begin
      if(rx-initial_l>=7)state<=NEXT_SCAN;else begin rx<=rx+1'b1;state<=RED_WIDTH;end
     end else begin initial_r<=rx;limit_width<=rx-initial_l+2;cx<=({1'b0,initial_l}+{1'b0,rx})>>1;cy<=ay;side_down<=0;state<=FOLLOW;end
    FOLLOW:read_map(cx,cy,FOLLOW_GOT);
    FOLLOW_GOT:if(!mq[0])state<=SIDE_DONE;else begin rl<=cx;rr<=cx;state<=LEFT;end
    LEFT:if(cx-rl>limit_width)state<=SIDE_DONE;else if(rl==0)state<=RIGHT;else read_map(rl-1'b1,cy,LEFT_GOT);
    LEFT_GOT:if(mq[0])begin rl<=rl-1'b1;state<=LEFT;end else state<=RIGHT;
    RIGHT:if(rr-rl>limit_width)state<=SIDE_DONE;else if(rr==79)begin probe<=signal_green?rl:(rl==0?7'd0:rl-1'b1);state<=BLOCK;end else read_map(rr+1'b1,cy,RIGHT_GOT);
    RIGHT_GOT:if(mq[0])begin rr<=rr+1'b1;state<=RIGHT;end else begin probe<=signal_green?rl:(rl==0?7'd0:rl-1'b1);state<=BLOCK;end
    BLOCK:begin
     if(signal_green)begin marker_hi_we<=1;marker_addr<=addr(probe,cy);marker_hi_wd<=4'b0100;end
     else begin swe<=1;sw<=addr(probe,cy);sd<=4'b0010;end
     if(probe==(signal_green?rr:(rr==79?7'd79:rr+1'b1)))begin
      cx<=({1'b0,rl}+{1'b0,rr})>>1;
      if((!side_down && cy==0) || (side_down && cy==44))state<=SIDE_DONE;
      else begin cy<=side_down?cy+1'b1:cy-1'b1;state<=FOLLOW;end
     end else probe<=probe+1'b1;
    end
    SIDE_DONE:if(!side_down)begin side_down<=1;cx<=({1'b0,initial_l}+{1'b0,initial_r})>>1;cy<=ay;state<=FOLLOW;end
      else state<=NEXT_SCAN;
    NEXT_SCAN:if(ax==79)begin ax<=0;if(ay==44)begin ay<=0;head<=0;tail<=0;state<=traffic_pass?SEED:SELECT;end else begin ay<=ay+1'b1;state<=SCAN;end end
      else begin ax<=ax+1'b1;state<=SCAN;end
    SEED:if(!start_ok || !goal_ok || (!(start_strong && goal_strong) &&
       ({1'b0,start_x}+8'd8>{1'b0,goal_x} || {1'b0,goal_y}+7'd8>{1'b0,start_y})))begin status<=3;state<=PUBLISH;end
      else read_search(start_x,start_y,SEED_GOT);
    ENDPOINT_START:if(start_ok && !start_strong)read_map(start_x,start_y,ENDPOINT_START_GOT);else state<=ENDPOINT_GOAL;
    ENDPOINT_START_GOT:begin
     marker_we<=1;marker_addr<=addr(start_x,start_y);marker_wd<=mq[3:0]|4'b0001;
     state<=ENDPOINT_GOAL;
    end
    ENDPOINT_GOAL:if(goal_ok && !goal_strong)read_map(goal_x,goal_y,ENDPOINT_GOAL_GOT);else state<=SEED_READ;
    ENDPOINT_GOAL_GOT:begin
     marker_we<=1;marker_addr<=addr(goal_x,goal_y);marker_wd<=mq[3:0]|4'b0001;
     state<=SEED_READ;
    end
    SEED_READ:begin ax<=0;ay<=0;state<=INIT;end
    SEED_GOT:if(!sq[0])begin status<=2;state<=PUBLISH;end else begin
     swe<=1;sw<=addr(start_x,start_y);sd<=4'b0011;
     distance_we<=1;distance_wa<=addr(start_x,start_y);distance_wd<=0;
     marker_we<=1;marker_addr<=addr(start_x,start_y);marker_wd<={mq[6],mq[2:0]};
     qwe<=1;qw<=0;qd<={3'd0,start_y,start_x};head<=0;tail<=1;state<=POP;
    end
    POP:if(head==tail)begin status<=2;state<=PUBLISH;end else begin qr<=head[11:0];head<=head+1'b1;state<=QWAIT;end
    QWAIT:state<=QGOT;
    QGOT:begin
     cx<=qq[6:0];cy<=qq[12:7];direction<=0;
     if(qq[6:0]==goal_x && qq[12:7]==goal_y)state<=TRACE;
     else begin mr<=addr(qq[6:0],qq[12:7]);distance_ra<=addr(qq[6:0],qq[12:7]);state<=BFS_CURRENT;end
    end
    BFS_CURRENT:state<=BFS_CURRENT_GOT;
    BFS_CURRENT_GOT:begin current_green<=mq[3];current_distance<=distance_q;state<=NB;end
    NB:case(direction)
     0:if(cx>0)begin nx<=cx-1'b1;ny<=cy;read_search(cx-1'b1,cy,NB_GOT);end else state<=NEXT_NB;
     1:if(cx<79)begin nx<=cx+1'b1;ny<=cy;read_search(cx+1'b1,cy,NB_GOT);end else state<=NEXT_NB;
     2:if(cy>0)begin nx<=cx;ny<=cy-1'b1;read_search(cx,cy-1'b1,NB_GOT);end else state<=NEXT_NB;
     3:if(cy<44)begin nx<=cx;ny<=cy+1'b1;read_search(cx,cy+1'b1,NB_GOT);end else state<=NEXT_NB;
    endcase
    NB_GOT:begin
     if(sq[1:0]==1 || (sq[1:0]==3 && distance_q==current_distance+12'd1 && neighbour_green && !mq[3]))begin
      swe<=1;sw<=addr(nx,ny);sd<={(direction^2'b01),2'b11};
      marker_we<=1;marker_addr<=addr(nx,ny);marker_wd<={neighbour_green,mq[2:0]};
      if(sq[1:0]==1)begin
       distance_we<=1;distance_wa<=addr(nx,ny);distance_wd<=current_distance+12'd1;
       qwe<=1;qw<=tail[11:0];qd<={3'd0,ny,nx};tail<=tail+1'b1;
      end
     end
     state<=NEXT_NB;
    end
    TRACE:if(cx==start_x && cy==start_y)begin
      if(run_len!=0)begin
       if(run_count==26)status<=3;else begin runs<={runs[199:0],run_dir,run_len};run_count<=run_count+1'b1;status<=1;end
      end else status<=1;
      state<=PUBLISH;
     end else read_search(cx,cy,TRACE_GOT);
    TRACE_GOT:begin
     if(run_len!=0 && (sq[3:2]!=run_dir || run_len==63))begin
      if(run_count==26)begin status<=3;state<=PUBLISH;end
      else begin runs<={runs[199:0],run_dir,run_len};run_count<=run_count+1'b1;run_dir<=sq[3:2];run_len<=1;state<=TRACE;end
     end else begin run_dir<=sq[3:2];run_len<=run_len+1'b1;state<=TRACE;end
     case(sq[3:2])0:cx<=cx-1'b1;1:cx<=cx+1'b1;2:cy<=cy-1'b1;3:cy<=cy+1'b1;endcase
    end
    PUBLISH:begin
     objects<={16'd0,runs,4'd0,goal_y,goal_x,run_count,status,8'hd4};
     source_id<=frame_id;result_epoch<=frame_epoch;valid<=1;state<=IDLE;head<=0;tail<=0;
    end
    default:state<=IDLE;
   endcase
   if(watchdog==22'd2000000 && state!=IDLE && state!=CAPTURE)begin status<=3;state<=PUBLISH;end
   if(clear)begin state<=IDLE;capture<=0;armed<=0;valid<=0;seen<=1;seen_generation<=generation;head<=0;tail<=0;end
  end
 end
endmodule
