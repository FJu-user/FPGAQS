`timescale 1ns / 1ns

// Streaming run-length encoder for a colour-labelled video mask.
//
// Input protocol:
//   I_color=0 is background; 1/2/3 are red/green/blue. Coordinates and
//   boundary flags are valid with I_de. I_line_end/I_frame_end accompany the
//   last active pixel, matching video_stream_context.v in this project.
//
// Output protocol:
//   O_run_valid describes one foreground run. O_line_done/O_frame_done follow
//   the last run, so a consumer updates statistics before scanning its table.
//   Runs shorter than MIN_RUN_LENGTH are suppressed. MIN_RUN_LENGTH >= 2 is
//   required by the compact end-of-line implementation.
//
// Timing/resources:
//   One labelled pixel is accepted per clock. This module uses registers,
//   comparators and an incrementer only: no line RAM and no multiplier.
module run_length_encode #(
    parameter GEOMETRY_ONLY=0,
    parameter CORE_EVIDENCE=0,
    parameter integer COORD_WIDTH    = 12,
    parameter integer MIN_RUN_LENGTH = 3
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

    output reg [4*(COORD_WIDTH+1)-1:0] O_run_color_area,
    output reg [COORD_WIDTH:0] O_run_core_count,
    output reg                          O_run_valid,
    output reg  [2:0]                   O_run_color,
    output reg  [COORD_WIDTH-1:0]       O_run_xmin,
    output reg  [COORD_WIDTH-1:0]       O_run_xmax,
    output reg  [COORD_WIDTH-1:0]       O_run_y,
    output reg  [COORD_WIDTH:0]         O_run_length,
    output reg                          O_line_done,
    output reg                          O_frame_done,
    output reg                          O_frame_is_new
);

reg                        run_active;
reg [2:0]                  run_color;
reg [COORD_WIDTH-1:0]      run_xmin;
reg [COORD_WIDTH-1:0]      run_xmax;
reg [COORD_WIDTH-1:0]      run_y;
reg [COORD_WIDTH:0]        run_length;
reg                        frame_is_new_latched;
reg                        pending_line_done;
reg                        pending_frame_done;
reg                        pending_frame_is_new;

localparam HIST_W=COORD_WIDTH+1;
reg [4*HIST_W-1:0] run_hist;
reg [COORD_WIDTH:0] run_core;
wire core_pixel=CORE_EVIDENCE?I_core:1'b1;
wire [4*HIST_W-1:0] hist_next;
genvar hc;
generate for(hc=0;hc<4;hc=hc+1) begin : g_hist
    assign hist_next[hc*HIST_W +: HIST_W] = run_hist[hc*HIST_W +: HIST_W] + (I_color==hc+1);
end endgenerate
function [4*HIST_W-1:0] seed_hist;
    input [2:0] color;
    integer k;
    begin
        seed_hist=0;
        for(k=0;k<4;k=k+1) seed_hist[k*HIST_W +: HIST_W]=(color==k+1);
    end
endfunction
wire foreground = I_de && (I_color != 2'd0);
wire run_continues = run_active && foreground &&
                     (GEOMETRY_ONLY || I_color == run_color) && (I_y == run_y) &&
                     ({1'b0, I_x} == ({1'b0, run_xmax} + 1'b1));

task emit_stored_run;
    begin
        if(run_length >= MIN_RUN_LENGTH) begin
            O_run_valid  <= 1'b1;
            O_run_color  <= run_color;
            O_run_xmin   <= run_xmin;
            O_run_xmax   <= run_xmax;
            O_run_y      <= run_y;
            O_run_length <= run_length;
            O_run_color_area <= run_hist;
            O_run_core_count <= run_core;
        end
    end
endtask

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        run_active           <= 1'b0;
        run_hist<=0; O_run_color_area<=0;
        run_core<=0;O_run_core_count<=0;
        run_color            <= 2'd0;
        run_xmin             <= {COORD_WIDTH{1'b0}};
        run_xmax             <= {COORD_WIDTH{1'b0}};
        run_y                <= {COORD_WIDTH{1'b0}};
        run_length           <= {(COORD_WIDTH+1){1'b0}};
        frame_is_new_latched <= 1'b0;
        pending_line_done    <= 1'b0;
        pending_frame_done   <= 1'b0;
        pending_frame_is_new <= 1'b0;
        O_run_valid          <= 1'b0;
        O_run_color          <= 2'd0;
        O_run_xmin           <= {COORD_WIDTH{1'b0}};
        O_run_xmax           <= {COORD_WIDTH{1'b0}};
        O_run_y              <= {COORD_WIDTH{1'b0}};
        O_run_length         <= {(COORD_WIDTH+1){1'b0}};
        O_line_done          <= 1'b0;
        O_frame_done         <= 1'b0;
        O_frame_is_new       <= 1'b0;
    end else begin
        // Boundary events are delayed so the final run is consumed first.
        O_run_valid    <= 1'b0;
        O_line_done    <= pending_line_done;
        O_frame_done   <= pending_frame_done;
        O_frame_is_new <= pending_frame_is_new;
        pending_line_done    <= 1'b0;
        pending_frame_done   <= 1'b0;
        pending_frame_is_new <= 1'b0;

        if(I_frame_start) begin
            // Frame start is a hard recovery point. Process its first pixel as
            // a fresh run rather than joining stale state.
            frame_is_new_latched <= I_frame_is_new;
            run_active           <= 1'b0;
            pending_line_done    <= 1'b0;
            pending_frame_done   <= 1'b0;

            if(foreground && !I_line_end) begin
                run_active <= 1'b1;
                run_color  <= I_color;
                run_xmin   <= I_x;
                run_xmax   <= I_x;
                run_y      <= I_y;
                run_length <= {{COORD_WIDTH{1'b0}}, 1'b1};
                run_hist <= seed_hist(I_color);
                run_core <= core_pixel;
            end

            if(I_line_end) begin
                // A one-pixel line is below the supported minimum run length.
                pending_line_done    <= 1'b1;
                pending_frame_done   <= I_frame_end;
                pending_frame_is_new <= I_frame_is_new;
            end
        end else if(I_line_end) begin
            // The boundary pixel may extend the stored run. If it starts a
            // different run, that singleton is intentionally noise-filtered.
            if(run_continues) begin
                if((run_length + 1'b1) >= MIN_RUN_LENGTH) begin
                    O_run_valid  <= 1'b1;
                    O_run_color  <= run_color;
                    O_run_xmin   <= run_xmin;
                    O_run_xmax   <= I_x;
                    O_run_y      <= run_y;
                    O_run_length <= run_length + 1'b1;
                    O_run_color_area <= hist_next;
                    O_run_core_count <= run_core+core_pixel;
                run_hist <= hist_next;
                end
            end else if(run_active) begin
                emit_stored_run();
            end

            run_active           <= 1'b0;
            pending_line_done    <= 1'b1;
            pending_frame_done   <= I_frame_end;
            pending_frame_is_new <= frame_is_new_latched;
        end else if(I_de) begin
            if(I_color == 2'd0) begin
                if(run_active)
                    emit_stored_run();
                run_active <= 1'b0;
            end else if(!run_active) begin
                run_active <= 1'b1;
                run_color  <= I_color;
                run_xmin   <= I_x;
                run_xmax   <= I_x;
                run_y      <= I_y;
                run_length <= {{COORD_WIDTH{1'b0}}, 1'b1};
                run_hist <= seed_hist(I_color);
                run_core <= core_pixel;
            end else if(run_continues) begin
                run_xmax   <= I_x;
                run_length <= run_length + 1'b1;
                run_hist <= hist_next;
                run_core <= run_core+core_pixel;
            end else begin
                emit_stored_run();
                run_active <= 1'b1;
                run_color  <= I_color;
                run_xmin   <= I_x;
                run_xmax   <= I_x;
                run_y      <= I_y;
                run_length <= {{COORD_WIDTH{1'b0}}, 1'b1};
                run_hist <= seed_hist(I_color);
                run_core <= core_pixel;
            end
        end else if(I_line_start && run_active) begin
            // Defensive recovery for a source which omitted I_line_end.
            emit_stored_run();
            run_active <= 1'b0;
        end
    end
end

endmodule
