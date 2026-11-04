`timescale 1ns/1ps
// Periodic, transmit-only snapshots. No command receiver or actuator controls.
module mode17_uart_diag #(
    parameter integer CLOCK_HZ=100000000,
    parameter integer BAUD=115200,
    parameter integer PERIOD_CYCLES=20000000
)(input wire clk,rst_n,input wire [511:0] snapshot,output wire tx);
    localparam integer DIV=CLOCK_HZ/BAUD;
    function integer counter_bits;
        input integer count;
        integer value;
        begin
            counter_bits=1;
            for(value=count-1;value>1;value=value>>1)counter_bits=counter_bits+1;
        end
    endfunction
    localparam integer PERIOD_BITS=PERIOD_CYCLES>0?counter_bits(PERIOD_CYCLES):32;
    localparam integer BAUD_BITS=(DIV>0 && DIV<=65536)?counter_bits(DIV):16;
    reg [PERIOD_BITS-1:0] period_count;
    reg [BAUD_BITS-1:0] baud_count;
    reg [9:0] frame;
    reg [3:0] bits_left;
    reg [7:0] index;
    reg active;
    reg [511:0] data_q;
    reg [3:0] byte_high;
    reg [7:0] checksum;
    reg [7:0] character;
    function [7:0] hexchar;
        input [3:0] n;
        begin hexchar=n<10?8'h30+n:8'h41+n-10;end
    endfunction
    always @* begin
        case(index)
            0:character="S";1:character="1";2:character="7";
            3:character="D";4:character=" ";133:character=" ";
            134:character=hexchar(checksum[7:4]);
            135:character=hexchar(checksum[3:0]);
            136:character=8'h0d;137:character=8'h0a;
            default:character=hexchar(data_q[511:508]);
        endcase
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            period_count<=0;baud_count<=0;frame<=10'h3ff;bits_left<=0;
            index<=0;active<=0;data_q<=0;byte_high<=0;checksum<=0;
        end else begin
            if(period_count==PERIOD_CYCLES-1)begin
                period_count<=0;
                if(!active && bits_left==0)begin
                    data_q<=snapshot;index<=0;active<=1;checksum<=0;
                end
            end else period_count<=period_count+1'b1;
            if(bits_left!=0)begin
                if(baud_count==0)begin
                    baud_count<=DIV-1;frame<={1'b1,frame[9:1]};
                    bits_left<=bits_left-1'b1;
                end else baud_count<=baud_count-1'b1;
            end else if(active)begin
                frame<={1'b1,character,1'b0};bits_left<=10;baud_count<=DIV-1;
                if(index>=5 && index<=132)begin
                    if(!index[0])checksum<=checksum^{byte_high,data_q[511:508]};
                    else byte_high<=data_q[511:508];
                    data_q<={data_q[507:0],4'd0};
                end
                if(index==137)active<=0;else index<=index+1'b1;
            end
        end
    end
    assign tx=frame[0];
endmodule
