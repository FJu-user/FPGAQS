

module design_top_wrapper #(
    parameter CASCADE_SUPPORT=1,
    parameter [47:0] LOCAL_MAC=48'h020000000002,PEER_MAC=48'h020000000003,
    parameter [31:0] LOCAL_IP=32'hc0a88902,PEER_IP=32'hc0a88903
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

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

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

    // Single source of truth for the current display mode.  The SC500CS and
    // ISP remain 1920x1080@30; only the DDR read/display side runs at 60 Hz,
    // so every captured frame is read twice.  A later dual-mode build can
    // replace these display constants and the dedicated display clock manager
    // at a frame boundary while keeping the camera/ISP/DDR write side alive.
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
    // Mature camera path: no color-bar or status-screen debug muxing.
    localparam integer HDMI_DEBUG_MODE = 0;
    // Kept only for compatibility with the former encrypted-core interface.
    localparam         HDMI_CORE_TPG = "Disable";


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
	wire        	S_hdmi_720_pixel_clk;
	wire        	S_hdmi_720_serial_clk;
	wire        	S_hdmi_1080_pixel_clk;
	wire        	S_hdmi_1080_serial_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire            S_hdmi_pll_lock;
    wire            S_hdmi_1080_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	wire [23:0]     S_ISP_frame_luma_sum;
	wire [15:0]     S_ISP_frame_sample_count;
	wire            S_ISP_frame_stats_toggle;
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;
    // Reserved mode-controller boundary.  A future hot-switch controller
    // deasserts this signal, changes the display clock/timing selection, waits
    // for the selected PLL to lock, and releases on a clean frame boundary.
    wire        S_display_mode_reset_n;
    wire        S_video_path_rst_n;
    wire        S_video_path_100m_rst_n;
    wire        S_hdmi_reset_async_n;
    reg [1:0]   S_video_path_100m_rst_sync;
    reg [3:0]   S_hdmi_reset_sync;
    reg [1:0]   S_sw4_sync;
    reg         S_sw4_candidate;
    reg [16:0]  S_sw4_stable_cnt;
    reg         S_mode_request;
    reg         S_mode_1080;
    reg         S_mode_path_run;
    reg         S_mode_display_run;
    reg [2:0]   S_mode_state;
    reg [21:0]  S_mode_wait_cnt;

    wire [11:0] S_active_width  = S_mode_1080 ? 12'd1920 : 12'd1280;
    wire [11:0] S_active_height = S_mode_1080 ? 12'd1080 : 12'd720;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
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
    wire        S_algo_out_vsync;
    wire        S_algo_out_hsync;
    wire        S_algo_out_de;
    wire[23:0]  S_algo_out_data;

    wire[23:0]  S_video_rd_data;
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    // 1080p input-format diagnostics. One 1920-pixel RAW10 line contains
    // 2400 bytes, i.e. 600 valid 32-bit CSI payload words.
    reg         S_dbg_hs_valid_d;
    reg [10:0]  S_dbg_csi_words;
    reg [10:0]  S_dbg_good_lines;
    reg         S_dbg_frame_seen_once;
    reg         S_dbg_frame_repeat_seen;
    reg         S_dbg_width_1920_seen;
    reg         S_dbg_height_1080_seen;
    reg         S_dbg_isp_frame_seen_once;
    reg         S_dbg_isp_frame_repeat_seen;
    reg [1:0]   S_dbg_frame_repeat_sync;
    reg [1:0]   S_dbg_width_1920_sync;
    reg [1:0]   S_dbg_height_1080_sync;
    reg [1:0]   S_dbg_isp_frame_repeat_sync;
    wire[3:0]   S_hdmi_debug_status;
    wire        S_lane_error_any;


    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
	assign S_rst_n = S_pll_lock;
    assign S_video_path_rst_n = S_rst_n & S_mode_path_run;
    assign S_video_path_100m_rst_n = S_video_path_100m_rst_sync[1];
    assign S_display_mode_reset_n = S_mode_display_run;
    assign S_hdmi_pll_lock = S_mode_1080 ? S_hdmi_1080_pll_lock : S_pll_lock;
    assign S_hdmi_reset_async_n = S_pll_lock & S_hdmi_pll_lock &
                                  S_display_mode_reset_n;

    // The mode FSM is in the 24 MHz domain, while the MIPI LP detector runs
    // at 100 MHz.  Synchronize both stop and start requests through two clean
    // 100 MHz edges so hot switching cannot violate reset recovery time.
    always @(posedge S_100m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_video_path_100m_rst_sync <= 2'b00;
        else
            S_video_path_100m_rst_sync <= {S_video_path_100m_rst_sync[0], S_mode_path_run};
    end

    localparam [2:0] MODE_BOOT   = 3'd0;
    localparam [2:0] MODE_CONFIG = 3'd1;
    localparam [2:0] MODE_FILL   = 3'd2;
    localparam [2:0] MODE_RUN    = 3'd3;
    localparam [2:0] MODE_QUIET  = 3'd4;

    // SW4 is a maintained mechanical switch: low selects the official
    // 720p60 chain and high selects 1080p30 capture / 1080p60 HDMI output.
    // Accept a new level only after roughly 5.5 ms of stability.
    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_sw4_sync       <= 2'b00;
            S_sw4_candidate  <= 1'b0;
            S_sw4_stable_cnt <= 17'd0;
            S_mode_request   <= 1'b0;
        end else begin
            S_sw4_sync <= {S_sw4_sync[0], I_mode_sw4};
            if(S_sw4_sync[1] != S_sw4_candidate) begin
                S_sw4_candidate  <= S_sw4_sync[1];
                S_sw4_stable_cnt <= 17'd0;
            end else if(!(&S_sw4_stable_cnt)) begin
                S_sw4_stable_cnt <= S_sw4_stable_cnt + 1'b1;
            end else begin
                S_mode_request <= S_sw4_candidate;
            end
        end
    end

    // Controlled hot-switch sequence.  HDMI is muted first, then the shared
    // camera/ISP path is reset and reconfigured.  After configuration, DDR is
    // allowed to collect fresh frames for 125 ms before HDMI is restarted.
    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_mode_1080       <= 1'b0;
            S_mode_path_run   <= 1'b0;
            S_mode_display_run<= 1'b0;
            S_mode_state      <= MODE_BOOT;
            S_mode_wait_cnt   <= 22'd0;
        end else begin
            case(S_mode_state)
                MODE_BOOT: begin
                    S_mode_path_run    <= 1'b0;
                    S_mode_display_run <= 1'b0;
                    if(S_mode_wait_cnt == 22'd262143) begin
                        S_mode_1080     <= S_mode_request;
                        S_mode_path_run <= 1'b1;
                        S_mode_wait_cnt <= 22'd0;
                        S_mode_state    <= MODE_CONFIG;
                    end else begin
                        S_mode_wait_cnt <= S_mode_wait_cnt + 1'b1;
                    end
                end
                MODE_CONFIG: begin
                    if(S_cam_cfg_done) begin
                        S_mode_wait_cnt <= 22'd0;
                        S_mode_state    <= MODE_FILL;
                    end
                end
                MODE_FILL: begin
                    if(S_mode_wait_cnt == 22'd2999999) begin
                        S_mode_display_run <= 1'b1;
                        S_mode_wait_cnt    <= 22'd0;
                        S_mode_state       <= MODE_RUN;
                    end else begin
                        S_mode_wait_cnt <= S_mode_wait_cnt + 1'b1;
                    end
                end
                MODE_RUN: begin
                    if(S_mode_request != S_mode_1080) begin
                        S_mode_display_run <= 1'b0;
                        S_mode_path_run    <= 1'b0;
                        S_mode_wait_cnt    <= 22'd0;
                        S_mode_state       <= MODE_QUIET;
                    end
                end
                default: begin // MODE_QUIET
                    if(S_mode_wait_cnt == 22'd65535) begin
                        S_mode_wait_cnt <= 22'd0;
                        S_mode_state    <= MODE_BOOT;
                    end else begin
                        S_mode_wait_cnt <= S_mode_wait_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    // Async assert, synchronous release in the selected display pixel domain.
    // This prevents the VTC/DDR reader/HDMI core from starting before the new
    // display clock is stable and is also the reset sequence needed by the
    // later 720p60/1080p60 hot-switch controller.
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_reset_async_n) begin
        if(!S_hdmi_reset_async_n)
            S_hdmi_reset_sync <= 4'b0000;
        else
            S_hdmi_reset_sync <= {S_hdmi_reset_sync[2:0], 1'b1};
    end

    assign S_hdmi_rst_n = S_hdmi_reset_sync[3];

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    // Count CSI payload words between HS packet boundaries.  This avoids
    // probing an internal net of csi_unpacket_2lane (which ChipWatcher cannot
    // legally connect to) and verifies the received line length externally.
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_dbg_hs_valid_d          <= 1'b0;
            S_dbg_csi_words           <= 11'd0;
            S_dbg_good_lines          <= 11'd0;
            S_dbg_frame_seen_once     <= 1'b0;
            S_dbg_frame_repeat_seen   <= 1'b0;
            S_dbg_width_1920_seen     <= 1'b0;
            S_dbg_height_1080_seen    <= 1'b0;
            S_dbg_isp_frame_seen_once <= 1'b0;
            S_dbg_isp_frame_repeat_seen <= 1'b0;
        end
        else begin
            S_dbg_hs_valid_d <= S_hs_rx_valid;

            if(!S_dbg_hs_valid_d && S_hs_rx_valid)
                S_dbg_csi_words <= 11'd0;
            else if(S_csi_valid)
                S_dbg_csi_words <= S_dbg_csi_words + 11'd1;

            // A packet with CSI payload is an image line.  Ignore short
            // frame-start/frame-end packets, whose payload count is zero.
            if(S_dbg_hs_valid_d && !S_hs_rx_valid && (S_dbg_csi_words != 0)) begin
                if(S_dbg_csi_words == 11'd600) begin
                    S_dbg_width_1920_seen <= 1'b1;
                    S_dbg_good_lines <= S_dbg_good_lines + 11'd1;
                end
            end

            if(S_csi_frame_start) begin
                if(S_dbg_frame_seen_once) begin
                    S_dbg_frame_repeat_seen <= 1'b1;
                    if(S_dbg_good_lines == 11'd1080)
                        S_dbg_height_1080_seen <= 1'b1;
                end
                else
                    S_dbg_frame_seen_once <= 1'b1;
                S_dbg_good_lines <= 11'd0;
            end

            if(S_ISP_O_tuser) begin
                if(S_dbg_isp_frame_seen_once)
                    S_dbg_isp_frame_repeat_seen <= 1'b1;
                else
                    S_dbg_isp_frame_seen_once <= 1'b1;
            end
        end
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
            S_dbg_frame_repeat_sync <= 2'b00;
            S_dbg_width_1920_sync <= 2'b00;
            S_dbg_height_1080_sync <= 2'b00;
            S_dbg_isp_frame_repeat_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            S_dbg_frame_repeat_sync <= {S_dbg_frame_repeat_sync[0], S_dbg_frame_repeat_seen};
            S_dbg_width_1920_sync <= {S_dbg_width_1920_sync[0], S_dbg_width_1920_seen};
            S_dbg_height_1080_sync <= {S_dbg_height_1080_sync[0], S_dbg_height_1080_seen};
            S_dbg_isp_frame_repeat_sync <= {S_dbg_isp_frame_repeat_sync[0], S_dbg_isp_frame_repeat_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    // Keep the factory diagnostic status bus available internally, while the
    // mature display path below permanently selects normal camera video.
    assign S_hdmi_debug_status = {
        S_dbg_width_1920_sync[1],
        S_dbg_frame_repeat_sync[1],
        S_dbg_hs_seen_sync[1],
        S_dbg_cam_cfg_seen_sync[1]
    };
	
	assign O_cam_rst 	= S_video_path_rst_n;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_720_pixel_clk ),
        .clk5_out    ( S_hdmi_720_serial_clk),

        .lock        ( S_pll_lock        )

    );

    // Static 1080p60 clock source for this build.  Its interface is the swap
    // point for the future dual-mode display clock manager.
    hdmi_pll_1080p60 u_hdmi_pll_1080p60 (
        .refclk     ( I_sys_clk          ),
        .reset      ( ~I_rst_n           ),
        .pixel_clk  ( S_hdmi_1080_pixel_clk  ),
        .serial_clk ( S_hdmi_1080_serial_clk ),
        .lock       ( S_hdmi_1080_pll_lock   )
    );

    glitchless_clock_mux u_pixel_clock_mux (
        .I_rst_n (S_rst_n),
        .I_sel   (S_mode_1080),
        .I_clk0  (S_hdmi_720_pixel_clk),
        .I_clk1  (S_hdmi_1080_pixel_clk),
        .O_clk   (S_hdmi_pixel_clk)
    );

    glitchless_clock_mux u_serial_clock_mux (
        .I_rst_n (S_rst_n),
        .I_sel   (S_mode_1080),
        .I_clk0  (S_hdmi_720_serial_clk),
        .I_clk1  (S_hdmi_1080_serial_clk),
        .O_clk   (S_hdmi_serial_clk)
    );

	

  
  ae_set u_ae_set (
      .I_clk(S_24m_clk),
      .I_rst(~S_video_path_rst_n),
      // KEY3/KEY4 are dedicated to algorithm control.  Do not allow the
      // same press to alter camera exposure or analogue gain.
      .I_btn(4'b1111),
      .I_mode_1080(S_mode_1080),
      .I_frame_luma_sum(S_ISP_frame_luma_sum),
      .I_frame_sample_count(S_ISP_frame_sample_count),
      .I_frame_stats_toggle(S_ISP_frame_stats_toggle),
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      .O_ae_req(S_ae_req),
      .O_ae(S_ae),
      .O_ag(S_ag)
  );
  
    uicfgcs500_1080p30 #(
      .CLK_DIV(24000000 / 100000 - 1)
  ) u_uicfgcs500 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_video_path_rst_n),  // mode-controlled reset
      .I_mode_1080(S_mode_1080),
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done)  //AE配置完成
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "0dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_video_path_100m_rst_n ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_video_path_rst_n ),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_video_path_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(VIDEO_H_ACTIVE),
.IMG_HEIGHT(VIDEO_V_ACTIVE),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_video_path_rst_n),
.I_img_width (S_active_width),
.I_img_height(S_active_height),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// SC500CS FHD mode directly outputs native 1920x1080 RAW10.
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tuser  = S_axis_tuser;


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


//ISP算法顶层模块
isp_top #(
    .IMG_WIDTH  (VIDEO_H_ACTIVE),
    .IMG_HEIGHT (VIDEO_V_ACTIVE)
) u_isp_top (
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_video_path_rst_n),
.I_img_width     (S_active_width),
.I_img_height    (S_active_height),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (10'd0),
.O_tready        (1'b1),
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.O_frame_luma_sum    (S_ISP_frame_luma_sum),
.O_frame_sample_count(S_ISP_frame_sample_count),
.O_frame_stats_toggle(S_ISP_frame_stats_toggle),
.I_tready        ()
  );



    wire [155:0] uart_mem_sys,uart_mem_ddr;
    wire uart_mem_valid,uart_mem_ready,uart_cmd_valid,uart_cmd_ready,uart_cmd_error;
    wire [383:0] uart_cmd_reply;
    wire uart_source_requested;wire uart_source_sys;wire [1:0] uart_compare_sys;
    wire uart_mode_set;wire [4:0] uart_requested_mode;
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
    wire [155:0] eth_mem_sys,shared_mem_sys;
    wire eth_mem_valid,eth_mem_ready,eth_mem_error,shared_mem_valid,shared_mem_ready;
    wire uart_transport_error;
    wire [383:0] eth_mem_reply,uart_transport_reply;
    wire eth_source_set,eth_source_value,eth_compare_set,eth_mode_set;
    wire [1:0] eth_compare_value;
    wire [4:0] eth_requested_mode;
    wire [26:0] cascade_cmd_sys,cascade_cmd_ddr;
    wire cascade_valid_sys,cascade_ready_sys,cascade_valid_ddr,cascade_ready_ddr;
    wire [127:0] cascade_reply_ddr;
    wire cascade_lock,cascade_read,cascade_response,cascade_lease_valid,video_reader_drained,cascade_camera_safe,camera_reader_ref_valid;
    wire [1:0] cascade_lease_bank;wire [24:0] cascade_addr;
    uart_mailbox #(.WIDTH(27)) u_cascade_read_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data(cascade_cmd_sys),.s_valid(cascade_valid_sys),.s_ready(cascade_ready_sys),
     .d_clk(S_ddr_clk),.d_rst_n(S_rst_n),.d_data(cascade_cmd_ddr),.d_valid(cascade_valid_ddr),.d_ready(cascade_ready_ddr));
    cascade_camera_reader u_cascade_camera_reader(
     .clk(S_ddr_clk),.rst_n(S_rst_n),.path_run(path_ddr_sync[1]),.mode1080(mode_ddr_sync[1]),
     .camera_bank(S_video_out_rp),.camera_safe(cascade_camera_safe),.camera_busy(S_video_in_wr_busy),.camera_write(S_vi_ddr_wr_en),
     .video_busy(S_video_out_rd_busy),.video_read(S_vo_ddr_rd_en),.video_drained(video_reader_drained),
     .upload_lock(uart_lock_bus || (uart_hold_frame && uart_frame_window)),.user_ready(S_ddr_user_ready),.queue_empty(ddr_queue_empty),
     .rd_valid(S_ddr_user_rd_valid),.rd_data(S_ddr_user_rd_data),.cmd(cascade_cmd_ddr),.cmd_valid(cascade_valid_ddr),
     .cmd_ready(cascade_ready_ddr),.reply(cascade_reply_ddr),.lease_valid(cascade_lease_valid),.lease_bank(cascade_lease_bank),
     .lock_bus(cascade_lock),.rd_en(cascade_read),.response_owned(cascade_response),.rd_addr(cascade_addr));
    wire cascade_view_sys;
    wire [127:0] rv_coordinate_sys;wire [255:0] rv_objects_sys;wire [3:0] rv_count_sys;wire rv_valid_sys,rv_overflow_sys;
    wire [31:0] rv_source_sys,rv_epoch_sys;
    wire [191:0] rv_reply;wire rv_request;wire [31:0] rv_request_epoch,rv_request_sequence;wire [4:0] rv_request_mode;
    wire rv_enable_sys=(S_algorithm_shadow_mode_sys==17 || S_algorithm_shadow_mode_sys==18) && !cascade_view_sys;
    assign uart_source_sys=rv_enable_sys?1'b0:uart_source_requested;
    wire [390:0] rv_pixel;
    wire rv_pixel_received,rv_pixel_capture,rv_pixel_prepare;
    reg rv_pixel_initialized;
    always @(posedge S_hdmi_pixel_clk or negedge S_rst_n)
      if(!S_rst_n)rv_pixel_initialized<=1'b0;
      else if(rv_pixel_received)rv_pixel_initialized<=1'b1;
    wire road_we,road_available,road_tag,road_taken,road_taken_available,road_taken_tag;
    wire [12:0] road_wa,road_ra;wire [1:0] road_wd,road_q;wire [15:0] road_metadata;
    wire [3:0] rv_display_count=S_algorithm_shadow_mode_sys==18?4'he:rv_count_sys;
    wire [255:0] rv_display_objects={rv_objects_sys[255:16],
       S_algorithm_shadow_mode_sys==18?road_metadata:rv_objects_sys[15:0]};
    road_route_writer u_road_writer(.clk(S_100m_clk),.rst_n(S_rst_n),
       .enable(rv_enable_sys && S_algorithm_shadow_mode_sys==18),.valid(rv_valid_sys),
       .route(rv_objects_sys),.source_id(rv_source_sys),
       .taken_pulse(road_taken),.taken_available(road_taken_available),.taken_tag(road_taken_tag),
       .metadata(road_metadata),.available(road_available),.tag(road_tag),
       .we(road_we),.wa(road_wa),.wd(road_wd));
    road_route_memory #(.W(2),.A(13)) u_road_mask(
       .wclk(S_100m_clk),.rclk(S_hdmi_pixel_clk),.we(road_we),.wa(road_wa),.ra(road_ra),.wd(road_wd),.q(road_q));
    road_frame_mailbox #(.WIDTH(391)) u_remote_result_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data({uart_mode_sys_sync[1],rv_coordinate_sys,rv_enable_sys,rv_valid_sys,rv_display_count,rv_display_objects}),
     .d_clk(S_hdmi_pixel_clk),.d_rst_n(S_rst_n),.d_data(rv_pixel),.d_valid(rv_pixel_received),.frame_prepare(rv_pixel_prepare),.frame_capture(rv_pixel_capture),
     .route_available(road_available),.route_tag(road_tag),
     .taken_pulse(road_taken),.taken_available(road_taken_available),.taken_tag(road_taken_tag));
    assign rv_reply=0;
    ethernet_image_bridge #(.NATIVE_COORDINATES(1),.VISION_ROLE(1),.MAX_MODE(18),.CASCADE_SUPPORT(CASCADE_SUPPORT),.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),
     .PEER_MAC(PEER_MAC),.PEER_IP(PEER_IP)) u_ethernet_image_bridge(
     .ref_clk(I_sys_clk),.sys_clk(S_100m_clk),.rst_n(S_rst_n),.mode1080(uart_mode_sys_sync[1]),
     .rgmii_rxd(I_a_rgmii_rxd),.rgmii_rx_ctl(I_a_rgmii_rx_ctl),.rgmii_rxc(I_a_rgmii_rxc),
     .rgmii_txd(O_a_rgmii_txd),.rgmii_tx_ctl(O_a_rgmii_tx_ctl),.rgmii_txc(O_a_rgmii_txc),.phy_rst_n(O_phy_rst),
     .source_image(uart_source_sys),.compare_mode(uart_compare_sys),.current_mode(S_algorithm_shadow_mode_sys),
     .front_valid(uart_status_sys[32]),.displayed_id(uart_status_sys[31:0]),
     .source_set(eth_source_set),.source_value(eth_source_value),.compare_set(eth_compare_set),.compare_value(eth_compare_value),
     .mode_set(eth_mode_set),.requested_mode(eth_requested_mode),
     .mem_data(eth_mem_sys),.mem_valid(eth_mem_valid),.mem_ready(eth_mem_ready),.mem_error(eth_mem_error),.mem_reply(eth_mem_reply),
     .cascade_run(S_video_path_100m_rst_n),.cascade_read_command(cascade_cmd_sys),.cascade_read_valid(cascade_valid_sys),
     .cascade_read_ready(cascade_ready_sys),.cascade_read_reply(cascade_reply_ddr),
     .vision_mode(rv_enable_sys?S_algorithm_shadow_mode_sys:5'd0),
     .vision_coordinate_bcd(rv_coordinate_sys),.vision_objects(rv_objects_sys),.vision_count(rv_count_sys),.vision_valid(rv_valid_sys),.vision_overflow(rv_overflow_sys),
     .vision_source_id(rv_source_sys),.vision_config_epoch(rv_epoch_sys),.vision_reply(rv_reply),
     .vision_request(rv_request),.vision_request_epoch(rv_request_epoch),.vision_request_sequence(rv_request_sequence),.vision_request_mode(rv_request_mode));
    image_memory_arbiter u_image_memory_arbiter(
     .clk(S_100m_clk),.rst_n(S_rst_n),
     .uart_data(uart_mem_sys),.uart_valid(uart_mem_valid),.uart_ready(uart_mem_ready),
     .uart_error(uart_transport_error),.uart_reply(uart_transport_reply),
     .eth_data(eth_mem_sys),.eth_valid(eth_mem_valid),.eth_ready(eth_mem_ready),.eth_error(eth_mem_error),.eth_reply(eth_mem_reply),
     .mem_data(shared_mem_sys),.mem_valid(shared_mem_valid),.mem_ready(shared_mem_ready),
     .mem_error(uart_error_sync[1]),.mem_reply(uart_cmd_reply),.upload_owner());
    cascade_view_switch u_cascade_view_switch(.clk(S_100m_clk),.rst_n(S_rst_n),
     .sw2(I_cascade_sw2),.view_image(cascade_view_sys));
    uart_image_control #(.MAX_MODE(18),.EXTERNAL_CONTROLS(1),.CASCADE_VIEW_SUPPORT(CASCADE_SUPPORT)) u_uart_image_control(
     .clk(S_100m_clk),.rst_n(S_rst_n),.uart_rx(I_uart_rx),.uart_tx(O_uart_tx),
     .mode1080(uart_mode_sys_sync[1]),.path_run(S_video_path_100m_rst_n),.key1_n(I_button[3]),
     .cascade_view(cascade_view_sys),
     .front_valid(uart_status_sys[32]),.displayed_id(uart_status_sys[31:0]),
     .source_uart(uart_source_requested),.compare_mode(uart_compare_sys),
     .mode_set(uart_mode_set),.requested_mode(uart_requested_mode),.current_mode(S_algorithm_shadow_mode_sys),
     .mem_data(uart_mem_sys),.mem_valid(uart_mem_valid),.mem_ready(uart_mem_ready),
     .mem_error(uart_transport_error),.mem_reply(uart_transport_reply),.image_id_status(),
     .external_source_set(eth_source_set),.external_source_value(eth_source_value),
     .external_compare_set(eth_compare_set),.external_compare_value(eth_compare_value));
    uart_mailbox #(.WIDTH(156)) u_uart_memory_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data(shared_mem_sys),.s_valid(shared_mem_valid),.s_ready(shared_mem_ready),
     .d_clk(S_ddr_clk),.d_rst_n(S_rst_n),.d_data(uart_mem_ddr),.d_valid(uart_cmd_valid),.d_ready(uart_cmd_ready));
    uart_mailbox #(.WIDTH(33)) u_uart_status_cdc(
     .s_clk(S_ddr_clk),.s_rst_n(S_rst_n),.s_data({uart_front_valid,uart_displayed_id}),.s_valid(1'b1),.s_ready(),
     .d_clk(S_100m_clk),.d_rst_n(S_rst_n),.d_data(uart_status_sys),.d_valid(uart_status_valid),.d_ready(1'b1));
    uart_mailbox #(.WIDTH(3)) u_uart_controls_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data({uart_source_sys,uart_compare_sys}),.s_valid(1'b1),.s_ready(),
     .d_clk(S_ddr_clk),.d_rst_n(S_rst_n),.d_data(uart_controls_ddr),.d_valid(uart_controls_valid),.d_ready(1'b1));
    uart_mailbox #(.WIDTH(2)) u_uart_compare_cdc(
     .s_clk(S_100m_clk),.s_rst_n(S_rst_n),.s_data(uart_compare_sys),.s_valid(1'b1),.s_ready(),
     .d_clk(S_hdmi_pixel_clk),.d_rst_n(S_rst_n),.d_data(uart_compare_pixel),.d_valid(uart_compare_valid),.d_ready(1'b1));
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

    wire [31:0] capture_latest_gray;
    wire frame_underflow,latency_frame_end;wire [1:0] latency_stream_bank;
    wire [23:0] latency_time_gray,capture_time_ddr,capture_time_pixel;
    wire [56:0] mipi_isp_descriptor;
    latency_timebase u_latency_timebase(I_sys_clk,S_rst_n,latency_time_gray);
    mipi_frame_timing u_mipi_frame_timing(S_csi_rx_clk,S_rst_n,S_video_path_rst_n,
      latency_time_gray,S_csi_frame_start,S_raw_tuser,S_ISP_O_tuser,capture_latest_gray,mipi_isp_descriptor);
    wire [25:0] frame_latency_token;
    mipi_latency_measure u_mipi_latency_measure(S_hdmi_pixel_clk,S_hdmi_rst_n,capture_latest_gray,latency_time_gray,capture_time_pixel,
      uart_present_frame,latency_frame_end,S_algo_out_de,S_hdmi_vsync,frame_underflow,
      !uart_frame_meta_pixel[11]&&!uart_frame_meta_pixel[85],capture_identity_pixel,
      latency_stream_bank,S_display_bank_pixel,frame_latency_token);
    wire [163:0] capture_bank_metadata_ddr;
    wire [95:0] capture_bank_time_ddr;
    wire [40:0] capture_identity_ddr;
    // Retain the phase-1 observation endpoint until a later authorized consumer
    // is added. No video data, external protocol or display field is changed.
    wire [40:0] capture_identity_pixel;
    video_in #(.CASCADE_SUPPORT(CASCADE_SUPPORT),.CAPTURE_TRACKING(1),.MIPI_TIMING(1)) u_video_in(
        .I_system_rst_n(S_rst_n),.O_capture_bank_metadata(capture_bank_metadata_ddr),.O_capture_latest_gray(),
        .I_mipi_descriptor(mipi_isp_descriptor),.O_capture_bank_time_gray(capture_bank_time_ddr),
        .I_rst_n              ( S_video_path_rst_n    ),
        .I_mode_1080          ( mode_ddr_sync[1]      ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        // Match the boundary to this RGB frame: RAW SOF can arrive while
        // the preceding ISP/DDR tail is still draining. The active AWB's
        // 50-clock data delay gives this ISP token FIFO-reset lead time.
        .I_camera_frame_start ( S_ISP_O_tuser ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_cascade_lease_valid(cascade_lease_valid),.I_cascade_lease_bank(cascade_lease_bank),
        .O_cascade_bank_safe(cascade_camera_safe),
        .I_cascade_display_ref_valid(camera_reader_ref_valid),.I_cascade_display_ref_bank(S_active_read_bank_ddr),
        .I_video_out_rd_busy  ( S_video_out_rd_busy | uart_lock_bus | cascade_lock | (uart_hold_frame && uart_frame_window) ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready && !uart_lock_bus && !cascade_lock )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en | uart_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en | uart_rd_en | cascade_read;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : cascade_read ? cascade_addr : uart_addr;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_en ? S_vi_ddr_wr_data : uart_wr_data;


    assign S_video_out_rst_n = S_hdmi_rst_n;

    video_out #(.META_HANDSHAKE(1),.PREVIEW_SUPPORT(CASCADE_SUPPORT),.CAPTURE_TRACKING(1),.MIPI_TIMING(1)) u_video_out(
        .I_capture_bank_metadata(capture_bank_metadata_ddr),.O_capture_identity(capture_identity_ddr),
        .I_capture_bank_time_gray(capture_bank_time_ddr),.O_capture_time_gray(capture_time_ddr),.O_frame_underflow(frame_underflow),
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
    uart_frame_bridge #(.CAPTURE_TRACKING(1),.MIPI_TIMING(1)) u_uart_frame_bridge(
      .capture_identity(capture_identity_ddr),.pixel_capture_identity(capture_identity_pixel),
      .capture_time_gray(capture_time_ddr),.pixel_capture_time_gray(capture_time_pixel),
      .ddr_clk(S_ddr_clk),.sys_rst_n(S_rst_n),.pixel_clk(S_hdmi_pixel_clk),.pixel_rst_n(S_hdmi_rst_n),
      .metadata({uart_reader_preview,uart_reader_resolution,uart_reader_generation,uart_reader_id,uart_context_epoch,
                 uart_active_source,S_frame_info_toggle_ddr,S_display_frame_seq_ddr,S_active_read_bank_ddr}),
      .reader_running(uart_reader_running),.metadata_ready(uart_metadata_ready),
      // Bridge expects active-high VS blanking. S_video_out_vsync is inverted
      // for the DDR reader's edge trigger and is HIGH throughout active video.
      .pixel_vsync(S_hdmi_vsync),.pixel_read_de(S_hdmi_window_rd_en),
      .present_frame(uart_present_frame && S_algo_out_de),
      .active_mode(uart_active_mode_pixel),.active_view(uart_active_view_pixel),
      .pixel_metadata(uart_frame_meta_pixel),.frame_enable(uart_frame_enable),.display_status(uart_display_status));
    assign uart_displayed_id=uart_display_status[48]?uart_display_status[127:96]:32'd0;
    assign {S_frame_info_toggle_pixel,S_display_frame_seq_pixel,S_display_bank_pixel}=uart_frame_meta_pixel[10:0];

    // Board KEY3 cycles Mode 0->1->...->16->0. Board KEY4 is the algorithm
    // RESET key and returns the shadow mode to 0. Both inputs are active-low.
    algorithm_mode_control #(.MAX_MODE(18),.DEBOUNCE_BITS(21)) u_algorithm_mode_control (
        .I_clk                   ( S_100m_clk                    ),
        .I_rst_n                 ( S_rst_n                       ),
        .I_key3_n                ( I_button[0]               ),
        .I_key4_n                ( I_button[1]               ),
        .I_remote_set(uart_mode_set | eth_mode_set),.I_remote_mode(eth_mode_set ? eth_requested_mode : uart_requested_mode),
        .O_shadow_mode           ( S_algorithm_shadow_mode_sys   ),
        .O_algorithm_reset_toggle( S_algorithm_reset_toggle_sys  )
    );

    // KEY2=A9; only frame-boundary commit may activate the received size.
    wire S_motion_overlay_pixel;
    wire [7:0] S_mosaic_strength_pixel;
    wire S_mosaic_strength_valid;
    key2_mosaic_size_control #(.MOTION_OVERLAY(1),.DEBOUNCE_BITS(21)) u_key2_mosaic_size_control (
        .I_clk(S_100m_clk), .I_rst_n(S_rst_n),
        .I_key2_n(I_button[2]),
        .I_mode_sys(S_algorithm_shadow_mode_sys), .O_motion_overlay_pixel(S_motion_overlay_pixel),
        .I_reset_toggle(S_algorithm_reset_toggle_sys),
        .I_pixel_clk(S_hdmi_pixel_clk), .I_pixel_rst_n(S_hdmi_rst_n),
        .O_size_shadow(), .O_strength_pixel(S_mosaic_strength_pixel),
        .O_valid_pixel(S_mosaic_strength_valid)
    );

    algorithm_control_cdc u_algorithm_control_cdc (
        .I_pixel_clk       ( S_hdmi_pixel_clk                ),
        .I_pixel_rst_n     ( S_hdmi_rst_n                    ),
        .I_mode_sys        ( S_algorithm_shadow_mode_sys     ),
        .I_reset_toggle_sys( S_algorithm_reset_toggle_sys    ),
        .O_mode_pixel      ( S_algorithm_shadow_mode         ),
        .O_mode_valid      ( S_algorithm_shadow_valid        ),
        .O_reset_event     ( S_algorithm_reset_event         )
    );



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
        .I_debug_status  ( S_hdmi_debug_status),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    // Image algorithms run in this post-DDR pixel-clock transaction wrapper.
    // Step 1 provides four equal-latency modes; OSD remains downstream.
    video_algorithm_wrapper #(.REMOTE_FRAME_LOCKED(1),.REMOTE_LOW_RESET(1),.MOTION_OVERLAY(1),.LATENCY_OSD(1),.TIME_OSD(1),.UART_SUPPORT(1),.REMOTE_VISION(1),.ROAD_PLANNING(1),.REMOTE_NATIVE_COORDINATES(1)) u_video_algorithm_wrapper (
        .I_road_mask_q(road_q),.O_road_mask_ra(road_ra),
        .I_shadow_motion_overlay(S_motion_overlay_pixel),.O_remote_capture(rv_pixel_capture),.O_remote_prepare(rv_pixel_prepare),
        .I_latency_token(frame_latency_token),
        .I_latency_local_source(!uart_frame_meta_pixel[11]&&!uart_frame_meta_pixel[85]),
        .I_clk           ( S_hdmi_pixel_clk          ),
        .I_rst_n         ( S_hdmi_rst_n              ),
        .I_mode_1080     ( S_mode_1080               ),
        .I_active_width  ( S_active_width             ),
        .I_active_height ( S_active_height            ),
        .I_rgb           ( S_hdmi_out_data           ),
        .I_de            ( S_hdmi_out_de && uart_frame_enable ),
        .I_hs            ( S_hdmi_out_hsync          ),
        .I_vs            ( S_hdmi_out_vsync          ),
        .I_display_bank  ( S_display_bank_pixel      ),
        .I_display_frame_seq ( S_display_frame_seq_pixel ),
        .I_frame_info_toggle ( S_frame_info_toggle_pixel ),
        .I_source_epoch(uart_frame_meta_pixel[19:12]),.I_compare_mode(uart_compare_pixel),
        .I_remote_coordinate_bcd(rv_pixel[389:262]),.I_remote_objects(rv_pixel[255:0]),.I_remote_count(rv_pixel[259:256]),.I_remote_valid((rv_pixel_initialized || rv_pixel_received) && rv_pixel[390]==S_mode_1080 && rv_pixel[260]),.I_remote_enable((rv_pixel_initialized || rv_pixel_received) && rv_pixel[261]),
        .I_shadow_mode      ( S_algorithm_shadow_mode ),
        .I_shadow_valid     ( S_algorithm_shadow_valid && S_mosaic_strength_valid ),
        .I_algorithm_reset_event ( S_algorithm_reset_event ),
        .I_shadow_threshold ( 8'd128                  ),
        .I_shadow_strength  ( (S_algorithm_shadow_mode == 5'd15) ? S_mosaic_strength_pixel : 8'd0 ),
        .O_rgb           ( S_algo_out_data           ),
        .O_de            ( S_algo_out_de             ),
        .O_hs            ( S_algo_out_hsync          ),
        .O_vs            ( S_algo_out_vsync          ),
        .O_stream_frame_start(uart_present_frame),
        .O_stream_frame_end(latency_frame_end),.O_stream_display_bank(latency_stream_bank),
        .O_active_mode(uart_active_mode_pixel),.O_active_view(uart_active_view_pixel)
    );

    hdmi_tx #(
        .HTOTAL    (VIDEO_H_TOTAL ),
        .HSA       (VIDEO_H_SYNC  ),
        .HFP       (VIDEO_H_FP    ),
        .HBP       (VIDEO_H_BP    ),
        .HACTIVE   (VIDEO_H_ACTIVE),
        .VTOTAL    (VIDEO_V_TOTAL ),
        .VSA       (VIDEO_V_SYNC  ),
        .VFP       (VIDEO_V_FP    ),
        .VBP       (VIDEO_V_BP    ),
        .VACTIVE   (VIDEO_V_ACTIVE),
        .VIDEO_VIC (VIDEO_VIC     ),
        .VIDEO_TPG (HDMI_CORE_TPG)
    ) u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_mode_1080        ( S_mode_1080       ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_algo_out_vsync  ),
        .I_video_in_de      ( S_algo_out_de     ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_algo_out_data   ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    
endmodule

// PH1P dedicated glitchless global-clock selector (UG1310 section 37).
// Select changes only while HDMI and the DDR reader are held in reset.
// Avoid fabric AND/OR clock gates and non-clock sinks on the PLL clock nets.
module glitchless_clock_mux (
    input  wire I_rst_n,
    input  wire I_sel,
    input  wire I_clk0,
    input  wire I_clk1,
    output wire O_clk
);
    wire selected = I_rst_n && I_sel;
    PH1P_PHY_GCLK #(.PRESELECT("CLK0"),.HOLD("YES"),.SEL_TRIGGER("NEG"),.GSR("DISABLE")) u_clock_select(
        .clkin({I_clk1,I_clk0}),.seln({~selected,selected}),
        .cen(2'b00),.drct(2'b00),.clkout(O_clk));
endmodule
