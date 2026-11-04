> 发布包补充：本包不附 NetAssist EXE 和本地 `_vendor` Python 安装副本。先按仓库根目录 `requirements.txt` 安装依赖；NetAssist 可从本人已有板卡资料中取得。以下为现有工具协议参考，其中旧构建/测试记录不代表当前 Mode18 主源码的验证结果。图片客户端现有模式参数限制仍为 0～17；Mode18 用板上 KEY3 进入。

# 以太网静态图片与 Mode 控制：赛方 NetAssist + 图片桥接

唯一活动工程：`F:/FPGA/project/liuqing/1080p+720p_PhaseB2_dev101/1080p+720p_PhaseB2_dev`。

当前状态：RTL 与离线仿真准备完成；**尚未综合、P&R、生成新 bit 或上板**。旧 UART Phase3 bit 不包含本次以太网功能。

## 1. 使用的官方软件

使用赛方资料包的原版程序。该 EXE 已移入当前工程，程序内容保持不变：

`tools/NetAssist/NetAssistv4325.exe`

双击 `tools/start_netassist.bat` 打开界面。图片桥接脚本、共享图片转换代码、本地依赖和命令手册均位于本工程 `tools` 中；迁移说明见 [NetAssist/README.md](NetAssist/README.md)。

资料包还包含 `video.exe`、`ATK-XCAM.exe`、XNET 和其他 NetAssist 副本。已找到视频工具的显示/采集信息，但没有确认其“PC 静态图片上传”的协议。因此本版**不是宣称兼容 video.exe 的未知图片格式**：官方 NetAssist 负责命令界面，本工程 `ethernet_image_host.py` 负责图片缩放、RGB565/RGB888、分包、校验、ACK 和重试。

NetAssist 向本地图片桥接发文本命令；图片桥接使用真实 UDP 网卡连接 FPGA。不要在 NetAssist 中直接“发送 PNG/JPEG 文件”给 FPGA，FPGA 不解码 PNG/JPEG，也不直接接收任意文件字节。

## 2. 用户手动后端检查

打开 `td_project/camera_to_dsi_display.al`，确认 9 个 `ethernet/*.v` 文件均存在（包括资源优化新增的 `ethernet_reply_cdc.v`）。由用户运行完整 TD 综合和 P&R，先检查：

- 新资源能放入 PH1P35：理论 ERAM 105/108、PLL 5/6；Slice/LUT 实际增量未知。
- 149.343 MHz、125 MHz、100 MHz 全局 Setup/Hold 非负；SDC 的 ETH_* clock/pin collections 非空，没有未约束 RGMII 通路。
- `u_rx_eram` 为 1 ERAM；不要接受意外新增多套 packet FIFO/整帧 RAM。
- `u_response_cdc` 使用以太网专用的稳定数据握手，仅包含6个握手寄存器，不再复制两份449-bit应答；数据在请求到返回确认之间保持不变，由TX原有寄存器一次捕获。应检查双级同步器和数据总线物理稳定窗口。
- PLL 90° 输出未用于本接口，已从 SDC 重命名/异步分组中删除。实际应存在 `ETH_TX_CLK`、`ETH_REF25_CLK`、`ETH_FORWARD_CLK`；不得用新增假时钟压制警告。
- RGMII 引脚必须与赛方 HX1P35 例程一致。R10/R11 已从旧的外部复位/屏幕 PWM 别名释放给 TX_CTL/TXD0。
- 顶层改用 50 MHz 上电计数释放 PLL 复位；确认寄存器初值、PLL 启动和 PHY 复位时序。原先 R10 的外部复位端口不再存在，需断电重启作全系统复位。

只有检查通过后，再由用户生成、下载新 bit。旧时序和旧 bit 不能证明这次新增功能通过。

2026-10-06 首版曾在 Packing 因21735 Slice超过21216失败。当前已做以太网资源重构与离线回归，但**没有新的综合/P&R资源结果，不能宣称已能放入器件**。详见 `verification/ethernet_image/RESOURCE_OPTIMIZATION_REPORT.md`。

## 3. 网卡与网络参数

首版固定千兆 RGMII，要求实际 Link 为 **1.0 Gbps**。没有做 100M/10M 自动切换、MDIO 管理、DHCP、IPv6、VLAN 或 ICMP ping 应答。

| 项目 | 本版设置 |
|---|---|
| PC 接板有线网卡静态 IP | 192.168.137.1 |
| 掩码 | 255.255.255.0 |
| FPGA IP / MAC | 192.168.137.2 / 02:00:00:00:00:02 |
| FPGA UDP 端口 | 6002 |
| Python 对板本地 UDP 端口 | 6001 |
| NetAssist → 本地桥接 | 127.0.0.1:6000 |
| NetAssist 本地端口 | 6003 |

网关/DNS 可留空。不要在未确认的情况下更改其他网卡或全局防火墙。必要时只允许 Python/NetAssist 对应的专用网络/端口。多网卡时使用 CLI 的 `--local-ip 192.168.137.1` 指定接板网卡。

FPGA 会回答针对上述地址的 ARP 请求。**ping 不通不等于以太网失败**，本版没有 ICMP；用 `STATUS`/HELLO 的 ACK 判断协议链路。

## 4. 启动官方界面

