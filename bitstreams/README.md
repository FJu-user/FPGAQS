# 当前配套 A/B 位流

仅包含用户2026-11-04这次TD原生运行产物，普通与压缩文件均保留原字节；phy_1与best_result副本一致。原生Runs、数据库和旧位流不在本包。

| 板 | 文件 | SHA256 |
|---|---|---|
| A | [camera_to_dsi_display_A.bit](A/camera_to_dsi_display_A.bit) | e485bb7abc3389fd61849c4b83c3f6ec0da5f332b4f125813a62c87bf25541d0 |
| A | [camera_to_dsi_display_A_compress.bit](A/camera_to_dsi_display_A_compress.bit) | 3e11e1d4c34e2a7d9eefe2003855b8462da8bf19c9669ae3b3bb436a818d39a7 |
| B | [camera_to_dsi_display_B.bit](B/camera_to_dsi_display_B.bit) | 01ebc06f4ac3389451ecf1eb5ca37381bfb876e1c63060edb09cf00d14fbd274 |
| B | [camera_to_dsi_display_B_compress.bit](B/camera_to_dsi_display_B_compress.bit) | 993897c021fd3773937f585fdd6d4f75c28031cce7cb209c3d96f58a0e361843 |

A为17:45:35生成、B为17:38:18生成；本地时区+08:00。生成与时序报告核对完成，硬件状态未确认。详细告警/覆盖率见../docs/TD_BUILD_RESULTS.md。请根据实际板卡和工具要求选择普通或压缩格式，不要把A/B相互替代。
