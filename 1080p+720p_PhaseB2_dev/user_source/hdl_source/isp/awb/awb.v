/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description: 
The reference demo provided by Milianke is only used for learning. 
We cannot ensure that the demo itself is free of bugs, so users 
should be responsible for the technical problems and consequences
caused by the use of their own products.
@Author      :   XiaoQingquan 
@Time        :   2024/10 
version:     :   
@Description :   鍦ㄥ師鍩虹涓婂垹鍘讳簡涓€浜涜禈浣欑殑浠ｇ爜锛屽苟涓斾紭鍖栦簡鏃跺簭锛屽姞鍏RAM IP鏍革紝
                 璁╀粠闄ゆ硶鍣ㄥ嚭鏉ョ殑姣忎竴涓暟鎹兘鍙互瀵逛笂鐩稿簲鐨勫儚绱犳暟鎹繘琛屽鐩婏紝浣?
                 寰楀畠鐨勯€傜敤琛屾洿鍔犲箍娉涗簡銆?
*****************************************************************/
module awb  #(   
    parameter IMG_HEIGHT = 1080,   // 鍥惧儚楂樺害鍙傛暟锛岄粯璁ゅ€间负1080
    parameter IMG_WIDTH  = 1920    // 鍥惧儚瀹藉害鍙傛暟锛岄粯璁ゅ€间负1920
) 
(
    input                   I_clk  ,    // 杈撳叆鏃堕挓淇″彿
    input                   I_rst_n,    // active-low reset
    input [11:0]            I_img_width,
    input [11:0]            I_img_height,

    input                   I_tlast  ,  // 琛岀粨鏉熶俊鍙?
    input                   I_tuser  ,  // 甯у紑濮嬩俊鍙?
    input [95:0]            I_tdata  ,  // 杈撳叆鏁版嵁锛屾€诲叡鍖呭惈4涓儚绱犵殑RGB鍊硷紝姣忎釜鍍忕礌24浣嶏紝4*24=96浣?
    input                   I_tvalid ,  // 杈撳叆鏁版嵁鏈夋晥淇″彿
    output                  I_tready ,  // 杈撳叆鏁版嵁鍑嗗濂戒俊鍙?

    output                  O_tlast  ,  // 杈撳嚭琛岀粨鏉熶俊鍙?
    output                  O_tuser  ,  // 杈撳嚭甯у紑濮嬩俊鍙?
    output [95:0]           O_tdata  ,  // 杈撳嚭鏁版嵁
    output                  O_tvalid ,  // 杈撳嚭鏁版嵁鏈夋晥淇″彿
    input                   O_tready    // 杈撳嚭鏁版嵁鍑嗗濂戒俊鍙?
);

/*****************************************************************
                          RGB565杞琑GB888锛堟湭浣跨敤閮ㄥ垎锛?                                       
*****************************************************************/

// //RGB565杞琑GB888鐨勪唬鐮侊紙姝ら儴鍒嗕唬鐮佽娉ㄩ噴鎺夛紝鏈娇鐢級
// wire [4:0]  rgb565_r   = I_st_data[11+:5];
// wire [5:0]  rgb565_g   = I_st_data[5+:6];
// wire [4:0]  rgb565_b   = I_st_data[0+:5];

// wire [23:0] rgb888     = {{rgb565_r[4:0],rgb565_r[2:0]},{rgb565_g[5:0],rgb565_g[1:0]},{rgb565_b[4:0],rgb565_b[2:0]}};

// wire [7:0]  rgb888_r   = rgb888[16+:8];
// wire [7:0]  rgb888_g   = rgb888[8+:8] ;
// wire [7:0]  rgb888_b   = rgb888[0+:8] ;

