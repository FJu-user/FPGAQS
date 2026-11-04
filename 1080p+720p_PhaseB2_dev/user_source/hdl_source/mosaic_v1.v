`timescale 1ns / 1ns

// Current Mode13: full-screen sample-and-hold Mosaic.
//
// The representative pixel is the top-left pixel of every B x B block.  The
// table stores one representative RGB value per horizontal block in the
// current block row.  MAX_BLOCKS is sized for the worst supported case:
// 1920 / 8 = 240.  No frame buffer, ROI state, divider, modulo operator or
// legacy FPGA RAM primitive is used.
//
// I_strength[1:0] selects the block size at a frame-committed boundary:
//   2'b00 -> 16x16 (board default)
//   2'b01 ->  8x8
//   2'b10 -> 32x32
//   2'b11 -> 16x16 (reserved/defensive default)
// The active strength is expected to remain constant for a frame, as supplied
// by algorithm_ctrl_commit.  A changed resolution or a reset does not require
// clearing the table: every valid frame starts at x=0,y=0 and the first pixel
// of every block uses explicit write-through of the current RGB.
module mosaic_v1 #(
    parameter integer MAX_BLOCKS = 240
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [23:0] I_rgb,
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire [7:0]  I_strength,
    output reg  [23:0] O_rgb,
    output reg         O_de,
    output reg         O_hs,
    output reg         O_vs,
    output reg  [11:0] O_x,
    output reg  [11:0] O_y
);

// Generic inference attribute only.  The actual PH1P35 ERAM/DRAM/LUT mapping
// is intentionally left for the user's TD synthesis run to confirm.
wire [23:0] block_read;

reg [2:0]  block_shift_comb;
reg [7:0]  block_addr_comb;
reg        block_sample_comb;

always @(*) begin
    case (I_strength[1:0])
        2'b01: begin
            block_shift_comb  = 3'd3;
            block_addr_comb   = I_x >> 3;
            block_sample_comb = (I_x[2:0] == 3'd0) &&
                                (I_y[2:0] == 3'd0);
        end
        2'b10: begin
            block_shift_comb  = 3'd5;
            block_addr_comb   = I_x >> 5;
            block_sample_comb = (I_x[4:0] == 5'd0) &&
                                (I_y[4:0] == 5'd0);
        end
        default: begin
            block_shift_comb  = 3'd4;
            block_addr_comb   = I_x >> 4;
            block_sample_comb = (I_x[3:0] == 4'd0) &&
                                (I_y[3:0] == 4'd0);
        end
    endcase
end

// Stage M0: capture the complete input pixel transaction and the decoded
// block address/sample condition.  The shift register is retained as an
// explicit sideband so the timing intent is visible in synthesis reports.
reg [23:0] rgb_m0;
reg [11:0] x_m0, y_m0;
reg        de_m0, hs_m0, vs_m0;
reg [7:0]  block_addr_m0;
reg        block_sample_m0;
reg [2:0]  block_shift_m0;

// Prefetch at M0; consume in the original M1 register. Existing last_write
// covers a write on the prefetch edge, independent of RAM collision behavior.
storage_dp #(.WIDTH(24))u_blocks(.clk(I_clk),
 .we(I_rst_n && de_m0 && block_sample_m0 && block_addr_m0<MAX_BLOCKS),
 .wa({1'b0,block_addr_m0}),.wd(rgb_m0),.read_en(1'b1),.ra({1'b0,block_addr_comb}),.qa(),.qb(block_read));
// Stage M1: perform representative write/read and explicit write-through.
// last_write_* covers both the same-cycle RAM read-during-write case and the
// first non-representative pixel immediately following a block sample.
reg [23:0] mosaic_rgb_m1;
reg [23:0] original_rgb_m1;
reg [11:0] x_m1, y_m1;
reg        de_m1, hs_m1, vs_m1;
reg        last_write_valid;
reg [7:0]  last_write_addr;
reg [23:0] last_write_rgb;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        rgb_m0          <= 24'd0;
        x_m0            <= 12'd0;
        y_m0            <= 12'd0;
        de_m0           <= 1'b0;
        hs_m0           <= 1'b0;
        vs_m0           <= 1'b0;
        block_addr_m0   <= 8'd0;
        block_sample_m0 <= 1'b0;
        block_shift_m0  <= 3'd4;

        mosaic_rgb_m1   <= 24'd0;
        original_rgb_m1 <= 24'd0;
        x_m1            <= 12'd0;
        y_m1            <= 12'd0;
        de_m1           <= 1'b0;
        hs_m1           <= 1'b0;
        vs_m1           <= 1'b0;

        last_write_valid <= 1'b0;
        last_write_addr  <= 8'd0;
        last_write_rgb   <= 24'd0;
    end else begin
        // M0
        rgb_m0          <= I_rgb;
        x_m0            <= I_x;
        y_m0            <= I_y;
        de_m0           <= I_de;
        hs_m0           <= I_hs;
        vs_m0           <= I_vs;
        block_addr_m0   <= block_addr_comb;
        block_sample_m0 <= I_de && block_sample_comb;
        block_shift_m0  <= block_shift_comb;

        // M1 transaction sideband
        original_rgb_m1 <= rgb_m0;
        x_m1            <= x_m0;
        y_m1            <= y_m0;
        de_m1           <= de_m0;
        hs_m1           <= hs_m0;
        vs_m1           <= vs_m0;

        if(!de_m0) begin
            mosaic_rgb_m1 <= 24'd0;
        end else if(block_sample_m0) begin
            // Current representative pixel is never allowed to see stale RAM.
            mosaic_rgb_m1              <= rgb_m0;
            last_write_valid           <= 1'b1;
            last_write_addr            <= block_addr_m0;
            last_write_rgb             <= rgb_m0;
        end else if(last_write_valid &&
                    (last_write_addr == block_addr_m0)) begin
            mosaic_rgb_m1 <= last_write_rgb;
        end else begin
            mosaic_rgb_m1 <= block_addr_m0<MAX_BLOCKS ? block_read : 24'bx;
        end
    end
end

// Stage M2: registered output.  The full transaction is delayed together,
// making the module suitable for an independent alignment measurement before
// it is padded to the public 13-cycle pixel-chain contract.
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_rgb <= 24'd0;
        O_de  <= 1'b0;
        O_hs  <= 1'b0;
        O_vs  <= 1'b0;
        O_x   <= 12'd0;
        O_y   <= 12'd0;
    end else begin
        O_de <= de_m1;
        O_hs <= hs_m1;
        O_vs <= vs_m1;
        O_x  <= x_m1;
        O_y  <= y_m1;
        O_rgb <= de_m1 ? mosaic_rgb_m1 : 24'd0;
    end
end

endmodule

