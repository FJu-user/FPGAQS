

module design_top_wrapper #(
    parameter CASCADE_SUPPORT=1,
    parameter integer P_SERVO_USB_DIAG=0,
    parameter [47:0] LOCAL_MAC=48'h020000000003,PEER_MAC=48'h020000000002,
    parameter [31:0] LOCAL_IP=32'hc0a88903,PEER_IP=32'hc0a88902
) (
    input wire        I_sys_clk,
    input wire        I_mode_sw4,
    input wire        I_cascade_sw2,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    input wire [3:0]  I_button,
    input wire I_uart_rx,
    output wire O_uart_tx,
    output wire [3:0] O_external_led,
    output wire O_buzzer_n,
    output wire O_sort_servo_pwm,

    input wire [3:0]  I_a_rgmii_rxd,
    input wire        I_a_rgmii_rx_ctl,
    input wire        I_a_rgmii_rxc,
    output wire [3:0] O_a_rgmii_txd,
    output wire       O_a_rgmii_tx_ctl,
    output wire       O_a_rgmii_txc,
    output wire       O_phy_rst,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,


    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);

    // R10 is physically Ethernet TX_CTL, not a board reset button. R11 is
    // Ethernet TXD0. Release both legacy DSI-example aliases for the PHY.
    // Preserve PLL reset polarity using a 1.31 ms power-on reset at 50 MHz.
    reg [15:0] S_power_on_count = 16'd0;
    wire I_rst_n = &S_power_on_count;
    always @(posedge I_sys_clk)
        if(!I_rst_n) S_power_on_count <= S_power_on_count + 1'b1;

    // Fixed 720p network-image reader; A owns camera capture and Mode0-16.
    localparam integer VIDEO_H_ACTIVE = 1920;
    localparam integer VIDEO_H_TOTAL  = 2200;
    localparam integer VIDEO_H_FP     = 88;
    localparam integer VIDEO_H_SYNC   = 44;
    localparam integer VIDEO_H_BP     = 148;
    localparam integer VIDEO_V_ACTIVE = 1080;
    localparam integer VIDEO_V_TOTAL  = 1125;
    localparam integer VIDEO_V_FP     = 4;
    localparam integer VIDEO_V_SYNC   = 5;
    localparam integer VIDEO_V_BP     = 36;
    localparam integer VIDEO_VIC      = 16;
    // Retain the existing network-image HDMI reader and pixel timing.
    localparam integer HDMI_DEBUG_MODE = 0;
    // Kept only for compatibility with the former encrypted-core interface.
    localparam         HDMI_CORE_TPG = "Disable";


    wire        	S_100m_clk;

    wire        	S_aux_50m_clk;
	wire        	S_hdmi_720_pixel_clk;
	wire        	S_hdmi_720_serial_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire            S_hdmi_pll_lock;
    wire        	S_rst_n;
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;
    wire S_video_path_100m_rst_n;
    wire S_hdmi_reset_async_n;
    reg [3:0] S_hdmi_reset_sync;
    wire S_mode_1080 = 1'b0;
    (* ASYNC_REG="TRUE" *) reg [1:0] S_memory_ready_sync;

    wire [11:0] S_active_width  = S_mode_1080 ? 12'd1920 : 12'd1280;
    wire [11:0] S_active_height = S_mode_1080 ? 12'd1080 : 12'd720;


wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     
    wire[1:0]   S_active_read_bank_ddr;
    wire[7:0]   S_display_frame_seq_ddr;
    wire        S_frame_info_toggle_ddr;
    wire[1:0]   S_display_bank_pixel;
    wire[7:0]   S_display_frame_seq_pixel;
    wire        S_frame_info_toggle_pixel;
    wire[4:0]   S_algorithm_shadow_mode_sys;
    wire        S_algorithm_reset_toggle_sys;
    wire[4:0]   S_algorithm_shadow_mode;
    wire        S_algorithm_shadow_valid;
    wire        S_algorithm_reset_event;

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;
    assign S_video_out_vsync = ~S_hdmi_vsync;
    assign S_rst_n = S_pll_lock;
    assign S_hdmi_pll_lock = S_pll_lock;

    // Network uploads and frame reads start after DDR calibration, independent
    // of the removed camera configuration. Each receiving domain releases reset
    // on its own clock; DDR itself remains on the original PLL reset boundary.
    always @(posedge S_100m_clk or negedge S_rst_n)
        if(!S_rst_n) S_memory_ready_sync <= 2'b00;
        else S_memory_ready_sync <= {S_memory_ready_sync[0],S_init_calib_complete};
    assign S_video_path_100m_rst_n = S_memory_ready_sync[1];
    assign S_hdmi_reset_async_n = S_rst_n & S_memory_ready_sync[1];
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_reset_async_n)
        if(!S_hdmi_reset_async_n) S_hdmi_reset_sync <= 4'b0000;
        else S_hdmi_reset_sync <= {S_hdmi_reset_sync[2:0],1'b1};
    assign S_hdmi_rst_n = S_hdmi_reset_sync[3];

    assign O_cam_rst = 1'b0;
    assign O_cam_24m = 1'b0;
    assign O_cam_scl = 1'b1;
    assign IO_cam_sda = 1'bz;

    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    (                    ),

        .clk4_out    ( S_hdmi_720_pixel_clk ),
        .clk5_out    (                    ),

        .lock        ( S_pll_lock        )

    );

    assign S_hdmi_pixel_clk = S_hdmi_720_pixel_clk;


    wire [383:0] uart_cmd_reply;
    wire uart_front_valid,uart_front_preview,uart_reader_preview;wire [24:0] uart_front_addr;wire [31:0] uart_front_id;
    wire [31:0] uart_front_generation,uart_reader_generation,uart_reader_id;
    wire uart_reader_resolution,uart_reader_ref_valid,uart_reader_running;
    wire [24:0] uart_reader_ref_base;
    wire uart_metadata_ready,uart_frame_enable,uart_present_frame;
    wire [4:0] uart_active_mode_pixel;wire [1:0] uart_active_view_pixel;
    wire [127:0] uart_display_status;
    wire [31:0] uart_displayed_id;
    wire uart_frame_window,uart_frame_boundary,uart_hold_frame,uart_lock_bus;
    wire uart_wr_en,uart_rd_en,uart_fence_response;
    wire [24:0] uart_addr;wire [127:0] uart_wr_data;
    wire ddr_queue_empty;
    reg [1:0] uart_error_sync;
    wire [32:0] uart_status_sys;wire uart_status_valid;
    wire [2:0] uart_controls_ddr;wire uart_controls_valid;
    wire [1:0] uart_compare_pixel;wire uart_compare_valid;
    reg [1:0] mode_ddr_sync,path_ddr_sync;
    (* ASYNC_REG="TRUE" *) reg [1:0] uart_mode_sys_sync;
    wire uart_active_source;wire [7:0] uart_context_epoch;
    wire [85:0] uart_frame_meta_pixel;
    always @(posedge S_100m_clk or negedge S_rst_n)
     if(!S_rst_n) uart_error_sync<=0;else uart_error_sync<={uart_error_sync[0],uart_cmd_error};
    always @(posedge S_100m_clk or negedge S_rst_n)
     if(!S_rst_n) uart_mode_sys_sync<=0;else uart_mode_sys_sync<={uart_mode_sys_sync[0],S_mode_1080};
    always @(posedge S_ddr_clk or negedge S_rst_n)
     if(!S_rst_n) begin mode_ddr_sync<=0;path_ddr_sync<=0;end
     else begin mode_ddr_sync<={mode_ddr_sync[0],S_mode_1080};path_ddr_sync<={path_ddr_sync[0],S_video_path_100m_rst_n};end
    wire uart_source_sys;
    wire [1:0] uart_compare_sys;
    wire [155:0] uart_mem_ddr;
    wire uart_cmd_valid,uart_cmd_ready,uart_cmd_error;
    wire [383:0] eth_mem_reply;
    wire [155:0] eth_mem_sys,shared_mem_sys;
    wire eth_mem_valid,eth_mem_ready,eth_mem_error,shared_mem_valid,shared_mem_ready;
    wire eth_source_set,eth_source_value,eth_compare_set,eth_mode_set;
    wire [1:0] eth_compare_value;
    wire [4:0] eth_requested_mode;
    // No B camera lease or image-return path exists in this compute endpoint.
    wire cascade_lock=1'b0,cascade_read=1'b0,cascade_response=1'b0;
    wire [24:0] cascade_addr=25'd0;
    wire [255:0] rv_objects_sys;wire [3:0] rv_count_sys;wire rv_valid_sys,rv_overflow_sys;
    wire [31:0] rv_source_sys,rv_epoch_sys;
    wire [191:0] rv_reply;wire rv_request;wire rv_request_native,rv_request_mode1080;wire [31:0] rv_request_epoch,rv_request_sequence;wire [4:0] rv_request_mode;
    wire rv_b_active;wire [4:0] rv_b_mode;wire [31:0] rv_b_epoch;
    assign uart_source_sys=1'b1; // B receives images only through Ethernet.
    wire [37:0] rv_control_pixel;wire [325:0] rv_result_sys;
    localparam integer RESULT_CDC_WIDTH=P_SERVO_USB_DIAG?422:326;
    wire [RESULT_CDC_WIDTH-1:0] rv_result_bundle;
    wire [421:0] rv_result_with_diag=rv_result_bundle;
    wire [95:0] rv_b_diag,rv_diag_sys;
    assign rv_result_sys=rv_result_bundle[325:0];
    assign rv_diag_sys=rv_result_with_diag[421:326];
    wire [255:0] rv_b_objects;wire [3:0] rv_b_count;wire rv_b_overflow,rv_b_valid;
    wire [31:0] rv_b_source,rv_b_result_epoch;
    uart_mailbox #(.WIDTH(38)) u_remote_control_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data({rv_b_mode,rv_b_active,rv_b_epoch}),.s_valid(1'b1),.s_ready(),
     .d_clk(S_hdmi_pixel_clk),.d_rst_n(S_rst_n),.d_data(rv_control_pixel),.d_valid(),.d_ready(1'b1));
    remote_vision_engine #(.P_SERVO_USB_DIAG(P_SERVO_USB_DIAG)) u_remote_vision(
     .clk(S_hdmi_pixel_clk),.rst_n(S_hdmi_rst_n),.mode(rv_control_pixel[37:33]),.enable(rv_control_pixel[32]),.control_epoch(rv_control_pixel[31:0]),
     .rgb(S_hdmi_out_data),.de(S_hdmi_out_de && uart_frame_enable),.hs(S_hdmi_out_hsync),.vs(S_hdmi_out_vsync),
     .preview_source(uart_frame_meta_pixel[85] && uart_frame_meta_pixel[11]),
     .image_id(uart_frame_meta_pixel[51:20]),.generation(uart_frame_meta_pixel[83:52]),
     .diagnostic(rv_b_diag),.objects(rv_b_objects),.count(rv_b_count),.overflow(rv_b_overflow),.valid(rv_b_valid),.source_id(rv_b_source),.result_epoch(rv_b_result_epoch));
    wire rv_result_update;
    wire [421:0] rv_result_source={rv_b_diag,rv_b_result_epoch,rv_b_source,rv_b_valid,rv_b_overflow,rv_b_count,rv_b_objects};
    uart_mailbox #(.WIDTH(RESULT_CDC_WIDTH)) u_remote_objects_cdc(
     .s_clk(S_hdmi_pixel_clk),.s_rst_n(S_rst_n),.s_data(rv_result_source[RESULT_CDC_WIDTH-1:0]),.s_valid(1'b1),.s_ready(),
     .d_clk(S_100m_clk),.d_rst_n(S_rst_n),.d_data(rv_result_bundle),.d_valid(rv_result_update),.d_ready(1'b1));
    // Additional consumers only: preserve the final recognition/coordinate/network chain.
    mode17_peripheral_control u_mode17_peripherals(
     .clk(S_100m_clk),.rst_n(S_rst_n),
     .enable(rv_b_active && rv_b_mode==17 && S_video_path_100m_rst_n),.control_epoch(rv_b_epoch),
     .result_update(rv_result_update),.result_valid(rv_result_sys[261]),
     .result_epoch(rv_result_sys[325:294]),.source_id(rv_result_sys[293:262]),
     .object_count(rv_result_sys[259:256]),.objects(rv_result_sys[255:0]),
     .buzzer_switch(I_mode_sw4),.led_rgb_y(O_external_led),.buzzer_n(O_buzzer_n));
    wire [511:0] sort_diagnostic;
    mode17_triangle_sorter u_mode17_triangle_sorter(
     .clk(S_100m_clk),.rst_n(S_rst_n),
     .enable(rv_b_active && rv_b_mode==17 && S_video_path_100m_rst_n),.control_epoch(rv_b_epoch),
     .result_update(rv_result_update),.result_valid(rv_result_sys[261]),.result_overflow(rv_result_sys[260]),
     .result_epoch(rv_result_sys[325:294]),.source_id(rv_result_sys[293:262]),
     .object_count(rv_result_sys[259:256]),.objects(rv_result_sys[255:0]),
     .servo_pwm(O_sort_servo_pwm),.diagnostic(sort_diagnostic));
    wire [325:0] rv_formatted;
    wire [255:0] rv_coordinate_bcd;
    remote_coordinate_formatter u_coordinate_formatter(
     .clk(S_100m_clk),.rst_n(S_rst_n),.raw(rv_result_sys),
     .result(rv_formatted),.coordinate_bcd(rv_coordinate_bcd));
    remote_vision_server u_remote_server(.clk(S_100m_clk),.rst_n(S_rst_n),.request(rv_request),
     .request_epoch(rv_request_epoch),.request_sequence(rv_request_sequence),.request_mode(rv_request_mode),.request_native(rv_request_native),.request_mode1080(rv_request_mode1080),
     .objects(rv_formatted[255:0]),.count(rv_formatted[259:256]),.overflow(rv_formatted[260]),.valid(rv_formatted[261]),
     .source_id(rv_formatted[293:262]),.result_epoch(rv_formatted[325:294]),.coordinate_bcd(rv_coordinate_bcd),
     .reply(rv_reply),.remote_mode(rv_b_mode),.remote_epoch(rv_b_epoch),.active(rv_b_active));
    ethernet_image_bridge #(.VISION_ROLE(2),.MAX_MODE(18),.CASCADE_SUPPORT(CASCADE_SUPPORT),.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),
     .PEER_MAC(PEER_MAC),.PEER_IP(PEER_IP)) u_ethernet_image_bridge(
     .ref_clk(I_sys_clk),.sys_clk(S_100m_clk),.rst_n(S_rst_n),.mode1080(uart_mode_sys_sync[1]),
     .rgmii_rxd(I_a_rgmii_rxd),.rgmii_rx_ctl(I_a_rgmii_rx_ctl),.rgmii_rxc(I_a_rgmii_rxc),
     .rgmii_txd(O_a_rgmii_txd),.rgmii_tx_ctl(O_a_rgmii_tx_ctl),.rgmii_txc(O_a_rgmii_txc),.phy_rst_n(O_phy_rst),
     .source_image(uart_source_sys),.compare_mode(uart_compare_sys),.current_mode(S_algorithm_shadow_mode_sys),
     .front_valid(uart_status_sys[32]),.displayed_id(uart_status_sys[31:0]),
     .source_set(eth_source_set),.source_value(eth_source_value),.compare_set(eth_compare_set),.compare_value(eth_compare_value),
     .mode_set(eth_mode_set),.requested_mode(eth_requested_mode),
     .mem_data(eth_mem_sys),.mem_valid(eth_mem_valid),.mem_ready(eth_mem_ready),.mem_error(eth_mem_error),.mem_reply(eth_mem_reply),
     .cascade_run(S_video_path_100m_rst_n),.cascade_read_command(),.cascade_read_valid(),
     .cascade_read_ready(1'b1),.cascade_read_reply(128'd0),
     .vision_mode(5'd0),
     .vision_objects(rv_objects_sys),.vision_count(rv_count_sys),.vision_valid(rv_valid_sys),.vision_overflow(rv_overflow_sys),
     .vision_source_id(rv_source_sys),.vision_config_epoch(rv_epoch_sys),.vision_reply(rv_reply),
     .vision_request(rv_request),.vision_request_epoch(rv_request_epoch),.vision_request_sequence(rv_request_sequence),.vision_request_mode(rv_request_mode),.vision_request_native(rv_request_native),.vision_request_mode1080(rv_request_mode1080));
    // Ethernet is the only upload producer. Its SEND/ACCEPT/WAIT handshake
    // matches the existing single-outstanding mailbox completion contract.
    assign shared_mem_sys=eth_mem_sys;
    assign shared_mem_valid=eth_mem_valid;
    assign eth_mem_ready=shared_mem_ready;
    assign eth_mem_error=uart_error_sync[1];
    assign eth_mem_reply=uart_cmd_reply;
    assign uart_compare_sys=2'b00;
    // Transmit-only monitoring; the original RX input remains unused.
    wire [511:0] usb_snapshot={rv_diag_sys[95:32],sort_diagnostic[447:416],rv_diag_sys[31:0],
      sort_diagnostic[383:136],8'd3,sort_diagnostic[127:32],14'd0,rv_b_active,S_video_path_100m_rst_n,16'ha17d};
    generate if(P_SERVO_USB_DIAG)begin:g_servo_usb_diag
      mode17_uart_diag u_servo_usb_diagnostic(.clk(S_100m_clk),.rst_n(S_rst_n),
        .snapshot(usb_snapshot),.tx(O_uart_tx));
    end else begin:g_servo_no_usb_diag
      assign O_uart_tx=1'b1;
    end endgenerate
    uart_mailbox #(.WIDTH(156)) u_uart_memory_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data(shared_mem_sys),.s_valid(shared_mem_valid),.s_ready(shared_mem_ready),
     .d_clk(S_ddr_clk),.d_rst_n(S_rst_n),.d_data(uart_mem_ddr),.d_valid(uart_cmd_valid),.d_ready(uart_cmd_ready));
    uart_mailbox #(.WIDTH(33)) u_uart_status_cdc(
     .s_clk(S_ddr_clk),.s_rst_n(S_rst_n),.s_data({uart_front_valid,uart_displayed_id}),.s_valid(1'b1),.s_ready(),
     .d_clk(S_100m_clk),.d_rst_n(S_rst_n),.d_data(uart_status_sys),.d_valid(uart_status_valid),.d_ready(1'b1));
    uart_mailbox #(.WIDTH(3)) u_uart_controls_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data({uart_source_sys,uart_compare_sys}),.s_valid(1'b1),.s_ready(),
     .d_clk(S_ddr_clk),.d_rst_n(S_rst_n),.d_data(uart_controls_ddr),.d_valid(uart_controls_valid),.d_ready(1'b1));
    assign uart_compare_pixel=2'b00;
    assign uart_compare_valid=1'b1;
    uart_ddr_service #(.COMPACT_SUPPORT(CASCADE_SUPPORT)) u_uart_ddr_service(
     .clk(S_ddr_clk),.rst_n(S_rst_n),.mode1080(mode_ddr_sync[1]),.path_run(path_ddr_sync[1]),
     .cmd_data(uart_mem_ddr),.cmd_valid(uart_cmd_valid),.cmd_ready(uart_cmd_ready),.cmd_error(uart_cmd_error),
     .cmd_reply(uart_cmd_reply),.reader_ref_valid(uart_reader_ref_valid),.reader_ref_base(uart_reader_ref_base),
     .display_status(uart_display_status),
     .camera_busy(S_video_in_wr_busy || cascade_lock),.camera_write(S_vi_ddr_wr_en),.video_busy(S_video_out_rd_busy),.video_read(S_vo_ddr_rd_en),
     .user_ready(S_ddr_user_ready),.queue_empty(ddr_queue_empty),.rd_valid(S_ddr_user_rd_valid),.rd_data(S_ddr_user_rd_data),
     .frame_window(uart_frame_window),.frame_boundary(uart_frame_boundary),.hold_frame(uart_hold_frame),.lock_bus(uart_lock_bus),
     .wr_en(uart_wr_en),.rd_en(uart_rd_en),.addr(uart_addr),.wr_data(uart_wr_data),.fence_response(uart_fence_response),
     .front_valid(uart_front_valid),.front_preview(uart_front_preview),.front_addr(uart_front_addr),.front_id(uart_front_id),.front_generation(uart_front_generation));

    // No camera writer or completed camera bank remains.
    assign S_video_in_wr_busy = 1'b0;
    assign S_video_out_rp = 2'b00;
    assign S_vi_ddr_wr_en = 1'b0;
    assign S_vi_ddr_wr_addr = 25'd0;
    assign S_vi_ddr_wr_data = 128'd0;
    assign S_ddr_user_wr_en = uart_wr_en;
    assign S_ddr_user_rd_en = S_vo_ddr_rd_en | uart_rd_en | cascade_read;
    assign S_ddr_user_addr = S_vo_ddr_rd_en ? S_vo_ddr_rd_addr :
                             cascade_read ? cascade_addr : uart_addr;
    assign S_ddr_user_wr_data = uart_wr_data;

    assign S_video_out_rst_n = S_hdmi_rst_n;

    video_out #(.META_HANDSHAKE(1),.PREVIEW_SUPPORT(CASCADE_SUPPORT)) u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_system_rst_n(S_rst_n),
        .I_mode_1080(mode_ddr_sync[1]),.I_source_uart(uart_controls_ddr[2]),
        .I_uart_preview(uart_front_preview),.I_preview_pixel(uart_frame_meta_pixel[85]),.I_preview_mode_1080(uart_frame_meta_pixel[84]),.I_uart_valid(uart_front_valid),.I_uart_base(uart_front_addr),.I_uart_id(uart_front_id),
        .I_uart_generation(uart_front_generation),.I_metadata_ready(uart_metadata_ready),.I_frame_enable(uart_frame_enable),
        .O_reader_ref_valid(uart_reader_ref_valid),.O_reader_ref_base(uart_reader_ref_base),.O_reader_running(uart_reader_running),.O_reader_drained(video_reader_drained),.O_camera_ref_valid(camera_reader_ref_valid),
        .O_uart_generation(uart_reader_generation),.O_active_resolution(uart_reader_resolution),.O_active_preview(uart_reader_preview),
        .I_hold_frame(uart_hold_frame),.O_frame_window(uart_frame_window),.O_frame_boundary(uart_frame_boundary),
        .O_source_uart(uart_active_source),.O_context_epoch(uart_context_epoch),.O_displayed_id(uart_reader_id),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy | uart_lock_bus | cascade_lock ),
        .I_video_out_rp      ( S_video_out_rp       ),
        .O_active_read_bank  ( S_active_read_bank_ddr ),
        .O_display_frame_seq ( S_display_frame_seq_ddr),
        .O_frame_info_toggle ( S_frame_info_toggle_ddr),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready && !uart_lock_bus && !cascade_lock && !S_vi_ddr_wr_en ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid && !uart_fence_response && !cascade_response ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );

    // Completion is acknowledged before video_out leaves CLEAR. Pixel admission
    // is decided once per complete frame; actual output confirms DISPLAYED.
    uart_frame_bridge u_uart_frame_bridge(
      .ddr_clk(S_ddr_clk),.sys_rst_n(S_rst_n),.pixel_clk(S_hdmi_pixel_clk),.pixel_rst_n(S_hdmi_rst_n),
      .metadata({uart_reader_preview,uart_reader_resolution,uart_reader_generation,uart_reader_id,uart_context_epoch,
                 uart_active_source,S_frame_info_toggle_ddr,S_display_frame_seq_ddr,S_active_read_bank_ddr}),
      .reader_running(uart_reader_running),.metadata_ready(uart_metadata_ready),
      // Bridge expects active-high VS blanking. S_video_out_vsync is inverted
      // for the DDR reader's edge trigger and is HIGH throughout active video.
      .pixel_vsync(S_hdmi_vsync),.pixel_read_de(S_hdmi_window_rd_en),
      .present_frame(uart_present_frame),
      .active_mode(uart_active_mode_pixel),.active_view(uart_active_view_pixel),
      .pixel_metadata(uart_frame_meta_pixel),.frame_enable(uart_frame_enable),.display_status(uart_display_status));
    assign uart_displayed_id=uart_display_status[48]?uart_display_status[127:96]:32'd0;
    assign {S_frame_info_toggle_pixel,S_display_frame_seq_pixel,S_display_bank_pixel}=uart_frame_meta_pixel[10:0];

    // A owns all physical mode controls; B reports its fixed transport mode.
    assign S_algorithm_shadow_mode_sys=5'd0;

    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_queue_empty(ddr_queue_empty),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( VIDEO_H_ACTIVE ),
        .H_FrameSize  ( VIDEO_H_TOTAL  ),
        .H_SyncStart  ( VIDEO_H_ACTIVE + VIDEO_H_FP ),
        .H_SyncEnd    ( VIDEO_H_ACTIVE + VIDEO_H_FP + VIDEO_H_SYNC ),
        .V_ActiveSize ( VIDEO_V_ACTIVE ),
        .V_FrameSize  ( VIDEO_V_TOTAL  ),
        .V_SyncStart  ( VIDEO_V_ACTIVE + VIDEO_V_FP ),
        .V_SyncEnd    ( VIDEO_V_ACTIVE + VIDEO_V_FP + VIDEO_V_SYNC )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .I_mode_1080   ( S_mode_1080      ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( VIDEO_H_ACTIVE ),
        .IMG_HEIGHT ( VIDEO_V_ACTIVE ),
        .DEBUG_MODE ( HDMI_DEBUG_MODE ),
        .READ_DATA_LATENCY(2)
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_debug_status  ( 4'b0000           ),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    // Preserve the old 20+3 pixel-clock publication-confirmation latency,
    // without a local display pipeline, logo memory or HDMI serializer.
    compute_frame_present u_compute_frame_present(
        .clk(S_hdmi_pixel_clk),.rst_n(S_hdmi_rst_n),
        .active_width(S_active_width),.active_height(S_active_height),
        .de(S_hdmi_out_de && uart_frame_enable),.vs(S_hdmi_out_vsync),
        .frame_present(uart_present_frame));
    assign uart_active_mode_pixel=5'd0;
    assign uart_active_view_pixel=2'd0;
    assign O_tmds_ch0_p=1'b0;
    assign O_tmds_ch1_p=1'b0;
    assign O_tmds_ch2_p=1'b0;
    assign O_tmds_clk_p=1'b0;
endmodule