/*****************************************************************
                          涓棿淇″彿                                        
*****************************************************************/

  reg         I_tvalid_r0,I_tvalid_r1;			// 杈撳叆鏈夋晥淇″彿鐨勫瘎瀛?
  reg  [95:0] I_tdata_d0,I_tdata_d1,I_tdata_d2; // 杈撳叆鏁版嵁鐨勫瘎瀛?


  // 绱姞RGB閫氶亾鐨勬暟鍊硷紝鐢ㄤ簬璁＄畻骞冲潎鍊?
  reg  [31:0]         sum_r[0:3];
  reg  [31:0]         sum_g[0:3];
  reg  [31:0]         sum_b[0:3];

  
  wire  [95:0]        data_d0 ;		// 寤舵椂鍚庣殑鏁版嵁
  wire                valid_d0;     // 寤舵椂鍚庣殑鏈夋晥淇″彿
  wire                I_tuser_r0;   // 寤舵椂鍚庣殑甯у紑濮嬩俊鍙?
                                    
  reg                 I_tuser_r1;   // 甯у紑濮嬩俊鍙风殑瀵勫瓨
                                    
  reg   [95:0]        data_d1 ;     // 鍐嶆寤舵椂鍚庣殑鏁版嵁
  reg                 valid_d1;     // 鍐嶆寤舵椂鍚庣殑鏈夋晥淇″彿

  /*****************************************************************
                            骞冲潎鍊艰绠?                                     
*****************************************************************/

	// 瀵硅緭鍏ユ暟鎹拰鏈夋晥淇″彿杩涜瀵勫瓨锛屽舰鎴愭祦姘寸嚎
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        I_tdata_d0  <= 0;
        I_tdata_d1  <= 0;
        I_tdata_d2  <= 0;
        {I_tvalid_r0,I_tvalid_r1} <= 0;
    end else begin
        I_tdata_d0  <= I_tdata   ;
        I_tdata_d1  <= I_tdata_d0;
        I_tdata_d2  <= I_tdata_d1;
        I_tvalid_r0 <= I_tvalid;
        I_tvalid_r1 <= I_tvalid_r0;
    end
  end
  
  // 灏嗚緭鍏ユ暟鎹媶鍒嗕负4涓儚绱犵殑RGB鍒嗛噺
    wire [7:0] rgb888_r_d0[0:3];
    wire [7:0] rgb888_g_d0[0:3];
    wire [7:0] rgb888_b_d0[0:3];

    assign  rgb888_r_d0[0] = I_tdata_d0[16+:8];
    assign  rgb888_g_d0[0] = I_tdata_d0[8+:8];
    assign  rgb888_b_d0[0] = I_tdata_d0[0+:8];
  
    assign  rgb888_r_d0[1] = I_tdata_d0[40+:8];
    assign  rgb888_g_d0[1] = I_tdata_d0[32+:8];
    assign  rgb888_b_d0[1] = I_tdata_d0[24+:8];
  
    assign  rgb888_r_d0[2] = I_tdata_d0[64+:8];
    assign  rgb888_g_d0[2] = I_tdata_d0[56+:8];
    assign  rgb888_b_d0[2] = I_tdata_d0[48+:8];
  
    assign  rgb888_r_d0[3] = I_tdata_d0[88+:8];
    assign  rgb888_g_d0[3] = I_tdata_d0[80+:8];
    assign  rgb888_b_d0[3] = I_tdata_d0[72+:8];

// 瀵规瘡涓€氶亾鐨勫€艰繘琛岀疮鍔狅紝鐢ㄤ簬璁＄畻骞冲潎鍊?
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n || I_tuser) begin
	  // 澶嶄綅鎴栬寮€濮嬩俊鍙锋湁鏁堟椂锛屾竻闆剁疮鍔犲櫒
      sum_r[0] <= 0;
      sum_g[0] <= 0;
      sum_b[0] <= 0;

      sum_r[1] <= 0;
      sum_g[1] <= 0;
      sum_b[1] <= 0;

      sum_r[2] <= 0;
      sum_g[2] <= 0;
      sum_b[2] <= 0;

      sum_r[3] <= 0;
      sum_g[3] <= 0;
      sum_b[3] <= 0;
    end else if (I_tvalid_r0) begin
	  // 褰撹緭鍏ユ湁鏁堟椂锛岀疮鍔燫GB鍒嗛噺鐨勫€?
      sum_r[0] <= sum_r[0] + rgb888_r_d0[0];
      sum_g[0] <= sum_g[0] + rgb888_g_d0[0];
      sum_b[0] <= sum_b[0] + rgb888_b_d0[0];

      sum_r[1] <= sum_r[1] + rgb888_r_d0[1];
      sum_g[1] <= sum_g[1] + rgb888_g_d0[1];
      sum_b[1] <= sum_b[1] + rgb888_b_d0[1];

      sum_r[2] <= sum_r[2] + rgb888_r_d0[2];
      sum_g[2] <= sum_g[2] + rgb888_g_d0[2];
      sum_b[2] <= sum_b[2] + rgb888_b_d0[2];

      sum_r[3] <= sum_r[3] + rgb888_r_d0[3];
      sum_g[3] <= sum_g[3] + rgb888_g_d0[3];
      sum_b[3] <= sum_b[3] + rgb888_b_d0[3];
    end
  end



  /*****************************************************************
                           闄ゆ硶杩愮畻                                        
*****************************************************************/
  // 瀹氫箟闄ゆ硶鍣ㄧ殑杈撳嚭淇″彿
  wire [47:0] dout_R[3:0];
  wire [47:0] dout_B[3:0];

  wire done[3:0];
  // 鎻愬彇闄ゆ硶鍣ㄧ殑杈撳嚭鏁版嵁锛岀敤浜庡悗缁鐩婅绠?
  wire [47:0] in_r_x1;
  wire [47:0] in_b_x1;
  assign in_r_x1 = dout_R[0][47:0];
  assign in_b_x1 = dout_B[0][47:0];


  wire [47:0] in_r_x2;
  wire [47:0] in_b_x2;
  assign in_r_x2 = dout_R[1][47:0];
  assign in_b_x2 = dout_B[1][47:0];


  wire [47:0] in_r_x3;
  wire [47:0] in_b_x3;
  assign in_r_x3 = dout_R[2][47:0];
  assign in_b_x3 = dout_B[2][47:0];


  wire [47:0] in_r_x4;
  wire [47:0] in_b_x4;
  assign in_r_x4 = dout_R[3][47:0];
  assign in_b_x4 = dout_B[3][47:0];
    

