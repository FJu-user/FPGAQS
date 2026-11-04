`timescale 1ns / 1ps
// ronghe active Mode3: max-channel gray -> median -> legacy bilateral.
// One instance serves both resolutions. Latency = 20 pixel clocks.
// The arithmetic preserves the active source's S*G matrix weights, leading-
// one normalization. Weights and pixels belong to the SAME input window.
// See verification/mode14/alignment_20260923 for regression evidence.
module bilateral_filter_v1 #(parameter integer MAX_WIDTH=1920)(
    input wire I_clk, I_rst_n,
    input wire [23:0] I_rgb,
    input wire I_de, I_hs, I_vs,
    input wire [11:0] I_active_width, I_active_height, I_x, I_y,
    output wire [23:0] O_rgb,
    output wire O_de, O_hs, O_vs
);
    wire [7:0] max_rg = I_rgb[23:16]>=I_rgb[15:8] ? I_rgb[23:16] : I_rgb[15:8];
    reg [7:0] gray_s1;
    reg de_s1;
    reg [11:0] x_s1,y_s1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin gray_s1<=0; de_s1<=0; x_s1<=0; y_s1<=0; end
        else begin
            gray_s1 <= max_rg>=I_rgb[7:0] ? max_rg : I_rgb[7:0];
            de_s1<=I_de; x_s1<=I_x; y_s1<=I_y;
        end
    end
    // C2..C3: two native ERAM rows, zero pad unavailable top/left pixels.
    wire [71:0] gray_window;
    wire gray_de;
    wire [11:0] gray_x,gray_y;
    bilateral_causal_window_v1 #(.MAX_WIDTH(MAX_WIDTH)) u_gray_window(
        .clk(I_clk),.rst_n(I_rst_n),.gray(gray_s1),.de(de_s1),.x(x_s1),.y(y_s1),
        .window_pixels(gray_window),.out_de(gray_de),.out_x(gray_x),.out_y(gray_y));
    // C4..C6: source three-stage median candidate network.
    wire [7:0] median_gray;
    bilateral_median9_v1 u_median(.clk(I_clk),.rst_n(I_rst_n),
        .pixels(gray_window),.median_gray(median_gray));
    reg [24:0] median_tags[0:2];
    integer m;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) for(m=0;m<3;m=m+1) median_tags[m]<=0;
        else begin
            median_tags[0]<={gray_de,gray_y,gray_x};
            for(m=1;m<3;m=m+1) median_tags[m]<=median_tags[m-1];
        end
    end
    // C7..C8: second window MUST consume the median stream.
    wire [71:0] median_window;
    wire bilateral_de;
    wire [11:0] bilateral_x,bilateral_y;
    bilateral_causal_window_v1 #(.MAX_WIDTH(MAX_WIDTH)) u_median_window(
        .clk(I_clk),.rst_n(I_rst_n),.gray(median_gray),.de(median_tags[2][24]),
        .x(median_tags[2][11:0]),.y(median_tags[2][23:12]),
        .window_pixels(median_window),.out_de(bilateral_de),
        .out_x(bilateral_x),.out_y(bilateral_y));
    // Same causal boundary policy as target spatial filters; source border
    // centre passthrough is retained. No extra line is synthesized in blanking.
    wire border = bilateral_x<12'd2 || bilateral_y<12'd2 ||
                  bilateral_x>=I_active_width-12'd1 || bilateral_y>=I_active_height-12'd1;
    wire [7:0] result_gray;
    // C9..C20: legacy formulas with aligned weight/pixel transactions.
    bilateral_weighted_core_v1 u_bilateral(.clk(I_clk),.rst_n(I_rst_n),
        .pixels(median_window),.border(border),.gray(result_gray));
    reg [19:0] de_pipe,hs_pipe,vs_pipe;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin de_pipe<=0;hs_pipe<=0;vs_pipe<=0;end
        else begin
            de_pipe<={de_pipe[18:0],I_de};
            hs_pipe<={hs_pipe[18:0],I_hs};
            vs_pipe<={vs_pipe[18:0],I_vs};
        end
    end
    assign O_rgb=O_de ? {result_gray,result_gray,result_gray} : 24'd0;
    assign O_de=de_pipe[19]; assign O_hs=hs_pipe[19]; assign O_vs=vs_pipe[19];
endmodule

// Two-clock causal 3x3 window. Coordinates come from the stream contract,
// so blanks never advance a row and frame/resolution resets need no RAM clear.
module bilateral_causal_window_v1 #(parameter integer MAX_WIDTH=1920)(
    input wire clk,rst_n,input wire [7:0] gray,input wire de,
    input wire [11:0] x,y,
    output wire [71:0] window_pixels,
    output reg out_de,output reg [11:0] out_x,out_y
);
    reg [7:0] gray_d1;
    reg [11:0] x_d1,y_d1;
    reg de_d1;
    wire [7:0] rows[0:1];
    genvar bank;
    generate for(bank=0;bank<2;bank=bank+1) begin: g_line
        wire [7:0] wr_data = bank==0 ? gray_d1 : rows[0];
        PH1P_LOGIC_ERAM #(
            .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
            .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
            .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),.CLKMODE("ASYNC"),
            .SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),
            .RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
            .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),
            .INIT_FILE("NONE"),.FILL_ALL("NONE")
        ) u_line_eram(
            .dia(wr_data),.dib(8'd0),.addra(x_d1[10:0]),.addrb(x[10:0]),
            .cea(de_d1 && rst_n),.ceb(de && rst_n),.ocea(1'b0),.oceb(1'b0),
            .clka(clk),.clkb(clk),.wea(de_d1 && rst_n),.web(1'b0),
            .bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(rows[bank]),
            .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
    end endgenerate
    reg [7:0] p11,p12,p13,p21,p22,p23,p31,p32,p33;
    wire [7:0] prev1 = y_d1>=12'd1 ? rows[0] : 8'd0;
    wire [7:0] prev2 = y_d1>=12'd2 ? rows[1] : 8'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            gray_d1<=0;x_d1<=0;y_d1<=0;de_d1<=0;out_de<=0;out_x<=0;out_y<=0;
            p11<=0;p12<=0;p13<=0;p21<=0;p22<=0;p23<=0;p31<=0;p32<=0;p33<=0;
        end else begin
            gray_d1<=gray;x_d1<=x;y_d1<=y;de_d1<=de && x<MAX_WIDTH;
            out_de<=de_d1;out_x<=x_d1;out_y<=y_d1;
            if(de_d1) begin
                p11 <= x_d1==0 ? 8'd0 : p12;
                p12 <= x_d1==0 ? 8'd0 : p13;
                p13 <= prev2;
                p21 <= x_d1==0 ? 8'd0 : p22;
                p22 <= x_d1==0 ? 8'd0 : p23;
                p23 <= prev1;
                p31 <= x_d1==0 ? 8'd0 : p32;
                p32 <= x_d1==0 ? 8'd0 : p33;
                p33 <= gray_d1;
            end else begin
                // Clear horizontal registers in blanking.
                p11<=0;p12<=0;p13<=0;p21<=0;p22<=0;p23<=0;p31<=0;p32<=0;p33<=0;
            end
        end
    end
    assign window_pixels={p11,p12,p13,p21,p22,p23,p31,p32,p33};
endmodule

module bilateral_median9_v1(input wire clk,rst_n,input wire [71:0] pixels,
    output reg [7:0] median_gray);
    function [7:0] min3;input [7:0] a,b,c;
        begin min3=(a<=b && a<=c)?a:((b<=c)?b:c);end endfunction
    function [7:0] max3;input [7:0] a,b,c;
        begin max3=(a>=b && a>=c)?a:((b>=c)?b:c);end endfunction
    function [7:0] med3;input [7:0] a,b,c;
        begin med3=((a>=b && a<=c)||(a<=b && a>=c))?a:
            (((b>=a && b<=c)||(b<=a && b>=c))?b:c);end endfunction
    reg [7:0] lo[0:2],mi[0:2],hi[0:2];
    reg [7:0] a,b,c;
    integer row;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(row=0;row<3;row=row+1) begin lo[row]<=0;mi[row]<=0;hi[row]<=0;end
            a<=0;b<=0;c<=0;median_gray<=0;
        end else begin
            for(row=0;row<3;row=row+1) begin
                lo[row]<=min3(pixels[71-row*24-:8],pixels[63-row*24-:8],pixels[55-row*24-:8]);
                mi[row]<=med3(pixels[71-row*24-:8],pixels[63-row*24-:8],pixels[55-row*24-:8]);
                hi[row]<=max3(pixels[71-row*24-:8],pixels[63-row*24-:8],pixels[55-row*24-:8]);
            end
            a<=max3(lo[0],lo[1],lo[2]);b<=med3(mi[0],mi[1],mi[2]);c<=min3(hi[0],hi[1],hi[2]);
            median_gray<=med3(a,b,c);
        end
    end
endmodule

// Matrix arithmetic compatibility core, 12-clock input-to-output latency.
// Each window uses its own similarity weights; one weight alignment register
// preserves the existing 12-clock core / 20-clock filter interface latency.
// No divider; floor(log2(sum(weights))) shift and 255 saturation are retained.
module bilateral_weighted_core_v1(input wire clk,rst_n,
    input wire [71:0] pixels,input wire border,output reg [7:0] gray);
    function [9:0] similarity_lut;
        input [7:0] d;
        begin
            case (d)
            8'h00: similarity_lut = 10'd1023;
            8'h01: similarity_lut = 10'd1022;
            8'h02: similarity_lut = 10'd1022;
            8'h03: similarity_lut = 10'd1022;
            8'h04: similarity_lut = 10'd1021;
            8'h05: similarity_lut = 10'd1020;
            8'h06: similarity_lut = 10'd1019;
            8'h07: similarity_lut = 10'd1018;
            8'h08: similarity_lut = 10'd1017;
            8'h09: similarity_lut = 10'd1015;
            8'h0A: similarity_lut = 10'd1014;
            8'h0B: similarity_lut = 10'd1012;
            8'h0C: similarity_lut = 10'd1010;
            8'h0D: similarity_lut = 10'd1008;
            8'h0E: similarity_lut = 10'd1006;
            8'h0F: similarity_lut = 10'd1003;
            8'h10: similarity_lut = 10'd1000;
            8'h11: similarity_lut = 10'd998;
            8'h12: similarity_lut = 10'd995;
            8'h13: similarity_lut = 10'd991;
            8'h14: similarity_lut = 10'd988;
            8'h15: similarity_lut = 10'd985;
            8'h16: similarity_lut = 10'd981;
            8'h17: similarity_lut = 10'd977;
            8'h18: similarity_lut = 10'd973;
            8'h19: similarity_lut = 10'd969;
            8'h1A: similarity_lut = 10'd965;
            8'h1B: similarity_lut = 10'd961;
            8'h1C: similarity_lut = 10'd956;
            8'h1D: similarity_lut = 10'd952;
            8'h1E: similarity_lut = 10'd947;
            8'h1F: similarity_lut = 10'd942;
            8'h20: similarity_lut = 10'd937;
            8'h21: similarity_lut = 10'd932;
            8'h22: similarity_lut = 10'd926;
            8'h23: similarity_lut = 10'd921;
            8'h24: similarity_lut = 10'd915;
            8'h25: similarity_lut = 10'd910;
            8'h26: similarity_lut = 10'd904;
            8'h27: similarity_lut = 10'd898;
            8'h28: similarity_lut = 10'd892;
            8'h29: similarity_lut = 10'd886;
            8'h2A: similarity_lut = 10'd879;
            8'h2B: similarity_lut = 10'd873;
            8'h2C: similarity_lut = 10'd867;
            8'h2D: similarity_lut = 10'd860;
            8'h2E: similarity_lut = 10'd853;
            8'h2F: similarity_lut = 10'd847;
            8'h30: similarity_lut = 10'd840;
            8'h31: similarity_lut = 10'd833;
            8'h32: similarity_lut = 10'd826;
            8'h33: similarity_lut = 10'd819;
            8'h34: similarity_lut = 10'd811;
            8'h35: similarity_lut = 10'd804;
            8'h36: similarity_lut = 10'd797;
            8'h37: similarity_lut = 10'd790;
            8'h38: similarity_lut = 10'd782;
            8'h39: similarity_lut = 10'd775;
            8'h3A: similarity_lut = 10'd767;
            8'h3B: similarity_lut = 10'd759;
            8'h3C: similarity_lut = 10'd752;
            8'h3D: similarity_lut = 10'd744;
            8'h3E: similarity_lut = 10'd736;
            8'h3F: similarity_lut = 10'd728;
            8'h40: similarity_lut = 10'd720;
            8'h41: similarity_lut = 10'd713;
            8'h42: similarity_lut = 10'd705;
            8'h43: similarity_lut = 10'd697;
            8'h44: similarity_lut = 10'd689;
            8'h45: similarity_lut = 10'd681;
            8'h46: similarity_lut = 10'd673;
            8'h47: similarity_lut = 10'd665;
            8'h48: similarity_lut = 10'd656;
            8'h49: similarity_lut = 10'd648;
            8'h4A: similarity_lut = 10'd640;
            8'h4B: similarity_lut = 10'd632;
            8'h4C: similarity_lut = 10'd624;
            8'h4D: similarity_lut = 10'd616;
            8'h4E: similarity_lut = 10'd608;
            8'h4F: similarity_lut = 10'd600;
            8'h50: similarity_lut = 10'd592;
            8'h51: similarity_lut = 10'd584;
            8'h52: similarity_lut = 10'd575;
            8'h53: similarity_lut = 10'd567;
            8'h54: similarity_lut = 10'd559;
            8'h55: similarity_lut = 10'd551;
            8'h56: similarity_lut = 10'd543;
            8'h57: similarity_lut = 10'd535;
            8'h58: similarity_lut = 10'd527;
            8'h59: similarity_lut = 10'd519;
            8'h5A: similarity_lut = 10'd512;
            8'h5B: similarity_lut = 10'd504;
            8'h5C: similarity_lut = 10'd496;
            8'h5D: similarity_lut = 10'd488;
            8'h5E: similarity_lut = 10'd480;
            8'h5F: similarity_lut = 10'd473;
            8'h60: similarity_lut = 10'd465;
            8'h61: similarity_lut = 10'd457;
            8'h62: similarity_lut = 10'd450;
            8'h63: similarity_lut = 10'd442;
            8'h64: similarity_lut = 10'd435;
            8'h65: similarity_lut = 10'd427;
            8'h66: similarity_lut = 10'd420;
            8'h67: similarity_lut = 10'd413;
            8'h68: similarity_lut = 10'd406;
            8'h69: similarity_lut = 10'd398;
            8'h6A: similarity_lut = 10'd391;
            8'h6B: similarity_lut = 10'd384;
            8'h6C: similarity_lut = 10'd377;
            8'h6D: similarity_lut = 10'd370;
            8'h6E: similarity_lut = 10'd363;
            8'h6F: similarity_lut = 10'd357;
            8'h70: similarity_lut = 10'd350;
            8'h71: similarity_lut = 10'd343;
            8'h72: similarity_lut = 10'd337;
            8'h73: similarity_lut = 10'd330;
            8'h74: similarity_lut = 10'd324;
            8'h75: similarity_lut = 10'd317;
            8'h76: similarity_lut = 10'd311;
            8'h77: similarity_lut = 10'd305;
            8'h78: similarity_lut = 10'd298;
            8'h79: similarity_lut = 10'd292;
            8'h7A: similarity_lut = 10'd286;
            8'h7B: similarity_lut = 10'd280;
            8'h7C: similarity_lut = 10'd275;
            8'h7D: similarity_lut = 10'd269;
            8'h7E: similarity_lut = 10'd263;
            8'h7F: similarity_lut = 10'd257;
            8'h80: similarity_lut = 10'd252;
            8'h81: similarity_lut = 10'd246;
            8'h82: similarity_lut = 10'd241;
            8'h83: similarity_lut = 10'd236;
            8'h84: similarity_lut = 10'd230;
            8'h85: similarity_lut = 10'd225;
            8'h86: similarity_lut = 10'd220;
            8'h87: similarity_lut = 10'd215;
            8'h88: similarity_lut = 10'd210;
            8'h89: similarity_lut = 10'd205;
            8'h8A: similarity_lut = 10'd201;
            8'h8B: similarity_lut = 10'd196;
            8'h8C: similarity_lut = 10'd191;
            8'h8D: similarity_lut = 10'd187;
            8'h8E: similarity_lut = 10'd182;
            8'h8F: similarity_lut = 10'd178;
            8'h90: similarity_lut = 10'd173;
            8'h91: similarity_lut = 10'd169;
            8'h92: similarity_lut = 10'd165;
            8'h93: similarity_lut = 10'd161;
            8'h94: similarity_lut = 10'd157;
            8'h95: similarity_lut = 10'd153;
            8'h96: similarity_lut = 10'd149;
            8'h97: similarity_lut = 10'd145;
            8'h98: similarity_lut = 10'd142;
            8'h99: similarity_lut = 10'd138;
            8'h9A: similarity_lut = 10'd134;
            8'h9B: similarity_lut = 10'd131;
            8'h9C: similarity_lut = 10'd127;
            8'h9D: similarity_lut = 10'd124;
            8'h9E: similarity_lut = 10'd121;
            8'h9F: similarity_lut = 10'd117;
            8'hA0: similarity_lut = 10'd114;
            8'hA1: similarity_lut = 10'd111;
            8'hA2: similarity_lut = 10'd108;
            8'hA3: similarity_lut = 10'd105;
            8'hA4: similarity_lut = 10'd102;
            8'hA5: similarity_lut = 10'd99;
            8'hA6: similarity_lut = 10'd97;
            8'hA7: similarity_lut = 10'd94;
            8'hA8: similarity_lut = 10'd91;
            8'hA9: similarity_lut = 10'd89;
            8'hAA: similarity_lut = 10'd86;
            8'hAB: similarity_lut = 10'd84;
            8'hAC: similarity_lut = 10'd81;
            8'hAD: similarity_lut = 10'd79;
            8'hAE: similarity_lut = 10'd76;
            8'hAF: similarity_lut = 10'd74;
            8'hB0: similarity_lut = 10'd72;
            8'hB1: similarity_lut = 10'd70;
            8'hB2: similarity_lut = 10'd68;
            8'hB3: similarity_lut = 10'd66;
            8'hB4: similarity_lut = 10'd64;
            8'hB5: similarity_lut = 10'd62;
            8'hB6: similarity_lut = 10'd60;
            8'hB7: similarity_lut = 10'd58;
            8'hB8: similarity_lut = 10'd56;
            8'hB9: similarity_lut = 10'd54;
            8'hBA: similarity_lut = 10'd53;
            8'hBB: similarity_lut = 10'd51;
            8'hBC: similarity_lut = 10'd49;
            8'hBD: similarity_lut = 10'd48;
            8'hBE: similarity_lut = 10'd46;
            8'hBF: similarity_lut = 10'd45;
            8'hC0: similarity_lut = 10'd43;
            8'hC1: similarity_lut = 10'd42;
            8'hC2: similarity_lut = 10'd41;
            8'hC3: similarity_lut = 10'd39;
            8'hC4: similarity_lut = 10'd38;
            8'hC5: similarity_lut = 10'd37;
            8'hC6: similarity_lut = 10'd35;
            8'hC7: similarity_lut = 10'd34;
            8'hC8: similarity_lut = 10'd33;
            8'hC9: similarity_lut = 10'd32;
            8'hCA: similarity_lut = 10'd31;
            8'hCB: similarity_lut = 10'd30;
            8'hCC: similarity_lut = 10'd29;
            8'hCD: similarity_lut = 10'd28;
            8'hCE: similarity_lut = 10'd27;
            8'hCF: similarity_lut = 10'd26;
            8'hD0: similarity_lut = 10'd25;
            8'hD1: similarity_lut = 10'd24;
            8'hD2: similarity_lut = 10'd23;
            8'hD3: similarity_lut = 10'd22;
            8'hD4: similarity_lut = 10'd21;
            8'hD5: similarity_lut = 10'd21;
            8'hD6: similarity_lut = 10'd20;
            8'hD7: similarity_lut = 10'd19;
            8'hD8: similarity_lut = 10'd18;
            8'hD9: similarity_lut = 10'd18;
            8'hDA: similarity_lut = 10'd17;
            8'hDB: similarity_lut = 10'd16;
            8'hDC: similarity_lut = 10'd16;
            8'hDD: similarity_lut = 10'd15;
            8'hDE: similarity_lut = 10'd15;
            8'hDF: similarity_lut = 10'd14;
            8'hE0: similarity_lut = 10'd14;
            8'hE1: similarity_lut = 10'd13;
            8'hE2: similarity_lut = 10'd13;
            8'hE3: similarity_lut = 10'd12;
            8'hE4: similarity_lut = 10'd12;
            8'hE5: similarity_lut = 10'd11;
            8'hE6: similarity_lut = 10'd11;
            8'hE7: similarity_lut = 10'd10;
            8'hE8: similarity_lut = 10'd10;
            8'hE9: similarity_lut = 10'd9;
            8'hEA: similarity_lut = 10'd9;
            8'hEB: similarity_lut = 10'd9;
            8'hEC: similarity_lut = 10'd8;
            8'hED: similarity_lut = 10'd8;
            8'hEE: similarity_lut = 10'd8;
            8'hEF: similarity_lut = 10'd7;
            8'hF0: similarity_lut = 10'd7;
            8'hF1: similarity_lut = 10'd7;
            8'hF2: similarity_lut = 10'd6;
            8'hF3: similarity_lut = 10'd6;
            8'hF4: similarity_lut = 10'd6;
            8'hF5: similarity_lut = 10'd6;
            8'hF6: similarity_lut = 10'd5;
            8'hF7: similarity_lut = 10'd5;
            8'hF8: similarity_lut = 10'd5;
            8'hF9: similarity_lut = 10'd5;
            8'hFA: similarity_lut = 10'd4;
            8'hFB: similarity_lut = 10'd4;
            8'hFC: similarity_lut = 10'd4;
            8'hFD: similarity_lut = 10'd4;
            8'hFE: similarity_lut = 10'd4;
            8'hFF: similarity_lut = 10'd3;
                default: similarity_lut = 10'd0;
            endcase
        end
    endfunction
    function [4:0] leading_one;input [21:0] d;integer bit_i;
        begin leading_one=0;for(bit_i=0;bit_i<22;bit_i=bit_i+1)
            if(d[bit_i]) leading_one=bit_i;end endfunction

    reg [71:0] pixel_pipe[0:5];
    reg [11:0] border_pipe;
    reg [7:0] center_pipe[0:10];
    reg [7:0] diff[0:8];
    reg [9:0] similarity[0:8];
    // S*G has identical outside columns. Factor them algebraically without
    // changing a single integer: A=109*(s0+s2)+115*s1, B=115*(s0+s2)+122*s1.
    reg [10:0] side_sim[0:2];reg [9:0] mid_sim[0:2];
    (* dsp_style="yes" *) reg [17:0] a_side[0:2],a_mid[0:2],b_side[0:2],b_mid[0:2];
    reg [18:0] wa[0:2],wb[0:2];
    reg [18:0] wa_d6[0:2],wb_d6[0:2];
    reg [27:0] prod_side[0:2];reg [26:0] prod_mid[0:2];
    reg [19:0] denominator_row_d6[0:2],denominator_row_d7[0:2];
    reg [28:0] numerator_row[0:2];
    reg [29:0] numerator,numerator_d9,normalized;
    reg [21:0] denominator;
    reg [4:0] norm_shift;
    reg nonzero_d9,nonzero_d10;
    wire [8:0] pair_pixel[0:2];
    genvar r;
    generate for(r=0;r<3;r=r+1) begin:g_pair
        assign pair_pixel[r]={1'b0,pixel_pipe[5][71-r*24-:8]}+
                             {1'b0,pixel_pipe[5][55-r*24-:8]};
    end endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(i=0;i<6;i=i+1)pixel_pipe[i]<=0;
            for(i=0;i<11;i=i+1)center_pipe[i]<=0;
            border_pipe<=0;
            for(i=0;i<9;i=i+1)begin diff[i]<=0;similarity[i]<=0;end
            for(i=0;i<3;i=i+1)begin
                side_sim[i]<=0;mid_sim[i]<=0;a_side[i]<=0;a_mid[i]<=0;b_side[i]<=0;b_mid[i]<=0;
                wa[i]<=0;wb[i]<=0;wa_d6[i]<=0;wb_d6[i]<=0;prod_side[i]<=0;prod_mid[i]<=0;
                denominator_row_d6[i]<=0;denominator_row_d7[i]<=0;numerator_row[i]<=0;
            end
            numerator<=0;denominator<=0;numerator_d9<=0;norm_shift<=0;
            normalized<=0;nonzero_d9<=0;nonzero_d10<=0;gray<=0;
        end else begin
            pixel_pipe[0]<=pixels;
            for(i=1;i<6;i=i+1)pixel_pipe[i]<=pixel_pipe[i-1];
            center_pipe[0]<=pixels[39:32];
            for(i=1;i<11;i=i+1)center_pipe[i]<=center_pipe[i-1];
            border_pipe<={border_pipe[10:0],border};
            // T1 differences, T2 exact LUT, T3 similarity row sums.
            for(i=0;i<9;i=i+1)begin
                diff[i]<=pixels[71-i*8-:8]>=pixels[39:32] ?
                         pixels[71-i*8-:8]-pixels[39:32] : pixels[39:32]-pixels[71-i*8-:8];
                similarity[i]<=similarity_lut(diff[i]);
            end
            for(i=0;i<3;i=i+1)begin
                side_sim[i]<={1'b0,similarity[i*3]}+{1'b0,similarity[i*3+2]};
                mid_sim[i]<=similarity[i*3+1];
                // T4 constant products, T5 weights.
                a_side[i]<=side_sim[i]*7'd109;a_mid[i]<=mid_sim[i]*7'd115;
                b_side[i]<=side_sim[i]*7'd115;b_mid[i]<=mid_sim[i]*7'd122;
                wa[i]<={1'b0,a_side[i]}+{1'b0,a_mid[i]};
                wb[i]<={1'b0,b_side[i]}+{1'b0,b_mid[i]};
                // T6 align weights with the six-register pixel window.
                wa_d6[i]<=wa[i];wb_d6[i]<=wb[i];
                // T7 multiply and denominator from the SAME window.
                prod_side[i]<=wa_d6[i]*pair_pixel[i];
                prod_mid[i]<=wb_d6[i]*pixel_pipe[5][63-i*24-:8];
                denominator_row_d6[i]<={wa_d6[i],1'b0}+{1'b0,wb_d6[i]};
                // T8 row sums; T9 frame-window total (legacy register names).
                numerator_row[i]<={1'b0,prod_side[i]}+{2'd0,prod_mid[i]};
                denominator_row_d7[i]<=denominator_row_d6[i];
            end
            numerator<={1'b0,numerator_row[0]}+{1'b0,numerator_row[1]}+{1'b0,numerator_row[2]};
            denominator<={2'd0,denominator_row_d7[0]}+{2'd0,denominator_row_d7[1]}+{2'd0,denominator_row_d7[2]};
            // T10 encode, T11 shift, T12 clamp / aligned border bypass.
            norm_shift<=leading_one(denominator);numerator_d9<=numerator;nonzero_d9<=|denominator;
            normalized<=numerator_d9>>norm_shift;nonzero_d10<=nonzero_d9;
            if(border_pipe[10] || !nonzero_d10) gray<=center_pipe[10];
            else gray<=|normalized[29:8] ? 8'hff : normalized[7:0];
        end
    end
endmodule
