> 发布包补充：本包不附 NetAssist EXE 和本地 `_vendor` Python 安装副本。先按仓库根目录 `requirements.txt` 安装依赖；NetAssist 可从本人已有板卡资料中取得。以下为现有工具协议参考，其中旧构建/测试记录不代表当前 Mode18 主源码的验证结果。图片客户端现有模式参数限制仍为 0～17；Mode18 用板上 KEY3 进入。

# 颜色修复版：串口检查与级联时使用上位机

适用工程：A = `F:/FPGA/project/liuqing/1080p+720p_PhaseB2_dev101/1080p+720p_PhaseB2_dev`，B = 同级 `HX1P35A_Cascade_B_clean`。本说明核对当前代码，不改 RTL、IP 或 bit。

用户已确认当前上板版颜色正确、A 的按键 Mode 切换正常。2026-10-18 本次通过 COM5 查询 A：HELLO 的 error=0；STATUS_EXT 返回 display_valid=1、transition_active=0、requested_mode=active_mode=9、resolution=1（1080p）、active_source=1（共享 IMAGE）。PC 解码器 CRC 错误计数为 0。本次只发送 HELLO / STATUS_EXT，不切换 Mode、Source，不上传图片；这证明 USB 串口双向命令和状态通路可用，不等于已验收图片上传或高速稳定性。

## 保留两板网线，先检查串口控制

1. USB 接 A 的板载下载/串口接口；设备管理器目前识别 `USB Serial Port (COM5)`。后续插拔以实际 COM 号为准。
2. 关闭占用 COM5 的其他串口工具。本工程的串口软件使用二进制分包和 CRC；SSCOM 里直接发送文字 `MODE 13` 不能控制当前协议。
3. 双击本目录 `start_uart_image.bat`。选择 COM5，先用 Safe（921600 / RGB565 / Window1）。
4. 在 Algorithm 0-16 选择 13、Compare 选择 processed，点击 **Apply mode / compare**；观察 A 的 HDMI。再选择 0、processed，点击同一按钮恢复。先后验证命令应答和实际画面。
5. 如果需要验证左右原图/算法图，使用一个可见差异的算法并选择 wipe，再点击 Apply。完成后恢复 processed。
6. 串口查询/Mode/Compare 可以保留 A-B 网线；只控制 USB 所接的板，不会自动转发给另一板。B 当前仅纯视频 hook，未加入 A 的算法。

命令行等效操作：在 PowerShell 先进入 tools，再运行以下命令。执行控制命令前，GUI 点 Disconnect 或关闭窗口。

```powershell
Set-Location -LiteralPath 'F:\FPGA\project\liuqing\1080p+720p_PhaseB2_dev101\1080p+720p_PhaseB2_dev\tools'
python uart_image_sender.py --port COM5 --baud 115200 --status
python uart_image_sender.py --port COM5 --mode 13 --compare processed
python uart_image_sender.py --port COM5 --status
python uart_image_sender.py --port COM5 --mode 0 --compare processed
```

期待 error=0，控制后 requested_mode / active_mode 与目标一致，display_valid=1、transition_active=0。分辨率 0=720p、1=1080p；Source 0=本地摄像头、1=共享 IMAGE。共享 IMAGE 可能来自级联，也可能来自 PC 图片，`image_valid=1` 本身不证明 PC 图片上传过。

SW2 高电平优先 IMAGE；需要用 **Show Camera** 或 `--source camera` 时先将 A 的 SW2 拨下。SW2 高电平下，软件摄像头请求不会覆盖拨码优先级。KEY1 仍使用同一个 CAMERA/IMAGE 选择。

## 不添设备，检查 USB 图片上传

PC 图片与对端摄像头预览共用 IMAGE DDR 槽。对端预览继续发布时，PC 图片可能被替换，上传可能 BUSY，或者 READY 后 DISPLAYED 等待失败。

首轮图片检查可暂时拔掉 A-B 网线，SW2 拨下：

1. GUI Browse 选择 PNG/JPG，分辨率选 Follow SW4，Profile 选 Safe，Mode0 / processed。
2. 点 **Upload image**，等待 **DISPLAYED**；HDMI 应显示选中的图片。不要直接用串口助手发送原始 PNG/JPG 文件。
3. 切 Mode / wipe，检查图片上的算法效果。需要同时验收两个分辨率缓存，可选 **Preload 720 + 1080**，完成后点 **Show UART**，再切 SW4 检查。
4. 点 **Show Camera** 返回本地摄像头，恢复 A-B 网线；需要看对端时再拨 SW2。

