`timescale 1ns/1ps
// Passive consumer of the existing atomic Mode17 result mailbox (100 MHz).
// LEDs are external, active-high. The board's PNP buzzer driver is active-low.
// The public object format and all image/recognition/transport paths are intact.
module mode17_peripheral_control #(
    parameter integer CLOCK_HZ=100000000,
    parameter integer ROI_X_MIN=128, ROI_X_MAX=1151,
    parameter integer ROI_Y_MIN=72, ROI_Y_MAX=647,
    parameter integer LED_HALF_MS=250,
    parameter integer BEEP_ON_MS=200, BEEP_PERIOD_MS=1000,
    parameter integer TONE_HZ=2000,
    parameter integer RESULT_TIMEOUT_MS=1000,
    parameter integer SWITCH_DEBOUNCE_MS=20
)(
    input wire clk,rst_n,
    input wire enable,
    input wire [31:0] control_epoch,
    input wire result_update,result_valid,
    input wire [31:0] result_epoch,source_id,
    input wire [3:0] object_count,
    input wire [255:0] objects,
    input wire buzzer_switch,
    output wire [3:0] led_rgb_y,
    output wire buzzer_n
);
    function integer bits_for;
        input integer n;
        integer v;
        begin
            bits_for=1;
            v=n-1;
            while(v>1)begin bits_for=bits_for+1;v=v>>1;end
        end
    endfunction
    localparam integer MS_CYCLES=CLOCK_HZ/1000;
    localparam integer TONE_HALF_CYCLES=CLOCK_HZ/(TONE_HZ*2);
    reg [bits_for(MS_CYCLES)-1:0] ms_divider;
    wire ms_tick=ms_divider==MS_CYCLES-1;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)ms_divider<=0;
        else if(ms_tick)ms_divider<=0;
        else ms_divider<=ms_divider+1'b1;

    // Synchronize the mechanical SW4 before a millisecond debounce filter.
    (* ASYNC_REG="TRUE" *) reg sw_meta,sw_sync;
    reg sw_enabled;
    reg [bits_for(SWITCH_DEBOUNCE_MS)-1:0] sw_count;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin sw_meta<=0;sw_sync<=0;sw_enabled<=0;sw_count<=0;end
        else begin
            sw_meta<=buzzer_switch;sw_sync<=sw_meta;
            if(sw_sync==sw_enabled)sw_count<=0;
            else if(ms_tick)begin
                if(sw_count==SWITCH_DEBOUNCE_MS-1)begin
                    sw_enabled<=sw_sync;sw_count<=0;
                end else sw_count<=sw_count+1'b1;
            end
        end
    end

    // A is allowed to change resolution; B's public result coordinates always
    // remain 1280x720. A target enters the ROI when its bbox centre is inside.
    // Register every lane's decision before reducing the four lanes, avoiding
    // a four-object combinational path into the freshness/confirmation state.
    wire [3:0] lane_mask[0:3];
    reg [3:0] lane_q[0:3];
    genvar i;
    generate for(i=0;i<4;i=i+1)begin:g_object
        wire [63:0] o=objects[i*64+:64];
        wire [11:0] x0=o[56:45],y0=o[44:33],x1=o[32:21],y1=o[20:9];
        wire [12:0] cx2={1'b0,x0}+{1'b0,x1};
        wire [12:0] cy2={1'b0,y0}+{1'b0,y1};
        wire in_roi=x0<=x1 && y0<=y1 && x1<1280 && y1<720 &&
            cx2>=ROI_X_MIN*2 && cx2<=ROI_X_MAX*2 &&
            cy2>=ROI_Y_MIN*2 && cy2<=ROI_Y_MAX*2;
        wire circle=i<object_count && o[63] && o[59:57]==3'd1 && in_roi;
        assign lane_mask[i]={circle && o[62:60]==3'd4,
                            circle && o[62:60]==3'd3,
                            circle && o[62:60]==3'd2,
                            circle && o[62:60]==3'd1};
        always @(posedge clk or negedge rst_n)
            if(!rst_n)lane_q[i]<=0;else lane_q[i]<=lane_mask[i];
    end endgenerate
    reg update_q,valid_q;
    reg [31:0] source_q,epoch_q;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin update_q<=0;valid_q<=0;source_q<=0;epoch_q<=0;end
        else begin
            update_q<=result_update;
            valid_q<=result_valid && object_count<=4;
            source_q<=source_id;epoch_q<=result_epoch;
        end
    end
    wire [3:0] hits=lane_q[0]|lane_q[1]|lane_q[2]|lane_q[3];
    reg [31:0] session_q,last_source;
    reg have_source;
    reg [3:0] previous_hits,confirmed;
    reg [bits_for(RESULT_TIMEOUT_MS+1)-1:0] age_ms;
    wire session_ok=enable && session_q==control_epoch;
    wire fresh=update_q && valid_q && epoch_q==control_epoch &&
        (!have_source || source_q!=last_source);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            session_q<=0;last_source<=0;have_source<=0;
            previous_hits<=0;confirmed<=0;age_ms<=RESULT_TIMEOUT_MS;
        end else begin
            session_q<=control_epoch;
            if(!session_ok)begin
                last_source<=source_q;have_source<=valid_q && epoch_q==control_epoch;previous_hits<=0;
                confirmed<=0;age_ms<=RESULT_TIMEOUT_MS;
            end else if(fresh)begin
                last_source<=source_q;have_source<=1;age_ms<=0;
                // Two distinct newly analysed source images are required.
                confirmed<=hits & previous_hits;
                previous_hits<=hits;
            end else if(update_q && (!valid_q || epoch_q!=control_epoch))begin
                previous_hits<=0;confirmed<=0;
            end else if(ms_tick && age_ms<RESULT_TIMEOUT_MS)begin
                age_ms<=age_ms+1'b1;
                if(age_ms==RESULT_TIMEOUT_MS-1)begin
                    previous_hits<=0;confirmed<=0;
                    // Keep last_source: retransmitting the stale bank cannot
                    // re-arm the outputs or restart the freshness watchdog.
                end
            end
        end
    end

    reg [bits_for(LED_HALF_MS)-1:0] led_ms;
    reg led_phase;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin led_ms<=0;led_phase<=1;end
        else if(!session_ok || confirmed==0)begin led_ms<=0;led_phase<=1;end
        else if(ms_tick)begin
            if(led_ms==LED_HALF_MS-1)begin led_ms<=0;led_phase<=~led_phase;end
            else led_ms<=led_ms+1'b1;
        end
    end
    assign led_rgb_y=(rst_n && session_ok && led_phase)?confirmed:4'b0000;

    reg [bits_for(BEEP_PERIOD_MS)-1:0] beep_ms;
    reg [bits_for(TONE_HALF_CYCLES)-1:0] tone_count;
    reg tone_phase;
    wire sound_allowed=session_ok && confirmed[0] && sw_enabled;
    wire beep_window=sound_allowed && beep_ms<BEEP_ON_MS;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin beep_ms<=0;tone_count<=0;tone_phase<=0;end
        else begin
            if(!sound_allowed)beep_ms<=0;
            else if(ms_tick)begin
                if(beep_ms==BEEP_PERIOD_MS-1)beep_ms<=0;
                else beep_ms<=beep_ms+1'b1;
            end
            if(!beep_window)begin tone_count<=0;tone_phase<=0;end
            else if(tone_count==TONE_HALF_CYCLES-1)begin
                tone_count<=0;tone_phase<=~tone_phase;
            end else tone_count<=tone_count+1'b1;
        end
    end
    // 2 kHz tone, 200 ms on / 800 ms off. High is the silent/reset state.
    assign buzzer_n=!(rst_n && beep_window && tone_phase);
endmodule
