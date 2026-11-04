> 发布包补充：本包不附 NetAssist EXE 和本地 `_vendor` Python 安装副本。先按仓库根目录 `requirements.txt` 安装依赖；NetAssist 可从本人已有板卡资料中取得。以下为现有工具协议参考，其中旧构建/测试记录不代表当前 Mode18 主源码的验证结果。图片客户端现有模式参数限制仍为 0～17；Mode18 用板上 KEY3 进入。

# 以太网上位机命令与操作手册

适用硬件：安路 HX1P35A 板卡 + SC500CS 摄像头。

适用工程：`F:\FPGA\project\liuqing\1080p+720p_PhaseB2_dev101\1080p+720p_PhaseB2_dev`。

上位机组合：赛方 NetAssist V4.3.25 + 本工程 `ethernet_image_host.py` 图片桥接程序。

本文整理当前已经支持的静态图片上传、Mode0～16 控制、图片/摄像头切换及原图对比命令。当前没有视频上传或播放命令。

## 1. 启动与连接设置

电脑连接板卡的有线网卡设置为：

| 项目 | 设置 |
|---|---|
| IPv4 地址 | `192.168.137.1` |
| 子网掩码 | `255.255.255.0` |
| 网关、DNS | 直连板卡时可留空 |
| 链路速率 | 1.0 Gbps |
| FPGA 地址 | `192.168.137.2` |

双击本工程 `tools/start_ethernet_image.bat`，保持 Python 窗口运行。也可以在 PowerShell 中执行：

```powershell
cd 'F:\FPGA\project\liuqing\1080p+720p_PhaseB2_dev101\1080p+720p_PhaseB2_dev\tools'
py -3 ethernet_image_host.py --bridge --local-ip 192.168.137.1
```

双击本工程 `tools/start_netassist.bat`，或直接打开赛方 NetAssist：

```text
F:\FPGA\project\liuqing\1080p+720p_PhaseB2_dev101\1080p+720p_PhaseB2_dev\tools\NetAssist\NetAssistv4325.exe
```

NetAssist 设置：

| 项目 | 设置 |
|---|---|
| 协议类型 | UDP |
| 本地主机地址 | `127.0.0.1` |
| 本地主机端口 | `6003` |
| 远程主机 | `127.0.0.1:6000` |
| 发送、接收显示 | ASCII / 文本 |
| 循环发送 | 关闭 |
| HEX 发送、文件数据源 | 关闭 |

点击左侧“打开”。该版本界面可能在打开连接后才显示底部“远程主机”输入框。远程主机填写 Python 桥接地址 `127.0.0.1:6000`。

NetAssist、图片桥接程序、图片转换依赖和本手册均已集中在本工程的 `tools` 目录；Python 桥接按自身位置查找 EXE，工程移动到其他目录后无需修改 EXE 路径。

以下命令均输入 NetAssist 底部发送框。每次只发送一条，再点击“发送”；示例中的多行操作需要逐条发送。

## 2. 帮助与状态查询

```text
HELP
```

查看桥接程序支持的命令。收到帮助回复只证明 NetAssist 能连接本机 Python 程序。

```text
STATUS
```

查询 FPGA 状态。收到包含 `error: 0` 的板端状态，才证明板端协议有正常应答。

`ACCEPTED ...` 表示 Python 收到了命令；它本身不代表 FPGA 已执行完成。来源、Mode 和对比视图在安全帧边界生效。控制命令发送后可等待约 1 秒，再查询 `STATUS`，并观察 HDMI 画面。

## 3. 上传图片

完整格式：

```text
UPLOAD "电脑上的图片完整路径" 分辨率 Mode编号 像素格式
```

参数：

| 参数 | 可用值及含义 |
|---|---|
| 图片路径 | PC 本地图片文件路径，建议始终加双引号 |
| 分辨率 | `720`：1280×720；`1080`：1920×1080 |
| Mode 编号 | `0`～`16`，对应第 5 节的算法 |
| 像素格式 | `rgb565`：每像素 2 字节；`rgb888`：每像素 3 字节 |

程序会自动缩放图片并居中补黑边。可以使用 PNG、JPEG 等 Pillow 能读取的静态图片。

上传 1080 图片，使用原始 RGB：

```text
UPLOAD "D:/test/image.png" 1080 0 rgb565
```

上传 1080 图片，使用 CLAHE：

```text
UPLOAD "D:/test/image.png" 1080 12 rgb565
```

上传 720 图片，使用马赛克：

```text
UPLOAD "D:/test/image.png" 720 15 rgb565
```

使用 RGB888：

```text
UPLOAD "D:/test/image.jpg" 1080 0 rgb888
```

如果省略可选参数，默认是 `720 0 rgb565`。首次测试建议写全参数，并让上传分辨率与当前 HDMI 显示分辨率一致。

等收到 `"result": "READY"` 后再进行下一项操作。上传完成后，程序自动请求设置指定 Mode 并切换到图片来源，不需要另外发送 `IMAGE`。若此前使用了原图或分屏对比，上传不会自动恢复全屏算法视图；需要时发送 `COMPARE processed`。

上传参数不会改变 HDMI 分辨率。HDMI 分辨率仍由板上 SW4 决定；上传 1080 图片不会自动把显示切换到 1080。

720 和 1080 图片可以分别缓存。切换显示分辨率后，图片来源使用该分辨率对应的已发布图片。同分辨率的新图片上传成功后替换旧图片。板卡断电或重新配置后，需要重新上传。

## 4. 摄像头与图片来源切换

