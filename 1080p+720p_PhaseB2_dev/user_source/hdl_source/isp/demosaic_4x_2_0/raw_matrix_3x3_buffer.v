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
@Time        :   2025/01 
version:     :   1.1
@Description :   该模块主要是用于3x3矩阵的形成，以及对图像边界像素的处理
                 在原基础上优化了时序，把原来的一些未完全对齐的信号进行对齐。
*****************************************************************/


module raw_matrix_3x3_buffer #(
    parameter IMG_HEIGHT = 1080,  // 图像高度
    parameter IMG_WIDTH  = 1920,   // 图像宽度
    parameter data_complete_delay = 50
)
(
    input           I_clk   ,   // 时钟信号
    input           I_rst_n ,   // 复位信号，低有效
    input [11:0]    I_img_width,
    input [11:0]    I_img_height,

    input [39:0]                         axi4s_video_tdata ,  // AXI4-Stream视频数据
    input [9:0]                          axi4s_video_tdest ,
    input                                axi4s_video_tlast ,  // 行结束信号
    input                                axi4s_video_tvalid,  // 数据有效信号
    input                                axi4s_video_tuser ,  // 帧开始信号
    output                               axi4s_video_tready,  // 从模块准备好接受数据

    output                               O_tlast         ,   // 行结束信号输出
    output                               O_tuser         ,   // 帧开始信号输出
    output                               O_tvalid        ,   // 数据有效信号输出
    input                                O_tready        ,   // 上一级模块准备好接受数据

    output                               bayer_ypos      ,   // Bayer滤波器行位置
    output  [95:0]                       matrix_last_line,   // 上一行3x3矩阵数据
    output  [95:0]                       matrix_cur_line ,   // 当前行3x3矩阵数据
    output  [95:0]                       matrix_next_line    // 下一行3x3矩阵数据
);


/*********************************************************
******************1.功能声明*******************************
*********************************************************/
// 计算数据的位宽
function integer clog2b(
    input integer depth
);
    begin
        for(clog2b=0; depth>0; clog2b=clog2b+1)begin
            depth = depth >> 1;
        end
    end    
endfunction

/*********************************************************
******************2.常数声明*******************************
*********************************************************/
localparam N = 3;  // 矩阵大小为3x3

localparam DATA_WIDTH   = 32;  // 数据位宽

wire [9:0] img_width_4x = I_img_width >> 2;

/*********************************************************
******************3.信号声明*******************************
*********************************************************/
// 定义线网信号
wire                        zhenghe_tlast ;    // 合并后的行结束信号
wire                        zhenghe_tuser ;    // 合并后的帧开始信号
wire  [31:0]                zhenghe_tdata ;    // 合并后的数据
wire                        zhenghe_tvalid;    // 合并后的数据有效信号

wire  [DATA_WIDTH-1:0]      raw_data        ;  // 原始数据
wire                        raw_data_valid  ;  // 原始数据有效信号

wire                valid   [0:N-1] ;          // 有效信号数组
wire [DATA_WIDTH:0] data    [0:N-1] ;          // 数据数组（包含tuser位）

wire                O_raw_tlast_d0;            // 行结束信号，延迟0周期
wire                O_raw_tuser_d0;            // 帧开始信号，延迟0周期
wire                I_raw_tready;              // 模块准备好接受原始数据
wire [32:0]         next_line_data;            // 下一行数据
wire [32:0]         data_d2;                   // 数据延迟2个周期
wire                next_line_start;           // 下一行的开始信号
wire                bayer_ypos_d0;             // Bayer位置，延迟0周期

/*********************************************************
******************4.寄存器信号声明*************************
*********************************************************/
// 定义寄存器信号
reg [95:0]      matrix_cur_line_buffer       ; // 当前行的3x3矩阵缓冲
reg [95:0]      matrix_last_line_buffer      ; // 上一行的3x3矩阵缓冲
reg [95:0]      matrix_next_line_buffer      ; // 下一行的3x3矩阵缓冲
reg             tlast_d0,tlast_d1,tlast_d2;     // 行结束信号延迟寄存器
reg             tuser_d0,tuser_d1,tuser_d2;     // 帧开始信号延迟寄存器
reg             ch_valid;                       // 数据通道有效信号
reg             horizontal_tail;                // 最后一组的右邻域补边
reg [13:0]      h_cnt;                          // 水平像素计数器
reg [13:0]      v_cnt,v_cnt_d;                  // 垂直像素计数器及其延迟
reg             next_line_data_valid;           // 下一行数据有效信号
reg             valid_d0,valid_d1;              // 有效信号延迟寄存器
reg             bayer_ypos_d;                   // Bayer位置延迟寄存器
reg  [32:0]     data_d0_d,data_d0;              // 数据延迟寄存器
reg  [32:0]     data_d1;

/*********************************************************
******************5.组合逻辑******************************
*********************************************************/
// 将数据和有效信号进行连接
reg [9:0] input_word,flush_word;
reg [11:0] input_row;
reg [2:0] flush_wait;
reg flush_pending,flush_active;
reg flush_active_d1;
always @(posedge I_clk or negedge I_rst_n)
    if(!I_rst_n)flush_active_d1<=0;else flush_active_d1<=flush_active;