/*****************************************************************
                   IP 璋冪敤                                    
*****************************************************************/
    //涓轰簡淇濊瘉鍚堢悊鐨勫欢杩燂紝杩欓噷浣跨敤浜嗛櫎娉曞櫒

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : div_gen
      divider div_gen_G_R_r1 (
          .clk(I_clk),  					// input wire aclk
          .rst(!I_rst_n),                    
          .start(I_tvalid_r1),              // 杈撳叆闄ゆ暟鏈夋晥淇″彿
          .denominator(sum_r[i]),  			// 杈撳叆闄ゆ暟鏁版嵁锛孯閫氶亾鐨勭疮鍔犲€?
          .numerator({sum_g[i],16'd0}),  	// 杈撳叆琚櫎鏁版暟鎹紝G閫氶亾鐨勭疮鍔犲€硷紝鎵╁睍16浣?
          .quotient(dout_R[i]),  			// 杈撳嚭鏁版嵁锛孏/R鐨勬瘮鍊?
          .done(done[i])                    // 杈撳嚭鏁版嵁鏈夋晥淇″彿
      );

      divider divide_G_B_r1 (
          .clk(I_clk),  					// input wire aclk
          .rst(!I_rst_n),                    
          .start(I_tvalid_r1),              // 杈撳叆闄ゆ暟鏈夋晥淇″彿
          .denominator(sum_b[i]),  			// 杈撳叆闄ゆ暟鏁版嵁锛孯閫氶亾鐨勭疮鍔犲€?
          .numerator({sum_g[i],16'd0}),  	// 杈撳叆琚櫎鏁版暟鎹紝G閫氶亾鐨勭疮鍔犲€硷紝鎵╁睍16浣?
          .quotient(dout_B[i]),  			// 杈撳嚭鏁版嵁锛孏/R鐨勬瘮鍊?
          .done()                           // 杈撳嚭鏁版嵁鏈夋晥淇″彿
      );
    end
  endgenerate
     
	// 淇″彿寤惰繜妯″潡锛岀敤浜庡悓姝ヤ俊鍙凤紝寤惰繜50涓椂閽熷懆鏈?
    signal_delay #(
        .IMG_HEIGHT   (IMG_HEIGHT),
        .IMG_WIDTH    (IMG_WIDTH ),
        .DATA_WIDTH   (96  ),	// 鏁版嵁浣嶅涓?6浣?
        .DELAY_CYCLE  (50)      // 寤惰繜50涓椂閽熷懆鏈?
    )signal_delay_d (           
         .I_clk  (I_clk  ),     // 杈撳叆鏃堕挓淇″彿
         .I_rst_n(I_rst_n),
         .I_img_width (I_img_width),
         .I_img_height(I_img_height),
         .I_tuser(I_tuser),  	// 杈撳叆甯у紑濮嬩俊鍙?
         .I_valid(I_tvalid_r1), // 杈撳叆鏁版嵁鏈夋晥淇″彿
         .I_data (I_tdata_d1 ), // 杈撳叆鏁版嵁
         .O_valid(valid_d0   ), // 杈撳嚭鏁版嵁鏈夋晥淇″彿
         .O_data (data_d0    ), // 杈撳嚭鏁版嵁
         .O_tuser(I_tuser_r0 )  // 杈撳嚭甯у紑濮嬩俊鍙?
    );

/*****************************************************************
                            澧炵泭璁＄畻                                      
*****************************************************************/

    reg  [19:0]   in_r_r1;
    reg  [19:0]   in_b_r1;

    reg  [19:0]   in_r_r2;
    reg  [19:0]   in_b_r2;

    reg  [19:0]   in_r_r3;
    reg  [19:0]   in_b_r3;

    reg  [19:0]   in_r_r4;
    reg  [19:0]   in_b_r4;
	
	// 璁＄畻澧炵泭锛岄槻姝㈠鐩婅繃澶ф孩鍑猴紝闄愬埗鍦?xFFFFF
    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n || I_tuser)begin
            in_r_r1 <= 20'h10000;
            in_b_r1 <= 20'h10000;
        end
        else if(done[0])begin
            if(|in_r_x1[47:20])    // 鍒ゆ柇楂樹綅鏄惁鏈?锛岄槻姝㈡孩鍑?
                in_r_r1 <= 20'hfffff;
            else 
                in_r_r1 <= in_r_x1[19:0];
            if(|in_b_x1[47:20])
                in_b_r1 <= 20'hfffff;
            else 
                in_b_r1 <= in_b_x1[19:0];
        end
    end

    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n|| I_tuser)begin
            in_r_r2 <= 20'h10000;
            in_b_r2 <= 20'h10000;
        end
        else if(done[1])begin
            if(|in_r_x2[47:20])
                in_r_r2 <= 20'hfffff;
            else 
                in_r_r2 <= in_r_x2[19:0];
            if(|in_b_x2[47:20])
                in_b_r2 <= 20'hfffff;
            else 
                in_b_r2 <= in_b_x2[19:0];
        end
    end



    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n || I_tuser)begin
            in_r_r3 <= 20'h10000;
            in_b_r3 <= 20'h10000;
        end
        else if(done[2])begin
            if(|in_r_x3[47:20])
                in_r_r3 <= 20'hfffff;
            else 
                in_r_r3 <= in_r_x3[19:0];
            if(|in_b_x3[47:20])
                in_b_r3 <= 20'hfffff;
            else 
                in_b_r3 <= in_b_x3[19:0];
        end
    end




    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n || I_tuser)begin
            in_r_r4 <= 20'h10000;
            in_b_r4 <= 20'h10000;
        end
        else if(done[3])begin
            if(|in_r_x4[47:20])
                in_r_r4 <= 20'hfffff;
            else 
                in_r_r4 <= in_r_x4[19:0];
            if(|in_b_x4[47:20])
                in_b_r4 <= 20'hfffff;
            else 
                in_b_r4 <= in_b_x4[19:0];
        end
    end
    // 淇″彿鍚屾锛屽欢杩熶竴绾?
    always @(posedge I_clk or negedge I_rst_n) begin
      if (!I_rst_n) begin
          valid_d1 <= 0;
          data_d1  <= 0;
          I_tuser_r1 <= 0;
      end else begin
          valid_d1 <= valid_d0;
          data_d1  <= data_d0 ;
          I_tuser_r1 <= I_tuser_r0;
      end
    end
