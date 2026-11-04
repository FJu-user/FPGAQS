# 上位机工具

工具位于 `1080p+720p_PhaseB2_dev/tools/`，保留本项目的 Python 与 BAT 脚本。

```powershell
python -m pip install -r requirements.txt
python -B .\1080p+720p_PhaseB2_dev\tools\uart_image_sender.py --help
python -B .\1080p+720p_PhaseB2_dev\tools\ethernet_image_host.py --help
```

| 文件 | 用途 |
|---|---|
| uart_image_sender.py / start_uart_image.bat | 串口图片转换、发送和界面 |
| uart_image_metrics.py / benchmark_uart_image.py | 传输统计与测量工具 |
| ethernet_image_host.py / start_ethernet_image.bat | UDP 图片传输与文本命令桥接 |
| cascade_control.py | 通过既有 UDP 客户端控制级联开关 |
| start_netassist.bat | 打开用户自行提供的 NetAssist |

Python 依赖沿用现有清单 Pillow>=9.1、pyserial>=3.5，本次不冒充已锁定并验证全部未来版本。可选本地 `_vendor` 安装副本和其中的 EXE 不加入 GitHub 包，请使用 pip 安装依赖。

NetAssistv4325.exe 属于板卡资料提供的第三方程序，源工程没有随附可证明公开再分发许可的说明，本发布包不附该 EXE。已有该板卡资料的用户可自行将合法取得的程序放在 `tools/NetAssist/NetAssistv4325.exe`；Python CLI/串口工具不依赖启动该 EXE。

现有工具协议说明保留在 tools 内，页首已添加本次发布范围说明。其历史测量、旧模式范围与旧版本构建说明不覆盖当前 Mode18 的现场状态。当前 Python 图片上传/界面仍有0～17限制；Mode18 用板上 KEY3 进入。静态图主要用于 Mode0～16，Mode17/18 的 B 引擎消费 A 的新实时预览。

默认网络配置来自源码：A 为192.168.137.2、B 为192.168.137.3；UDP 图片服务目标端口6002，客户端本地端口6001。桥接工具与 NetAssist 的本机回环端口6000/6003，具体参数见 tools/README_ETHERNET_IMAGE.md 与 ETHERNET_HOST_COMMANDS.md。应根据实际网卡和拓扑配置；本次未连接设备进行传输测试。