always @(posedge I_clk or negedge I_rst_n)begin
    if(!I_rst_n || zhenghe_tuser)begin
        input_word<=0;input_row<=0;flush_word<=0;flush_wait<=0;flush_pending<=0;flush_active<=0;
        // tuser is aligned with the first input word.
        if(I_rst_n && zhenghe_tvalid)input_word<=1;
    end else begin
        if(zhenghe_tvalid)begin
            if(input_word==img_width_4x-1'b1)begin
                input_word<=0;input_row<=input_row+1'b1;
                if(input_row==I_img_height-1'b1)begin flush_pending<=1;flush_wait<=0;end
            end else input_word<=input_word+1'b1;
        end
        if(flush_pending && !zhenghe_tvalid)begin
            if(flush_wait==5)begin flush_pending<=0;flush_active<=1;flush_word<=0;end
            else flush_wait<=flush_wait+1'b1;
        end
        if(flush_active)begin
            if(flush_word==img_width_4x-1'b1)begin flush_active<=0;flush_word<=0;end
            else flush_word<=flush_word+1'b1;
        end
    end
end
assign data[0]  = {zhenghe_tuser, zhenghe_tdata};  // 将tuser和数据拼接
assign valid[0] = zhenghe_tvalid || flush_active;                  // 第一个有效信号

// 将准备信号连接到上级模块
assign axi4s_video_tready = O_tready;

/*********************************************************/
// 将矩阵缓冲输出
assign matrix_last_line = matrix_last_line_buffer;
assign matrix_cur_line  = matrix_cur_line_buffer ;
assign matrix_next_line = matrix_next_line_buffer;

// 计算Bayer滤波器的行位置
assign bayer_ypos_d0 = !v_cnt_d[0] & ch_valid;

/*********************************************************
******************6.模块实例化*****************************
*********************************************************/
// 实例化mipi_to_raw_converter模块，将MIPI协议的数据转换为RAW数据
mipi_to_raw_converter mipi_to_raw_converter_r0(
    .I_clk       (I_clk  ),              // 时钟信号
    .I_rst_n     (I_rst_n),              // 复位信号，低有效
    .I_raw_tdata (axi4s_video_tdata ),   // 输入原始数据
    .I_raw_tdest (axi4s_video_tdest ),   // 输入目的地地址
    .I_raw_tlast (axi4s_video_tlast ),   // 输入行结束信号
    .I_raw_tvalid(axi4s_video_tvalid),   // 输入数据有效信号
    .I_raw_tuser (axi4s_video_tuser),    // 输入帧开始信号
    .I_raw_tready(I_raw_tready  ),       // 输出准备好信号
    .O_raw_tdata (raw_data      ),       // 输出原始数据
    .O_raw_tlast (O_raw_tlast_d0),       // 输出行结束信号
    .O_raw_tvalid(raw_data_valid),       // 输出数据有效信号
    .O_raw_tuser (O_raw_tuser_d0),       // 输出帧开始信号
    .O_raw_tready(1)                     // 模块始终准备好接受数据
);

// 实例化“zhenghe”模块，将数据进行合并处理
zhenghe#(
    .IMG_WIDTH ( IMG_WIDTH ),
    .IMG_HEIGHT( IMG_HEIGHT),
    .DATA_WIDTH( 32),
    .data_complete_delay (data_complete_delay)
) 
zhenghe_d(
    .I_clk    (I_clk   ),               // 时钟信号
    .I_rst_n  (I_rst_n ),               // 复位信号，低有效
    .I_img_width (I_img_width),
    .I_img_height(I_img_height),

    .I_tlast  (O_raw_tlast_d0 ),        // 输入行结束信号
    .I_tuser  (O_raw_tuser_d0 ),        // 输入帧开始信号
    .I_tdata  (raw_data ),              // 输入原始数据
    .I_tvalid (raw_data_valid),         // 输入数据有效信号

    .O_tlast  (zhenghe_tlast ),         // 输出合并后的行结束信号
    .O_tuser  (zhenghe_tuser ),         // 输出合并后的帧开始信号
    .O_tdata  (zhenghe_tdata ),         // 输出合并后的数据
    .O_tvalid (zhenghe_tvalid)          // 输出合并后的数据有效信号
);

// 生成两行缓冲区，使用线性缓冲区实现3x3矩阵的行数据缓存
genvar i;
generate
    for(i=1; i<3; i=i+1)
    begin: two_line_buffer  // 模块命名为two_line_buffer
        line_buffer_demosaic #(
            .IMG_HEIGHT (IMG_HEIGHT),
            .IMG_WIDTH  (IMG_WIDTH )
        ) line_buffer_demosaic_r1 (
            .I_clk     ( I_clk      ),    // 时钟信号
            .I_rst_n   ( I_rst_n    ),    // 复位信号，低有效
            .I_read_only(i==1?flush_active:flush_active_d1),
            .I_img_width (I_img_width),
            .I_tuser   ( data[i-1][32] & valid[i-1]), // 输入帧开始信号
            .I_valid   ( valid[i-1] ),    // 输入有效信号
            .I_data    ( data[i-1]  ),    // 输入数据
            .O_valid   ( valid[i]   ),    // 输出有效信号
            .O_data    ( data[i]    )     // 输出数据
        );           
    end        
endgenerate

// 由于在BRAM中每次输出数据都会延迟一个周期，所以要使这些数据对齐，需要对这些数据进行延迟处理，其中data[0]延迟2个周期，data[1]延迟一个周期
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        data_d0_d <= 0;
        data_d0   <= 0;
        data_d1   <= 0;
        valid_d0  <= 0;
        valid_d1  <= 0;
    end
    else begin
        valid_d0  <= valid[0];
        valid_d1  <= valid_d0;
        data_d0_d <= data[0];
        data_d0   <= data_d0_d;
        data_d1   <= data[1];
    end
end

assign data_d2 = data[2];
/*********************************************************
***********3x3矩阵的形成，以及对边界元素的补充处理***********
*********************************************************/

// A group needs the next group's first pixel. Delay visible groups by one
// input group, then flush the last group in horizontal blank. The existing
// matrix registers hold the lookahead; no extra line memory is required.
wire [31:0] centre_word=data_d1[31:0];
wire [31:0] upper_word=v_cnt==1?data_d0[31:0]:data_d2[31:0];
wire [31:0] lower_word=v_cnt==I_img_height?data_d2[31:0]:data_d0[31:0];
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)horizontal_tail<=0;
    else horizontal_tail<=valid_d1 && v_cnt!=0 && h_cnt==img_width_4x-1'b1;
