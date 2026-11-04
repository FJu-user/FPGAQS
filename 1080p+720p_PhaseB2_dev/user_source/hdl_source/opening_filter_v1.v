`timescale 1ns / 1ns

// Second half of a true binary opening: 3x3 dilation of an already eroded
// mask.  Keeping this as a separate one-bit line store preserves the required
// erosion -> dilation dependency instead of displaying two unrelated branches.
module opening_filter_v1 #(
    parameter integer MAX_WIDTH = 1920
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_bit,
    input  wire        I_de,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    output reg         O_opened,
    output reg         O_valid
);

wire [1:0] line_rd;
reg       bit_d1;
reg       de_d1;
reg [11:0] addr_d1, x_d1, y_d1;

// The old enabled synchronous read already consumed one clock. Native ERAM
// supplies that same stage; window/erosion/opening transaction stays unchanged.
binary_line_buffer_eram u_opening_line_buffer_eram (
    .I_clk(I_clk), .I_rd_en(I_de), .I_rd_addr(I_x[10:0]),
    .I_wr_en(de_d1), .I_wr_addr(addr_d1[10:0]),
    .I_wr_data({line_rd[0],bit_d1}), .O_rd_data(line_rd)
);

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        bit_d1 <= 1'b0;
        de_d1 <= 1'b0;
        addr_d1 <= 12'd0;
        x_d1 <= 12'd0;
        y_d1 <= 12'd0;
    end else begin
        bit_d1 <= I_bit;
        de_d1 <= I_de;
        addr_d1 <= I_x;
        x_d1 <= I_x;
        y_d1 <= I_y;
    end
end

reg p11, p12, p13;
reg p21, p22, p23;
reg p31, p32, p33;
reg window_valid_d2;
reg de_d2;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        p11 <= 1'b0; p12 <= 1'b0; p13 <= 1'b0;
        p21 <= 1'b0; p22 <= 1'b0; p23 <= 1'b0;
        p31 <= 1'b0; p32 <= 1'b0; p33 <= 1'b0;
        window_valid_d2 <= 1'b0;
        de_d2 <= 1'b0;
    end else begin
        // The local mask starts at x/y=2 and erosion at x/y=4.  A complete
        // 3x3 window of eroded samples therefore starts at x/y=6.
        window_valid_d2 <= de_d1 && (x_d1 >= 12'd6) &&
                                    (y_d1 >= 12'd6);
        de_d2 <= de_d1;
        if(de_d1) begin
            if(x_d1 == 12'd0) begin
                p11 <= 1'b0; p12 <= 1'b0; p13 <= line_rd[1];
                p21 <= 1'b0; p22 <= 1'b0; p23 <= line_rd[0];
                p31 <= 1'b0; p32 <= 1'b0; p33 <= bit_d1;
            end else begin
                p11 <= p12; p12 <= p13; p13 <= line_rd[1];
                p21 <= p22; p22 <= p23; p23 <= line_rd[0];
                p31 <= p32; p32 <= p33; p33 <= bit_d1;
            end
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        O_opened <= 1'b0;
        O_valid <= 1'b0;
    end else begin
        O_opened <= window_valid_d2 &&
                    (p11 || p12 || p13 || p21 || p22 || p23 ||
                     p31 || p32 || p33);
        O_valid <= de_d2;
    end
end

endmodule