921600 / 8N1 下，RGB565 仅像素的理论传输时间约为 720p 20 秒、1080p 45 秒，协议与 ACK 会增加时间。串口用于控制和静态图片，不用于实时摄像头视频回传。先验收 Safe，2M/3M 和 Window8 的稳定性另行测量。

## 同时连接 A、B、网络上位机

将原 A-B 直连改为三者都接同一台千兆交换机，三个独立网线连接：

```text
A 网口 ─┐
B 网口 ─┼─ 同一台千兆交换机
PC网口 ─┘
```

使用同一二层网络的普通 LAN 口；各链路应为 1.0 Gbps。当前 FPGA 未实现 100M/10M 自适应、DHCP、VLAN 或 ICMP ping 应答。PC 的 USB 仍可接 A 以使用串口；PC 没有有线网口时需要一个支持千兆的网卡。交换机不需要承担路由或联网功能。

| 节点 | IPv4 | 掩码 | FPGA UDP 端口 |
|---|---|---|---|
| PC 对应有线网卡 | 192.168.137.1 | 255.255.255.0 | 主机默认使用 6001 |
| A | 192.168.137.2 | 255.255.255.0 | 6002 |
| B | 192.168.137.3 | 255.255.255.0 | 6002 |

仅设置接交换机的 PC 网卡；本地独立网络网关/DNS 可留空，避免同网段地址冲突。板端 IP/MAC 已不同，级联数据发给对端固定 MAC，PC 命令回复请求者的 MAC/IP/端口；代码支持这种接法，不需要因加入普通交换机修改 FPGA。交换机现场共存吞吐仍需接好后验证。

先关闭默认的图片桥接，分别做状态检查：

```powershell
python ethernet_image_host.py --local-ip 192.168.137.1 --board-ip 192.168.137.2 --command STATUS
python ethernet_image_host.py --local-ip 192.168.137.1 --board-ip 192.168.137.3 --command STATUS
```

收到 FPGA error=0 后，再开 `start_ethernet_image.bat`（默认目标 A），以及 `start_netassist.bat`。NetAssist 选 UDP、文本/ASCII、本地 127.0.0.1:6003、远端 127.0.0.1:6000。发 `STATUS` 检查板端回复；`HELP` / `ACCEPTED` 只表示本机桥接响应。

控制 B 时关闭原桥接后使用：

```powershell
python ethernet_image_host.py --bridge --local-ip 192.168.137.1 --board-ip 192.168.137.3
```

使用 A 的 MODE / COMPARE / STATUS 控制不需要关闭级联。需要在 A 显示 PC 静态图片时，先将 A 的 SW2 拨下，再在另一个 PowerShell 执行：

```powershell
python cascade_control.py off --board-ip 192.168.137.2 --local-ip 192.168.137.1
```

该脚本默认使用 6010，不与桥接 6001 冲突。它暂停 A 的级联收发，网络线仍可保留；等待当前事务收尾后，再用串口 Upload 或在 NetAssist 发送：

```text
UPLOAD "F:/test.png" 720 0 rgb565
```

显示分辨率由 SW4 决定，上传 720 图片不会自动切 SW4。完成后先用 NetAssist 发 `CAMERA`（SW2 保持低），再恢复：

```powershell
python cascade_control.py on --board-ip 192.168.137.2 --local-ip 192.168.137.1
```

随后 SW2 可重新切到 B。如操作 B，命令中的板地址换成 `.3`。上电默认打开级联。当前串口命令表没有 CASCADE_ENABLE，直接 A-B 网线加 USB 的接法无法通过已有串口工具关闭级联；采用上面的临时断网法，或通过交换机发送 UDP 开关命令。

现有上位机提供控制和静态图片上传，没有 PC 实时查看两板摄像头的功能；板间预览也不会自动变成 PC 接收视频。未来 PC 视频接收需要另外实现接收协议和显示工具。

交换机转发原理参考：[Cisco：How Does a Switch Work?](https://www.cisco.com/site/us/en/learn/topics/small-business/network-switch-how.html)。工程具体地址、缓冲复用、协议和开关以当前 RTL 与 tools 实现为准。