/*****************************************************************
                           鍍忕礌鍊艰绠?                                      
*****************************************************************/

    reg [27:0] R_new_r1;
    reg [27:0] G_new_r1;
    reg [27:0] B_new_r1;

    reg [27:0] R_new_r2;
    reg [27:0] G_new_r2;
    reg [27:0] B_new_r2;

    reg [27:0] R_new_r3;
    reg [27:0] G_new_r3;
    reg [27:0] B_new_r3;

    reg [27:0] R_new_r4;
    reg [27:0] G_new_r4;
    reg [27:0] B_new_r4;


    wire   [7:0] rgb888_r_d1[0:3];
    wire   [7:0] rgb888_g_d1[0:3];
    wire   [7:0] rgb888_b_d1[0:3];

    assign  rgb888_r_d1[0] = data_d1[16+:8];
    assign  rgb888_g_d1[0] = data_d1[8+:8];
    assign  rgb888_b_d1[0] = data_d1[0+:8];

    assign  rgb888_r_d1[1] = data_d1[40+:8];
    assign  rgb888_g_d1[1] = data_d1[32+:8];
    assign  rgb888_b_d1[1] = data_d1[24+:8];

    assign  rgb888_r_d1[2] = data_d1[64+:8];
    assign  rgb888_g_d1[2] = data_d1[56+:8];
    assign  rgb888_b_d1[2] = data_d1[48+:8];

    assign  rgb888_r_d1[3] = data_d1[88+:8];
    assign  rgb888_g_d1[3] = data_d1[80+:8];
    assign  rgb888_b_d1[3] = data_d1[72+:8];
	
	// 璁＄畻鏂扮殑RGB鍊硷紝搴旂敤澧炵泭
    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n)begin
            R_new_r1 <= 0;
            G_new_r1 <= 0;
            B_new_r1 <= 0;

            R_new_r2 <= 0;
            G_new_r2 <= 0;
            B_new_r2 <= 0;

            R_new_r3 <= 0;
            G_new_r3 <= 0;
            B_new_r3 <= 0;

            R_new_r4 <= 0;
            G_new_r4 <= 0;
            B_new_r4 <= 0;
        end
        else if(valid_d1) begin
            R_new_r1 <= in_r_r1 * rgb888_r_d1[0];
            G_new_r1 <=           rgb888_g_d1[0];
            B_new_r1 <= in_b_r1 * rgb888_b_d1[0];

            R_new_r2 <= in_r_r2 * rgb888_r_d1[1];
            G_new_r2 <=           rgb888_g_d1[1];
            B_new_r2 <= in_b_r2 * rgb888_b_d1[1];

            R_new_r3 <= in_r_r3 * rgb888_r_d1[2];
            G_new_r3 <=           rgb888_g_d1[2];
            B_new_r3 <= in_b_r3 * rgb888_b_d1[2];

            R_new_r4 <= in_r_r4 * rgb888_r_d1[3];
            G_new_r4 <=           rgb888_g_d1[3];
            B_new_r4 <= in_b_r4 * rgb888_b_d1[3];
        end
    end

