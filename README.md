# 双 FPGA 视觉处理与道路规划系统

Dual-board FPGA vision processing and road planning, targeting PH1P35MDG324.

本仓库整理当前 A/B 比赛主工程源码：A 板负责摄像头采集、ISP、DDR、图像处理和 HDMI 显示；B 板经以太网接收 A 板预览，完成颜色/形状识别与道路规划，并提供 SG90、LED 和蜂鸣器控制。

## 当前版本

- 源码快照：2026-11-04，Mode18 道路规划已合入，保留 Mode0～17、720p/1080p 与 SG90。
- 本次重新读取了用户在 TD GUI 中完成的综合、布局布线和位流结果；当前源码与上次包一致，新增当前配套 A/B 位流及最终报告。
- TD 最终报告：A 建立/保持裕量 +0.100/+0.020 ns，B 为 +0.104/+0.020 ns，建立/保持 TNS 均为0。报告STA覆盖率分别97.32%和97.08%，工具告警另列；这不是全面约束/CDC签核结论。
- 本次位流的上板验证状态尚未确认。
- 本次整理仅做依赖、文件与哈希核验，没有重新综合、仿真或操作硬件。
- 本包只附本次原生TD运行生成的A/B普通及压缩位流，不附旧bit、历史工程、候选版本或AGENTS等agent文件。

## 工程入口

| 板卡 | TD 工程 | 顶层模块 |
|---|---|---|
| A：采集/处理/显示 | [camera_to_dsi_display.al](1080p+720p_PhaseB2_dev/td_project/camera_to_dsi_display.al) | `design_top_wrapper` |
| B：识别/规划/外设 | [camera_to_dsi_display.al](HX1P35A_Cascade_B_clean/td_project/camera_to_dsi_display.al) | `design_top_wrapper` |

器件为 PH1P35MDG324，速度等级 -3；原 `.al` 记录 Anlogic TD 6.2.168116。需要另行安装对应 TD 器件库；不能用通用 Verilog 仿真器替代厂商加密 IP 工具链。

## 快速使用

1. 下载/克隆并完整保留目录层级，分别在 TD 打开 A/B 的 `.al`。
2. 若自行复现，从源码重新综合、布局布线、检查时序并生成位流。A 工程保留 `ofv=70`、宏布局约束及当前物理参数；若 TD 显示 Current70/Default80 的私有参数弹窗，选择 **Cancel** 保留70，Revert 会恢复80。
3. 本次工具生成的配套位流见 [bitstreams](bitstreams/README.md)，其中普通/压缩文件分别列出SHA256。构建完成不等于上板验收；下载和硬件验证由用户执行。
4. 上位机先执行 `python -m pip install -r requirements.txt`；具体工具、串口和以太网接入见[工具说明](docs/HOST_TOOLS.md)。

KEY3 循环 Mode0→…→18→0，KEY4 回 Mode0。Mode17/18 使用 A 板实时摄像头经网络交给 B 计算，SW2 保持 A 本地摄像头显示路径，SW4 切换 720p/1080p。现有 Python 图片客户端模式参数仍限制 0～17；Mode18 可通过 KEY3 进入。

## 功能

| 模式 | 功能 |
|---|---|
| 0～3 | 原图、灰度、亮度色调、自适应阈值二值化 |
| 4～8 | Sobel、局部二值化、腐蚀、开运算、灰度中值滤波 |
| 9～12 | Gamma、直方图均衡、卡通量化、CLAHE-Lite |
| 13～16 | 运动自适应时域滤波/运动区域叠加、锐化、马赛克、双边滤波 |
| 17 | B 板颜色与形状识别，A 板叠加目标及坐标，B 板控制外设 |
| 18 | B 板道路规划，A 板叠加黄色路线及状态点 |

Mode18 要求白色道路、蓝色起点、紫色终点完整入镜；红灯禁止灯牌右侧相邻路段，最短路等长时优先绿灯。状态点：绿色成功、红色无路、紫色端点缺失/编码超限、橙色未收到有效结果。Mode18 不触发 Mode17 外设。端点漏检等现有边界仍需现场验证。

## 文件导航

- [工程结构与阅读说明](docs/ARCHITECTURE.md)
- [构建与依赖](docs/BUILD.md)
- [上位机工具](docs/HOST_TOOLS.md)
- [GitHub 上传步骤](docs/GITHUB_UPLOAD.md)
- [本次TD构建结果](docs/TD_BUILD_RESULTS.md)
- [验证范围与已知限制](docs/VALIDATION.md)
- [第三方代码说明](THIRD_PARTY_NOTICES.md)及[权利说明](RIGHTS.md)
- [逐文件索引](docs/FILE_INDEX.csv)、[HDL 模块索引](docs/HDL_MODULES.csv)、[完整性清单](MANIFEST.sha256.json)

## 权利与许可

作者尚未选择开源许可证，本次不授予新的开源许可。厂商 IP、MiLianKe/UISRC 参考代码及其版权声明按原文件保留；其公开再分发授权需由项目权利人核实，打包检查不能代替授权。详见上述权利及第三方说明。
