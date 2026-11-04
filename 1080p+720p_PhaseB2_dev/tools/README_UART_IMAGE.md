> 发布包补充：本包不附 NetAssist EXE 和本地 `_vendor` Python 安装副本。先按仓库根目录 `requirements.txt` 安装依赖；NetAssist 可从本人已有板卡资料中取得。以下为现有工具协议参考，其中旧构建/测试记录不代表当前 Mode18 主源码的验证结果。图片客户端现有模式参数限制仍为 0～17；Mode18 用板上 KEY3 进入。

# 串口图片显示与算法对比

## Phase 3 PC 工具更新（2026-09-30）

启动入口仍是 `start_uart_image.bat`。先关闭已打开的旧工具窗口，再启动新版本。本次重点更新 PC 工具，并配套核对当前 RTL 的 Window8 接收/累计 ACK 路径；未运行综合、P&R 或生成 bit。离线验证与实施边界详见 [Phase 3 报告](../verification/uart_image_phase3/UART_IMAGE_PHASE3_REPORT.md)。

- 默认 **Safe = 921600 / RGB565 / Window1**。**Fast = 2M / RGB565 / Window8**，**Quality = 2M / RGB888 / Window8** 为待实板验证的候选；Custom 可手动设置。2M/3M 和 Window8 必须由板上固件支持。
- GUI 实时显示速度、效率、ACK RTT、重试、PC 接收 CRC、整图 CRC 和 ETA；已保留工作线程并改为 250 ms 刷新。FPGA 包 CRC/framing 计数当前不可获取，显示 N/A。
- 同图重复上传/预加载会查询 FPGA 的尺寸、格式、valid 和内容 ID；匹配则直接报告 READY、跳过上传。GUI **Force upload** 或命令行 `--force-upload` 可强制发送，测速时必须使用。
- 默认将每张上传的汇总 JSON 和逐包 CSV 保存到 `verification/uart_image_phase3/measurements/`，失败也保留诊断。`--metrics-dir` 可指定路径。
- Window8 已由当前 `user_source/hdl_source/uart_packet_rx.v` 的双 bank 接收队列和 `uart_image_control.v` 的累计 ACK 路径支持；发送端会先用 `CAPS` 协商能力，旧 bitstream 会明确拒绝并回退到 Safe/Window1。Window16 仍未实现，也不会被命令行接受。

```powershell
python tools/uart_image_sender.py --port COM15 --image D:/images/test.png --both --preset Safe
python tools/uart_image_sender.py --port COM15 --image D:/images/test.png --both --preset Fast
python tools/uart_image_sender.py --port COM15 --image D:/images/test.png --both --preset Quality
# 真实测速入口：每轮强制完整上传，两张参考图保存到该次报告目录
python tools/benchmark_uart_image.py --port COM15 --image D:/images/test.png --baud 921600 --format rgb888 --repeats 10
```

`--baseline-flush` 恢复逐包 flush 用于 A/B 对照；它只比较 flush 行为，不等同于原 Phase 2 软件。32 位内容 ID 存在碰撞概率，严格重测或怀疑命中时使用 Force upload。RGB565 参考图仍是量化后再展开的真实 FPGA 输入；要保留 RGB888 色彩精度请明确选择 Quality 或 `--format rgb888`。

本次按用户要求只做代码与离线验证，真实速度、2M/3M 十次稳定性和比赛最终参数仍待接板测量。

当前工程位于 `D:\qiansaichuankou\1080p+720p_PhaseB2_dev`。2026-09-29 已将 Phase 2 四槽缓存、SW4 保图、后台跨分辨率上传和实际显示确认接入活动 RTL，并配套 PC sender。当前交付为源码与功能仿真；尚未生成 Phase 2 bitstream，尚未上板。磁盘中的历史 bitstream 不会自动包含这些改动。

## Phase 2 使用入口

上传速度优化：当前源码新增 **2000000（优先试用）/3000000** 两档。必须先用当前RTL重新生成并烧录bit，再重启电脑端工具，在Baud中选择新档位。默认仍为921600以兼容旧固件；旧固件拒绝新档位时工具提示更新bit或选择921600。精确算法比较继续使用RGB888；需要更短加载时间且接受RGB565量化时，可选RGB565。READY日志会显示总耗时和有效KiB/s。具体边界、理论时间及测试见 `verification/uart_image_phase2/UPLOAD_SPEED_REPORT.md`。

生成并加载 Phase 2 配置后可使用以下命令。旧固件仍支持单图；缺少 STATUS_EXT 时工具明确拒绝 `--both`，不会开始第一张上传。

