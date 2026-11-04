`timescale 1ns / 1ns

// Pixel-domain stream context shared by every later image algorithm.
// Coordinates advance only on active pixels, so the same logic serves both
// 1280x720 and 1920x1080 without timing constants.
module video_stream_context (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [11:0] I_active_width,
    input  wire [11:0] I_active_height,
    input  wire        I_de,
    input  wire        I_vs,
    output wire [11:0] O_x,
    output wire [11:0] O_y,
    output wire        O_frame_start,
    output wire        O_frame_end,
    output wire        O_line_start,
    output wire        O_line_end
);

reg [11:0] x_count;
reg [11:0] y_count;
reg        vs_d;

wire dimensions_valid = (I_active_width != 12'd0) &&
                        (I_active_height != 12'd0);
wire [11:0] width_last  = I_active_width  - 12'd1;
wire [11:0] height_last = I_active_height - 12'd1;

assign O_x = x_count;
assign O_y = y_count;
assign O_line_start  = I_de && dimensions_valid && (x_count == 12'd0);
assign O_line_end    = I_de && dimensions_valid && (x_count == width_last);
assign O_frame_start = O_line_start && (y_count == 12'd0);
assign O_frame_end   = O_line_end   && (y_count == height_last);

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        x_count <= 12'd0;
        y_count <= 12'd0;
        vs_d    <= 1'b0;
    end else begin
        vs_d <= I_vs;

        // The display VTC supplies a clean frame reset during vertical blank.
        if(I_vs && !vs_d) begin
            x_count <= 12'd0;
            y_count <= 12'd0;
        end else if(I_de && dimensions_valid) begin
            if(x_count == width_last) begin
                x_count <= 12'd0;
                if(y_count == height_last)
                    y_count <= 12'd0;
                else
                    y_count <= y_count + 12'd1;
            end else begin
                x_count <= x_count + 12'd1;
            end
        end
    end
end

endmodule

