`timescale 1ns / 1ns

// Shared colour-preserving Gamma and preceding-frame histogram equalization.
// Both paths transform luma, then apply the signed luma delta to RGB with
// saturation.  The output contract is three clocks, one pixel per clock.
module luma_tone_modes_v1 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_soft_reset,
    input  wire [23:0] I_rgb,
    input  wire [7:0]  I_luma,
    input  wire        I_de,
    input  wire [11:0] I_x,
    input  wire [11:0] I_y,
    input  wire        I_frame_end,
    input  wire        I_frame_is_new,
    output reg  [23:0] O_gamma_rgb,
    output reg  [23:0] O_hist_rgb,
    output reg         O_valid
);

function [7:0] sat_add;
    input [7:0] base;
    input signed [8:0] delta;
    reg signed [9:0] value;
    begin
        value = $signed({2'b00,base}) + $signed({delta[8],delta});
        if(value < 0)
            sat_add = 8'd0;
        else if(value > 10'sd255)
            sat_add = 8'd255;
        else
            sat_add = value[7:0];
    end
endfunction

// -------------------------------------------------------------------------
// Gamma 1/2.2 approximation: 16 linear segments.  These knot points are the
// rounded values of 255*(Y/255)^(1/2.2).  This is the useful display-correction
// direction; ronghe's Curve_Gamma_2P2 table instead computes Y^2.2 and darkens.
// -------------------------------------------------------------------------
reg [7:0] gamma_base_c;
reg [7:0] gamma_rise_c;
reg [7:0] gamma_dark_c;
always @(*) begin
    case(I_luma[7:4])
        4'h0: begin gamma_base_c=8'd0;   gamma_rise_c=8'd72; end
        4'h1: begin gamma_base_c=8'd72;  gamma_rise_c=8'd27; end
        4'h2: begin gamma_base_c=8'd99;  gamma_rise_c=8'd20; end
        4'h3: begin gamma_base_c=8'd119; gamma_rise_c=8'd17; end
        4'h4: begin gamma_base_c=8'd136; gamma_rise_c=8'd15; end
        4'h5: begin gamma_base_c=8'd151; gamma_rise_c=8'd13; end
        4'h6: begin gamma_base_c=8'd164; gamma_rise_c=8'd11; end
        4'h7: begin gamma_base_c=8'd175; gamma_rise_c=8'd11; end
        4'h8: begin gamma_base_c=8'd186; gamma_rise_c=8'd11; end
        4'h9: begin gamma_base_c=8'd197; gamma_rise_c=8'd9;  end
        4'hA: begin gamma_base_c=8'd206; gamma_rise_c=8'd9;  end
        4'hB: begin gamma_base_c=8'd215; gamma_rise_c=8'd9;  end
        4'hC: begin gamma_base_c=8'd224; gamma_rise_c=8'd8;  end
        4'hD: begin gamma_base_c=8'd232; gamma_rise_c=8'd8;  end
        4'hE: begin gamma_base_c=8'd240; gamma_rise_c=8'd8;  end
        default: begin gamma_base_c=8'd248; gamma_rise_c=8'd8; end
    endcase
    case(I_luma[3:0])
        4'h0: gamma_dark_c=8'd0;  4'h1: gamma_dark_c=8'd21;
        4'h2: gamma_dark_c=8'd28; 4'h3: gamma_dark_c=8'd34;
        4'h4: gamma_dark_c=8'd39; 4'h5: gamma_dark_c=8'd43;
        4'h6: gamma_dark_c=8'd46; 4'h7: gamma_dark_c=8'd50;
        4'h8: gamma_dark_c=8'd53; 4'h9: gamma_dark_c=8'd56;
        4'hA: gamma_dark_c=8'd59; 4'hB: gamma_dark_c=8'd61;
        4'hC: gamma_dark_c=8'd64; 4'hD: gamma_dark_c=8'd66;
        4'hE: gamma_dark_c=8'd68; default: gamma_dark_c=8'd70;
    endcase
end

reg [7:0] gamma_base_s1, gamma_rise_s1, gamma_luma_s1;
reg [7:0] gamma_dark_s1;
reg gamma_dark_valid_s1;
reg [3:0] gamma_frac_s1;
reg [23:0] gamma_rgb_s1;
reg gamma_de_s1;

wire [10:0] gamma_product_s1 =
    (gamma_frac_s1[0] ? {3'd0,gamma_rise_s1}       : 11'd0) +
    (gamma_frac_s1[1] ? {2'd0,gamma_rise_s1,1'b0} : 11'd0) +
    (gamma_frac_s1[2] ? {1'd0,gamma_rise_s1,2'b0} : 11'd0) +
    (gamma_frac_s1[3] ? {gamma_rise_s1,3'b0}      : 11'd0);
wire [8:0] gamma_interp_s1 = {1'b0,gamma_base_s1} +
                              ((gamma_product_s1 + 11'd8) >> 4);

// Sandbox only: bit-exact table replaces the existing S1/S2 gamma map.
reg [7:0] gamma_exact [0:255] /* synthesis rom_style=bram */;
initial $readmemh("gamma_exact.hex",gamma_exact);
reg [7:0] gamma_lookup_s1;
reg gamma_rom_live;
always @(posedge I_clk) gamma_lookup_s1<=gamma_exact[I_luma];
always @(posedge I_clk or negedge I_rst_n)
    if(!I_rst_n)gamma_rom_live<=0;else gamma_rom_live<=1;
reg [7:0] gamma_y_s2, gamma_luma_s2;
reg [23:0] gamma_rgb_s2;
reg gamma_de_s2;

// -------------------------------------------------------------------------
// 32-bin histogram accumulated only for a genuinely new camera frame.
// A complete preceding-frame LUT is updated during vertical blanking.
// -------------------------------------------------------------------------

reg [7:0] hist_lut [0:31];
reg calc_active;
reg [5:0] calc_index;
reg [13:0] cdf_acc;
reg calc_is_1080;
reg hist_lut_ready;
reg [2:0] calc_state;
wire [13:0] calc_bin_count;
reg [14:0] calc_cdf_next;
reg [7:0] calc_map_value;
integer i;

localparam [2:0] CALC_IDLE  = 3'd0;
localparam [2:0] CALC_READ  = 3'd1;
localparam [2:0] CALC_ACCUM = 3'd2;
localparam [2:0] CALC_MAP   = 3'd3;
localparam [2:0] CALC_WRITE = 3'd4;

wire hist_sample = I_de && I_frame_is_new &&
                   (I_x[3:0] == 4'd0) && (I_y[3:0] == 4'd0);
wire [4:0] hist_sample_bin = I_luma[7:3];
reg hist_sample_s1, hist_sample_s2;
reg [4:0] hist_bin_s1, hist_bin_s2;
wire [13:0] hist_count_s2;
// 720p has exactly 3600 sparse samples.  145/2048 approximates 255/3600.
// The registered CDF feeds a balanced two-level adder tree.  The LUT writer
// therefore no longer contains histogram mux + CDF add + normalization in
// one 149.343 MHz path.

// Exact original case admission, including frame-end priority.
wire store_run=I_rst_n && !I_soft_reset;
wire store_frame_begin=I_frame_end && I_frame_is_new && !calc_active;
wire store_calc_read=store_run && !store_frame_begin && calc_state==CALC_READ;
wire store_calc_write=store_run && !store_frame_begin && calc_state==CALC_WRITE;

reg [31:0] hist_valid;
wire hist_we=store_run && hist_sample_s2;
wire [13:0] hist_wdata=hist_count_s2+14'd1;
wire [13:0] sample_raw,calc_raw;
reg sample_live,sample_valid_d,sample_hit_d;
reg calc_live,calc_valid_d,calc_hit_d;
reg [13:0] sample_old_d,calc_old_d;
reg hist_last_write;
reg [4:0] hist_last_addr;
reg [13:0] hist_last_data;
// Current write was pre-read by the sample port on the preceding edge.
// A write on that preceding edge is the sole possible intervening raw change.
wire [13:0] hist_old_write=(hist_last_write && hist_last_addr==hist_bin_s2)?hist_last_data:sample_raw;
assign hist_count_s2=!sample_live || !sample_valid_d ? 14'd0 : sample_hit_d?sample_old_d:sample_raw;
assign calc_bin_count=!calc_live || !calc_valid_d ? 14'd0 : calc_hit_d?calc_old_d:calc_raw;
storage_dp #(.WIDTH(14))u_hist_sample(.clk(I_clk),.we(hist_we),.wa({4'd0,hist_bin_s2}),.wd(hist_wdata),
 .read_en(store_run&&hist_sample_s1),.ra({4'd0,hist_bin_s1}),.qa(),.qb(sample_raw));
storage_dp #(.WIDTH(14))u_hist_calc(.clk(I_clk),.we(hist_we),.wa({4'd0,hist_bin_s2}),.wd(hist_wdata),
 .read_en(store_calc_read),.ra({4'd0,calc_index[4:0]}),.qa(),.qb(calc_raw));
always@(posedge I_clk or negedge I_rst_n)begin
 if(!I_rst_n)begin
  hist_valid<=0;sample_live<=0;sample_valid_d<=0;sample_hit_d<=0;sample_old_d<=0;
  calc_live<=0;calc_valid_d<=0;calc_hit_d<=0;calc_old_d<=0;
  hist_last_write<=0;hist_last_addr<=0;hist_last_data<=0;
 end else if(I_soft_reset)begin
  hist_valid<=0;sample_live<=0;sample_valid_d<=0;sample_hit_d<=0;sample_old_d<=0;
  calc_live<=0;calc_valid_d<=0;calc_hit_d<=0;calc_old_d<=0;
  hist_last_write<=0;hist_last_addr<=0;hist_last_data<=0;
 end else begin
  if(hist_we)hist_valid[hist_bin_s2]<=1;
  if(store_calc_write)hist_valid[calc_index[4:0]]<=0;
  hist_last_write<=hist_we;
  if(hist_we)begin hist_last_addr<=hist_bin_s2;hist_last_data<=hist_wdata;end
  if(hist_sample_s1)begin
   sample_live<=1;sample_valid_d<=hist_valid[hist_bin_s1];
   sample_hit_d<=hist_we && hist_bin_s1==hist_bin_s2;sample_old_d<=hist_old_write;
  end
  if(store_calc_read)begin
   calc_live<=1;calc_valid_d<=hist_valid[calc_index[4:0]];
   calc_hit_d<=hist_we && calc_index[4:0]==hist_bin_s2;calc_old_d<=hist_old_write;
  end
 end
end
`ifdef STORAGE_TABLE_VIEW
wire [13:0] histogram[0:31];
genvar hv;
generate for(hv=0;hv<32;hv=hv+1)begin:hist_view
 assign histogram[hv]=hist_valid[hv]?u_hist_sample.u_ram.mem[hv]:14'd0;
