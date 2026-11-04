# 本次 TD GUI 构建结果（2026-11-04）

从用户指定主工程的两份 `td_project/camera_to_dsi_display_Runs` 重新读取本次原生运行。没有调用 TD 重跑，也没有修改主工程。

| 项目 | A板 | B板 |
|---|---:|---:|
| 位流生成时间（本地，+08:00） | 17:45:35 | 17:38:18 |
| 建立裕量 SWNS / ns | +0.100 | +0.104 |
| 保持裕量 HWNS / ns | +0.020 | +0.020 |
| 建立/保持总负裕量 / ns | 0 / 0 | 0 / 0 |
| 报告STA覆盖率 | 97.32% | 97.08% |
| Slice | 19949 / 21216（94.03%） | 19584 / 21216（92.31%） |
| REG | 24644 | 16290 |
| ERAM | 95 / 108 | 26 / 108 |
| DSP | 24 / 40 | 4 / 40 |
| PLL | 5 / 6 | 4 / 6 |

两板均为PH1P35MDG324、-3、顶层design_top_wrapper、TD6.2.168116。最终报告为Routed、Slow/Fast双角检查，工具报告无multi-drive和abnormal timing path；不能由此推断没有全部工程风险。

## 来源关联

两板的综合及物理运行 `.prj` 与当前 `.al` 引用文件集合一致，A106项、B49项；当前源码、约束、IP和构建模板与上次发布包原始输入哈希一致。user_source 没有晚于该次原生综合开始的修改时间。`.al` 的保存时间较晚，但字节与上次原始输入一致；没有把保存时间本身当作源码变化。

本次捕获输入哈希，不冒充TD运行当时生成的签名输入清单。每个普通/压缩位流均核对phy_1与best_result字节相同，并在文件清单中记录源文件哈希。详细关联依据见evidence/BUILD_ASSOCIATION.json。

## 告警和签核边界

- A综合142条告警（其中13条critical），物理21条（其中3条critical）；B综合140条（其中6条critical），物理6条（无critical）。计数来自本次run.log的WARNING/CRITICAL-WARNING诊断行，不合并重复诊断。
- 重要类别包括RGMII的IDDR/ODDR复位规则提示、A隐式声明、Logo ROM同时设置INIT_FILE/FILL_ALL、时钟混合扇出/局部路由、PLL引脚及较高利用率等。完整逐条诊断见evidence/TD_WARNINGS.csv。
- STA覆盖率未达100%。既有约束下被分析路径的裕量为正，不代表未覆盖路径、所有CDC和所有外部电气条件都已验证。
- 本次仅保留并说明这些现有告警，未修改RTL、约束或私有参数，也未擅自重跑实现。本包是当前源码与工具产物的可审阅归档，不是零告警的硬件签核或上板验收声明。

## 报告

`reports/A`、`reports/B` 含本次routed.ts、routed.area、route_flow.status、route.qor、final_timing.rpt、exceptions.timing、route_clock_utilization.txt和gate.area。选定文本报告中的原机器工程根路径替换为`${PROJECT_ROOT}`并统一LF；数值及实例名保留，原报告SHA256记录于完整性清单。完整Runs、原始日志、数据库和历史工程不随仓库发布。