end
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)begin
        matrix_last_line_buffer<=0;matrix_cur_line_buffer<=0;matrix_next_line_buffer<=0;
    end else if(horizontal_tail)begin
        matrix_cur_line_buffer<={matrix_cur_line_buffer[63:0],matrix_cur_line_buffer[15:8],24'd0};
        matrix_last_line_buffer<={matrix_last_line_buffer[63:0],matrix_last_line_buffer[15:8],24'd0};
        matrix_next_line_buffer<={matrix_next_line_buffer[63:0],matrix_next_line_buffer[15:8],24'd0};
    end else if(valid_d1 && v_cnt!=0)begin
        if(h_cnt==0)begin
            matrix_cur_line_buffer<={24'd0,centre_word[23:16],centre_word,centre_word};
            matrix_last_line_buffer<={24'd0,upper_word[23:16],upper_word,upper_word};
            matrix_next_line_buffer<={24'd0,lower_word[23:16],lower_word,lower_word};
        end else if(h_cnt==1)begin
            matrix_cur_line_buffer<={24'd0,matrix_cur_line_buffer[71:64],matrix_cur_line_buffer[31:0],centre_word};
            matrix_last_line_buffer<={24'd0,matrix_last_line_buffer[71:64],matrix_last_line_buffer[31:0],upper_word};
            matrix_next_line_buffer<={24'd0,matrix_next_line_buffer[71:64],matrix_next_line_buffer[31:0],lower_word};
        end else begin
            matrix_cur_line_buffer<={matrix_cur_line_buffer[63:0],centre_word};
            matrix_last_line_buffer<={matrix_last_line_buffer[63:0],upper_word};
            matrix_next_line_buffer<={matrix_next_line_buffer[63:0],lower_word};
        end
    end else begin
        matrix_last_line_buffer<=0;matrix_cur_line_buffer<=0;matrix_next_line_buffer<=0;
    end
end

// 计算水平和垂直计数器
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || zhenghe_tuser) begin
        h_cnt <= 0;
        v_cnt <= 0;
    end else begin
        h_cnt    <= valid_d1 ? ((h_cnt == img_width_4x - 1'b1) ? 0 : h_cnt + 1) : h_cnt;
        v_cnt    <= valid_d1 && (h_cnt == img_width_4x - 1'b1) ? (v_cnt + 1) : v_cnt;
    end
end

// 数据有效信号的延迟处理
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        ch_valid <= 0;
        v_cnt_d <= 0;
    end else begin
        ch_valid <= (valid_d1 && v_cnt!=0 && h_cnt!=0) || horizontal_tail;
        if(!horizontal_tail)v_cnt_d <= v_cnt;
    end
end

assign bayer_ypos = bayer_ypos_d0 ;

// 对tuser和tlast信号进行同步处理，此时数据和流控制信号已经同步
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        tlast_d0 <= 0;
        tlast_d1 <= 0;
        tlast_d2 <= 0;
        tuser_d0 <= 0;
        tuser_d1 <= 0;
        tuser_d2 <= 0;
    end
    else begin
        tlast_d0 <= horizontal_tail;
        tlast_d1 <= tlast_d0;
        tlast_d2 <= tlast_d1;
        tuser_d0 <= valid_d1 && v_cnt==1 && h_cnt==1;
        tuser_d1 <= tuser_d0;
        tuser_d2 <= tuser_d1;
    end
end

// 将同步后的信号输出
assign O_tuser  = tuser_d0;
assign O_tlast  = tlast_d0;
assign O_tvalid = ch_valid;


endmodule


