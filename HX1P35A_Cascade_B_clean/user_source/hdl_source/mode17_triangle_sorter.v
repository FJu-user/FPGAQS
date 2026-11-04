`timescale 1ns/1ps
// Passive atomic-result consumer; no writes/backpressure to vision/network.
// Positional servo SIGNAL ONLY, J2.7/GPIOB6/F14, 3.3 V. Independent servo supply.
// SG90 candidate: actual input compatibility, power and endpoints need bench validation.
module mode17_triangle_sorter #(
    parameter integer CLOCK_HZ=100000000,
    parameter integer RESULT_TIMEOUT_MS=1000,
    parameter integer CONFIRM_MS=250,
    parameter integer CLEAR_MS=1000,
    parameter integer HOLD_MS=2500,
    parameter integer RETURN_MS=300,
    // Conservative initial travel, not guaranteed angles. Change only after unloaded calibration.
    parameter integer CENTER_US=1500,
    parameter integer YELLOW_US=1200,
    parameter integer BLUE_US=1800,
    parameter integer ROI_X_MIN=128, ROI_X_MAX=1151,
    parameter integer ROI_Y_MIN=72, ROI_Y_MAX=647
)(
    input wire clk,rst_n,enable,
    input wire [31:0] control_epoch,
    input wire result_update,result_valid,result_overflow,
    input wire [31:0] result_epoch,source_id,
    input wire [3:0] object_count,
    input wire [255:0] objects,
    output wire servo_pwm,
    output wire [511:0] diagnostic
);
    function integer bits_for;
        input integer n;integer v;
        begin bits_for=1;v=n-1;while(v>1)begin bits_for=bits_for+1;v=v>>1;end end
    endfunction
    function [11:0] bounded_us;
        input integer us;
        begin if(us<1000)bounded_us=1000;else if(us>2000)bounded_us=2000;else bounded_us=us;end
    endfunction
    localparam integer US_CYCLES=CLOCK_HZ/1000000;
    reg [bits_for(US_CYCLES)-1:0] us_div;
    wire us_tick=us_div==US_CYCLES-1;
    reg [9:0] ms_div;
    wire ms_tick=us_tick && ms_div==999;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin us_div<=0;ms_div<=0;end
        else if(us_tick)begin
            us_div<=0;
            if(ms_div==999)ms_div<=0;else ms_div<=ms_div+1'b1;
        end else us_div<=us_div+1'b1;
    end

    wire [63:0] o=objects[63:0];
    wire [11:0] x0=o[56:45],y0=o[44:33],x1=o[32:21],y1=o[20:9];
    wire [12:0] cx2={1'b0,x0}+{1'b0,x1},cy2={1'b0,y0}+{1'b0,y1};
    wire bbox_good=object_count==1 && o[63] && x0<=x1 && y0<=y1 && x1<1280 && y1<720;
    wire target_good=bbox_good && o[59:57]==3'd2 && (o[62:60]==3'd3 || o[62:60]==3'd4) &&
        cx2>=ROI_X_MIN*2 && cx2<=ROI_X_MAX*2 && cy2>=ROI_Y_MIN*2 && cy2<=ROI_Y_MAX*2;
    // Register the predicate before watchdog/state logic, aligned with the mailbox.
    reg update_q,valid_q,overflow_q,target_q;
    reg [3:0] count_q;
    reg [2:0] color_q;
    reg [31:0] source_q,epoch_q;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            update_q<=0;valid_q<=0;overflow_q<=0;target_q<=0;count_q<=0;color_q<=0;source_q<=0;epoch_q<=0;
        end else begin
            update_q<=result_update;valid_q<=result_valid;overflow_q<=result_overflow;
            target_q<=target_good;count_q<=object_count;color_q<=o[62:60];source_q<=source_id;epoch_q<=result_epoch;
        end
    end
    reg [31:0] session_q,last_source;
    reg have_source,data_valid;
    reg [bits_for(RESULT_TIMEOUT_MS+1)-1:0] age_ms;
    reg scene_empty;
    reg [2:0] candidate;
    reg two_frames;
    reg [bits_for(CONFIRM_MS+1)-1:0] confirm_ms;
    wire session_ok=enable && session_q==control_epoch;
    wire [31:0] source_delta=source_q-last_source;
    wire forward_source=(!have_source || (source_delta!=0 && !source_delta[31]));
    // User-confirmed 2026-11-03 policy: act on final recognized objects.
    // Pipeline overflow describes pre-filter CCL/ranking capacity. Keep it in
    // telemetry; freshness/format/session/timeout checks still gate commands.
    wire fresh=update_q && valid_q && count_q<=4 &&
        epoch_q==control_epoch && forward_source;
    wire healthy=session_ok && data_valid && age_ms<RESULT_TIMEOUT_MS;
    wire invalid_update=update_q && (!valid_q || count_q>4 || epoch_q!=control_epoch);
    wire new_mismatch=fresh && (!target_q || color_q!=candidate);
    wire qualified=healthy && !invalid_update && !new_mismatch && candidate!=0 && two_frames && confirm_ms>=CONFIRM_MS;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            session_q<=0;last_source<=0;have_source<=0;data_valid<=0;age_ms<=RESULT_TIMEOUT_MS;
            scene_empty<=0;candidate<=0;two_frames<=0;confirm_ms<=0;
        end else begin
            session_q<=control_epoch;
            if(!session_ok)begin
                last_source<=source_q;have_source<=valid_q && epoch_q==control_epoch;
                data_valid<=0;age_ms<=RESULT_TIMEOUT_MS;scene_empty<=0;candidate<=0;two_frames<=0;confirm_ms<=0;
            end else if(invalid_update)begin
                data_valid<=0;scene_empty<=0;candidate<=0;two_frames<=0;confirm_ms<=0;
            end else begin
                if(ms_tick)begin
                    if(age_ms<RESULT_TIMEOUT_MS)age_ms<=age_ms+1'b1;
                    if(healthy && candidate!=0 && confirm_ms<CONFIRM_MS)confirm_ms<=confirm_ms+1'b1;
                    if(age_ms>=RESULT_TIMEOUT_MS-1)begin
                        data_valid<=0;scene_empty<=0;candidate<=0;two_frames<=0;confirm_ms<=0;
                    end
                end
                if(fresh)begin
                    last_source<=source_q;have_source<=1;data_valid<=1;age_ms<=0;
                    scene_empty<=count_q==0;
                    if(target_q)begin
                        if(candidate!=color_q || !healthy)begin candidate<=color_q;two_frames<=0;confirm_ms<=0;end
                        else two_frames<=1;
                    end else begin candidate<=0;two_frames<=0;confirm_ms<=0;end
                end
            end
        end
    end

    localparam [1:0] WAIT_CLEAR=0,READY=1,SORT_HOLD=2,RETURN_CENTER=3;
    reg [1:0] state;
    reg [2:0] selected_color;
    reg [bits_for(CLEAR_MS+1)-1:0] clear_ms;
    reg [bits_for(HOLD_MS+1)-1:0] hold_ms;
    reg [bits_for(RETURN_MS+1)-1:0] return_ms;
    wire empty_now=healthy && scene_empty && !invalid_update && !(fresh && count_q!=0);
    // No outlet feedback: these are commanded routes, never confirmed sort counts.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin state<=WAIT_CLEAR;selected_color<=0;clear_ms<=0;hold_ms<=0;return_ms<=0;end
        else if(!healthy || invalid_update)begin
            state<=WAIT_CLEAR;selected_color<=0;clear_ms<=0;hold_ms<=0;return_ms<=0;
        end else begin
            if(!empty_now)clear_ms<=0;
            else if(ms_tick && clear_ms<CLEAR_MS)clear_ms<=clear_ms+1'b1;
            case(state)
                WAIT_CLEAR:begin
                    selected_color<=0;hold_ms<=0;return_ms<=0;
                    if(empty_now && clear_ms>=CLEAR_MS)state<=READY;
                end
                READY:begin
                    if(qualified)begin
                        selected_color<=candidate;state<=SORT_HOLD;hold_ms<=0;clear_ms<=0;
                    end
                end
                SORT_HOLD:begin
                    // Never reroute for flickering/opposite-colour detections of this item.
                    if(ms_tick && hold_ms<HOLD_MS)hold_ms<=hold_ms+1'b1;
                    if(hold_ms>=HOLD_MS && empty_now && clear_ms>=CLEAR_MS)begin
                        selected_color<=0;state<=RETURN_CENTER;return_ms<=0;
                    end
                end
                RETURN_CENTER:begin
                    if(ms_tick && return_ms<RETURN_MS)return_ms<=return_ms+1'b1;
                    if(return_ms>=RETURN_MS)begin state<=WAIT_CLEAR;clear_ms<=0;end
                end
            endcase
        end
    end
    wire [11:0] requested_us=selected_color==4?bounded_us(YELLOW_US):
        selected_color==3?bounded_us(BLUE_US):bounded_us(CENTER_US);
    reg [14:0] frame_us;
    reg [11:0] pulse_us;
    reg pulse_enabled;
    reg pwm_q;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin frame_us<=0;pulse_us<=bounded_us(CENTER_US);pulse_enabled<=0;pwm_q<=0;end
        else if(us_tick)begin
            if(frame_us==19999)begin
                frame_us<=0;pulse_us<=requested_us;pulse_enabled<=session_ok;pwm_q<=session_ok;
            end else begin
                frame_us<=frame_us+1'b1;pwm_q<=pulse_enabled && (frame_us+15'd1)<pulse_us;
            end
        end
    end
    // Width/enable update only at the 20 ms boundary: no pulse stretching or
    // mid-pulse shortening on colour/mode changes (asynchronous reset forces LOW).
    // Register the external pin; binary counter/comparator transitions cannot
    // appear as sub-cycle glitches on the servo signal.
    assign servo_pwm=pwm_q;

    // Diagnostic taps only; no feedback to the sorting state machine.
    reg [63:0] diag_object;
    reg diag_previous_pwm;
    reg [31:0] diag_edges,diag_fresh,diag_ms;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            diag_object<=0;diag_previous_pwm<=0;diag_edges<=0;diag_fresh<=0;diag_ms<=0;
        end else begin
            diag_object<=objects[63:0];diag_previous_pwm<=pwm_q;
            if(pwm_q && !diag_previous_pwm)diag_edges<=diag_edges+1'b1;
            if(fresh)diag_fresh<=diag_fresh+1'b1;
            if(ms_tick)diag_ms<=diag_ms+1'b1;
        end
    end
    wire [31:0] diag_flags;
    assign diag_flags[0]=enable;
    assign diag_flags[1]=session_ok;
    assign diag_flags[2]=valid_q;
    assign diag_flags[3]=overflow_q;
    assign diag_flags[4]=healthy;
    assign diag_flags[5]=target_q;
    assign diag_flags[6]=two_frames;
    assign diag_flags[7]=scene_empty;
    assign diag_flags[8]=invalid_update;
    assign diag_flags[9]=qualified;
    assign diag_flags[10]=empty_now;
    assign diag_flags[11]=update_q;
    assign diag_flags[12]=fresh;
    assign diag_flags[13]=have_source;
    assign diag_flags[14]=data_valid;
    assign diag_flags[15]=pwm_q;
    assign diag_flags[16]=pulse_enabled;
    assign diag_flags[17]=epoch_q==control_epoch;
    assign diag_flags[31:18]=0;
    assign diagnostic[511-:32]=control_epoch;
    assign diagnostic[479-:32]=epoch_q;
    assign diagnostic[447-:32]=source_q;
    assign diagnostic[415-:32]=last_source;
    assign diagnostic[383-:64]=diag_object;
    assign diagnostic[319-:32]=diag_flags;
    assign diagnostic[287-:16]=pulse_us;
    assign diagnostic[271-:16]=frame_us;
    assign diagnostic[255-:16]=age_ms;
    assign diagnostic[239-:16]=confirm_ms;
    assign diagnostic[223-:16]=clear_ms;
    assign diagnostic[207-:16]=hold_ms;
    assign diagnostic[191-:16]=return_ms;
    assign diagnostic[175-:8]=state;
    assign diagnostic[167-:8]=selected_color;
    assign diagnostic[159-:8]=candidate;
    assign diagnostic[151-:8]=count_q;
    assign diagnostic[143-:8]=color_q;
    assign diagnostic[135-:8]=8'd1;
    assign diagnostic[127-:32]=diag_edges;
    assign diagnostic[95-:32]=diag_fresh;
    assign diagnostic[63-:32]=diag_ms;
    assign diagnostic[31-:32]=32'd0;
endmodule
