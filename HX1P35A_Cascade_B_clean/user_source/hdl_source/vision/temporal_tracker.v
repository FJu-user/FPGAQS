`timescale 1ns/1ps
// Serial 4x4 nearest-position association in blanking (<110 clocks/frame).
// Separate read, absolute-difference, distance, selection and write stages.
// Only completed NEW source frames enter this module.
module temporal_tracker #(
    parameter integer CONFIRM_FRAMES=2, HOLD_FRAMES=2, MATCH_DISTANCE=80, CAMERA_ASSOCIATION=0
)(
    input wire clk, rst_n, clear,
    input wire strobe, last,
    input wire [2:0] index,
    input wire [75:0] record_in,
    output reg out_strobe, out_last,
    output reg [2:0] out_index,
    output reg [75:0] record_out
);
// Reset tags mask uninitialized RAM words; no record is read as live until
// written. One write port and one asynchronous read port per 4-word table.
reg [75:0] candidates[0:3], tracks[0:3];
reg [3:0] candidate_written,track_written;
wire [1:0] track_read_index=(state==2)?probe:cursor;
wire [75:0] probe_track=track_written[track_read_index]?tracks[track_read_index]:76'd0;
wire [75:0] cursor_candidate=candidate_written[cursor]?candidates[cursor]:76'd0;
wire can_start_track=!CAMERA_ASSOCIATION || candidate[71:69]!=0;
wire write_track=(state==6)&&candidate[75]&&(found||(free_found&&can_start_track));
wire [1:0] write_track_index=found?chosen:free_slot;
reg[2:0] confirmed_shape[0:3],pending_color[0:3];
reg[3:0] unknown_seen;
wire same_color=candidate[74:72]==pending_color[chosen];
wire [2:0] write_shape=!found?candidate[71:69]:
 (candidate[71:69]==0)?((same_color&&!unknown_seen[chosen])?confirmed_shape[chosen]:3'd0):
 (candidate[71:69]!=pending_shape[chosen])?3'd0:candidate[71:69];
wire[12:0] candidate_width={1'b0,candidate[23:12]}-{1'b0,candidate[47:36]}+13'd1;
wire[12:0] candidate_height={1'b0,candidate[11:0]}-{1'b0,candidate[35:24]}+13'd1;
wire[12:0] track_width={1'b0,probe_track[23:12]}-{1'b0,probe_track[47:36]}+13'd1;
wire[12:0] track_height={1'b0,probe_track[11:0]}-{1'b0,probe_track[35:24]}+13'd1;
wire size_matches=({1'b0,candidate_width}<=({1'b0,track_width}<<1))&&
 ({1'b0,track_width}<=({1'b0,candidate_width}<<1))&&
 ({1'b0,candidate_height}<=({1'b0,track_height}<<1))&&
 ({1'b0,track_height}<=({1'b0,candidate_height}<<1));
// For a nearby same-hue circular track, expand immediately to cover the
// latest measurement and contract slowly through quantization/glare noise.
// A camera pan beyond 32 analysis pixels of centre motion bypasses smoothing.
wire [75:0] matched_track=tracks[chosen];
wire stabilize_bounds=CAMERA_ASSOCIATION && found && best_color_match &&
 best_distance<=64 && candidate[71:69]==1 && matched_track[71:69]==1;
function [11:0] slow_edge;
 input [11:0] previous,current;reg[13:0] sum;
 begin sum=({2'b0,previous}<<1)+{2'b0,previous}+{2'b0,current};slow_edge=sum[13:2];end
endfunction
wire [11:0] stable_xmin=candidate[47:36]<matched_track[47:36]?candidate[47:36]:slow_edge(matched_track[47:36],candidate[47:36]);
wire [11:0] stable_ymin=candidate[35:24]<matched_track[35:24]?candidate[35:24]:slow_edge(matched_track[35:24],candidate[35:24]);
wire [11:0] stable_xmax=candidate[23:12]>matched_track[23:12]?candidate[23:12]:slow_edge(matched_track[23:12],candidate[23:12]);
wire [11:0] stable_ymax=candidate[11:0]>matched_track[11:0]?candidate[11:0]:slow_edge(matched_track[11:0],candidate[11:0]);
wire [47:0] write_bbox=stabilize_bounds?{stable_xmin,stable_ymin,stable_xmax,stable_ymax}:candidate[47:0];
always @(posedge clk) begin
    if(rst_n && !clear) begin
        if(state==0 && strobe) candidates[index[1:0]]<=record_in;
        if(write_track)begin
            tracks[write_track_index]<={1'b1,candidate[74:72],write_shape,candidate[68:48],write_bbox};
            pending_color[write_track_index]<=candidate[74:72];
            if(!found)confirmed_shape[write_track_index]<=0;
            else if(candidate[71:69]!=0)confirmed_shape[write_track_index]<=write_shape;
            else if(unknown_seen[chosen]||!same_color)confirmed_shape[write_track_index]<=0;
        end
    end
end
reg [3:0] age[0:3], misses[0:3];
reg [2:0] pending_shape[0:3];
reg [3:0] used;
reg [3:0] state;
reg [1:0] cursor, probe, chosen, free_slot;
reg found,free_found,eligible;
reg best_color_match;
reg eligible_color_match;
wire probe_color_match=candidate[74:72]!=0 && candidate[74:72]==probe_track[74:72];
reg [75:0] candidate;
reg [12:0] cx,cy,tx,ty,dx,dy;
reg [13:0] distance,best_distance;

integer j;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=0; cursor<=0; probe<=0;used<=0;
        chosen<=0;free_slot<=0;found<=0;free_found<=0;eligible<=0;
        best_color_match<=0;eligible_color_match<=0;
        candidate<=0;cx<=0;cy<=0;tx<=0;ty<=0;dx<=0;dy<=0;distance<=0;best_distance<=0;
        out_strobe<=0; out_last<=0; out_index<=0; record_out<=0;
        candidate_written<=0;track_written<=0;
        unknown_seen<=0;
        for(j=0;j<4;j=j+1) begin
            age[j]<=0; misses[j]<=0;
            pending_shape[j]<=0;
        end
    end else if(clear) begin
        state<=0; cursor<=0; used<=0; out_strobe<=0; out_last<=0;
        candidate_written<=0;track_written<=0;
        unknown_seen<=0;
        for(j=0;j<4;j=j+1) begin
            age[j]<=0; misses[j]<=0;
            pending_shape[j]<=0;
        end
    end else begin
        out_strobe<=0; out_last<=0;
        case(state)
        0: if(strobe) begin
            candidate_written[index[1:0]]<=1;
            if(last) begin state<=1; cursor<=0; used<=0; end
        end
        1: begin
            candidate<=cursor_candidate;
            found<=0;free_found<=0;probe<=0;best_distance<=2*MATCH_DISTANCE+1;best_color_match<=0;
            state<=2;
        end
        2: begin
            cx<={1'b0,candidate[47:36]}+{1'b0,candidate[23:12]};
            cy<={1'b0,candidate[35:24]}+{1'b0,candidate[11:0]};
            tx<={1'b0,probe_track[47:36]}+{1'b0,probe_track[23:12]};
            ty<={1'b0,probe_track[35:24]}+{1'b0,probe_track[11:0]};
            eligible<=candidate[75] && probe_track[75] && !used[probe] && size_matches &&
                (!CAMERA_ASSOCIATION || candidate[74:72]==0 || probe_track[74:72]==0 || probe_color_match);
            eligible_color_match<=probe_color_match;
            if(!probe_track[75] && !used[probe] && !free_found) begin
                free_found<=1;free_slot<=probe;
            end
            state<=3;
        end
        3: begin
            dx<=cx>=tx ? cx-tx : tx-cx;
            dy<=cy>=ty ? cy-ty : ty-cy;
            state<=4;
        end
        4: begin distance<={1'b0,dx}+{1'b0,dy};state<=5;end
        5: begin
            // Prefer the same reliable hue when nearby objects cross. Fall
            // back to position for real colour changes or neutral objects.
            if(eligible && (distance<=2*MATCH_DISTANCE || (CAMERA_ASSOCIATION && eligible_color_match && candidate[71:69]!=0)) &&
               ((!found) || (eligible_color_match&&!best_color_match) ||
                (eligible_color_match==best_color_match && distance<best_distance))) begin
                found<=1;chosen<=probe;best_distance<=distance;best_color_match<=eligible_color_match;
            end
            if(probe==3) state<=6;
            else begin probe<=probe+1'b1;state<=2;end
        end
        6: begin
            // Exact current-frame bounds; temporal confirmation/debounce remains.
            for(j=0;j<4;j=j+1) begin
                if(candidate[75] && found && chosen==j) begin
                    used[j]<=1; misses[j]<=0;
                    if(age[j]<CONFIRM_FRAMES) age[j]<=age[j]+1'b1;
                    if(candidate[71:69]!=0)begin pending_shape[j]<=candidate[71:69];unknown_seen[j]<=0;end
                    else begin
                        unknown_seen[j]<=1;
                        if(unknown_seen[j]||!same_color||confirmed_shape[j]==0)pending_shape[j]<=0;
                    end
                end else if(candidate[75] && !found && free_found && can_start_track && free_slot==j) begin
                    track_written[j]<=1; age[j]<=1; misses[j]<=0; used[j]<=1;
                    pending_shape[j]<=candidate[71:69];
                    unknown_seen[j]<=0;
                end
            end
            if(cursor==3) begin state<=7; cursor<=0; end
            else begin cursor<=cursor+1'b1;state<=1;end
        end
        7: begin
            for(j=0;j<4;j=j+1) begin
                if(cursor==j && track_written[j] && !used[j]) begin
                    if(age[j]<CONFIRM_FRAMES || misses[j]>=HOLD_FRAMES) begin
                        track_written[j]<=0;age[j]<=0;misses[j]<=0;
                    end else misses[j]<=misses[j]+1'b1;
                end
            end
            if(cursor==3) begin state<=8;cursor<=0;end
            else cursor<=cursor+1'b1;
        end
        8: begin
            out_strobe<=1;out_last<=(cursor==3);out_index<={1'b0,cursor};
            record_out<=probe_track;
            record_out[75]<=probe_track[75] && age[cursor]>=CONFIRM_FRAMES &&
                (CAMERA_ASSOCIATION ? probe_track[71:69]!=0 :
                 (probe_track[74:72]!=0 || probe_track[71:69]!=0));
            if(cursor==3) begin state<=0;cursor<=0;end
            else cursor<=cursor+1'b1;
        end
        default: state<=0;
        endcase
    end
end
endmodule
