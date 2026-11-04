

module video_in #(parameter CASCADE_SUPPORT=0, CAPTURE_TRACKING=0, MIPI_TIMING=0,
    parameter BEATS_720=172800, BEATS_1080=388800) (
    input wire         I_rst_n,
    input wire         I_system_rst_n,
    input wire         I_mode_1080,

    input wire         I_camera_clk,
    input wire         I_camera_frame_start,
    input wire [56:0] I_mipi_descriptor,
    output wire [95:0] O_capture_bank_time_gray,
    input wire         I_camera_valid,
    input wire[127:0]  I_camera_data,
    input wire         I_mipi_rx_error,

    input wire         I_ddr_clk,

    input wire         I_display_pause,
    input wire I_cascade_lease_valid,input wire [1:0] I_cascade_lease_bank,
    input wire I_cascade_display_ref_valid,input wire [1:0] I_cascade_display_ref_bank,
    output wire O_cascade_bank_safe,
    input wire         I_video_out_rd_busy,
    output wire        O_video_in_wr_busy,
    output reg[1:0]    O_video_out_rp,     ///读指针
    output wire[163:0] O_capture_bank_metadata,
    output wire [31:0] O_capture_latest_gray,

    output wire        O_ddr_user_wr_en,
    output reg[24:0]   O_ddr_user_addr,
    output wire[127:0] O_ddr_user_wr_data,
    input wire         I_ddr_user_ready
);

    wire        S_fifo_rst;
    reg         S_camera_frame_start_extend; ///脉冲展宽，同步到ddr_clk时钟域
    reg[3:0]    S_extend_cnt;
    reg         S_camera_frame_start_extend_1d;
    reg         S_camera_frame_start_extend_2d;
    reg         S_camera_frame_start_extend_3d;
    wire        S_frame_start;
    reg[1:0]    S_video_in_wp;       ///写指针
    wire[8:0]   S_fifo_rd_num;      
    wire        S_fifo_rd_en;   
    wire        S_fifo_rd_valid;
    wire[127:0] S_fifo_rd_data; 
    reg         S_ddr_wr_valid;
    reg[9:0]    S_ddr_wr_cnt;
    reg pending_write;
    reg frame_live;
    reg [18:0] frame_written,frame_limit;
    reg boundary_fault;
    wire cascade_conflict;
    reg cascade_discard_frame;
    wire discard_overrun;
    // Count committed writes, including the FIFO's one-clock output stage.
    // Saturate until SOF: missing frame markers can never reach a UART slot.
    assign O_ddr_user_wr_en = pending_write && I_rst_n && frame_live &&
                             !S_frame_start && !S_fifo_rst && frame_written<frame_limit && !cascade_conflict && !cascade_discard_frame;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            frame_live<=0;frame_written<=0;frame_limit<=0;boundary_fault<=0;
        end else if(S_frame_start) begin
            frame_live<=1;frame_written<=0;
            frame_limit<=I_mode_1080 ? BEATS_1080:BEATS_720;
        end else begin
            if(O_ddr_user_wr_en) frame_written<=frame_written+1'b1;
            if(frame_live && frame_written==frame_limit && S_fifo_rd_num!=0) boundary_fault<=1;
        end
    end

    localparam IMAGE_BASE_ADDR_0 = 25'd0;
    localparam IMAGE_BASE_ADDR_1 = 25'd7000000;
    localparam IMAGE_BASE_ADDR_2 = 25'd14000000;
    localparam IMAGE_BASE_ADDR_3 = 25'd21000000;


    assign S_fifo_rst = S_camera_frame_start_extend_3d;
    reg [1:0] cascade_write_bank;
    reg latest_complete_valid;
    reg capture_select_pending;
    function bank_reserved(input [1:0] candidate,input lease_on,input [1:0] leased,input display_on,input [1:0] displayed);
        begin bank_reserved=(lease_on && candidate==leased) || (display_on && candidate==displayed);end
    endfunction
    // Four DDR camera banks, three independent references: latest completed
    // frame, HDMI descriptor (including drain/clear), and network snapshot.
    // Skipping banks invalidates the old arithmetic read-pointer = wp - 2.
    function capture_reserved(input [1:0] candidate,input lease_on,input [1:0] leased,
        input display_on,input [1:0] displayed,input completed_on,input [1:0] completed);
        begin capture_reserved=bank_reserved(candidate,lease_on,leased,display_on,displayed) ||
                               (completed_on && candidate==completed);end
    endfunction
    wire reserved0=capture_reserved(S_video_in_wp,I_cascade_lease_valid,I_cascade_lease_bank,
        I_cascade_display_ref_valid,I_cascade_display_ref_bank,latest_complete_valid,O_video_out_rp);
    wire reserved1=capture_reserved(S_video_in_wp+2'd1,I_cascade_lease_valid,I_cascade_lease_bank,
        I_cascade_display_ref_valid,I_cascade_display_ref_bank,latest_complete_valid,O_video_out_rp);
    wire reserved2=capture_reserved(S_video_in_wp+2'd2,I_cascade_lease_valid,I_cascade_lease_bank,
        I_cascade_display_ref_valid,I_cascade_display_ref_bank,latest_complete_valid,O_video_out_rp);
    wire [1:0] next_capture_bank=!reserved0?S_video_in_wp:
        !reserved1?S_video_in_wp+2'd1:!reserved2?S_video_in_wp+2'd2:S_video_in_wp+2'd3;
    wire completed_frame=frame_live && frame_written==frame_limit &&
                         !cascade_discard_frame && !I_mipi_rx_error;
    // Publish at SOF, then select the new writer ONE DDR clock later. HDMI
    // may capture the previous publication on the SOF edge; its reference
    // must be visible before reusing that bank. The camera FIFO is in reset.
    always @(posedge I_ddr_clk or negedge I_rst_n)
        if(!I_rst_n) capture_select_pending<=0;
        else capture_select_pending<=S_frame_start;
    always @(posedge I_ddr_clk or negedge I_rst_n)
        if(!I_rst_n) begin cascade_write_bank<=0;latest_complete_valid<=0;end
        else if(CASCADE_SUPPORT) begin
            if(S_frame_start && completed_frame && !I_display_pause) latest_complete_valid<=1;
            if(capture_select_pending) cascade_write_bank<=next_capture_bank;
        end else if(S_frame_start) cascade_write_bank<=I_mipi_rx_error?S_video_in_wp-2'd1:S_video_in_wp;
    // Observes existing events only; never changes FIFO resets or DDR grants.
    generate if(CAPTURE_TRACKING) begin:g_capture_tracking
        capture_frame_metadata #(.MIPI_TIMING(MIPI_TIMING)) u_capture_frame_metadata(
            .I_clk(I_ddr_clk),.I_system_rst_n(I_system_rst_n),.I_path_rst_n(I_rst_n),
            .I_frame_start(S_frame_start),
            .I_mipi_descriptor(I_mipi_descriptor),.O_bank_time_gray(O_capture_bank_time_gray),
            .I_writer_select(CASCADE_SUPPORT ? capture_select_pending : S_frame_start),
            .I_next_write_bank(CASCADE_SUPPORT ? next_capture_bank :
                              (I_mipi_rx_error ? S_video_in_wp-2'd1 : S_video_in_wp)),
            .I_write_bank(cascade_write_bank),.I_write_en(O_ddr_user_wr_en),
            .I_frame_fault(discard_overrun),
            .I_publish(S_frame_start && completed_frame && !I_display_pause),
            .O_latest_gray(O_capture_latest_gray),.O_bank_metadata(O_capture_bank_metadata));
    end else begin:g_no_capture_tracking
        assign O_capture_bank_time_gray=96'd0;
        assign O_capture_bank_metadata=164'd0;assign O_capture_latest_gray=0;
    end endgenerate

    assign O_cascade_bank_safe=CASCADE_SUPPORT ?
        latest_complete_valid && !S_frame_start && !capture_select_pending && O_video_out_rp!=cascade_write_bank :
        !S_frame_start && O_video_out_rp!=cascade_write_bank && O_video_out_rp!=S_video_in_wp;
    assign cascade_conflict=CASCADE_SUPPORT && bank_reserved(cascade_write_bank,I_cascade_lease_valid,I_cascade_lease_bank,I_cascade_display_ref_valid,I_cascade_display_ref_bank);
    always @(posedge I_ddr_clk or negedge I_rst_n)
        if(!I_rst_n)cascade_discard_frame<=0;
        else if(S_frame_start || capture_select_pending)cascade_discard_frame<=0;
        else if(cascade_conflict)cascade_discard_frame<=1;

    // S_ddr_wr_valid is the ownership flag for the complete DDR write burst.
    // O_ddr_user_wr_en is registered one cycle after S_fifo_rd_en; including it
    // here bridges the only idle cycle between consecutive 240-beat bursts.
    // With a continuous 1080p stream that kept wr_busy permanently asserted and
    // starved video_out, so no DDR read request could ever start.
    assign O_video_in_wr_busy = S_ddr_wr_valid;

    w128_d512_fifo U_w128_d512_fifo(
        .rst        ( S_fifo_rst         ),   

        .clkw       ( I_camera_clk       ),     
        .we         ( I_camera_valid     ),
        .di         ( I_camera_data      ),
        .afull      (),
        .full_flag  (),
        .wrusedw    (),
 
        .clkr       ( I_ddr_clk          ),
        .re         ( S_fifo_rd_en       ), 
        .dout       ( O_ddr_user_wr_data ),  
        .rdusedw    ( S_fifo_rd_num      ),
        .valid      (), 
        .empty_flag (),
        .aempty     ()
    );


    always @(posedge I_camera_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_camera_frame_start_extend <= 1'b0;
        else
            if(I_camera_frame_start)
                S_camera_frame_start_extend <= 1'b1;
            else if(S_extend_cnt == 'd7)
                S_camera_frame_start_extend <= 1'b0;
            else
                S_camera_frame_start_extend <= S_camera_frame_start_extend;
    end

	
    always @ (posedge I_camera_clk) begin
    	if(S_camera_frame_start_extend)
        	S_extend_cnt <= S_extend_cnt + 'd1;
      	else
          	S_extend_cnt <= 'd0;
    end


    always @(posedge I_ddr_clk) begin
        S_camera_frame_start_extend_1d <= S_camera_frame_start_extend;
        S_camera_frame_start_extend_2d <= S_camera_frame_start_extend_1d;
        S_camera_frame_start_extend_3d <= S_camera_frame_start_extend_2d;
    end

    assign S_frame_start = ~S_camera_frame_start_extend_3d & S_camera_frame_start_extend_2d;

	/*
		如果前一帧图像有误少行了，那么地址回退为之前的，覆盖有问题的那帧图像
	*/
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) S_video_in_wp<=0;
        else if(CASCADE_SUPPORT) begin
            if(capture_select_pending) S_video_in_wp<=next_capture_bank+2'd1;
        end else if(!I_display_pause && S_frame_start && !I_mipi_rx_error)
            S_video_in_wp<=S_video_in_wp+2'd1;
    end

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) O_video_out_rp<=0;
        else if(!I_display_pause && S_frame_start) begin
            if(CASCADE_SUPPORT) begin
                // A snapshot protects its own bank; it does not freeze HDMI.
                // Truncated/aborted frames never become display descriptors.
                if(completed_frame) O_video_out_rp<=cascade_write_bank;
            end else O_video_out_rp<=S_video_in_wp-2'd2;
        end
    end

    /*
        fifo的深度是512，实际的深度是510，因此需要注意每次读出的长度避免为256，否则连续两次读写会引起fifo读空，丢失数据
    */
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_ddr_wr_valid <= 1'b0;
        else
            if(S_frame_start || S_fifo_rst || (frame_live && frame_written==frame_limit))
                S_ddr_wr_valid <= 1'b0;
            else if(S_ddr_wr_valid && I_ddr_user_ready && S_ddr_wr_cnt == 'd239)
                S_ddr_wr_valid <= 1'b0;
            else if(S_fifo_rd_num >= 'd240 && (!I_video_out_rd_busy) && (!S_fifo_rst) && frame_live && frame_written<frame_limit)
                S_ddr_wr_valid <= 1'b1;
            else
                S_ddr_wr_valid <= S_ddr_wr_valid;
    end

    always @(posedge I_ddr_clk) begin
        if(S_ddr_wr_valid)
            begin
                if(I_ddr_user_ready)
                    S_ddr_wr_cnt <= S_ddr_wr_cnt + 'd1;
                else
                    S_ddr_wr_cnt <= S_ddr_wr_cnt;
            end
        else
            S_ddr_wr_cnt <= 'd0;
    end

    assign discard_overrun = frame_live && frame_written==frame_limit && S_fifo_rd_num!=0;
    assign S_fifo_rd_en = !S_frame_start && !S_fifo_rst && frame_live &&
                         (discard_overrun || (S_ddr_wr_valid && I_ddr_user_ready &&
                          ({1'b0,frame_written}+pending_write < {1'b0,frame_limit})));

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) pending_write<=0;
        else pending_write <= S_fifo_rd_en;
    end

	/*
		如果前一帧图像有误少行了，那么地址回退为之前的，覆盖有问题的那帧图像
	*/
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            O_ddr_user_addr <= 1'b0;
        else
            if(CASCADE_SUPPORT && capture_select_pending)
                begin
                    case(next_capture_bank)
                        0: O_ddr_user_addr<=IMAGE_BASE_ADDR_0;
                        1: O_ddr_user_addr<=IMAGE_BASE_ADDR_1;
                        2: O_ddr_user_addr<=IMAGE_BASE_ADDR_2;
                        3: O_ddr_user_addr<=IMAGE_BASE_ADDR_3;
                    endcase
                end
            else if(!CASCADE_SUPPORT && S_frame_start && (!I_mipi_rx_error))
                begin
                    case(S_video_in_wp)
                        'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                        'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                        'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
                        'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
                    endcase
                end
			else if(!CASCADE_SUPPORT && S_frame_start && I_mipi_rx_error)
				begin
                	case(S_video_in_wp)
                        'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
                        'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                        'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                        'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
                    endcase
                end
            else if(O_ddr_user_wr_en)
                O_ddr_user_addr <= O_ddr_user_addr + 'd8;
            else    
                O_ddr_user_addr <= O_ddr_user_addr;
    end

    
endmodule
