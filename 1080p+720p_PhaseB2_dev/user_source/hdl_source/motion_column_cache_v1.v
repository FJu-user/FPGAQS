`timescale 1ns / 1ps

// PH1P distributed RAM, not ERAM: one 14-bit partial sum per block column.
// READREG=DISABLE preserves the pre-existing combinational table read and
// its capture into column_sum_active. Data RAM has no reset. Resettable
// validity bits preserve the old table's zero-on-reset semantics, including
// reset during a partially received block row. Soft reset intentionally does
// not clear this cache, exactly as in the original Motion accumulator.
module motion_column_cache_v1 #(
    parameter integer COLS = 240
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [7:0]  I_rd_addr,
    input  wire [7:0]  I_wr_addr,
    input  wire [13:0] I_wr_data,
    input  wire        I_wr_en,
    output wire [13:0] O_rd_data
);
    wire [13:0] raw_data;
    reg [COLS-1:0] valid;
    wire write_enable = I_rst_n && I_wr_en && (I_wr_addr < COLS);
    wire read_valid = (I_rd_addr < COLS) ? valid[I_rd_addr] : 1'b0;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            valid <= {COLS{1'b0}};
        else if(write_enable)
            valid[I_wr_addr] <= 1'b1;
    end

    // Interface and parameter names follow TD 6.2.1 arch/ph1p_macro.v.
    // 256 physical slots permit an 8-bit address; slots COLS..255 are never
    // written or made visible. No dependence on power-up or same-edge
    // read/write behaviour: Motion reads at x[2:0]=0, writes at x[2:0]=7.
    PH1P_LOGIC_DRAM #(
        .DATA_WIDTH_W(14), .DATA_WIDTH_R(14),
        .ADDR_WIDTH_W(8), .ADDR_WIDTH_R(8),
        .DATA_DEPTH_W(256), .DATA_DEPTH_R(256),
        .INIT_FILE("NONE"), .FILL_ALL("NONE"),
        .READREG("DISABLE"), .RESETMODE("ASYNC")
    ) u_column_dram (
        .di(I_wr_data), .waddr(I_wr_addr), .we(write_enable), .wclk(I_clk),
        .rclk(I_clk), .rrst(1'b0), .rce(1'b0), .raddr(I_rd_addr),
        .rdo(raw_data), .rdoq()
    );

    assign O_rd_data = read_valid ? raw_data : 14'd0;
endmodule