/*****************************************************************
                            鍍忕礌鍊兼埅鏂?                                     
*****************************************************************/

    wire [7:0] R_new_x1;
    wire [7:0] G_new_x1;
    wire [7:0] B_new_x1;

    wire [7:0] R_new_x2;
    wire [7:0] G_new_x2;
    wire [7:0] B_new_x2;

    wire [7:0] R_new_x3;
    wire [7:0] G_new_x3;
    wire [7:0] B_new_x3;

    wire [7:0] R_new_x4;
    wire [7:0] G_new_x4;
    wire [7:0] B_new_x4;
	
	// 瀵规柊鐨勫儚绱犲€艰繘琛屾埅鏂紝闃叉婧㈠嚭
    assign R_new_x1 = (R_new_r1[27:24])?255:R_new_r1[23:16];
    assign G_new_x1 =  G_new_r1;
    assign B_new_x1 = (B_new_r1[27:24])?255:B_new_r1[23:16];

    assign R_new_x2 = (R_new_r2[27:24])?255:R_new_r2[23:16];
    assign G_new_x2 =  G_new_r2;
    assign B_new_x2 = (B_new_r2[27:24])?255:B_new_r2[23:16];

    assign R_new_x3 = (R_new_r3[27:24])?255:R_new_r3[23:16];
    assign G_new_x3 =  G_new_r3;
    assign B_new_x3 = (B_new_r3[27:24])?255:B_new_r3[23:16];

    assign R_new_x4 = (R_new_r4[27:24])?255:R_new_r4[23:16];
    assign G_new_x4 =  G_new_r4;
    assign B_new_x4 = (B_new_r4[27:24])?255:B_new_r4[23:16];
/*****************************************************************
                           同鍚屾淇″彿                                      
*****************************************************************/

    reg valid_d2,I_tuser_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)begin
            valid_d2 <= 0;
            I_tuser_r2 <= 0;
        end
        else begin
            valid_d2 <= valid_d1;
            I_tuser_r2 <= I_tuser_r1;
        end
    end

	// 杈撳嚭淇″彿鐨勭敓鎴?
    assign  O_tlast  = (valid_d1 == 0) && (valid_d2 == 1);   // 琛岀粨鏉熶俊鍙?
    assign  O_tuser  = I_tuser_r2 ;                          // 甯у紑濮嬩俊鍙?
    assign  O_tvalid = valid_d2;                             // 杈撳嚭鏈夋晥淇″彿
	
	// 杈撳嚭鏁版嵁锛岀敱鍥涗釜鍍忕礌鐨勬暟鎹嫾鎺ヨ€屾垚
    assign  O_tdata = O_tvalid?{R_new_x4,G_new_x4,B_new_x4,
                       R_new_x3,G_new_x3,B_new_x3,
                       R_new_x2,G_new_x2,B_new_x2,
                       R_new_x1,G_new_x1,B_new_x1}:0;
    // assign O_t_data = {R_new[7-:5],G_new[7-:6],B_new[7-:5]};
	// 杈撳叆鍑嗗濂戒俊鍙凤紝鐩存帴杩炴帴鍒拌緭鍑哄噯澶囧ソ淇″彿
    assign  I_tready = O_tready;
 
endmodule



