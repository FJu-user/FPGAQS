> 发布包补充：本包不附 NetAssist EXE 和本地 `_vendor` Python 安装副本。先按仓库根目录 `requirements.txt` 安装依赖；NetAssist 可从本人已有板卡资料中取得。以下为现有工具协议参考，其中旧构建/测试记录不代表当前 Mode18 主源码的验证结果。图片客户端现有模式参数限制仍为 0～17；Mode18 用板上 KEY3 进入。

# 工程内 NetAssist 上位机

赛方原版 `NetAssistv4325.exe` 移入本目录，作为本工程以太网图片和 Mode 控制的命令界面。

原位置：`F:\FPGA\购买板卡资料\HX1P35A_Contest_202606\2_Example\33_ethernet_udp_led\uisrc\NetAssistv4325.exe`。

新位置：`tools/NetAssist/NetAssistv4325.exe`，相对于当前工程根目录。

EXE 大小：497152 字节。

EXE SHA256：`DC406C726E678CE951F7A23575E34CAFF229D2B1C64EFA23E22DCF8D4E3258B0`。

原目录没有随附的 DLL、INI 或其他上位机运行文件。`01_rtl`、`03_ip`、`04_pin`、`05_doc` 属于赛方 FPGA 示例资料，保留在资料包中。

本工程运行相关文件：

| 工程内路径 | 用途 |
|---|---|
| `tools/NetAssist/NetAssistv4325.exe` | 官方网络调试界面 |
| `tools/start_netassist.bat` | 打开本目录的官方界面 |
| `tools/start_ethernet_image.bat` | 启动图片桥接程序 |
| `tools/ethernet_image_host.py` | 文本命令、UDP 图片分包、CRC、ACK 和重试 |
| `tools/uart_image_sender.py` | 共享图片转换及协议工具 |
| `tools/uart_image_metrics.py` | 共享 Python 模块依赖 |
| `tools/_vendor/` | 已有本地 Python 依赖 |
| `tools/requirements_uart.txt` | 共享依赖清单 |
| `tools/ETHERNET_HOST_COMMANDS.md` | 图片、Mode0～16、来源切换命令手册 |
| `tools/README_ETHERNET_IMAGE.md` | 以太网接入和协议说明 |

除移入的 EXE 和新增启动入口外，上述脚本及依赖原本已经位于工程内部，继续使用现有位置。

先运行 `tools/start_ethernet_image.bat` 并保持窗口开启，再运行 `tools/start_netassist.bat`。NetAssist 设置 UDP、本地 `127.0.0.1:6003`、远程 `127.0.0.1:6000`，按命令手册发送 `HELP`、`STATUS` 等命令。

Python 桥接和启动入口均按自身文件位置定位 EXE，不再依赖原资料包的绝对路径。移动整个工程时保留 `tools` 内部结构。电脑仍需安装 Python，操作系统自带组件不随本次迁移移动。