```powershell
python tools/uart_image_sender.py --port COM5 --image "D:\images\test.png" --both
python tools/uart_image_sender.py --port COM5 --image "D:\images\test.png" --both --show
python tools/uart_image_sender.py --port COM5 --image "D:\images\test.png" --resolution 1080 --preload
```

`--both` 依次等待两张图片 READY，核对各自 generation/image_id，不等待图片实际显示；传入 `--mode`/`--compare` 时会先应用对应显示设置，但不会自动切换 Source。`--show` 在两张就绪后请求 UART；该选项表示发出显示请求，不表示已经确认 DISPLAYED。`--reference-dir` 可指定两张精确参考图的输出目录，默认保存在原图片旁，文件名为 `test_720_reference.png`、`test_1080_reference.png`。

`--preload` 单张上传只等待 READY；跨当前 SW4 分辨率上传同样需要 Phase 2 固件。未加 `--preload` 的单图上传保留“上传后选择 UART 并确认显示”的用法。第二张上传失败会保留并报告第一张已成功的结果；BUSY 会有限重试，超时不自动发送清缓存或 ABORT。

GUI 新增 **Preload 720 + 1080**、**Show Camera**、**Show UART**。上传或预加载完成后会应用当前界面选中的 Mode/Compare；Show UART 之前也会再次应用一次，因此选择 `wipe` 后切换图片即可生效。GUI 由一个工作线程顺序访问串口。

连接修订：GUI在连续操作之间保持同一个COM连接，每次操作前先HELLO确认；遇到空闲波特率回退则在同一连接上有限重探测115200/921600/2000000/3000000。切换COM口或目标波特率时释放旧连接，通信异常后释放句柄。新增 **Disconnect** 按钮；使用SSCOM或其他串口工具前，先点击Disconnect或关闭本窗口。更新脚本后必须关闭旧工具窗口，再运行start_uart_image.bat；无需为此重新生成bit。该修订通过10项连接策略测试与14项上位机回归，尚未实板复测。

`--status` 优先查询同一快照的四页扩展状态，旧固件显示兼容提示。当前主机和活动 RTL 测试见 `verification/uart_image_phase2/results.json`，接口与恢复约定见同目录 `INTERFACE_CONTRACT.md`。

以下说明适用于当前 Phase 2 源码；运行旧 bitstream 时仍遵循旧固件行为。

## 推荐使用：图片发送工具

1. 接好板卡 USB 串口与 HDMI，启动新 FPGA 配置。串口使用板载 UART，FPGA RX=J1、TX=H1，8N1、无流控。
2. 双击同目录 `start_uart_image.bat`。当前电脑已有 Pillow，pyserial 已放在 `_vendor`；换电脑可执行 `python -m pip install -r tools/requirements_uart.txt`。
3. 选择正确 COM 口、图片，默认 Safe 使用 RGB565、921600；需要无 RGB565 量化的算法比较时手动选 RGB888。GUI 的单图上传可用 **720p**、**1080p** 或 **Follow SW4** 按钮选择目标尺寸；选择 Follow SW4 时才读取板卡 SW4。图片会适配到 1280×720 或 1920×1080。
4. 点击 **Upload image**，等待日志显示 `DISPLAYED`。整个传输完成、校验正确且实际换帧后才报告显示成功。
5. 选择 Mode 0～16 和比较方式，再点击 **Apply mode / compare**。`processed` 为算法图，`original` 为原图，`wipe` 为左半原图、右半算法图（同一图像坐标，不挤压缩放）。原有 OSD 继续叠加。

图片工具默认保持比例、黑边补齐，处理 EXIF 方向和透明背景。图片旁会保存 `*_fpga_reference.png`，这是缩放、量化后真正送进算法的参考图。RGB565 速度更快，但颜色会量化，评估算法优先选 RGB888。

KEY1 切换 Camera/UART 显示意图；当前尺寸缺图时临时显示 Camera，图片就绪后自动回到 UART。720p 与1080p 各自保留最近发布的图片，切 SW4 不清缓存，也不改变 Mode/View。KEY3、KEY4、KEY2 保持原有算法控制。全局复位会清缓存。比较方式同时适用于两种图源。

刚开始上传时继续显示旧画面。中途断线、错包或整图 CRC 失败不会把未完成图片发布为新画面。可靠模式自动重发丢失响应的数据包。串口高速模式空闲约 5 秒后回到 115200，工具重连会自动探测和协商。