end endgenerate
`endif

wire [22:0] calc_norm_hi = ({8'd0,calc_cdf_next} << 7) +
                            ({8'd0,calc_cdf_next} << 4);
wire [22:0] calc_norm_lo = {8'd0,calc_cdf_next} + 23'd1024;
wire [22:0] calc_norm_720 = calc_norm_hi + calc_norm_lo;
wire [8:0] calc_map_720 = calc_norm_720 >> 11;
wire [8:0] calc_map_1080 = calc_cdf_next >> 5; // 8160 samples = 255*32
wire [8:0] calc_map_selected = calc_is_1080 ?
                                calc_map_1080 : calc_map_720;
wire [7:0] calc_map_clamped = calc_map_selected[8] ?
                               8'hff : calc_map_selected[7:0];

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        calc_active <= 1'b0;
        calc_index <= 6'd0;
        cdf_acc <= 14'd0;
        calc_is_1080 <= 1'b0;
        hist_lut_ready <= 1'b0;
        calc_state <= CALC_IDLE;
        calc_cdf_next <= 15'd0;
        calc_map_value <= 8'd0;
        hist_sample_s1 <= 1'b0; hist_sample_s2 <= 1'b0;
        hist_bin_s1 <= 5'd0; hist_bin_s2 <= 5'd0;
        for(i=0;i<32;i=i+1) begin
            hist_lut[i] <= i * 8;
        end
    end else if(I_soft_reset) begin
        calc_active <= 1'b0;
        calc_index <= 6'd0;
        cdf_acc <= 14'd0;
        calc_is_1080 <= 1'b0;
        hist_lut_ready <= 1'b0;
        calc_state <= CALC_IDLE;
        calc_cdf_next <= 15'd0;
        calc_map_value <= 8'd0;
        hist_sample_s1 <= 1'b0; hist_sample_s2 <= 1'b0;
        hist_bin_s1 <= 5'd0; hist_bin_s2 <= 5'd0;
        for(i=0;i<32;i=i+1) begin
            hist_lut[i] <= i * 8;
        end
    end else begin
        // Samples are 16 active pixels apart, so a three-stage
        // index/read/write pipeline is hazard-free and avoids a long
        // 32-way-select + increment + decoder path in one 149.343 MHz cycle.
        hist_sample_s1 <= hist_sample;
        hist_bin_s1 <= hist_sample_bin;
        hist_sample_s2 <= hist_sample_s1;
        hist_bin_s2 <= hist_bin_s1;

        if(I_frame_end && I_frame_is_new && !calc_active) begin
            calc_active <= 1'b1;
            calc_index <= 6'd0;
            cdf_acc <= 14'd0;
            calc_is_1080 <= (I_y >= 12'd1000);
            calc_state <= CALC_READ;
        end else begin
            case(calc_state)
                CALC_READ: begin
                    calc_state <= CALC_ACCUM;
                end
                CALC_ACCUM: begin
                    calc_cdf_next <= {1'b0,cdf_acc} +
                                     {1'b0,calc_bin_count};
                    calc_state <= CALC_MAP;
                end
                CALC_MAP: begin
                    calc_map_value <= calc_map_clamped;
                    calc_state <= CALC_WRITE;
                end
                CALC_WRITE: begin
                    hist_lut[calc_index[4:0]] <= calc_map_value;
                    cdf_acc <= calc_cdf_next[13:0];
                    if(calc_index == 6'd31) begin
                        calc_active <= 1'b0;
                        calc_index <= 6'd0;
                        hist_lut_ready <= 1'b1;
                        calc_state <= CALC_IDLE;
                    end else begin
                        calc_index <= calc_index + 6'd1;
                        calc_state <= CALC_READ;
                    end
                end
                default: begin
                    calc_active <= 1'b0;
                    calc_state <= CALC_IDLE;
                end
            endcase
        end
    end
end

reg [7:0] hist_lo_s1, hist_hi_s1, hist_luma_s1;
reg [2:0] hist_frac_s1;
reg [23:0] hist_rgb_s1;
reg hist_de_s1;
wire [4:0] hist_bin_next = (I_luma[7:3] == 5'd31) ?
                            5'd31 : (I_luma[7:3] + 5'd1);

wire [7:0] hist_rise_s1 = hist_hi_s1 - hist_lo_s1;
wire [10:0] hist_product_s1 =
    (hist_frac_s1[0] ? {3'd0,hist_rise_s1}       : 11'd0) +
    (hist_frac_s1[1] ? {2'd0,hist_rise_s1,1'b0} : 11'd0) +
    (hist_frac_s1[2] ? {1'd0,hist_rise_s1,2'b0} : 11'd0);
wire [8:0] hist_interp_s1 = {1'b0,hist_lo_s1} +
                             ((hist_product_s1 + 11'd4) >> 3);

reg [7:0] hist_y_s2, hist_luma_s2;
reg [23:0] hist_rgb_s2;
reg hist_de_s2;

always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        gamma_base_s1 <= 8'd0; gamma_rise_s1 <= 8'd0;
        gamma_dark_s1 <= 8'd0; gamma_dark_valid_s1 <= 1'b0;
        gamma_luma_s1 <= 8'd0; gamma_frac_s1 <= 4'd0;
        gamma_rgb_s1 <= 24'd0; gamma_de_s1 <= 1'b0;
        gamma_y_s2 <= 8'd0; gamma_luma_s2 <= 8'd0;
        gamma_rgb_s2 <= 24'd0; gamma_de_s2 <= 1'b0;
        hist_lo_s1 <= 8'd0; hist_hi_s1 <= 8'd0;
        hist_luma_s1 <= 8'd0; hist_frac_s1 <= 3'd0;
        hist_rgb_s1 <= 24'd0; hist_de_s1 <= 1'b0;
        hist_y_s2 <= 8'd0; hist_luma_s2 <= 8'd0;
        hist_rgb_s2 <= 24'd0; hist_de_s2 <= 1'b0;
        O_gamma_rgb <= 24'd0; O_hist_rgb <= 24'd0; O_valid <= 1'b0;
    end else begin
        gamma_base_s1 <= gamma_base_c;
        gamma_rise_s1 <= gamma_rise_c;
        gamma_dark_s1 <= gamma_dark_c;
        gamma_dark_valid_s1 <= (I_luma[7:4] == 4'd0);
        gamma_luma_s1 <= I_luma;
        gamma_frac_s1 <= I_luma[3:0];
        gamma_rgb_s1 <= I_rgb;
        gamma_de_s1 <= I_de;

        gamma_y_s2 <= gamma_rom_live ? gamma_lookup_s1 : 8'd0;
        gamma_luma_s2 <= gamma_luma_s1;
        gamma_rgb_s2 <= gamma_rgb_s1;
        gamma_de_s2 <= gamma_de_s1;

        hist_lo_s1 <= hist_lut[I_luma[7:3]];
        hist_hi_s1 <= hist_lut[hist_bin_next];
        hist_luma_s1 <= I_luma;
        hist_frac_s1 <= I_luma[2:0];
        hist_rgb_s1 <= I_rgb;
        hist_de_s1 <= I_de;

        hist_y_s2 <= hist_interp_s1[8] ? 8'hff : hist_interp_s1[7:0];
        hist_luma_s2 <= hist_luma_s1;
        hist_rgb_s2 <= hist_rgb_s1;
        hist_de_s2 <= hist_de_s1;

        O_gamma_rgb <= {
            sat_add(gamma_rgb_s2[23:16],
                    $signed({1'b0,gamma_y_s2})-$signed({1'b0,gamma_luma_s2})),
            sat_add(gamma_rgb_s2[15:8],
                    $signed({1'b0,gamma_y_s2})-$signed({1'b0,gamma_luma_s2})),
            sat_add(gamma_rgb_s2[7:0],
                    $signed({1'b0,gamma_y_s2})-$signed({1'b0,gamma_luma_s2}))
        };
        if(hist_lut_ready)
            O_hist_rgb <= {
                sat_add(hist_rgb_s2[23:16],
                        $signed({1'b0,hist_y_s2})-$signed({1'b0,hist_luma_s2})),
                sat_add(hist_rgb_s2[15:8],
                        $signed({1'b0,hist_y_s2})-$signed({1'b0,hist_luma_s2})),
                sat_add(hist_rgb_s2[7:0],
                        $signed({1'b0,hist_y_s2})-$signed({1'b0,hist_luma_s2}))
            };
        else
            O_hist_rgb <= hist_rgb_s2;
        O_valid <= gamma_de_s2 && hist_de_s2;
    end
end

endmodule