| 操作 | 命令 |
|---|---|
| 从上传图片切回摄像头 | `CAMERA` |
| 从摄像头切回已上传图片 | `IMAGE` |

`IMAGE` 使用板上缓存的图片，不需要重新上传；当前显示分辨率对应的图片必须已经上传成功。

来源选择与算法选择相互独立：`CAMERA`、`IMAGE` 不代表切换到 Mode0；`MODE 0` 也不会把上传图片切换成摄像头。`COMPARE processed` 只设置显示视图，不切换来源。

## 5. Mode0～16 算法命令

这些命令对当前选中的来源生效，摄像头和上传图片均可使用。

| 命令 | 算法效果 |
|---|---|
| `MODE 0` | 原始 RGB |
| `MODE 1` | 灰度 |
| `MODE 2` | Tone 亮度增强 |
| `MODE 3` | 帧级自适应二值化 |
| `MODE 4` | Sobel 边缘 |
| `MODE 5` | 局部自适应二值化 |
| `MODE 6` | 腐蚀 |
| `MODE 7` | 开运算 |
| `MODE 8` | 中值滤波 |
| `MODE 9` | Gamma 校正 |
| `MODE 10` | 直方图均衡化 |
| `MODE 11` | Cartoon Lite 卡通效果 |
| `MODE 12` | CLAHE-Lite V2 |
| `MODE 13` | Motion / 时域运动自适应处理 |
| `MODE 14` | Sobel 锐化 |
| `MODE 15` | Mosaic 马赛克 |
| `MODE 16` | Bilateral 双边滤波 |

Mode13 是时域算法，建议使用有运动的摄像头画面观察；静态图片不适合验证运动响应。

## 6. 原图与算法结果对比

| 命令 | 显示效果 |
|---|---|
| `COMPARE processed` | 全屏显示当前算法结果 |
| `COMPARE raw` | 全屏显示未经算法处理的原图 |
| `COMPARE split` | 左半原图，右半算法结果 |

如果切换 Mode 后看不到算法效果，先发送：

```text
COMPARE processed
```

因为 `COMPARE raw` 会让显示保持原图，即使算法 Mode 已经改变。官方 Logo 和分辨率文字仍位于显示后级。

## 7. 常用操作组合

以下每组命令均逐条发送。

### 7.1 图片切回摄像头，恢复原始画面

```text
CAMERA
MODE 0
COMPARE processed
```

### 7.2 摄像头使用 CLAHE

```text
CAMERA
MODE 12
COMPARE processed
```

### 7.3 摄像头切回缓存图片，显示马赛克

```text
IMAGE
MODE 15
COMPARE processed
```

### 7.4 对比图片的锐化效果

```text
IMAGE
MODE 14
COMPARE split
```

### 7.5 显示图片原图

```text
IMAGE
COMPARE raw
```

### 7.6 恢复全屏算法结果

```text
COMPARE processed
```

### 7.7 上传新图片并观察双边滤波

先发送：

```text
UPLOAD "D:/test/new_image.png" 1080 16 rgb565
```

等待 `READY`，再发送：

```text
COMPARE processed
```

## 8. STATUS 字段说明

| 字段 | 含义 |
|---|---|
| `error` | `0` 表示本次协议请求未报告错误 |
| `source` | `0`：摄像头；`1`：上传图片 |
| `mode` | 状态返回的算法编号，范围 0～16 |
| `compare` | `0`：算法结果；`1`：原图；`2`：左右对比 |
| `resolution` | `0`：720；`1`：1080 |
| `image_valid` | 图片有效状态 |
| `received_bytes` | 图片传输接收字节数 |
| `next_sequence` | 下一数据包序号 |
| `ready_image_id` | 已发布的 READY 图片标识 |
| `displayed_image_id` | 显示图片标识 |

切回摄像头后，`image_valid` 仍可能为 `1`，因为图片缓存可以继续保留。判断来源时查看 `source`，并结合 HDMI 实际画面确认。

## 9. 常见问题

### 发送 MODE 0 后仍显示上传图片

Mode0 表示原始 RGB，不代表摄像头来源。发送 `CAMERA` 切回摄像头。

### 发送 COMPARE processed 后仍显示上传图片

该命令只设置算法结果视图。发送 `CAMERA` 切换来源。

### 发送 IMAGE 后没有显示目标图片

确认当前 SW4 显示分辨率，以及该分辨率的图片是否上传成功。需要时重新上传并等待 `READY`。

### Mode 改变，但画面效果没有改变

发送 `COMPARE processed`，等约 1 秒后查询 `STATUS`。不要只根据 `ACCEPTED` 判断板端是否生效。

### 上传时其他命令没有立即回复

当前桥接程序同步执行上传。等待 `READY` 或错误结果后再发送其他命令，并保持循环发送关闭。

### 中文或带空格路径

使用双引号包住完整路径，例如：

```text
UPLOAD "D:/我的文档/测试图片.png" 1080 0 rgb565
```

### 上传与显示的分辨率不一致

上传命令不改变 SW4。选择正确的板上显示分辨率，或上传当前分辨率对应的图片。

## 10. 实现依据

命令语法依据本工程 [ethernet_image_host.py](ethernet_image_host.py)，Mode 定义依据 [pixel_chain_v1.v](../user_source/hdl_source/pixel_chain_v1.v)，原图/左右对比规则依据 [video_algorithm_wrapper.v](../user_source/hdl_source/video_algorithm_wrapper.v)。更多协议和工程说明见 [README_ETHERNET_IMAGE.md](README_ETHERNET_IMAGE.md)。