命令行示例（COM5 替换为实际串口）：

```powershell
python tools/uart_image_sender.py --port COM5 --image "D:\images\test.png" --mode 13 --compare wipe
python tools/uart_image_sender.py --port COM5 --compare original
python tools/uart_image_sender.py --port COM5 --source camera
python tools/uart_image_sender.py --port COM5 --status
```

在 921600、8N1 下，仅像素的理论传输时间：720p RGB888 约 30 秒、1080p 约 67.5 秒；RGB565 分别约 20 秒、45 秒。包头、转义、确认及电脑调度还会增加耗时，实际时间以工具日志为准。遇到连接不稳定可选 115200，耗时约增加到 8 倍。

## 使用安路资料中的 SSCOM 发送文件

普通 JPG/PNG/BMP 文件不能直接发送，先生成协议文件：

```powershell
python tools/uart_image_sender.py --image "D:\images\test.png" --resolution 720 --format rgb888 --export "D:\images\test.aimg"
```

Phase 2 可预加载与当前 SW4 不同的尺寸；旧固件要求尺寸一致。关闭图片发送工具以释放串口，等待至少 6 秒，或复位板卡。SSCOM 设置 **115200、8 数据位、1 停止位、无校验、无流控**；通过“发送文件”按原始二进制发送 `.aimg`。不要选择文本转换、自动换行或把文件内容转换成 ASCII 十六进制。

`.aimg` 使用与可靠模式相同的分包及 CRC，附加处理间隔字节，并关闭回复。因此 SSCOM 无需理解确认报文；末尾自动请求显示图片。这种方式没有重传和进度确认，DDR 长时间拥塞、丢字节或尺寸不符会使上传失败，需要完整重发；推荐使用上面的可靠发送工具。SSCOM 文件发送仅保证本协议的二进制兼容，尚未在实物上验证软件的发送行为。

## 实现要点

串口 → 单块 1536 字节接收缓存 → 校验/重传 → 后台 DDR 槽 → 完整图片 CRC → DDR 写完成屏障 → 缓存发布 READY → 安全帧切换 → 实际算法输出回执 DISPLAYED。

720p 两槽地址为 3200000、4600000，1080p 两槽为 25000000、29000000（地址单位16位，128位一拍加8）。分配器保护 FRONT 及仍在读的旧槽；正常上传失败不影响已发布图片。

活动 DDR 配置和生成参数已同步为 STRICT，并修复命令/写数据 ready 的联合接收。Camera writer 加入逐帧写范围保护。末 beat 读回的完成保证依赖厂商 STRICT 排序契约；厂商加密控制器内部行为、带宽和时序仍需后端及实板验证，详见 Phase 2 审计。

对比直接使用算法链同延迟的原始 RGB，保留 C20 输出时序。静态图片每次显示刷新都提供新的处理帧序号，使切换到需要统计/预热的模式后能继续建立状态；更换图片或图源会清理跨图像状态。需要预热的模式仍保留原算法的过渡行为，刚切换的首帧不代表最终稳定效果。

## 验证与异常定位

验证结果及边界见 `verification/uart_image_phase2/UART_IMAGE_PHASE2_REPORT.md`。统一运行：

```powershell
python verification/uart_image_phase2/run_checks.py
```

包含完整720p/1080p逐像素 reader、Camera边界、协议/四槽/分页状态、跨域握手、算法上下文和KEY2回归，耗时数分钟。测试使用功能性 RAM/FIFO/DDR 模型；顶层可见 HDL 检查将加密厂商 IP 作为黑盒，不能代替 TD 综合、时序及电气验证。旧 Phase 1 全套脚本含已废弃的 SW4 清图断言，不作为当前固件验收入口。

- 无响应：检查 COM 口、是否加载新配置、USB 串口驱动；关闭占用串口的软件。
- 尺寸错误：检查 BEGIN 是否为1280×720或1920×1080，以及像素格式和总长度；旧固件还要求与SW4一致。
- DDR 错误：新图片不会发布。若 DDR 通路永久不返回响应，需要复位板卡后重新上传；系统不会强行释放未完成事务，以免把旧返回数据混入显示。
- 图片已准备但未显示：检查 HDMI 时钟/复位及视频路径是否运行。工具区分“已准备”和“已显示”。

Phase 2 修改前文件位于 `verification/uart_image_phase2/baseline`；更早的 Phase 1 前备份位于 `verification/uart_image_input/baseline`。原设计讨论文档是方案依据，实际协议和功能以本说明、实现报告及当前源码为准。
