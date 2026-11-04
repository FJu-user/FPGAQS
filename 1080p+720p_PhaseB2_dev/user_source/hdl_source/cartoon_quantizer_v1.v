`timescale 1ns / 1ns

// Stateless 8-level-per-channel colour quantizer for Mode 11 Cartoon Lite.
//
// The three most-significant bits select one of eight levels. Replicating
// those bits back across the byte maps 3'b000 to 0 and 3'b111 to 255 without
// an adder, multiplier, divider, RAM or DSP. The result is registered by the
// existing pixel_chain_v1 stage-4 register and then follows its shared delay.
module cartoon_quantizer_v1 (
    input  wire [23:0] I_rgb,
    output wire [23:0] O_rgb
);

function [7:0] quantize_channel;
    input [7:0] channel;
    begin
        quantize_channel = {channel[7:5], channel[7:5], channel[7:6]};
    end
endfunction

assign O_rgb = {
    quantize_channel(I_rgb[23:16]),
    quantize_channel(I_rgb[15:8]),
    quantize_channel(I_rgb[7:0])
};

endmodule
