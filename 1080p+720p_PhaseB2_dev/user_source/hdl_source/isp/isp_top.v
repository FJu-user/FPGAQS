module isp_top #(
    parameter integer IMG_WIDTH  = 1920,
    parameter integer IMG_HEIGHT = 1080
) (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input [11:0]    I_img_width     ,
    input [11:0]    I_img_height    ,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			O_tready		,
    output [127:0] 	O_tdata			,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output [23:0]   O_frame_luma_sum,
    output [15:0]   O_frame_sample_count,
    output          O_frame_stats_toggle,
    output 			I_tready
);
 
wire         m_aixs_tvalid;  //synthesis keep 
  wire [127:0] m_aixs_tdata;  //synthesis keep 
  wire         m_aixs_tuser;  //synthesis keep 
  wire         m_aixs_tlast;  //synthesis keep 
  wire         m_aixs_tready;  //synthesis keep 
  
  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 


  wire         awb_O_tlast;  //synthesis keep 
  wire         awb_O_tuser;  //synthesis keep 
  wire [ 95:0] awb_O_tdata;  //synthesis keep 
  wire         awb_O_tvalid;  //synthesis keep 
  wire         awb_O_tready;  //synthesis keep 

  wire         awb_O_tuser_128;  //synthesis keep 
  wire         awb_O_tvalid_128;  //synthesis keep 
  wire [127:0] awb_O_tdata_128;  //synthesis keep 

  assign awb_O_tready = O_tready;
  assign O_tdata  = awb_O_tdata_128;
  assign O_tlast  = awb_O_tlast    ;
  assign O_tuser  = awb_O_tuser_128    ;
  assign O_tvalid = awb_O_tvalid_128   ;
  
  //assign m_aixs_tready = O_tready;
  //assign O_tdata  = m_aixs_tdata;
  //assign O_tlast  = m_aixs_tlast    ;
  //assign O_tuser  = m_aixs_tuser    ;
  //assign O_tvalid = m_aixs_tvalid   ;
 
 
demosaic #(
    .IMG_HEIGHT          (IMG_HEIGHT), // 鍥惧儚楂樺害
    .IMG_WIDTH           (IMG_WIDTH ), // 鍥惧儚瀹藉害
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
)
u_demosaic
(
    .I_clk   			(axi4s_video_aclk)	,   // 鏃堕挓淇″彿
    .I_rst_n 			(I_rst_n)	,   // active-low reset
    .I_img_width       (I_img_width ),
    .I_img_height      (I_img_height),
    .axi4s_video_tdata 	(I_tdata)	,  // AXI4-Stream瑙嗛鏁版嵁
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,  // 琛岀粨鏉熶俊鍙?
    .axi4s_video_tvalid	(I_tvalid)	,  // 鏁版嵁鏈夋晥淇″彿
    .axi4s_video_tuser 	(I_tuser)	,  // 甯у紑濮嬩俊鍙?
    .axi4s_video_tready	(I_tready)	,  // 浠庢ā鍧楀噯澶囧ソ鎺ュ彈鏁版嵁
    .O_tlast  			(m_aixs_tlast)	,  // 杈撳嚭琛岀粨鏉熶俊鍙?
    .O_tuser  			(m_aixs_tuser)	,  // 杈撳嚭甯у紑濮嬩俊鍙?
    .O_tdata  			(m_aixs_tdata)	,  // 杈撳嚭鏁版嵁
    .O_tvalid 			(m_aixs_tvalid)	,  // 杈撳嚭鏁版嵁鏈夋晥淇″彿
    .O_tready   		(m_aixs_tready)	   // 杈撳嚭鏁版嵁鍑嗗濂戒俊鍙?
);
 
data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(IMG_HEIGHT),
    .IMG_WIDTH (IMG_WIDTH )
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_img_width (I_img_width),
    .I_img_height(I_img_height),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_frame_luma_sum    (O_frame_luma_sum),
    .O_frame_sample_count(O_frame_sample_count),
    .O_frame_stats_toggle(O_frame_stats_toggle),
    .O_tready(awb_O_tready)
);

    // The demosaic and AWB interfaces already carry RGB888 pixels.
    // Preserve that order before packing; the shared DDR/UDP/HDMI paths
    // all consume the same R,G,B byte stream. No post-ISP channel rotation.
    data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
	
        .I_96b_frame_start  ( awb_O_tuser	    ),
        .I_96b_valid        ( awb_O_tvalid 		),
        .I_96b_data         ( awb_O_tdata		),
	
        .O_128b_frame_start ( awb_O_tuser_128  	),
        .O_128b_valid       ( awb_O_tvalid_128 	),
        .O_128b_data        ( awb_O_tdata_128  	)
    );



//data96_128 u_data96_128 (
//    .I_tdata(awb_O_tdata),
//    .O_tdata(awb_O_tdata_128)
//);
	
endmodule
