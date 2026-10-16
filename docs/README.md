# 工程文档导航

> 当前开发基线：v4.3.0-G（Android versionCode=39）。


## 历史维护约定：v4.2.0-G 原生渲染预算与跑道抗闪烁

- 方向光和辉光必须通过 `World.set_perf_profile()` 分档，并可从 Telemetry 的 `renderBudget` 诊断快照确认实际生效配置。
- 道路细小蚀刻/导轨的屏幕空间抗闪烁必须使用 `cyber_line_coverage()`，不能以降低渲染分辨率或关闭 4× MSAA 替代。
## 当前维护入口

- [`../RELEASE_MANIFEST.json`](../RELEASE_MANIFEST.json)：版本、Android build number、Godot 系列、物理频率与资源清单的唯一发布元数据来源。
- [`RELEASE_STATUS.md`](RELEASE_STATUS.md)：当前交付边界、已经完成的静态检查和仍需引擎/设备验收的项目。
- [`CHANGELOG.md`](CHANGELOG.md)：当前版本改动。
- [`CHANGELOG_HISTORY.md`](CHANGELOG_HISTORY.md)：归档的旧版本更新明细。
- [`PROJECT_MAP.md`](PROJECT_MAP.md)：目录职责、系统边界和主要数据流。
- [`ART_PIPELINE.md`](ART_PIPELINE.md)：模型/PBR 生成、几何预算和视觉验收。
- [`RUN_LIFECYCLE.md`](RUN_LIFECYCLE.md)：新局、暂停/继续、复活、结算状态契约。
- [`DEVELOPMENT_GUIDE.md`](DEVELOPMENT_GUIDE.md)：修改顺序、代码风格、模块所有权和版本更新流程。
- [`REGRESSION_CHECKLIST.md`](REGRESSION_CHECKLIST.md)：统一离线、引擎、游戏模拟和 Android 验收清单。
- [`build/ENVIRONMENT_SETUP.md`](build/ENVIRONMENT_SETUP.md)：Godot 与 Android 工具链准备。
- [`build/ANDROID_RELEASE_CHECKLIST.md`](build/ANDROID_RELEASE_CHECKLIST.md)：APK 签名、构建、安装与发布门槛。

## 当前版本审计

- [`audit/V4_3_0_CLEAN_HANDOFF.md`](audit/V4_3_0_CLEAN_HANDOFF.md)：v4.3.0-G 测试数据隔离、原子回放恢复、移动触控失焦清理和实体跑道细节。
- [`audit/archive/V4_2_0_CLEAN_HANDOFF.md`](audit/archive/V4_2_0_CLEAN_HANDOFF.md)：v4.2.0-G 原生阴影/辉光分档、赛博跑道远景抗闪烁和渲染预算遥测的历史审计。
- [`audit/archive/V4_1_0_CLEAN_HANDOFF.md`](audit/archive/V4_1_0_CLEAN_HANDOFF.md)：v4.1.0-G 确定性机制测试与 PBR 材质保真历史记录。
- [`audit/archive/V4_0_0_CLEAN_HANDOFF.md`](audit/archive/V4_0_0_CLEAN_HANDOFF.md)：v4.0.0-G 原生赛博天空和 headless 执行器修复的历史记录。
- [`audit/archive/V3_9_0_CLEAN_HANDOFF.md`](audit/archive/V3_9_0_CLEAN_HANDOFF.md)：v3.9.0-G 相机冲击反馈与震动设置历史记录。
- [`audit/archive/V3_7_0_CLEAN_HANDOFF.md`](audit/archive/V3_7_0_CLEAN_HANDOFF.md)：v3.7.0-G 装甲/跑道纹理层级与原生矢量 UI 的历史记录。
- [`audit/archive/V3_6_0_CLEAN_HANDOFF.md`](audit/archive/V3_6_0_CLEAN_HANDOFF.md)：v3.6.0-G 原生 PBR 细节遮罩与颜色保真历史记录。
- [`audit/archive/V3_1_0_CLEAN_HANDOFF.md`](audit/archive/V3_1_0_CLEAN_HANDOFF.md)：v3.1.0-G 的历史交付记录；其中对“15 轮”的表述已在报告顶部更正说明中澄清。

- [`audit/archive/V3_8_0_CLEAN_HANDOFF.md`](audit/archive/V3_8_0_CLEAN_HANDOFF.md)：v3.8.0-G 原生细节法线与触屏设置体验历史记录。

## 历史审计

当前版本以 [`audit/V4_3_0_CLEAN_HANDOFF.md`](audit/V4_3_0_CLEAN_HANDOFF.md) 为当前基线报告；所有旧版本审计、阶段记录、扫描报告和执行摘要统一归档在 [`audit/archive/`](audit/archive/)，历史更新明细单独放在 `CHANGELOG_HISTORY.md`。这些归档文件只用于历史追溯，不是当前问题状态来源。当前状态以 `RELEASE_MANIFEST.json`、`RELEASE_STATUS.md` 和当前版本审计报告为准。

