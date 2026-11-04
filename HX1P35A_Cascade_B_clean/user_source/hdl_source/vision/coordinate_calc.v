`timescale 1ns / 1ns

// Bounding-box centre and decimal-coordinate generator.
//
// Four ranked incoming component records are first captured at one record per
// clock.  During vertical blanking, a small iterative double-dabble engine
// converts X and Y in parallel: one conversion iteration per clock, twelve
// clocks per record.  This removes the former twelve-iteration combinational
// path from the 149.343 MHz HDMI pixel clock while needing no divider/DSP.
module coordinate_calc (
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_strobe,
    input  wire         I_last,
    input  wire [2:0]   I_index,
    input  wire         I_valid,
    input  wire [2:0]   I_color,
    input  wire [2:0]   I_shape,
    input  wire [20:0]  I_area,
    input  wire [11:0]  I_xmin,
    input  wire [11:0]  I_ymin,
    input  wire [11:0]  I_xmax,
    input  wire [11:0]  I_ymax,

    output reg          O_strobe,
    output reg          O_last,
    output reg  [2:0]   O_index,
    output reg  [143:0] O_record
);

reg         slot_valid [0:3];
reg [2:0]   slot_color [0:3];
reg [2:0]   slot_shape [0:3];
reg [20:0]  slot_area  [0:3];
reg [11:0]  slot_xmin  [0:3];
reg [11:0]  slot_ymin  [0:3];
reg [11:0]  slot_xmax  [0:3];
reg [11:0]  slot_ymax  [0:3];
reg [11:0]  slot_cx    [0:3];
reg [11:0]  slot_cy    [0:3];

function [27:0] bcd_step;
    input [27:0] current;
    reg [27:0] adjusted;
    begin
        adjusted = current;
        if(adjusted[15:12] >= 4'd5)
            adjusted[15:12] = adjusted[15:12] + 4'd3;
        if(adjusted[19:16] >= 4'd5)
            adjusted[19:16] = adjusted[19:16] + 4'd3;
        if(adjusted[23:20] >= 4'd5)
            adjusted[23:20] = adjusted[23:20] + 4'd3;
        if(adjusted[27:24] >= 4'd5)
            adjusted[27:24] = adjusted[27:24] + 4'd3;
        bcd_step = adjusted << 1;
    end
endfunction

reg        start_pending;
reg [2:0]  last_index;
reg        convert_active;
reg [2:0]  convert_index;
reg [3:0]  iteration;
reg [27:0] bcd_x_work;
reg [27:0] bcd_y_work;

reg        work_valid;
reg [2:0]  work_color;
reg [2:0]  work_shape;
reg [20:0] work_area;
reg [11:0] work_xmin, work_ymin, work_xmax, work_ymax;
reg [11:0] work_cx, work_cy;

wire [27:0] bcd_x_next = bcd_step(bcd_x_work);
wire [27:0] bcd_y_next = bcd_step(bcd_y_work);
wire [2:0] next_index = convert_index + 3'd1;

integer reset_i;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        for(reset_i = 0; reset_i < 4; reset_i = reset_i + 1) begin
            slot_valid[reset_i] <= 1'b0;
            slot_color[reset_i] <= 2'd0;
            slot_shape[reset_i] <= 2'd0;
            slot_area[reset_i]  <= 21'd0;
            slot_xmin[reset_i]  <= 12'd0;
            slot_ymin[reset_i]  <= 12'd0;
            slot_xmax[reset_i]  <= 12'd0;
            slot_ymax[reset_i]  <= 12'd0;
            slot_cx[reset_i]    <= 12'd0;
            slot_cy[reset_i]    <= 12'd0;
        end
        start_pending <= 1'b0;
        last_index <= 3'd0;
        convert_active <= 1'b0;
        convert_index <= 3'd0;
        iteration <= 4'd0;
        bcd_x_work <= 28'd0;
        bcd_y_work <= 28'd0;
        work_valid <= 1'b0;
        work_color <= 2'd0;
        work_shape <= 2'd0;
        work_area <= 21'd0;
        work_xmin <= 12'd0; work_ymin <= 12'd0;
        work_xmax <= 12'd0; work_ymax <= 12'd0;
        work_cx <= 12'd0; work_cy <= 12'd0;
        O_strobe <= 1'b0;
        O_last <= 1'b0;
        O_index <= 3'd0;
        O_record <= 144'd0;
    end else begin
        O_strobe <= 1'b0;
        O_last   <= 1'b0;

        if(I_strobe) begin
            slot_valid[I_index] <= I_valid;
            slot_color[I_index] <= I_color;
            slot_shape[I_index] <= I_shape;
            slot_area[I_index]  <= I_area;
            slot_xmin[I_index]  <= I_xmin;
            slot_ymin[I_index]  <= I_ymin;
            slot_xmax[I_index]  <= I_xmax;
            slot_ymax[I_index]  <= I_ymax;
            slot_cx[I_index]    <=
                ({1'b0,I_xmin} + {1'b0,I_xmax}) >> 1;
            slot_cy[I_index]    <=
                ({1'b0,I_ymin} + {1'b0,I_ymax}) >> 1;
            if(I_last) begin
                start_pending <= 1'b1;
                last_index    <= I_index;
            end
        end

        if(start_pending && !convert_active) begin
            start_pending <= 1'b0;
            convert_active <= 1'b1;
            convert_index <= 3'd0;
            iteration <= 4'd0;
            bcd_x_work <= {16'd0,slot_cx[0]};
            bcd_y_work <= {16'd0,slot_cy[0]};
            work_valid <= slot_valid[0];
            work_color <= slot_color[0];
            work_shape <= slot_shape[0];
            work_area  <= slot_area[0];
            work_xmin  <= slot_xmin[0];
            work_ymin  <= slot_ymin[0];
            work_xmax  <= slot_xmax[0];
            work_ymax  <= slot_ymax[0];
            work_cx    <= slot_cx[0];
            work_cy    <= slot_cy[0];
        end else if(convert_active) begin
            if(iteration == 4'd11) begin
                O_strobe <= 1'b1;
                O_last   <= (convert_index == last_index);
                O_index  <= convert_index;
                O_record <= {
                    work_valid, work_color, work_shape[1:0], work_area,
                    work_xmin, work_ymin, work_xmax, work_ymax,
                    work_cx, work_cy,
                    bcd_x_next[27:12], bcd_y_next[27:12], work_shape[2], 12'd0
                };

                if(convert_index == last_index) begin
                    convert_active <= 1'b0;
                end else begin
                    convert_index <= next_index;
                    iteration <= 4'd0;
                    bcd_x_work <= {16'd0,slot_cx[next_index]};
                    bcd_y_work <= {16'd0,slot_cy[next_index]};
                    work_valid <= slot_valid[next_index];
                    work_color <= slot_color[next_index];
                    work_shape <= slot_shape[next_index];
                    work_area  <= slot_area[next_index];
                    work_xmin  <= slot_xmin[next_index];
                    work_ymin  <= slot_ymin[next_index];
                    work_xmax  <= slot_xmax[next_index];
                    work_ymax  <= slot_ymax[next_index];
                    work_cx    <= slot_cx[next_index];
                    work_cy    <= slot_cy[next_index];
                end
            end else begin
                bcd_x_work <= bcd_x_next;
                bcd_y_work <= bcd_y_next;
                iteration <= iteration + 1'b1;
            end
        end
    end
end

endmodule
