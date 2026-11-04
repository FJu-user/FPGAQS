# 第三方代码与工具

本文件为来源线索索引，不是对全部代码归属的确权，也不构成新的开源许可。

| 组件/线索 | 包内位置 | 本次处理 |
|---|---|---|
| Anlogic 厂商 IP/生成封装 | 两板 ip_source、ph1p35_ddr；A 的 MIPI、HDMI 和部分 ISP RAM | 保留明文接口、加密区、XML、参数、头文件和原版权；另需 TD 厂商库。未解密或扩大许可 |
| MiLianKe / UISRC 参考实现 | 部分 CSI、RGMII、VTC、ISP、signal_delay 等文件头 | 保留原版权及“用于学习”等原说明；公开再分发权利未由本次打包证明 |
| Pillow、pyserial | tools/requirements_uart.txt | 通过包管理器安装，不附原机器的 _vendor 安装副本 |
| NetAssistv4325.exe | 原 tools/NetAssist，当前包不含 EXE | 原工程没有随附公开再分发许可证明，故不附二进制；保留启动脚本及取得后放置位置说明 |
| Logo/初始化图像数据 | A 的 anlogic_logo_* 等表 | 属于当前显示依赖，原样保留；没有据此声明图像/商标归项目作者所有 |

逐文件线索见 [THIRD_PARTY_FILES.csv](docs/THIRD_PARTY_FILES.csv)。自动索引包含版权/作者/加密标记及厂商目录线索；未命中标记不表示一定属于项目作者，目录命中也不表示完成法律归属判断。完整来源权利应以用户掌握的板卡资料、授权协议和各文件原始声明为准。
