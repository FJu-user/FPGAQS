`timescale 1ns/1ps

// DDR-domain observer of video_in's existing capture and bank ownership events.
// Each 41-bit bank record is {valid, capture_epoch[7:0], capture_frame_id[31:0]}.
module capture_frame_metadata #(parameter MIPI_TIMING=0) (
    input wire I_clk, I_system_rst_n, I_path_rst_n,
    input wire I_frame_start,
    input wire [56:0] I_mipi_descriptor,
    output wire [95:0] O_bank_time_gray,
    input wire I_writer_select,
    input wire [1:0] I_next_write_bank,
    input wire [1:0] I_write_bank,
    input wire I_write_en, I_frame_fault, I_publish,
    output reg [31:0] O_latest_gray,
    output wire [163:0] O_bank_metadata
);
    (* ASYNC_REG="TRUE" *) reg [1:0] capture_run_sync;
    wire capture_running=capture_run_sync[1];
    reg run_seen;
    wire run_reset_n = I_system_rst_n && I_path_rst_n;
    always @(posedge I_clk or negedge run_reset_n)
        if(!run_reset_n) capture_run_sync <= 2'b00;
        else capture_run_sync <= {capture_run_sync[0],1'b1};

    // These counters survive a video-path reset. No frame from the previous
    // SW4 session can acquire the same identity as the restarted capture.
    reg [31:0] capture_frame_id;
    reg [7:0] capture_epoch;
    reg [31:0] active_id;
    reg [23:0] active_time;
    reg [23:0] bank_time [0:3];
    reg [7:0] active_epoch;
    reg active_valid, seen_write, frame_fault;
    reg [31:0] bank_id [0:3];
    reg [7:0] bank_epoch [0:3];
    reg [3:0] bank_valid;
    integer i;
    always @(posedge I_clk or negedge I_system_rst_n) begin
        if(!I_system_rst_n) begin
            capture_frame_id <= 0; O_latest_gray<=0;
            capture_epoch <= 0;
            run_seen <= 0;
            active_id <= 0; active_epoch <= 0; active_time<=0;
            active_valid <= 0; seen_write <= 0; frame_fault <= 0;
            bank_valid <= 0;
            for(i=0;i<4;i=i+1) begin bank_id[i]<=0; bank_epoch[i]<=0; bank_time[i]<=0; end
        end else begin
            if(!I_path_rst_n || !capture_running) begin
                active_valid<=0; seen_write<=0; frame_fault<=0; bank_valid<=0; run_seen<=0;
            end
            if(I_path_rst_n && capture_running && !run_seen) begin
                capture_epoch<=capture_epoch+1'b1;
                run_seen<=1;
            end
            if(I_path_rst_n && capture_running) begin
                // I_publish and I_frame_start coincide: nonblocking updates
                // intentionally publish the OLD active identity, not the new ID.
                if(I_publish) begin
                    bank_id[I_write_bank]<=active_id;
                    bank_time[I_write_bank]<=active_time;
                    bank_epoch[I_write_bank]<=active_epoch;
                    bank_valid[I_write_bank]<=active_valid && seen_write && !frame_fault && !I_frame_fault;
                end
                // Selection can skip banks. Clear the destination before it is
                // overwritten; a reader that locks on this edge sees the old
                // record together with the old read pointer, just like video_in.
                if(I_writer_select) bank_valid[I_next_write_bank]<=0;
                if(!I_frame_start) begin
                    if(I_write_en) seen_write<=1;
                    if(I_frame_fault) frame_fault<=1;
                end
            end
            // Count every accepted capture boundary, including a boundary during
            // reset-release warmup. Such an early boundary is conservatively
            // invalid; normal video_in SOF traverses its existing synchronizer.
            if(I_path_rst_n && I_frame_start) begin
                capture_frame_id<=capture_frame_id+1'b1;
                O_latest_gray<=((capture_frame_id+32'd1)>>1)^(capture_frame_id+32'd1);
                active_id<=MIPI_TIMING?I_mipi_descriptor[55:24]:capture_frame_id+1'b1;
                active_time<=MIPI_TIMING?I_mipi_descriptor[23:0]:24'd0;
                active_epoch<=run_seen ? capture_epoch : capture_epoch+1'b1;
                active_valid<=capture_running && (!MIPI_TIMING || I_mipi_descriptor[56]); seen_write<=0; frame_fault<=0;
            end
        end
    end
    genvar b;
    generate for(b=0;b<4;b=b+1) begin:g_bank
        assign O_bank_time_gray[b*24+:24]=bank_time[b];
        assign O_bank_metadata[b*41+:41] = {
            bank_valid[b] && I_path_rst_n && capture_running,
            bank_epoch[b],bank_id[b]};
    end endgenerate
endmodule
