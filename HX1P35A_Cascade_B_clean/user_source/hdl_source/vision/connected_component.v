`timescale 1ns / 1ns

// Bounded streaming connected-component accumulator.
//
// The input colour mask is first converted into horizontal runs.  A run is
// joined to the first active component of the same colour whose most recent
// run is on the preceding row and overlaps horizontally (CONNECT_MARGIN
// allows one-pixel diagonal contact).  Otherwise the first free table entry
// is allocated.  The table is deliberately bounded so resource use and
// blanking-time latency are deterministic on HX1P35A.
//
// Pipeline timing:
//   A: compare a valid run with all table entries in parallel;
//   B: register the first matching/free entry as a one-hot selection;
//   C: update the selected entry and its accumulated features.
//
// MIN_RUN_LENGTH is three in the project.  Consequently valid RLE records are
// separated by at least three pixel clocks, so stage C commits a table entry
// before the next run performs its stage-A comparison.  Frame-done is delayed
// through the update pipeline; scanning can therefore never miss the final
// run of a frame.
//
// This compact architecture is exact for the solid contest shapes (one run
// per object on a row).  A run which bridges two previously separate regions
// selects the lower-numbered region; no expensive union-find merge RAM is
// instantiated.  O_overflow is sticky for the frame if the bounded table is
// exhausted.
module connected_component #(
    parameter INDEPENDENT_COLOR=0,
    parameter GEOMETRY=0,
    parameter SEPARATE_NEUTRAL=0,
    parameter SEEDED_COLOR=0,
    parameter integer COORD_WIDTH    = 12,
    parameter integer MAX_COMPONENTS = 8,
    parameter integer MIN_RUN_LENGTH = 3,
    parameter integer CONNECT_MARGIN = 1,
    parameter integer MAX_EMPTY_ROWS = 1,
    parameter integer DEBUG=0,
    parameter integer RECLAIM_SPECKLES=0,
    parameter integer MIN_SEED_RUN=12,
    parameter integer MIN_COMPONENT_AREA=256,
    parameter integer MAX_RUN_WIDTH=4095
    ,parameter integer COLOR_PRIORITY=0
) (
    input  wire                         I_clk,
    input  wire                         I_rst_n,
    input  wire [2:0]                   I_color,
    input wire I_core,
    input  wire                         I_de,
    input  wire [COORD_WIDTH-1:0]       I_x,
    input  wire [COORD_WIDTH-1:0]       I_y,
    input  wire                         I_line_start,
    input  wire                         I_line_end,
    input  wire                         I_frame_start,
    input  wire                         I_frame_end,
    input  wire                         I_frame_is_new,

    // One record per clock while the bounded table is scanned.  Exactly
    // MAX_COMPONENTS records are produced for every new source frame.
    output reg [143:0] O_geometry,
    output reg                          O_component_strobe,
    output reg                          O_component_last,
    output reg [COORD_WIDTH:0]          O_first_width,
    output reg [COORD_WIDTH:0]          O_last_width,
    output reg [COORD_WIDTH:0]          O_max_width,
    output reg [COORD_WIDTH-1:0]        O_peak_y,
    output reg  [2:0]                   O_component_index,
    output reg                          O_component_active,
    output reg O_component_present,
    output reg [1:0] O_component_reject_reason,
    output reg  [2:0]                   O_component_color,
    output reg  [20:0]                  O_component_area,
    output reg  [COORD_WIDTH-1:0]       O_component_xmin,
    output reg  [COORD_WIDTH-1:0]       O_component_ymin,
    output reg  [COORD_WIDTH-1:0]       O_component_xmax,
    output reg  [COORD_WIDTH-1:0]       O_component_ymax,
    output reg                          O_scan_done,
    output reg                          O_overflow,
    output wire [15:0] O_slot_drops, O_queue_drops, O_allocations,
    output wire [15:0] O_emitted, O_reclaimed, O_wide_runs,
    output wire [7:0] O_slot_active,
    output wire O_slot_overflow, O_queue_overflow
);

localparam integer AREA_WIDTH = 21;
localparam [COORD_WIDTH:0] CONNECT_MARGIN_EXT = CONNECT_MARGIN;

localparam HIST_W=COORD_WIDTH+1;
wire [4*HIST_W-1:0] run_hist;
reg [4*HIST_W-1:0] hist_a,hist_b;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin hist_a<=0;hist_b<=0;end
    else begin
        if(run_valid) hist_a<=run_hist;
        if(stage_a_valid) hist_b<=hist_a;
    end
end
wire                       run_valid;
wire [2:0]                 run_color;
wire [COORD_WIDTH-1:0]     run_xmin;
wire [COORD_WIDTH-1:0]     run_xmax;
wire [COORD_WIDTH-1:0]     run_y;
wire [COORD_WIDTH:0]       run_length;
wire                       run_line_done;
wire                       run_frame_done;
wire                       run_frame_is_new;

wire run_is_geometry,queue_overflow,queue_drop;
wire [1:0] wide_events;
reg slot_overflow;
assign O_slot_overflow=slot_overflow;
assign O_queue_overflow=queue_overflow;
genvar ds;
generate for(ds=0;ds<8;ds=ds+1)begin:g_debug_active
 if(ds<MAX_COMPONENTS)assign O_slot_active[ds]=component_active[ds];
 else assign O_slot_active[ds]=0;
end endgenerate
wire [COORD_WIDTH:0] run_core;
reg [COORD_WIDTH:0] core_a,core_b;
reg [20:0] core_area[0:MAX_COMPONENTS/2-1];
always @(posedge I_clk)begin
 if(run_valid)core_a<=run_core;
 if(stage_a_valid)core_b<=core_a;
end
generate
if(!SEPARATE_NEUTRAL) begin : g_legacy
run_length_encode #(
    .COORD_WIDTH    (COORD_WIDTH), .GEOMETRY_ONLY(INDEPENDENT_COLOR),
    .MIN_RUN_LENGTH (MIN_RUN_LENGTH)
) u_run_length_encode (
    .I_clk          (I_clk),
    .I_rst_n        (I_rst_n),
    .I_color        (I_color),
    .I_de           (I_de),
    .I_x            (I_x),
    .I_y            (I_y),
    .I_line_start   (I_line_start),
    .I_line_end     (I_line_end),
    .I_frame_start  (I_frame_start),
    .I_frame_end    (I_frame_end),
    .I_frame_is_new (I_frame_is_new),
    .O_run_valid    (run_valid), .O_run_color_area(run_hist),
    .O_run_color    (run_color),
    .O_run_xmin     (run_xmin),
    .O_run_xmax     (run_xmax),
    .O_run_y        (run_y),
    .O_run_length   (run_length),
    .O_line_done    (run_line_done),
    .O_frame_done   (run_frame_done),
    .O_frame_is_new (run_frame_is_new)
);


assign run_is_geometry=0;assign queue_overflow=0;assign queue_drop=0;
assign wide_events=0;assign run_core=run_length;
end else begin : g_dual
wire c_valid,c_done;wire[2:0] c_color;
wire[COORD_WIDTH-1:0] c_xmin,c_xmax,c_y;wire[COORD_WIDTH:0] c_length;
wire[COORD_WIDTH:0] c_core;
run_length_encode #(.COORD_WIDTH(COORD_WIDTH),.GEOMETRY_ONLY(0),.CORE_EVIDENCE(SEEDED_COLOR),.MIN_RUN_LENGTH(MIN_RUN_LENGTH)) rle_c(
.I_clk(I_clk),.I_rst_n(I_rst_n),.I_color((I_color<=4)?I_color:3'd0),
.I_core(I_core),.O_run_core_count(c_core),
.I_de(I_de),.I_x(I_x),.I_y(I_y),.I_line_start(I_line_start),.I_line_end(I_line_end),
.I_frame_start(I_frame_start),.I_frame_end(I_frame_end),.I_frame_is_new(I_frame_is_new),
.O_run_valid(c_valid),.O_run_color(c_color),.O_run_xmin(c_xmin),.O_run_xmax(c_xmax),
.O_run_y(c_y),.O_run_length(c_length),.O_frame_done(c_done));
wire g_valid,g_done;wire[2:0] g_color;
wire[COORD_WIDTH-1:0] g_xmin,g_xmax,g_y;wire[COORD_WIDTH:0] g_length;
run_length_encode #(.COORD_WIDTH(COORD_WIDTH),.GEOMETRY_ONLY(1),.MIN_RUN_LENGTH(MIN_RUN_LENGTH)) rle_g(
.I_clk(I_clk),.I_rst_n(I_rst_n),.I_color(I_color),
.I_de(I_de),.I_x(I_x),.I_y(I_y),.I_line_start(I_line_start),.I_line_end(I_line_end),
.I_frame_start(I_frame_start),.I_frame_end(I_frame_end),.I_frame_is_new(I_frame_is_new),
.O_run_valid(g_valid),.O_run_color(g_color),.O_run_xmin(g_xmin),.O_run_xmax(g_xmax),
.O_run_y(g_y),.O_run_length(g_length),.O_frame_done(g_done));
candidate_run_queue #(.W(5*COORD_WIDTH+6)) queue(
.clk(I_clk),.rst_n(I_rst_n),.clear(I_frame_start),
.a_valid(c_valid),.b_valid(g_valid),.a({c_core,1'b0,c_color,c_xmin,c_xmax,c_y,c_length}),
.b({{(COORD_WIDTH+1){1'b0}},1'b1,g_color,g_xmin,g_xmax,g_y,g_length}),.a_done(c_done),.b_done(g_done),
.valid(run_valid),.data({run_core,run_is_geometry,run_color,run_xmin,run_xmax,run_y,run_length}),
.done(run_frame_done),.overflow(queue_overflow),.drop_event(queue_drop));
assign wide_events={1'b0,(c_valid && c_length>MAX_RUN_WIDTH)}+
                   {1'b0,(g_valid && g_length>MAX_RUN_WIDTH)};
assign run_frame_is_new=source_new;assign run_line_done=0;assign run_hist=0;
end endgenerate
reg                         component_active    [0:MAX_COMPONENTS-1];
reg component_has_gap[0:MAX_COMPONENTS-1];
// Retain connectivity after an over-wide row. Dropping that row before CCL
// splits one rejected background region into apparently valid head/tail boxes.
// These entries are reclaimable by a disconnected in-envelope candidate.
reg component_wide[0:MAX_COMPONENTS-1];
reg previous_row_valid[0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0] previous_xmin[0:MAX_COMPONENTS-1],previous_xmax[0:MAX_COMPONENTS-1],previous_y[0:MAX_COMPONENTS-1];
reg [2:0]                   component_color     [0:MAX_COMPONENTS-1];
reg [AREA_WIDTH-1:0]        component_area      [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_xmin      [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_ymin      [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_xmax      [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_ymax      [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_last_xmin [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_last_xmax [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0]       component_last_y    [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH:0] first_width [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH:0] last_width [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH:0] max_width [0:MAX_COMPONENTS-1];
reg [COORD_WIDTH-1:0] peak_y [0:MAX_COMPONENTS-1];
// A single update port shares four adders across all eight component slots.
// Allocation writes every lane before the active component can be emitted;
// unused memory contents therefore do not require a frame-wide RAM reset.
reg [20:0] red_area [0:MAX_COMPONENTS-1];
reg [20:0] green_area [0:MAX_COMPONENTS-1];
reg [20:0] blue_area [0:MAX_COMPONENTS-1];
reg [20:0] yellow_area [0:MAX_COMPONENTS-1];
function [2:0] color_vote;
    input [2:0] idx;
    reg [20:0] threshold;
    begin
        threshold=component_area[idx]-(component_area[idx]>>2);
        color_vote=red_area[idx]>=threshold ? 3'd1 :
            green_area[idx]>=threshold ? 3'd2 :
            blue_area[idx]>=threshold ? 3'd3 :
            yellow_area[idx]>=threshold ? 3'd4 : 3'd0;
    end
endfunction
reg source_new;
reg [2:0] retire_index;
reg [7:0] line_end_delay;
reg [COORD_WIDTH-1:0] ended_y, completed_y;
reg completed_valid;

reg                         stage_a_valid;
reg [MAX_COMPONENTS-1:0]    stage_a_matches;
reg [MAX_COMPONENTS-1:0]    stage_a_frees;
reg [2:0]                   stage_a_color;
reg [COORD_WIDTH-1:0]       stage_a_xmin;
reg [COORD_WIDTH-1:0]       stage_a_xmax;
reg [COORD_WIDTH-1:0]       stage_a_y;
reg [COORD_WIDTH:0]         stage_a_length;

// Priority encoder is isolated in stage B.  One-hot selections let stage C
// update every physical table slot directly, avoiding a wide dynamic mux and
// decoder on the area feedback path.
function [MAX_COMPONENTS-1:0] first_onehot;
    input [MAX_COMPONENTS-1:0] value;
    integer priority_index;
    reg already_found;
    begin
        first_onehot = {MAX_COMPONENTS{1'b0}};
        already_found = 1'b0;
        for(priority_index = 0;
            priority_index < MAX_COMPONENTS;
            priority_index = priority_index + 1) begin
            if(value[priority_index] && !already_found) begin
                first_onehot[priority_index] = 1'b1;
                already_found = 1'b1;
            end
        end
    end
endfunction

wire [MAX_COMPONENTS-1:0] stage_a_first_match =
    first_onehot(stage_a_matches);
wire [MAX_COMPONENTS-1:0] stage_a_first_free =
    first_onehot(stage_a_frees);

reg                         stage_b_valid;
reg [MAX_COMPONENTS-1:0]    stage_b_match_select;
reg [MAX_COMPONENTS-1:0]    stage_b_all_matches;
reg [MAX_COMPONENTS-1:0]    stage_b_free_select;
reg                         stage_b_has_match;
reg                         stage_b_has_free;
reg [2:0]                   stage_b_color;
reg [COORD_WIDTH-1:0]       stage_b_xmin;
reg [COORD_WIDTH-1:0]       stage_b_xmax;
reg [COORD_WIDTH-1:0]       stage_b_y;
reg [COORD_WIDTH:0]         stage_b_length;

wire [MAX_COMPONENTS-1:0] stage_b_selected =
    stage_b_has_match ? stage_b_match_select :
    (stage_b_has_free ? stage_b_free_select :
                        {MAX_COMPONENTS{1'b0}});
wire stage_b_writes_table =
    stage_b_valid && (stage_b_has_match || stage_b_has_free);
wire stage_b_wide=SEPARATE_NEUTRAL && stage_b_length>MAX_RUN_WIDTH;
wire stage_b_slot_loss=stage_b_valid && !stage_b_has_match && !stage_b_has_free && !stage_b_wide;

// Stage A: expensive geometry comparisons run in parallel and terminate at
// registers.  Extended coordinates avoid wrap at the right/bottom boundary.
//
// A valid stage-B write is forwarded into this view of the component table.
// This covers the shortest legal back-to-back RLE sequence, where a new run's
// comparison and the preceding run's stage-C write occur on the same edge.
// Without the bypass, two adjacent differently-coloured runs could both see
// one slot as free and the latter would overwrite the former.
reg [MAX_COMPONENTS-1:0] match_vector_comb;
reg [MAX_COMPONENTS-1:0] free_vector_comb;
reg [MAX_COMPONENTS-1:0] provisional_vector;
wire [COORD_WIDTH-1:0] view_xmin[0:MAX_COMPONENTS-1],view_xmax[0:MAX_COMPONENTS-1],view_y[0:MAX_COMPONENTS-1];
wire [COORD_WIDTH-1:0] view_previous_xmin[0:MAX_COMPONENTS-1],view_previous_xmax[0:MAX_COMPONENTS-1],view_previous_y[0:MAX_COMPONENTS-1];
wire [MAX_COMPONENTS-1:0] row_match,forward_row,view_previous_valid;
// With the production one-empty-row policy, share y-1/y-2 across
// all slots. Extended guards preserve the top-edge non-wrapping semantics.
wire [COORD_WIDTH-1:0] run_y_minus1=run_y-1'b1,run_y_minus2=run_y-2'd2;
// For margin1 and unsigned coordinates: a<=b+1 iff a==0 || a-1<=b.
// Subtract once from the incoming run, instead of adding at every stored bound.
wire [COORD_WIDTH-1:0] run_xmin_minus1=run_xmin-1'b1;
genvar rv;
generate for(rv=0;rv<MAX_COMPONENTS;rv=rv+1)begin:g_recent_rows
 assign forward_row[rv]=stage_b_writes_table&&stage_b_selected[rv];
 wire same_row=stage_b_has_match&&(stage_b_y==component_last_y[rv]);
 assign view_xmin[rv]=forward_row[rv]?
  ((same_row&&component_last_xmin[rv]<stage_b_xmin)?component_last_xmin[rv]:stage_b_xmin):component_last_xmin[rv];
 assign view_xmax[rv]=forward_row[rv]?
  ((same_row&&component_last_xmax[rv]>stage_b_xmax)?component_last_xmax[rv]:stage_b_xmax):component_last_xmax[rv];
 assign view_y[rv]=forward_row[rv]?stage_b_y:component_last_y[rv];
 wire new_row=forward_row[rv]&&stage_b_has_match&&!same_row;
 assign view_previous_valid[rv]=forward_row[rv]?
  (stage_b_has_match&&(new_row||previous_row_valid[rv])):previous_row_valid[rv];
 assign view_previous_xmin[rv]=new_row?component_last_xmin[rv]:previous_xmin[rv];
 assign view_previous_xmax[rv]=new_row?component_last_xmax[rv]:previous_xmax[rv];
 assign view_previous_y[rv]=new_row?component_last_y[rv]:previous_y[rv];
 wire overlap_current=((CONNECT_MARGIN==1)?((run_xmin==0)||(run_xmin_minus1<=view_xmax[rv])):({1'b0,run_xmin}<={1'b0,view_xmax[rv]}+CONNECT_MARGIN_EXT))&&
  ({1'b0,run_xmax}+CONNECT_MARGIN_EXT>={1'b0,view_xmin[rv]});
 wire overlap_previous=((CONNECT_MARGIN==1)?((run_xmin==0)||(run_xmin_minus1<=view_previous_xmax[rv])):({1'b0,run_xmin}<={1'b0,view_previous_xmax[rv]}+CONNECT_MARGIN_EXT))&&
  ({1'b0,run_xmax}+CONNECT_MARGIN_EXT>={1'b0,view_previous_xmin[rv]});
 wire recent_current=(run_y==view_y[rv]) ||
  (run_y>=1 && run_y_minus1==view_y[rv]) || (run_y>=2 && run_y_minus2==view_y[rv]);
 wire recent_previous=(run_y<=view_previous_y[rv]) ||
  (run_y>=1 && run_y_minus1==view_previous_y[rv]) || (run_y>=2 && run_y_minus2==view_previous_y[rv]);
 assign row_match[rv]=(MAX_EMPTY_ROWS==1)?
  (recent_current && (overlap_current ||
   ((run_y==view_y[rv]) && view_previous_valid[rv] && recent_previous && overlap_previous))):
  ((run_y>=view_y[rv]) && ({1'b0,run_y}<={1'b0,view_y[rv]}+MAX_EMPTY_ROWS+1) &&
   (overlap_current || ((run_y==view_y[rv]) && view_previous_valid[rv] &&
    ({1'b0,run_y}<={1'b0,view_previous_y[rv]}+MAX_EMPTY_ROWS+1) && overlap_previous)));

end endgenerate
integer compare_index;
always @* begin
    match_vector_comb = {MAX_COMPONENTS{1'b0}};
    free_vector_comb  = {MAX_COMPONENTS{1'b0}};
    provisional_vector = 0;

    for(compare_index = 0;
        compare_index < MAX_COMPONENTS;
        compare_index = compare_index + 1) begin
        if(stage_b_writes_table && stage_b_selected[compare_index]) begin
            free_vector_comb[compare_index] = 1'b0;
            match_vector_comb[compare_index] =
                (SEPARATE_NEUTRAL ? ((run_is_geometry==(compare_index>=MAX_COMPONENTS/2)) && (run_is_geometry || (stage_b_color == run_color))) : (INDEPENDENT_COLOR || (stage_b_color == run_color))) &&
                row_match[compare_index];
        end else begin
            // Narrow repeated speckles are still unqualified after one row.
            // Reuse only below the existing minimum area AND width, and only
            // for a longer incoming run when this population has no free slot.
            provisional_vector[compare_index] = RECLAIM_SPECKLES &&
                component_active[compare_index] &&
                ((SEPARATE_NEUTRAL && component_wide[compare_index] && run_length<=MAX_RUN_WIDTH) ||
                (component_area[compare_index]<MIN_COMPONENT_AREA &&
                ({1'b0,component_xmax[compare_index]}-{1'b0,component_xmin[compare_index]}+1)<MIN_SEED_RUN &&
                run_length>=MIN_SEED_RUN)) &&
                (!SEPARATE_NEUTRAL || (run_is_geometry==(compare_index>=MAX_COMPONENTS/2)));
            if(COLOR_PRIORITY && !SEPARATE_NEUTRAL && component_active[compare_index] &&
               component_color[compare_index]==5 && run_color>=1 && run_color<=4)
                provisional_vector[compare_index]=1;
            free_vector_comb[compare_index] =
                !component_active[compare_index] && (!SEPARATE_NEUTRAL || (run_is_geometry==(compare_index>=MAX_COMPONENTS/2)));
            match_vector_comb[compare_index] =
                component_active[compare_index] &&
                (SEPARATE_NEUTRAL ? ((run_is_geometry==(compare_index>=MAX_COMPONENTS/2)) && (run_is_geometry || (component_color[compare_index] == run_color))) : (INDEPENDENT_COLOR || (component_color[compare_index] == run_color))) &&
                row_match[compare_index];
        end
    end
    if(!( |free_vector_comb)) free_vector_comb=provisional_vector;
end

// Delay the RLE frame boundary beyond stage C.  When frame_done_d2 is
// observed by the sequential block, the last run was committed one cycle
// earlier at the same edge that produced frame_done_d2.
reg frame_done_d1;
reg frame_done_d2;
reg frame_new_d1;
reg frame_new_d2;

reg       scan_active;
reg [2:0] scan_index;
reg       scan_done_pending;

// Retirement and the end-of-frame scan are mutually exclusive. Share their
// wide payload read mux; keep the original table reset and writeback logic.
wire retire_emit = !scan_active && !frame_done_d2 && completed_valid &&
    component_active[retire_index] &&
    !(stage_b_writes_table && stage_b_selected[retire_index]) &&
    !(stage_a_valid && stage_a_matches[retire_index]) &&
    ({1'b0,completed_y} >
     ({1'b0,component_last_y[retire_index]} + MAX_EMPTY_ROWS));
wire [2:0] shared_emit_index=scan_active?scan_index:retire_index;

reg [2:0] color_write_index;
integer cw;
always @(posedge I_clk)begin
 if(!I_frame_start&&SEEDED_COLOR&&stage_b_writes_table&&color_write_index<MAX_COMPONENTS/2)
  core_area[color_write_index%(MAX_COMPONENTS/2)]<=
   (stage_b_has_match?core_area[color_write_index%(MAX_COMPONENTS/2)]:21'd0)+core_b;
end
always @* begin
    color_write_index=0;
    for(cw=0;cw<MAX_COMPONENTS;cw=cw+1)
        if(stage_b_selected[cw]) color_write_index=cw;
end
always @(posedge I_clk) begin
    if(!I_frame_start && INDEPENDENT_COLOR && !SEPARATE_NEUTRAL && stage_b_writes_table) begin
        red_area[color_write_index] <= (stage_b_has_match ? red_area[color_write_index] : 21'd0) + hist_b[0*HIST_W +: HIST_W];
        green_area[color_write_index] <= (stage_b_has_match ? green_area[color_write_index] : 21'd0) + hist_b[1*HIST_W +: HIST_W];
        blue_area[color_write_index] <= (stage_b_has_match ? blue_area[color_write_index] : 21'd0) + hist_b[2*HIST_W +: HIST_W];
        yellow_area[color_write_index] <= (stage_b_has_match ? yellow_area[color_write_index] : 21'd0) + hist_b[3*HIST_W +: HIST_W];
    end
end
// One selected slot is updated per run. Share its arithmetic; do not
// replicate saturation, width and gap adders eight times.
wire [AREA_WIDTH:0] selected_area_sum={1'b0,component_area[color_write_index]}+
 {{(AREA_WIDTH-COORD_WIDTH){1'b0}},stage_b_length};
wire [AREA_WIDTH-1:0] selected_area_next=selected_area_sum[AREA_WIDTH]?
 {AREA_WIDTH{1'b1}}:selected_area_sum[AREA_WIDTH-1:0];
wire [COORD_WIDTH-1:0] selected_xmin=stage_b_xmin<component_xmin[color_write_index]?stage_b_xmin:component_xmin[color_write_index];
wire [COORD_WIDTH-1:0] selected_xmax=stage_b_xmax>component_xmax[color_write_index]?stage_b_xmax:component_xmax[color_write_index];
wire [COORD_WIDTH:0] selected_box_width={1'b0,selected_xmax}-{1'b0,selected_xmin}+1'b1;
wire [COORD_WIDTH+1:0] selected_gap_limit={2'd0,component_last_xmax[color_write_index]}+
 2+({2'd0,max_width[color_write_index]}>>3);
wire selected_same_row=stage_b_y==component_last_y[color_write_index];
wire [COORD_WIDTH:0] selected_row_width=selected_same_row?
 ({1'b0,stage_b_xmax}-{1'b0,component_last_xmin[color_write_index]}+1'b1):stage_b_length;
wire [COORD_WIDTH-1:0] selected_ymin=stage_b_y<component_ymin[color_write_index]?stage_b_y:component_ymin[color_write_index];
wire [COORD_WIDTH-1:0] selected_ymax=stage_b_y>component_ymax[color_write_index]?stage_b_y:component_ymax[color_write_index];
wire [COORD_WIDTH-1:0] selected_last_xmin=stage_b_xmin<component_last_xmin[color_write_index]?stage_b_xmin:component_last_xmin[color_write_index];
wire [COORD_WIDTH-1:0] selected_last_xmax=stage_b_xmax>component_last_xmax[color_write_index]?stage_b_xmax:component_last_xmax[color_write_index];
wire selected_first_row=stage_b_y==component_ymin[color_write_index];
wire selected_peak=selected_row_width>max_width[color_write_index];

// Single encoded write port for valid component payload. Tags retain all
// asynchronous/frame reset semantics; allocation initializes every field.
// Payload of unowned slots is intentionally unspecified and never published
// as PRESENT. No extra clock or output-record latency is introduced.
always @(posedge I_clk) begin
 if(!I_frame_start && stage_b_valid) begin
  if(stage_b_has_match) begin
   component_area[color_write_index]<=selected_area_next;
   component_xmin[color_write_index]<=selected_xmin;
   component_xmax[color_write_index]<=selected_xmax;
   component_ymin[color_write_index]<=selected_ymin;
   component_ymax[color_write_index]<=selected_ymax;
   if(!selected_same_row) begin
    previous_xmin[color_write_index]<=component_last_xmin[color_write_index];
    previous_xmax[color_write_index]<=component_last_xmax[color_write_index];
    previous_y[color_write_index]<=component_last_y[color_write_index];
    component_last_xmin[color_write_index]<=stage_b_xmin;
    component_last_xmax[color_write_index]<=stage_b_xmax;
   end else begin
    component_last_xmin[color_write_index]<=selected_last_xmin;
    component_last_xmax[color_write_index]<=selected_last_xmax;
   end
   component_last_y[color_write_index]<=stage_b_y;
   last_width[color_write_index]<=selected_row_width;
   if(selected_first_row)first_width[color_write_index]<=selected_row_width;
   if(selected_peak)begin max_width[color_write_index]<=selected_row_width;peak_y[color_write_index]<=stage_b_y;end
  end else if(stage_b_has_free) begin
   first_width[color_write_index]<=stage_b_length;
   last_width[color_write_index]<=stage_b_length;
   max_width[color_write_index]<=stage_b_length;
   peak_y[color_write_index]<=stage_b_y;
   component_color[color_write_index]<=stage_b_color;
   component_area[color_write_index]<={{(AREA_WIDTH-COORD_WIDTH-1){1'b0}},stage_b_length};
   component_xmin[color_write_index]<=stage_b_xmin;
   component_ymin[color_write_index]<=stage_b_y;
   component_xmax[color_write_index]<=stage_b_xmax;
   component_ymax[color_write_index]<=stage_b_y;
   component_last_xmin[color_write_index]<=stage_b_xmin;
   component_last_xmax[color_write_index]<=stage_b_xmax;
   component_last_y[color_write_index]<=stage_b_y;
  end
 end
end

// Eight support points, quantized to the native 320x180 preview grid.
// Only 99 bits per occupied slot are additional; axis bounds/last run are
// reused. Allocation initializes payload, so no frame-wide RAM reset is needed.
wire [143:0] geometry_read;
generate if(GEOMETRY)begin:g_geometry
 reg [8:0] north_x[0:MAX_COMPONENTS-1],east_y[0:MAX_COMPONENTS-1],west_y[0:MAX_COMPONENTS-1];
 reg [17:0] ne[0:MAX_COMPONENTS-1],se[0:MAX_COMPONENTS-1],sw[0:MAX_COMPONENTS-1],nw[0:MAX_COMPONENTS-1];
 wire [8:0] left_x=stage_b_xmin>>2,right_x=stage_b_xmax>>2,row_y=stage_b_y>>2;
 wire [9:0] sum_left={1'b0,left_x}+{1'b0,row_y},sum_right={1'b0,right_x}+{1'b0,row_y};
 wire signed [9:0] diff_left=$signed({1'b0,left_x})-$signed({1'b0,row_y});
 wire signed [9:0] diff_right=$signed({1'b0,right_x})-$signed({1'b0,row_y});
 wire [17:0] old_ne=ne[color_write_index],old_se=se[color_write_index],old_sw=sw[color_write_index],old_nw=nw[color_write_index];
 wire signed [9:0] old_ne_diff=$signed({1'b0,old_ne[8:0]})-$signed({1'b0,old_ne[17:9]});
 wire signed [9:0] old_sw_diff=$signed({1'b0,old_sw[8:0]})-$signed({1'b0,old_sw[17:9]});
 wire [9:0] old_se_sum={1'b0,old_se[8:0]}+{1'b0,old_se[17:9]};
 wire [9:0] old_nw_sum={1'b0,old_nw[8:0]}+{1'b0,old_nw[17:9]};
 always @(posedge I_clk)if(!I_frame_start && stage_b_writes_table)begin
  if(!stage_b_has_match)begin
   north_x[color_write_index]<=left_x;east_y[color_write_index]<=row_y;west_y[color_write_index]<=row_y;
   ne[color_write_index]<={row_y,right_x};se[color_write_index]<={row_y,right_x};
   sw[color_write_index]<={row_y,left_x};nw[color_write_index]<={row_y,left_x};
  end else begin
   if(stage_b_xmax>component_xmax[color_write_index])east_y[color_write_index]<=row_y;
   if(stage_b_xmin<component_xmin[color_write_index])west_y[color_write_index]<=row_y;
   if(diff_right>old_ne_diff)ne[color_write_index]<={row_y,right_x};
   if(sum_right>old_se_sum)se[color_write_index]<={row_y,right_x};
   if(diff_left<old_sw_diff)sw[color_write_index]<={row_y,left_x};
   if(sum_left<old_nw_sum)nw[color_write_index]<={row_y,left_x};
  end
 end
 wire [8:0] north_y=component_ymin[shared_emit_index]>>2;
 wire [8:0] south_y=component_ymax[shared_emit_index]>>2;
 wire [8:0] south_x=component_last_xmin[shared_emit_index]>>2;
 wire [8:0] east_x=component_xmax[shared_emit_index]>>2;
 wire [8:0] west_x=component_xmin[shared_emit_index]>>2;
 assign geometry_read={nw[shared_emit_index],{west_y[shared_emit_index],west_x},sw[shared_emit_index],
  {south_y,south_x},se[shared_emit_index],{east_y[shared_emit_index],east_x},ne[shared_emit_index],{north_y,north_x[shared_emit_index]}};
end else begin:g_no_geometry
 assign geometry_read=144'd0;
end endgenerate

integer state_index;
// Require an absolute seed population tied to the minimum accepted object,
// rather than penalizing a larger connected weak body for the same seed patch.
localparam integer MIN_CORE_AREA=(MIN_COMPONENT_AREA>>3)>0 ? (MIN_COMPONENT_AREA>>3) : 1;
// Emit completed components as a stream; only the final frame-scan record
// carries LAST. Slot indices may be reused within a frame.
task emit_component;
    input [2:0] idx;
    begin
        O_component_strobe <= source_new;
        O_geometry <= geometry_read;
        O_component_index <= idx;
        O_component_present <= component_active[idx];
        O_component_reject_reason <= {
            (SEPARATE_NEUTRAL && (component_wide[idx] || (idx>=MAX_COMPONENTS/2 && component_has_gap[idx]))),
            (SEEDED_COLOR && idx<MAX_COMPONENTS/2 && core_area[idx%(MAX_COMPONENTS/2)]<MIN_CORE_AREA)};
        O_component_active <= component_active[idx] && !(SEPARATE_NEUTRAL && component_wide[idx]) && !(SEPARATE_NEUTRAL && idx>=MAX_COMPONENTS/2 && component_has_gap[idx]) &&
            (!SEEDED_COLOR || idx>=MAX_COMPONENTS/2 || core_area[idx%(MAX_COMPONENTS/2)]>=MIN_CORE_AREA);
        O_component_color <= SEPARATE_NEUTRAL ? ((idx>=MAX_COMPONENTS/2)?3'd0:component_color[idx]) : INDEPENDENT_COLOR ? color_vote(idx) : component_color[idx];
        O_component_area <= component_area[idx];
        O_component_xmin <= component_xmin[idx];
        O_component_ymin <= component_ymin[idx];
        O_component_xmax <= component_xmax[idx];
        O_component_ymax <= component_ymax[idx];
        O_first_width <= first_width[idx];
        O_last_width <= last_width[idx];
        O_max_width <= max_width[idx];
        O_peak_y <= peak_y[idx];
        component_active[idx] <= 1'b0;
    end
endtask
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        source_new <= 0;
        retire_index <= 0;
        line_end_delay <= 0;
        ended_y <= 0;
        completed_y <= 0;
        completed_valid <= 0;
        O_component_last <= 0;
        O_first_width <= 0; O_last_width <= 0;
        O_max_width <= 0; O_peak_y <= 0;
        stage_a_valid        <= 1'b0;
        stage_a_matches      <= {MAX_COMPONENTS{1'b0}};
        stage_a_frees        <= {MAX_COMPONENTS{1'b0}};
        stage_a_color        <= 2'd0;
        stage_a_xmin         <= {COORD_WIDTH{1'b0}};
        stage_a_xmax         <= {COORD_WIDTH{1'b0}};
        stage_a_y            <= {COORD_WIDTH{1'b0}};
        stage_a_length       <= {(COORD_WIDTH+1){1'b0}};

        stage_b_valid        <= 1'b0;
        stage_b_match_select <= {MAX_COMPONENTS{1'b0}};
        stage_b_all_matches <= 0;
        stage_b_free_select  <= {MAX_COMPONENTS{1'b0}};
        stage_b_has_match    <= 1'b0;
        stage_b_has_free     <= 1'b0;
        stage_b_color        <= 2'd0;
        stage_b_xmin         <= {COORD_WIDTH{1'b0}};
        stage_b_xmax         <= {COORD_WIDTH{1'b0}};
        stage_b_y            <= {COORD_WIDTH{1'b0}};
        stage_b_length       <= {(COORD_WIDTH+1){1'b0}};

        frame_done_d1        <= 1'b0;
        frame_done_d2        <= 1'b0;
        frame_new_d1         <= 1'b0;
        frame_new_d2         <= 1'b0;
        scan_active          <= 1'b0;
        scan_index           <= 3'd0;
        scan_done_pending    <= 1'b0;

        O_component_strobe   <= 1'b0;
        O_component_index    <= 3'd0;
        O_component_active   <= 1'b0;
        O_component_present <= 0;O_component_reject_reason<=0;
        O_component_color    <= 2'd0;
        O_component_area     <= 21'd0;
        O_component_xmin     <= {COORD_WIDTH{1'b0}};
        O_component_ymin     <= {COORD_WIDTH{1'b0}};
        O_component_xmax     <= {COORD_WIDTH{1'b0}};
        O_component_ymax     <= {COORD_WIDTH{1'b0}};
        O_scan_done          <= 1'b0;
        O_overflow           <= 1'b0;

        for(state_index = 0;
            state_index < MAX_COMPONENTS;
            state_index = state_index + 1) begin
            component_active[state_index]    <= 1'b0;
            component_has_gap[state_index] <= 0;
            component_wide[state_index] <= 0;
            previous_row_valid[state_index] <= 0;

        end
    end else begin
        O_component_last <= 0;
        if(queue_overflow)O_overflow<=1;
        line_end_delay <= {line_end_delay[6:0], I_line_end};
        if(I_line_end) ended_y <= I_y;
        if(line_end_delay[7]) begin
            completed_y <= ended_y;
            completed_valid <= 1;
        end
        retire_index <= (retire_index == MAX_COMPONENTS-1) ? 0 : retire_index + 1'b1;
        O_component_strobe <= 1'b0;
        O_scan_done        <= scan_done_pending;
        scan_done_pending  <= 1'b0;

        frame_done_d1 <= run_frame_done;
        frame_done_d2 <= frame_done_d1;
        frame_new_d1  <= run_frame_is_new;
        frame_new_d2  <= frame_new_d1;

        // Stage A registers the comparator bank result and its run payload.
        stage_a_valid <= run_valid;
        if(run_valid) begin
            stage_a_matches <= match_vector_comb;
            stage_a_frees   <= free_vector_comb;
            stage_a_color   <= run_color;
            stage_a_xmin    <= run_xmin;
            stage_a_xmax    <= run_xmax;
            stage_a_y       <= run_y;
            stage_a_length  <= run_length;
        end

        // Stage B registers the priority result.  A match always wins over a
        // free slot, preserving accumulation of an existing object.
        stage_b_valid <= stage_a_valid;
        if(stage_a_valid) begin
            stage_b_has_match    <= |stage_a_matches;
            stage_b_has_free     <= |stage_a_frees;
            stage_b_match_select <= stage_a_first_match;
            stage_b_all_matches <= stage_a_matches;
            stage_b_free_select  <= stage_a_first_free;
            stage_b_color        <= stage_a_color;
            stage_b_xmin         <= stage_a_xmin;
            stage_b_xmax         <= stage_a_xmax;
            stage_b_y            <= stage_a_y;
            stage_b_length       <= stage_a_length;
        end

        if(I_frame_start) begin
            source_new <= I_frame_is_new;
            completed_valid <= 0;
            line_end_delay <= 0;
            retire_index <= 0;
            // Frame start is the recovery/ownership boundary for the table.
            // It also cancels any stale pipeline or scan state.
            stage_a_valid     <= 1'b0;
            stage_b_valid     <= 1'b0;
            frame_done_d1     <= 1'b0;
            frame_done_d2     <= 1'b0;
            frame_new_d1      <= 1'b0;
            frame_new_d2      <= 1'b0;
            scan_active       <= 1'b0;
            scan_index        <= 3'd0;
            scan_done_pending <= 1'b0;
            O_overflow        <= 1'b0;

            for(state_index = 0;
                state_index < MAX_COMPONENTS;
                state_index = state_index + 1) begin
                component_active[state_index]    <= 1'b0;
            component_has_gap[state_index] <= 0;
                component_wide[state_index] <= 0;

            end
        end else begin
            // A slot expires only after the last connectable row has fully
            // drained through RLE and the writeback pipeline. This scan also
            // works with zero horizontal blanking and never steals a run.
            // Stage C uses static per-slot write enables.  The area increment
            // is saturating so a pathological mask cannot wrap to a small
            // object and pass the downstream size filter.
            if(stage_b_valid) begin
                // A wide bridge invalidates every prefix it touches in this
                // population, including non-selected matches. Other hues and
                // the independent colour/geometry population are unaffected.
                if(stage_b_wide)begin
                    for(state_index=0;state_index<MAX_COMPONENTS;state_index=state_index+1)
                        if(stage_b_all_matches[state_index])component_wide[state_index]<=1;
                end
                if(stage_b_has_match) begin
                    for(state_index = 0;
                        state_index < MAX_COMPONENTS;
                        state_index = state_index + 1) begin
                        if(stage_b_match_select[state_index]) begin

                            if(SEPARATE_NEUTRAL && (stage_b_wide || selected_box_width>MAX_RUN_WIDTH)) component_wide[state_index]<=1;
                            if(stage_b_y==component_last_y[state_index] && {2'd0,stage_b_xmin}>selected_gap_limit) component_has_gap[state_index]<=1;
                            if(!selected_same_row) previous_row_valid[state_index]<=1;

end
                    end
                end else if(stage_b_has_free) begin
                    for(state_index = 0;
                        state_index < MAX_COMPONENTS;
                        state_index = state_index + 1) begin
                        if(stage_b_free_select[state_index]) begin

                            component_active[state_index]<=1;
                            component_has_gap[state_index]<=0;
                            component_wide[state_index]<=stage_b_wide;
                            previous_row_valid[state_index]<=0;

end
                    end
                end else if(!stage_b_wide) begin
                    O_overflow <= 1'b1;
                end
            end

            // Begin a result-table scan only after both CCL pipeline stages
            // following the RLE boundary have drained.  Repeated DDR display
            // frames are deliberately ignored.
            // Retirement excludes any write to its selected slot, so moving
            // its inactive-tag clear here preserves write priority. Scan
            // emission remains after stage C, exactly as in the original.
            if(retire_emit || scan_active)
                emit_component(shared_emit_index);
            if(frame_done_d2 && frame_new_d2 && !scan_active) begin
                scan_active <= 1'b1;
                scan_index  <= 3'd0;
            end else if(scan_active) begin
                O_component_last <= (scan_index == MAX_COMPONENTS-1);

                if(scan_index == (MAX_COMPONENTS-1)) begin
                    scan_active       <= 1'b0;
                    scan_done_pending <= 1'b1;
                end else begin
                    scan_index <= scan_index + 1'b1;
                end
            end
        end
    end
end

// Keep the RLE line event intentionally visible to synthesis/lint without
// adding control logic; all component joining is driven by run_y.
wire _unused_run_line_done = run_line_done;

always @(posedge I_clk or negedge I_rst_n) begin
 if(!I_rst_n) slot_overflow<=0;
 else if(I_frame_start)slot_overflow<=0;
 else if(stage_b_slot_loss)slot_overflow<=1;
end
generate if(DEBUG)begin:g_counters
 reg [15:0] slots,queues,allocations,emitted,reclaimed,wide;
 assign O_slot_drops=slots;assign O_queue_drops=queues;assign O_allocations=allocations;
 assign O_emitted=emitted;assign O_reclaimed=reclaimed;assign O_wide_runs=wide;
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin slots<=0;queues<=0;allocations<=0;
   emitted<=0;reclaimed<=0;wide<=0;end
  else if(I_frame_start)begin slots<=0;queues<=0;allocations<=0;
   emitted<=0;reclaimed<=0;wide<=0;end
  else begin
   if(stage_b_slot_loss && slots!=65535)slots<=slots+1'b1;
   if(queue_drop && queues!=65535)queues<=queues+1'b1;
   if(stage_b_valid && !stage_b_has_match && stage_b_has_free)begin
    if(allocations!=65535)allocations<=allocations+1'b1;
    if((stage_b_free_select & O_slot_active)!=0 && reclaimed!=65535)reclaimed<=reclaimed+1'b1;
   end
   if(O_component_strobe && O_component_active && emitted!=65535)emitted<=emitted+1'b1;
   if(wide_events!=0 && wide<65533)wide<=wide+wide_events;
  end
 end
end else begin:g_no_counters
 assign O_slot_drops=0;assign O_queue_drops=0;assign O_allocations=0;
 assign O_emitted=0;assign O_reclaimed=0;assign O_wide_runs=0;
end endgenerate

endmodule