1. 准备 Python 3.10+；图片转换需要 Pillow。沿用现有 UART sender 的本地 `_vendor`/Python 依赖，不需要 pyserial 来打开以太网，也没有打开 COM 口。
2. 双击本工程 `tools/start_ethernet_image.bat`，保持 Python 窗口开启。
3. 双击本工程 `tools/start_netassist.bat`，或直接打开 `tools/NetAssist/NetAssistv4325.exe`。
4. NetAssist 选择 UDP，远端 `127.0.0.1`、远端端口 `6000`、本地端口 `6003`；本地地址可用 `127.0.0.1` 或 `0.0.0.0`。打开网络连接，选文本/ASCII发送，关闭循环发送和 HEX 发送。
5. 发 `HELP`，应有本地桥接的 ACCEPTED/帮助回复；它只证明 GUI→Python，不证明 FPGA 已连接。再发 `STATUS`，收到含 `error: 0` 的 FPGA 状态才证明板端协议应答。

中文图片路径兼容 UTF-8 或 Windows GBK/GB18030；第一次 smoke 建议用简单路径，例如 `F:/test.png`。带空格路径必须加引号。

## 5. 上传并显示

720（板上 SW4 当前处于 720）例子：

```text
UPLOAD "F:/test.png" 720 0 rgb565
```

1080（SW4 当前处于 1080）例子：

```text
UPLOAD "F:/test.png" 1080 12 rgb565
```

桥接会将任意输入图片缩放并居中填充成 1280×720 或 1920×1080，默认 RGB565，上传 READY 后发 MODE，再发 IMAGE/source=1。路径是 **PC 本地图片路径**。

支持离线 preload：先上传 720，再上传 1080，两份 READY 可以共存。上传分辨率不必等于当前 SW4 分辨率，HDMI 仍由 SW4 决定；上传 1080 不会自动把显示切到 1080。切换到目标分辨率后，共享 reader 在安全帧边界显示对应 FRONT。

可发：

```text
MODE 0
MODE 12
MODE 15
MODE 16
COMPARE processed
COMPARE raw
COMPARE split
CAMERA
IMAGE
STATUS
```

MODE 范围 0～16；ACK 表示控制请求被接受，真正生效仍是现有帧边界提交，不是 ACK 到达瞬间就换算法。官方 Logo/分辨率 OSD 仍位于算法后级。KEY1 切 Camera/共享 Image；KEY2 保持 Mosaic 大小控制；KEY3 保持 Mode 循环；KEY4 保持下一帧安全回 Mode0。

UART 与 Ethernet 使用同一套图片 FRONT/BACK，不是两组独立来源。后上传并成功发布的同分辨率图片替换该分辨率 FRONT；传输失败、CRC 错误或 fence 失败不能替换旧 FRONT。两种上传不得并发：已有上传持有 lease 时，另一种 BEGIN 应 BUSY。

## 6. 不经过 GUI 的诊断命令

在本工程 tools 目录：

```powershell
py -3 ethernet_image_host.py --local-ip 192.168.137.1 --command "STATUS"
py -3 ethernet_image_host.py --local-ip 192.168.137.1 --command "MODE 16"
py -3 ethernet_image_host.py --local-ip 192.168.137.1 --command 'UPLOAD "F:/test.png" 720 12 rgb565'
```

不能同时运行桥接和第二个默认端口 6001 的 CLI。先关闭桥接，或用另一空闲 `--local-port`。

也可以关闭桥接，让官方 NetAssist **直接**连接 FPGA（UDP远端192.168.137.2:6002、本地6001，HEX发送/接收），做最小协议诊断：

```text
HELLO:
01 01 00 00 00 00 00 00 00 00 00 00 00 00 68 97 64 E6 67 38

MODE16:
01 07 00 00 00 00 00 00 00 00 00 00 01 00 32 2B 10 C8 37 F8 C2
```

这两段是完整的应用数据报（不是命令文字、不含MAC/IP头），HEX框中只粘贴对应数字。NetAssist/OS封装UDP，FPGA应返回44-byte应用ACK。图片上传仍使用桥接分包，不用“发送图片文件”替代协议。上述HEX诊断尚待实机确认。

## 7. 第一轮上板验收

先不开上位机，确认摄像头双分辨率、Mode0～16、KEY1～4、Logo/文字正常，再连接网线：

1. 千兆 Link、ARP、STATUS/Mode0/Mode16；
2. 720 RGB565 原图，检查首像素、末行、RGB 顺序、块边界、无撕裂；
3. 1080 RGB565，检查 x>1280 右侧和最后一行；再验 RGB888；
4. 所有 Mode、Compare、KEY1、KEY4、OSD，SW4 720→1080→720 缓存恢复；
5. 上传中拔网线/停止发送，旧 FRONT 保持，约 5 秒空闲清理后可以重新 BEGIN；
6. UART Window8 与 Ethernet 分别上传，验证互斥 BUSY 和失败恢复；
7. 记录实际上传耗时、重试、资源与新时序。此版本不承诺视频流/高 fps 或已经测得的上传速度。

本版为静态图片 stop-and-wait，payload 1024 bytes，每包有效 ACK 后才发下一包。不要套用旧 ronghe 1456-byte 原始广播帧/Npcap 程序。
