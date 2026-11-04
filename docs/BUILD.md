# 构建与依赖

## 推荐入口：TD GUI

分别打开仓库根目录下 A/B 的 `td_project/camera_to_dsi_display.al`。器件 PH1P35MDG324、速度等级 -3，工程记录 TD 6.2.168116。TD 安装、厂商原语、器件数据库和工具许可不在仓库中。

两个 `.al` 仅把 `<Project Path>` 的原机器绝对路径改为 `.`。源码注册、编译顺序、引脚/SDC、宏约束和运行参数没有修改。原 `.al` 是 TD 的原生格式，含 `UsedInP&R` 等不符合通用 XML 解析器的字段；完整性脚本按文件引用检查，不重写整个 XML。

A 原有 `ofv=70`、pack effort high、seed0、route effort normal 及宏布局配置已保留。Current70/Default80 弹窗选择 Cancel 保留70。当前用户GUI运行已完成布局布线及位流生成，报告见TD_BUILD_RESULTS.md。原生结果的正裕量只适用于本次工具、配置与既有约束，不替代未覆盖路径和告警的核查。

本包不附完整运行目录、原始日志、数据库和历史快照；只单独导出本次配套位流与选定报告。若重新构建，应由TD自行生成新的Runs，避免安装旧运行缓存。

## 初始化数据

保留 `user_source` 内所有 HEX/DATH/MIF/DAT、DDR ROM、IP 参数和仿真文件表。`td_project` 根目录保留源工程中的初始化文件；B 工作目录额外放入其原 DDR IP 内 `ddrphy_cfg_rom.txt` 的逐字节副本。文件清单标注该新增副本。

## 可选 A 构建脚本

A 的现有 `rebuild.py` 与 `build_templates/` 原样保留。Python 3.10及以上可使用以下准备命令：

```powershell
python -B .\1080p+720p_PhaseB2_dev\rebuild.py --prepare-only --work C:\fpga_build\A_prepare
```

`--work` 必须指向尚不存在的新目录。该步骤只生成隔离构建输入，不运行 TD。完整构建入口为：

```powershell
python -B .\1080p+720p_PhaseB2_dev\rebuild.py --td "C:\YourTD\bin\td_commands_prompt.exe" --work C:\fpga_build\A_build
```

将 TD 路径替换为实际安装路径。脚本包含与既有设计层级和端点数量相关的审计断言；本次只验证准备阶段，未执行新 Mode18 版本的完整脚本流程。B 以原生 TD 工程为入口，本包不新增未经验证的 B 一键构建脚本。

## 本地完整性检查

在仓库根目录执行 `python -B scripts/verify_package.py`。它使用 Python 标准库，核对文件哈希、两份原生工程引用和 IP-XACT 文件列表；检查成功只说明发布包完整，不等于综合、时序或硬件验收。
