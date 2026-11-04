`timescale 1ns / 1ns

// Fixed-latency transaction delay.  Algorithms may replace the RGB function,
// but every field in this record must retain the same latency.
module video_stream_delay #(
    parameter integer LATENCY = 1
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_start,
    input  wire        I_frame_end,
    input  wire        I_line_start,
    input  wire        I_line_end,
    input  wire [1:0]  I_display_bank,
    input  wire [7:0]  I_frame_seq,
    input  wire        I_frame_is_new,
    input  wire        I_new_frame_pulse,
    input  wire [4:0]  I_algorithm_mode,
    input  wire [7:0]  I_threshold,
    input  wire [7:0]  I_strength,
    input  wire [7:0]  I_config_epoch,
    output wire [23:0] O_rgb,
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [11:0] O_x,
    output wire [11:0] O_y,
    output wire        O_frame_start,
    output wire        O_frame_end,
    output wire        O_line_start,
    output wire        O_line_end,
    output wire [1:0]  O_display_bank,
    output wire [7:0]  O_frame_seq,
    output wire        O_frame_is_new,
    output wire        O_new_frame_pulse,
    output wire [4:0]  O_algorithm_mode,
    output wire [7:0]  O_threshold,
    output wire [7:0]  O_strength,
    output wire [7:0]  O_config_epoch
);

localparam integer TXN_WIDTH = 24 + 3 + 24 + 4 + 2 + 8 + 2 + 5 + 8 + 8 + 8;
wire [TXN_WIDTH-1:0] input_transaction = {
    I_rgb, I_de, I_hs, I_vs, I_x, I_y,
    I_frame_start, I_frame_end, I_line_start, I_line_end,
    I_display_bank, I_frame_seq, I_frame_is_new, I_new_frame_pulse,
    I_algorithm_mode, I_threshold, I_strength, I_config_epoch
};
wire [TXN_WIDTH-1:0] output_transaction;

generate
    if(LATENCY == 0) begin : g_no_delay
        assign output_transaction = input_transaction;
    end else begin : g_fixed_delay
        reg [TXN_WIDTH-1:0] delay_pipe [0:LATENCY-1];
        integer delay_index;
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin
                for(delay_index = 0; delay_index < LATENCY; delay_index = delay_index + 1)
                    delay_pipe[delay_index] <= {TXN_WIDTH{1'b0}};
            end else begin
                delay_pipe[0] <= input_transaction;
                for(delay_index = 1; delay_index < LATENCY; delay_index = delay_index + 1)
                    delay_pipe[delay_index] <= delay_pipe[delay_index-1];
            end
        end
        assign output_transaction = delay_pipe[LATENCY-1];
    end
endgenerate

assign {
    O_rgb, O_de, O_hs, O_vs, O_x, O_y,
    O_frame_start, O_frame_end, O_line_start, O_line_end,
    O_display_bank, O_frame_seq, O_frame_is_new, O_new_frame_pulse,
    O_algorithm_mode, O_threshold, O_strength, O_config_epoch
} = output_transaction;

endmodule

