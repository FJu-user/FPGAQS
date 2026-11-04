`timescale 1ns/1ps
// Three-clock overlay; backgrounds are exact native RGB, never recoloured.
// Only boxes/English labels are returned from B. Coordinates stay in B 720p
// space and are transformed before this module by the frame-latched mapper.
module remote_vision_osd #(parameter RESET_BANK=1,FRAME_LOCKED_INPUT=0)(input wire clk,rst_n,enable,input wire [23:0] rgb,input wire de,fs,
 input wire [127:0] coordinate_bcd,
 input wire [11:0] x,y,input wire [255:0] objects,input wire valid,input wire [3:0] count,
 output wire [23:0] out_rgb,output reg out_ink);
reg [127:0] coordinate_bank;
reg [255:0] bank;reg bank_valid;reg [3:0] bank_count;
wire [255:0] objs=FRAME_LOCKED_INPUT?objects:(fs?objects:bank);wire good=FRAME_LOCKED_INPUT?valid:(fs?valid:bank_valid);
wire [3:0] cnt=FRAME_LOCKED_INPUT?count:(fs?count:bank_count);
wire [127:0] coordinates=FRAME_LOCKED_INPUT?coordinate_bcd:coordinate_bank;
generate if(!FRAME_LOCKED_INPUT)begin:g_frame_bank
always @(posedge clk or negedge rst_n)
 if(!rst_n)bank_valid<=0;else if(fs)bank_valid<=valid;
// Invalid banks are never rendered. Keep reset only on the validity control.
if(RESET_BANK)begin:g_reset_bank
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin coordinate_bank<=0;bank<=0;bank_count<=0;end
  else if(fs)begin coordinate_bank<=coordinate_bcd;bank<=objects;bank_count<=count;end
end else begin:g_validated_bank
 always @(posedge clk)if(rst_n && fs)begin
  coordinate_bank<=coordinate_bcd;bank<=objects;bank_count<=count;
 end
end
end endgenerate
function [4:0] glyph_row;
    input [7:0] ch;
    input [2:0] row;
    begin
        glyph_row = 5'b00000;
        case(ch)
            "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0; endcase
            "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0; endcase
            "C": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0; endcase
            "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0; endcase
            "F": case(row) 0:glyph_row=31;1,2:glyph_row=16;3:glyph_row=30;4,5,6:glyph_row=16;default:glyph_row=0;endcase
            "P": case(row) 0,3:glyph_row=30;1,2:glyph_row=17;4,5,6:glyph_row=16;default:glyph_row=0;endcase
            "S": case(row) 0:glyph_row=15;1,2:glyph_row=16;3:glyph_row=14;4,5:glyph_row=1;6:glyph_row=30;default:glyph_row=0;endcase
            "V": case(row) 0,1,2,3,4:glyph_row=17;5:glyph_row=10;6:glyph_row=4;default:glyph_row=0;endcase
            "Y": case(row) 0,1:glyph_row=17;2:glyph_row=10;3,4,5,6:glyph_row=4;default:glyph_row=0;endcase
            "W": case(row) 0,1,2:glyph_row=17;3,4:glyph_row=21;5:glyph_row=27;6:glyph_row=17;default:glyph_row=0;endcase
            "&": case(row) 0:glyph_row=12;1:glyph_row=18;2:glyph_row=20;3:glyph_row=8;4:glyph_row=21;5:glyph_row=18;6:glyph_row=13;default:glyph_row=0;endcase
            "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "I": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b11111;default:glyph_row=0; endcase
            "J": case(row) 0:glyph_row=5'b00111;1,2,3,4:glyph_row=5'b00010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0; endcase
            "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0; endcase
            "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b11001;3:glyph_row=5'b10101;4:glyph_row=5'b10011;5:glyph_row=5'b10011;6:glyph_row=5'b10001;default:glyph_row=0; endcase
            "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "Q": case(row) 0:glyph_row=14;1,2,3:glyph_row=17;4:glyph_row=21;5:glyph_row=18;6:glyph_row=13;default:glyph_row=0;endcase
            "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0; endcase
            "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0; endcase
            "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0; endcase
            "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0; endcase
            "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0; endcase
            "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0; endcase
            "6": case(row) 0:glyph_row=5'b00110;1:glyph_row=5'b01000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0; endcase
            "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0; endcase
            "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00010;6:glyph_row=5'b01100;default:glyph_row=0; endcase
            "(": case(row) 0:glyph_row=5'b00110;1:glyph_row=5'b01000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b01000;6:glyph_row=5'b00110;default:glyph_row=0; endcase
            ")": case(row) 0:glyph_row=5'b01100;1:glyph_row=5'b00010;2:glyph_row=5'b00001;3:glyph_row=5'b00001;4:glyph_row=5'b00001;5:glyph_row=5'b00010;6:glyph_row=5'b01100;default:glyph_row=0; endcase
            ",": case(row) 0,1,2,3,4:glyph_row=5'b00000;5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0; endcase
            ":": case(row) 0,1:glyph_row=5'b00000;2:glyph_row=5'b00100;3,4:glyph_row=5'b00000;5:glyph_row=5'b00100;default:glyph_row=0; endcase
            "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00000;6:glyph_row=5'b00100;default:glyph_row=0; endcase
            default: glyph_row = 5'b00000;
        endcase
    end
endfunction
// Constant digit truth tables: {row,digit} -> the unchanged five pixels.
localparam [127:0] COORD_DIGIT_BIT_0 = 128'h00000004016903790201030d838d00a0;
localparam [127:0] COORD_DIGIT_BIT_1 = 128'h0000017f02100010037c8091001083fd;
localparam [127:0] COORD_DIGIT_BIT_2 = 128'h0000836f0402801683eb0402001283ef;
localparam [127:0] COORD_DIGIT_BIT_3 = 128'h000003ef0084009103680010004283ad;
localparam [127:0] COORD_DIGIT_BIT_4 = 128'h0000002c0141015100710361832500a8;
function [4:0] coordinate_digit_row;
 input [3:0] digit;input [2:0] row;
 reg [6:0] address;
 begin
  address={row,digit};
  coordinate_digit_row={COORD_DIGIT_BIT_4[address],COORD_DIGIT_BIT_3[address],
   COORD_DIGIT_BIT_2[address],COORD_DIGIT_BIT_1[address],COORD_DIGIT_BIT_0[address]};
 end
endfunction
// Direct glyph-row ROMs for fixed words. The bitmap is bit-exact to
// glyph_row(label_char(...)); no added latency or new RAM array/IP is required.
function [4:0] color_word_row;
 input [2:0] label_id;input [2:0] letter;input [2:0] row;
 reg [2:0] normalized;
 begin
 normalized=label_id<=4?label_id:3'd0;
 color_word_row=0;
 case({normalized,letter,row})
  9'h000: color_word_row=5'b10001;
  9'h001: color_word_row=5'b10001;
  9'h002: color_word_row=5'b10001;
  9'h003: color_word_row=5'b10001;
  9'h004: color_word_row=5'b10001;
  9'h005: color_word_row=5'b10001;
  9'h006: color_word_row=5'b01110;
  9'h008: color_word_row=5'b10001;
  9'h009: color_word_row=5'b11001;
  9'h00a: color_word_row=5'b11001;
  9'h00b: color_word_row=5'b10101;
  9'h00c: color_word_row=5'b10011;
  9'h00d: color_word_row=5'b10011;
  9'h00e: color_word_row=5'b10001;
  9'h018: color_word_row=5'b10001;
  9'h019: color_word_row=5'b11001;
  9'h01a: color_word_row=5'b11001;
  9'h01b: color_word_row=5'b10101;
  9'h01c: color_word_row=5'b10011;
  9'h01d: color_word_row=5'b10011;
  9'h01e: color_word_row=5'b10001;
  9'h020: color_word_row=5'b01110;
  9'h021: color_word_row=5'b10001;
  9'h022: color_word_row=5'b10001;
  9'h023: color_word_row=5'b10001;
  9'h024: color_word_row=5'b10001;
  9'h025: color_word_row=5'b10001;
  9'h026: color_word_row=5'b01110;
  9'h028: color_word_row=5'b10001;
  9'h029: color_word_row=5'b10001;
  9'h02a: color_word_row=5'b10001;
  9'h02b: color_word_row=5'b10101;
  9'h02c: color_word_row=5'b10101;
  9'h02d: color_word_row=5'b11011;
  9'h02e: color_word_row=5'b10001;
  9'h030: color_word_row=5'b10001;
  9'h031: color_word_row=5'b11001;
  9'h032: color_word_row=5'b11001;
  9'h033: color_word_row=5'b10101;
  9'h034: color_word_row=5'b10011;
  9'h035: color_word_row=5'b10011;
  9'h036: color_word_row=5'b10001;
  9'h040: color_word_row=5'b11110;
  9'h041: color_word_row=5'b10001;
  9'h042: color_word_row=5'b10001;
  9'h043: color_word_row=5'b11110;
  9'h044: color_word_row=5'b10100;
  9'h045: color_word_row=5'b10010;
  9'h046: color_word_row=5'b10001;
  9'h048: color_word_row=5'b11111;
  9'h049: color_word_row=5'b10000;
  9'h04a: color_word_row=5'b10000;
  9'h04b: color_word_row=5'b11110;
  9'h04c: color_word_row=5'b10000;
  9'h04d: color_word_row=5'b10000;
  9'h04e: color_word_row=5'b11111;
  9'h050: color_word_row=5'b11110;
  9'h051: color_word_row=5'b10001;
  9'h052: color_word_row=5'b10001;
  9'h053: color_word_row=5'b10001;
  9'h054: color_word_row=5'b10001;
  9'h055: color_word_row=5'b10001;
  9'h056: color_word_row=5'b11110;
  9'h080: color_word_row=5'b01110;
  9'h081: color_word_row=5'b10001;
  9'h082: color_word_row=5'b10000;
  9'h083: color_word_row=5'b10111;
  9'h084: color_word_row=5'b10001;
  9'h085: color_word_row=5'b10001;
  9'h086: color_word_row=5'b01110;
  9'h088: color_word_row=5'b11110;
  9'h089: color_word_row=5'b10001;
  9'h08a: color_word_row=5'b10001;
  9'h08b: color_word_row=5'b11110;
  9'h08c: color_word_row=5'b10100;
  9'h08d: color_word_row=5'b10010;
  9'h08e: color_word_row=5'b10001;
  9'h090: color_word_row=5'b11111;
  9'h091: color_word_row=5'b10000;
  9'h092: color_word_row=5'b10000;
  9'h093: color_word_row=5'b11110;
  9'h094: color_word_row=5'b10000;
  9'h095: color_word_row=5'b10000;
  9'h096: color_word_row=5'b11111;
  9'h098: color_word_row=5'b11111;
  9'h099: color_word_row=5'b10000;
  9'h09a: color_word_row=5'b10000;
  9'h09b: color_word_row=5'b11110;
  9'h09c: color_word_row=5'b10000;
  9'h09d: color_word_row=5'b10000;
  9'h09e: color_word_row=5'b11111;
  9'h0a0: color_word_row=5'b10001;
  9'h0a1: color_word_row=5'b11001;
  9'h0a2: color_word_row=5'b11001;
  9'h0a3: color_word_row=5'b10101;
  9'h0a4: color_word_row=5'b10011;
  9'h0a5: color_word_row=5'b10011;
  9'h0a6: color_word_row=5'b10001;
  9'h0c0: color_word_row=5'b11110;
  9'h0c1: color_word_row=5'b10001;
  9'h0c2: color_word_row=5'b10001;
  9'h0c3: color_word_row=5'b11110;
  9'h0c4: color_word_row=5'b10001;
  9'h0c5: color_word_row=5'b10001;
  9'h0c6: color_word_row=5'b11110;
  9'h0c8: color_word_row=5'b10000;
  9'h0c9: color_word_row=5'b10000;
  9'h0ca: color_word_row=5'b10000;
  9'h0cb: color_word_row=5'b10000;
  9'h0cc: color_word_row=5'b10000;
  9'h0cd: color_word_row=5'b10000;
  9'h0ce: color_word_row=5'b11111;
  9'h0d0: color_word_row=5'b10001;
  9'h0d1: color_word_row=5'b10001;
  9'h0d2: color_word_row=5'b10001;
  9'h0d3: color_word_row=5'b10001;
  9'h0d4: color_word_row=5'b10001;
  9'h0d5: color_word_row=5'b10001;
  9'h0d6: color_word_row=5'b01110;
  9'h0d8: color_word_row=5'b11111;
  9'h0d9: color_word_row=5'b10000;
  9'h0da: color_word_row=5'b10000;
  9'h0db: color_word_row=5'b11110;
  9'h0dc: color_word_row=5'b10000;
  9'h0dd: color_word_row=5'b10000;
  9'h0de: color_word_row=5'b11111;
  9'h100: color_word_row=5'b10001;
  9'h101: color_word_row=5'b10001;
  9'h102: color_word_row=5'b01010;
  9'h103: color_word_row=5'b00100;
  9'h104: color_word_row=5'b00100;
  9'h105: color_word_row=5'b00100;
  9'h106: color_word_row=5'b00100;
  9'h108: color_word_row=5'b11111;
  9'h109: color_word_row=5'b10000;
  9'h10a: color_word_row=5'b10000;
  9'h10b: color_word_row=5'b11110;
  9'h10c: color_word_row=5'b10000;
  9'h10d: color_word_row=5'b10000;
  9'h10e: color_word_row=5'b11111;
  9'h110: color_word_row=5'b10000;
  9'h111: color_word_row=5'b10000;
  9'h112: color_word_row=5'b10000;
  9'h113: color_word_row=5'b10000;
  9'h114: color_word_row=5'b10000;
  9'h115: color_word_row=5'b10000;
  9'h116: color_word_row=5'b11111;
  9'h118: color_word_row=5'b10000;
  9'h119: color_word_row=5'b10000;
  9'h11a: color_word_row=5'b10000;
  9'h11b: color_word_row=5'b10000;
  9'h11c: color_word_row=5'b10000;
  9'h11d: color_word_row=5'b10000;
  9'h11e: color_word_row=5'b11111;
  9'h120: color_word_row=5'b01110;
  9'h121: color_word_row=5'b10001;
  9'h122: color_word_row=5'b10001;
  9'h123: color_word_row=5'b10001;
  9'h124: color_word_row=5'b10001;
  9'h125: color_word_row=5'b10001;
  9'h126: color_word_row=5'b01110;
  9'h128: color_word_row=5'b10001;
  9'h129: color_word_row=5'b10001;
  9'h12a: color_word_row=5'b10001;
  9'h12b: color_word_row=5'b10101;
  9'h12c: color_word_row=5'b10101;
  9'h12d: color_word_row=5'b11011;
  9'h12e: color_word_row=5'b10001;
  default:color_word_row=0;
 endcase
 end
endfunction
function [4:0] shape_word_row;
 input [2:0] label_id;input [3:0] letter;input [2:0] row;
 reg [2:0] normalized;
 begin
 normalized=label_id<=4?label_id:3'd0;
 shape_word_row=0;
 case({normalized,letter,row})
  10'h000: shape_word_row=5'b10001;
  10'h001: shape_word_row=5'b10001;
  10'h002: shape_word_row=5'b10001;
  10'h003: shape_word_row=5'b10001;
  10'h004: shape_word_row=5'b10001;
  10'h005: shape_word_row=5'b10001;
  10'h006: shape_word_row=5'b01110;
  10'h008: shape_word_row=5'b10001;
  10'h009: shape_word_row=5'b11001;
  10'h00a: shape_word_row=5'b11001;
  10'h00b: shape_word_row=5'b10101;
  10'h00c: shape_word_row=5'b10011;
  10'h00d: shape_word_row=5'b10011;
  10'h00e: shape_word_row=5'b10001;
  10'h018: shape_word_row=5'b10001;
  10'h019: shape_word_row=5'b11001;
  10'h01a: shape_word_row=5'b11001;
  10'h01b: shape_word_row=5'b10101;
  10'h01c: shape_word_row=5'b10011;
  10'h01d: shape_word_row=5'b10011;
  10'h01e: shape_word_row=5'b10001;
  10'h020: shape_word_row=5'b01110;
  10'h021: shape_word_row=5'b10001;
  10'h022: shape_word_row=5'b10001;
  10'h023: shape_word_row=5'b10001;
  10'h024: shape_word_row=5'b10001;
  10'h025: shape_word_row=5'b10001;
  10'h026: shape_word_row=5'b01110;
  10'h028: shape_word_row=5'b10001;
  10'h029: shape_word_row=5'b10001;
  10'h02a: shape_word_row=5'b10001;
  10'h02b: shape_word_row=5'b10101;
  10'h02c: shape_word_row=5'b10101;
  10'h02d: shape_word_row=5'b11011;
  10'h02e: shape_word_row=5'b10001;
  10'h030: shape_word_row=5'b10001;
  10'h031: shape_word_row=5'b11001;
  10'h032: shape_word_row=5'b11001;
  10'h033: shape_word_row=5'b10101;
  10'h034: shape_word_row=5'b10011;
  10'h035: shape_word_row=5'b10011;
  10'h036: shape_word_row=5'b10001;
  10'h080: shape_word_row=5'b01110;
  10'h081: shape_word_row=5'b10001;
  10'h082: shape_word_row=5'b10000;
  10'h083: shape_word_row=5'b10000;
  10'h084: shape_word_row=5'b10000;
  10'h085: shape_word_row=5'b10001;
  10'h086: shape_word_row=5'b01110;
  10'h088: shape_word_row=5'b11111;
  10'h089: shape_word_row=5'b00100;
  10'h08a: shape_word_row=5'b00100;
  10'h08b: shape_word_row=5'b00100;
  10'h08c: shape_word_row=5'b00100;
  10'h08d: shape_word_row=5'b00100;
  10'h08e: shape_word_row=5'b11111;
  10'h090: shape_word_row=5'b11110;
  10'h091: shape_word_row=5'b10001;
  10'h092: shape_word_row=5'b10001;
  10'h093: shape_word_row=5'b11110;
  10'h094: shape_word_row=5'b10100;
  10'h095: shape_word_row=5'b10010;
  10'h096: shape_word_row=5'b10001;
  10'h098: shape_word_row=5'b01110;
  10'h099: shape_word_row=5'b10001;
  10'h09a: shape_word_row=5'b10000;
  10'h09b: shape_word_row=5'b10000;
  10'h09c: shape_word_row=5'b10000;
  10'h09d: shape_word_row=5'b10001;
  10'h09e: shape_word_row=5'b01110;
  10'h0a0: shape_word_row=5'b10000;
  10'h0a1: shape_word_row=5'b10000;
  10'h0a2: shape_word_row=5'b10000;
  10'h0a3: shape_word_row=5'b10000;
  10'h0a4: shape_word_row=5'b10000;
  10'h0a5: shape_word_row=5'b10000;
  10'h0a6: shape_word_row=5'b11111;
  10'h0a8: shape_word_row=5'b11111;
  10'h0a9: shape_word_row=5'b10000;
  10'h0aa: shape_word_row=5'b10000;
  10'h0ab: shape_word_row=5'b11110;
  10'h0ac: shape_word_row=5'b10000;
  10'h0ad: shape_word_row=5'b10000;
  10'h0ae: shape_word_row=5'b11111;
  10'h100: shape_word_row=5'b11111;
  10'h101: shape_word_row=5'b00100;
  10'h102: shape_word_row=5'b00100;
  10'h103: shape_word_row=5'b00100;
  10'h104: shape_word_row=5'b00100;
  10'h105: shape_word_row=5'b00100;
  10'h106: shape_word_row=5'b00100;
  10'h108: shape_word_row=5'b11110;
  10'h109: shape_word_row=5'b10001;
  10'h10a: shape_word_row=5'b10001;
  10'h10b: shape_word_row=5'b11110;
  10'h10c: shape_word_row=5'b10100;
  10'h10d: shape_word_row=5'b10010;
  10'h10e: shape_word_row=5'b10001;
  10'h110: shape_word_row=5'b11111;
  10'h111: shape_word_row=5'b00100;
  10'h112: shape_word_row=5'b00100;
  10'h113: shape_word_row=5'b00100;
  10'h114: shape_word_row=5'b00100;
  10'h115: shape_word_row=5'b00100;
  10'h116: shape_word_row=5'b11111;
  10'h118: shape_word_row=5'b01110;
  10'h119: shape_word_row=5'b10001;
  10'h11a: shape_word_row=5'b10001;
  10'h11b: shape_word_row=5'b11111;
  10'h11c: shape_word_row=5'b10001;
  10'h11d: shape_word_row=5'b10001;
  10'h11e: shape_word_row=5'b10001;
  10'h120: shape_word_row=5'b10001;
  10'h121: shape_word_row=5'b11001;
  10'h122: shape_word_row=5'b11001;
  10'h123: shape_word_row=5'b10101;
  10'h124: shape_word_row=5'b10011;
  10'h125: shape_word_row=5'b10011;
  10'h126: shape_word_row=5'b10001;
  10'h128: shape_word_row=5'b01110;
  10'h129: shape_word_row=5'b10001;
  10'h12a: shape_word_row=5'b10000;
  10'h12b: shape_word_row=5'b10111;
  10'h12c: shape_word_row=5'b10001;
  10'h12d: shape_word_row=5'b10001;
  10'h12e: shape_word_row=5'b01110;
  10'h130: shape_word_row=5'b10000;
  10'h131: shape_word_row=5'b10000;
  10'h132: shape_word_row=5'b10000;
  10'h133: shape_word_row=5'b10000;
  10'h134: shape_word_row=5'b10000;
  10'h135: shape_word_row=5'b10000;
  10'h136: shape_word_row=5'b11111;
  10'h138: shape_word_row=5'b11111;
  10'h139: shape_word_row=5'b10000;
  10'h13a: shape_word_row=5'b10000;
  10'h13b: shape_word_row=5'b11110;
  10'h13c: shape_word_row=5'b10000;
  10'h13d: shape_word_row=5'b10000;
  10'h13e: shape_word_row=5'b11111;
  10'h180: shape_word_row=5'b11110;
  10'h181: shape_word_row=5'b10001;
  10'h182: shape_word_row=5'b10001;
  10'h183: shape_word_row=5'b11110;
  10'h184: shape_word_row=5'b10100;
  10'h185: shape_word_row=5'b10010;
  10'h186: shape_word_row=5'b10001;
  10'h188: shape_word_row=5'b11111;
  10'h189: shape_word_row=5'b10000;
  10'h18a: shape_word_row=5'b10000;
  10'h18b: shape_word_row=5'b11110;
  10'h18c: shape_word_row=5'b10000;
  10'h18d: shape_word_row=5'b10000;
  10'h18e: shape_word_row=5'b11111;
  10'h190: shape_word_row=5'b01110;
  10'h191: shape_word_row=5'b10001;
  10'h192: shape_word_row=5'b10000;
  10'h193: shape_word_row=5'b10000;
  10'h194: shape_word_row=5'b10000;
  10'h195: shape_word_row=5'b10001;
  10'h196: shape_word_row=5'b01110;
  10'h198: shape_word_row=5'b11111;
  10'h199: shape_word_row=5'b00100;
  10'h19a: shape_word_row=5'b00100;
  10'h19b: shape_word_row=5'b00100;
  10'h19c: shape_word_row=5'b00100;
  10'h19d: shape_word_row=5'b00100;
  10'h19e: shape_word_row=5'b00100;
  10'h1a0: shape_word_row=5'b01110;
  10'h1a1: shape_word_row=5'b10001;
  10'h1a2: shape_word_row=5'b10001;
  10'h1a3: shape_word_row=5'b11111;
  10'h1a4: shape_word_row=5'b10001;
  10'h1a5: shape_word_row=5'b10001;
  10'h1a6: shape_word_row=5'b10001;
  10'h1a8: shape_word_row=5'b10001;
  10'h1a9: shape_word_row=5'b11001;
  10'h1aa: shape_word_row=5'b11001;
  10'h1ab: shape_word_row=5'b10101;
  10'h1ac: shape_word_row=5'b10011;
  10'h1ad: shape_word_row=5'b10011;
  10'h1ae: shape_word_row=5'b10001;
  10'h1b0: shape_word_row=5'b01110;
  10'h1b1: shape_word_row=5'b10001;
  10'h1b2: shape_word_row=5'b10000;
  10'h1b3: shape_word_row=5'b10111;
  10'h1b4: shape_word_row=5'b10001;
  10'h1b5: shape_word_row=5'b10001;
  10'h1b6: shape_word_row=5'b01110;
  10'h1b8: shape_word_row=5'b10000;
  10'h1b9: shape_word_row=5'b10000;
  10'h1ba: shape_word_row=5'b10000;
  10'h1bb: shape_word_row=5'b10000;
  10'h1bc: shape_word_row=5'b10000;
  10'h1bd: shape_word_row=5'b10000;
  10'h1be: shape_word_row=5'b11111;
  10'h1c0: shape_word_row=5'b11111;
  10'h1c1: shape_word_row=5'b10000;
  10'h1c2: shape_word_row=5'b10000;
  10'h1c3: shape_word_row=5'b11110;
  10'h1c4: shape_word_row=5'b10000;
  10'h1c5: shape_word_row=5'b10000;
  10'h1c6: shape_word_row=5'b11111;
  10'h200: shape_word_row=5'b01111;
  10'h201: shape_word_row=5'b10000;
  10'h202: shape_word_row=5'b10000;
  10'h203: shape_word_row=5'b01110;
  10'h204: shape_word_row=5'b00001;
  10'h205: shape_word_row=5'b00001;
  10'h206: shape_word_row=5'b11110;
  10'h208: shape_word_row=5'b01110;
  10'h209: shape_word_row=5'b10001;
  10'h20a: shape_word_row=5'b10001;
  10'h20b: shape_word_row=5'b10001;
  10'h20c: shape_word_row=5'b10101;
  10'h20d: shape_word_row=5'b10010;
  10'h20e: shape_word_row=5'b01101;
  10'h210: shape_word_row=5'b10001;
  10'h211: shape_word_row=5'b10001;
  10'h212: shape_word_row=5'b10001;
  10'h213: shape_word_row=5'b10001;
  10'h214: shape_word_row=5'b10001;
  10'h215: shape_word_row=5'b10001;
  10'h216: shape_word_row=5'b01110;
  10'h218: shape_word_row=5'b01110;
  10'h219: shape_word_row=5'b10001;
  10'h21a: shape_word_row=5'b10001;
  10'h21b: shape_word_row=5'b11111;
  10'h21c: shape_word_row=5'b10001;
  10'h21d: shape_word_row=5'b10001;
  10'h21e: shape_word_row=5'b10001;
  10'h220: shape_word_row=5'b11110;
  10'h221: shape_word_row=5'b10001;
  10'h222: shape_word_row=5'b10001;
  10'h223: shape_word_row=5'b11110;
  10'h224: shape_word_row=5'b10100;
  10'h225: shape_word_row=5'b10010;
  10'h226: shape_word_row=5'b10001;
  10'h228: shape_word_row=5'b11111;
  10'h229: shape_word_row=5'b10000;
  10'h22a: shape_word_row=5'b10000;
  10'h22b: shape_word_row=5'b11110;
  10'h22c: shape_word_row=5'b10000;
  10'h22d: shape_word_row=5'b10000;
  10'h22e: shape_word_row=5'b11111;
  default:shape_word_row=0;
 endcase
 end
endfunction
function [4:0] count_word_row;
 input [3:0] value;input [3:0] letter;input [2:0] row;
 begin
 count_word_row=0;
 if(letter<6)begin
 case({letter[2:0],row})
  6'h00:count_word_row=5'b01110;
  6'h01:count_word_row=5'b10001;
  6'h02:count_word_row=5'b10000;
  6'h03:count_word_row=5'b10000;
  6'h04:count_word_row=5'b10000;
  6'h05:count_word_row=5'b10001;
  6'h06:count_word_row=5'b01110;
  6'h08:count_word_row=5'b01110;
  6'h09:count_word_row=5'b10001;
  6'h0a:count_word_row=5'b10001;
  6'h0b:count_word_row=5'b10001;
  6'h0c:count_word_row=5'b10001;
  6'h0d:count_word_row=5'b10001;
  6'h0e:count_word_row=5'b01110;
  6'h10:count_word_row=5'b10001;
  6'h11:count_word_row=5'b10001;
  6'h12:count_word_row=5'b10001;
  6'h13:count_word_row=5'b10001;
  6'h14:count_word_row=5'b10001;
  6'h15:count_word_row=5'b10001;
  6'h16:count_word_row=5'b01110;
  6'h18:count_word_row=5'b10001;
  6'h19:count_word_row=5'b11001;
  6'h1a:count_word_row=5'b11001;
  6'h1b:count_word_row=5'b10101;
  6'h1c:count_word_row=5'b10011;
  6'h1d:count_word_row=5'b10011;
  6'h1e:count_word_row=5'b10001;
  6'h20:count_word_row=5'b11111;
  6'h21:count_word_row=5'b00100;
  6'h22:count_word_row=5'b00100;
  6'h23:count_word_row=5'b00100;
  6'h24:count_word_row=5'b00100;
  6'h25:count_word_row=5'b00100;
  6'h26:count_word_row=5'b00100;
  6'h2a:count_word_row=5'b00100;
  6'h2d:count_word_row=5'b00100;
  default:count_word_row=0;endcase
 end else if(letter==6)begin
 case({value,row})
  7'h00:count_word_row=5'b01110;
  7'h01:count_word_row=5'b10001;
  7'h02:count_word_row=5'b10011;
  7'h03:count_word_row=5'b10101;
  7'h04:count_word_row=5'b11001;
  7'h05:count_word_row=5'b10001;
  7'h06:count_word_row=5'b01110;
  7'h08:count_word_row=5'b00100;
  7'h09:count_word_row=5'b01100;
  7'h0a:count_word_row=5'b00100;
  7'h0b:count_word_row=5'b00100;
  7'h0c:count_word_row=5'b00100;
  7'h0d:count_word_row=5'b00100;
  7'h0e:count_word_row=5'b01110;
  7'h10:count_word_row=5'b01110;
  7'h11:count_word_row=5'b10001;
  7'h12:count_word_row=5'b00001;
  7'h13:count_word_row=5'b00010;
  7'h14:count_word_row=5'b00100;
  7'h15:count_word_row=5'b01000;
  7'h16:count_word_row=5'b11111;
  7'h18:count_word_row=5'b11110;
  7'h19:count_word_row=5'b00001;
  7'h1a:count_word_row=5'b00001;
  7'h1b:count_word_row=5'b01110;
  7'h1c:count_word_row=5'b00001;
  7'h1d:count_word_row=5'b00001;
  7'h1e:count_word_row=5'b11110;
  7'h20:count_word_row=5'b00010;
  7'h21:count_word_row=5'b00110;
  7'h22:count_word_row=5'b01010;
  7'h23:count_word_row=5'b10010;
  7'h24:count_word_row=5'b11111;
  7'h25:count_word_row=5'b00010;
  7'h26:count_word_row=5'b00010;
  7'h28:count_word_row=5'b11111;
  7'h29:count_word_row=5'b10000;
  7'h2a:count_word_row=5'b10000;
  7'h2b:count_word_row=5'b11110;
  7'h2c:count_word_row=5'b00001;
  7'h2d:count_word_row=5'b00001;
  7'h2e:count_word_row=5'b11110;
  7'h30:count_word_row=5'b00110;
  7'h31:count_word_row=5'b01000;
  7'h32:count_word_row=5'b10000;
  7'h33:count_word_row=5'b11110;
  7'h34:count_word_row=5'b10001;
  7'h35:count_word_row=5'b10001;
  7'h36:count_word_row=5'b01110;
  7'h38:count_word_row=5'b11111;
  7'h39:count_word_row=5'b00001;
  7'h3a:count_word_row=5'b00010;
  7'h3b:count_word_row=5'b00100;
  7'h3c:count_word_row=5'b01000;
  7'h3d:count_word_row=5'b01000;
  7'h3e:count_word_row=5'b01000;
  7'h40:count_word_row=5'b01110;
  7'h41:count_word_row=5'b10001;
  7'h42:count_word_row=5'b10001;
  7'h43:count_word_row=5'b01110;
  7'h44:count_word_row=5'b10001;
  7'h45:count_word_row=5'b10001;
  7'h46:count_word_row=5'b01110;
  7'h48:count_word_row=5'b01110;
  7'h49:count_word_row=5'b10001;
  7'h4a:count_word_row=5'b10001;
  7'h4b:count_word_row=5'b01111;
  7'h4c:count_word_row=5'b00001;
  7'h4d:count_word_row=5'b00010;
  7'h4e:count_word_row=5'b01100;
  7'h52:count_word_row=5'b00100;
  7'h55:count_word_row=5'b00100;
  7'h78:count_word_row=5'b01110;
  7'h79:count_word_row=5'b10001;
  7'h7a:count_word_row=5'b00010;
  7'h7b:count_word_row=5'b00100;
  7'h7c:count_word_row=5'b00100;
  7'h7e:count_word_row=5'b00100;
  default:count_word_row=0;endcase
 end
 end
endfunction
function [23:0] ink(input [2:0] c);
 case(c)1:ink=24'hff3030;2:ink=24'h20e040;3:ink=24'h3080ff;4:ink=24'hffe020;default:ink=24'hffffff;endcase
endfunction
// Boxes use shared x/y +/- one values; labels occupy four fixed rows
// below the logo. One text decoder serves the complete result panel.
reg [31:0] selected_coordinate;reg [3:0] coordinate_char,digit;
integer i;reg [63:0] o,label_object;reg hit;reg [3:0] borders;
reg [2:0] font_kind;reg [3:0] font_id;reg [4:0] font_letter;
reg [2:0] row,col,label_ink;reg [11:0] panel_y;
wire [11:0] x_next=x+12'd1,y_next=y+12'd1,x_previous=x-12'd1,y_previous=y-12'd1;
always @*begin
 selected_coordinate=0;coordinate_char=0;digit=0;hit=0;borders=0;font_kind=0;font_id=0;font_letter=0;row=0;col=0;label_ink=0;o=0;label_object=0;panel_y=y-12'd200;
 if(enable && de)begin
  for(i=3;i>=0;i=i-1)begin
   o=objs[i*64+:64];
   if(good && o[63] && x>=o[56:45] && x<=o[32:21] && y>=o[44:33] && y<=o[20:9] &&
     (x==o[56:45] || x_previous==o[56:45] || y==o[44:33] || y_previous==o[44:33] ||
      x==o[32:21] || x_next==o[32:21] || y==o[20:9] || y_next==o[20:9]))begin
     borders[i]=1;
   end
  end
  if(y>=200 && y<328 && panel_y[4]==0 && x>=16 && x<288)begin
   label_object=objs[panel_y[6:5]*64+:64];
   if(good && label_object[63])begin
    hit=1;row=panel_y[3:1];col=(x-16)>>1;
    font_letter=(x-16)>>4;
    if(font_letter<7)begin font_kind=1;font_id={1'b0,label_object[62:60]};end
    else if(font_letter>=8)begin font_kind=2;font_id={1'b0,label_object[59:57]};font_letter=font_letter-8;end
    label_ink=label_object[62:60];
   end
  end
  // B supplies decimal digits atomically with the four object records.
  // Eleven 16-pixel cells: (XXXX,YYYY), with blank leading zeroes.
  if(y>=200 && y<328 && panel_y[4]==0 && x>=304 && x<480)begin
   label_object=objs[panel_y[6:5]*64+:64];
   selected_coordinate=coordinates[panel_y[6:5]*32+:32];
   coordinate_char=(x-304)>>4;
   if(good && label_object[63] && selected_coordinate[27:16]!=12'hfff)begin
    hit=1;row=panel_y[3:1];col=(x-304)>>1;
    label_ink=label_object[62:60];
    case(coordinate_char)
     0:begin font_kind=5;font_id=0;end
     5:begin font_kind=5;font_id=1;end
     10:begin font_kind=5;font_id=2;end
     default:begin
      case(coordinate_char)
       1:digit=selected_coordinate[31:28];2:digit=selected_coordinate[27:24];
       3:digit=selected_coordinate[23:20];4:digit=selected_coordinate[19:16];
       6:digit=selected_coordinate[15:12];7:digit=selected_coordinate[11:8];
       8:digit=selected_coordinate[7:4];9:digit=selected_coordinate[3:0];
       default:digit=0;
      endcase
      font_kind=4;font_id=digit;
      case(coordinate_char)
       1:if(selected_coordinate[31:28]==0)font_kind=0;
       2:if(selected_coordinate[31:24]==0)font_kind=0;
       3:if(selected_coordinate[31:20]==0)font_kind=0;
       6:if(selected_coordinate[15:12]==0)font_kind=0;
       7:if(selected_coordinate[15:8]==0)font_kind=0;
       8:if(selected_coordinate[15:4]==0)font_kind=0;
      endcase
     end
    endcase
   end
  end
  if(y>=168 && y<184 && x>=16 && x<128)begin
   hit=1;row=(y-168)>>1;col=(x-16)>>1;label_ink=0;
   font_kind=3;font_id=good?cnt:4'd15;font_letter=(x-16)>>4;
  end
 end
end
// Register independent geometry tests before priority/colour decoding. This
// retains the three-cycle pixel contract while cutting the bounds -> RGB mux
// path. A label still overrides box ink throughout its complete text panel.
function [2:0] border_ink;
 input [3:0] hits;input [11:0] inks;
 begin casez(hits)
  4'b???1:border_ink=inks[2:0];4'b??10:border_ink=inks[5:3];
  4'b?100:border_ink=inks[8:6];4'b1000:border_ink=inks[11:9];
  default:border_ink=0;
 endcase end
endfunction
reg [23:0] r1,r2,r3,c2;reg [2:0] font_kind1;reg [3:0] font_id1;reg [4:0] font_letter1;reg [2:0] row1,col1,col2,label_ink1;
reg [3:0] borders1;reg [11:0] border_inks1;
reg hit1,hit2,b2;reg [4:0] bits2;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin out_ink<=0;r1<=0;r2<=0;r3<=0;c2<=0;font_kind1<=0;font_id1<=0;font_letter1<=0;row1<=0;col1<=0;col2<=0;hit1<=0;hit2<=0;b2<=0;bits2<=0;borders1<=0;border_inks1<=0;label_ink1<=0;end
 else begin
  r1<=rgb;font_kind1<=font_kind;font_id1<=font_id;font_letter1<=font_letter;row1<=row;col1<=col;hit1<=hit;
  borders1<=borders;label_ink1<=label_ink;
  border_inks1<={objs[254:252],objs[190:188],objs[126:124],objs[62:60]};
  r2<=r1;c2<=ink(hit1?label_ink1:border_ink(borders1,border_inks1));col2<=col1;hit2<=hit1;b2<=|borders1;case(font_kind1)
   1:bits2<=color_word_row(font_id1[2:0],font_letter1[2:0],row1);
   2:bits2<=shape_word_row(font_id1[2:0],font_letter1[3:0],row1);
   3:bits2<=count_word_row(font_id1,font_letter1[3:0],row1);
   4:bits2<=coordinate_digit_row(font_id1,row1);
   5:begin
    case(font_id1)
     0:case(row1)0,6:bits2<=5'b00010;1,5:bits2<=5'b00100;2,3,4:bits2<=5'b01000;default:bits2<=0;endcase
     1:case(row1)4,5:bits2<=5'b00100;6:bits2<=5'b01000;default:bits2<=0;endcase
     2:case(row1)0,6:bits2<=5'b01000;1,5:bits2<=5'b00100;2,3,4:bits2<=5'b00010;default:bits2<=0;endcase
     default:bits2<=0;
    endcase
   end
   default:bits2<=0;
  endcase
  out_ink<=b2 || (hit2 && col2<5 && bits2[4-col2]);
  r3<=(b2 || (hit2 && col2<5 && bits2[4-col2]))?c2:r2;
 end
end
assign out_rgb=r3;
endmodule
