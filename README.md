# 霓虹疾驰 2099（NEON RUNNER 2099）

> 当前开发基线：v4.3.0-G（Android versionCode=39）。

**发布元数据唯一来源：[`RELEASE_MANIFEST.json`](RELEASE_MANIFEST.json)。** 该文件统一记录项目身份、版本号、主场景、渲染器、竖屏视口、Android 包名、ABI、备份策略和资源库存；项目设置与 Android 导出预设由离线检查自动对齐。

## 当前版本概览

v4.3.0-G 在原生渲染预算与赛博跑道抗闪烁基础上，新增四组跨模块修复：回放记录先写临时文件、回读校验再原子替换，并保留上一份可验证记录供损坏恢复；所有 Godot 测试入口强制使用独立存档/回放路径，避免测试删除或覆写玩家数据。移动端应用失焦/暂停会取消半截触控手势；跑道新增原生 MultiMesh 机械横肋与钛合金紧固件，在两个额外绘制调用内强化近景 3D/PBR 高光细节，并按现有道路 shader 周期同步滚动。

本轮源码、资源和最终 ZIP 干净解压后的离线检查属于静态验收。当前环境没有可用的 Godot 4.7.2-stable 可执行文件，且官方二进制分发主机无法从执行环境访问，因此本版 GDScript 语义编译、Shader 实际编译/截图、Android APK 和设备 FPS/p95/温度仍未完成；不会以离线检查替代实际运行结论。

## 工程地图

```text
core/       游戏状态机、配置、事件总线、工具与性能遥测
entities/   玩家、障碍/芯片/道具池、碰撞与生成
world/      章节环境、道路、城市建筑、交通与窗格 Shader
fx/         雨、速度线、碎屑、尾迹、冲击波与后处理
systems/    输入、音频、存档、任务、成就、钱包
ui/         HUD、菜单、商店、任务、设置
scenes/     主场景装配入口
assets/     GLB 模型、PBR 贴图、OGG 音乐、WAV 音效
icons/      Android 启动器图标资源
tools/      离线资源、模式、发布元数据、项目完整性检查
build/      Android 导出目标目录（当前不包含 APK）
docs/       当前开发/发布指南与历史审计归档
```

详细职责见 [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)，生命周期约定见 [`docs/RUN_LIFECYCLE.md`](docs/RUN_LIFECYCLE.md)，代码规约见 [`docs/DEVELOPMENT_GUIDE.md`](docs/DEVELOPMENT_GUIDE.md)。

## 打开与检查

推荐使用 **Godot 4.7.2-stable**（截至 2026-10-16 的 4.7 系列最新稳定补丁；Godot 4.8 仍是 beta，不作为当前验收基线）打开 `project.godot`，等待导入完成，再运行主场景（F5）。触屏为左右滑动换道、上滑/轻点跳跃、下滑滑铲；键盘方向键/WASD 可用于桌面检查，P/Esc 暂停，O 超频，R 在结算后重开。

每次改动后，从项目根目录运行：

```bash
sh tools/run_offline_checks.sh
```

该命令执行 Python 工具语法、资源路径、模型/贴图、音频、UID、模式库、版本元数据、GDScript 基础词法和源码合同检查。若检测到与 `RELEASE_MANIFEST.json` 中推荐补丁一致的 Godot 可执行文件，还会追加 headless 导入与主场景冒烟测试；缺少引擎时会明确显示 SKIP，不把静态检查写成编译通过。

打包前必须将 ZIP 解压到干净目录，在该目录重跑同一命令。回归门槛见 [`docs/REGRESSION_CHECKLIST.md`](docs/REGRESSION_CHECKLIST.md)。

## 当前交付边界

这是**源码交付包，不是 APK**。当前执行环境未找到推荐的 Godot 4.7.2-stable 和 ADB，所以 GDScript 语义编译、场景/着色器实际导入、真实跑局、Android 安装、声音听感、GPU 帧时间、温度和长时间稳定性尚未被实测。`export_presets.cfg` 中发布 keystore 字段保持为空，私钥与密码必须由开发者在本地安全配置，不进入源码包。

Android 构建说明见 [`docs/build/ENVIRONMENT_SETUP.md`](docs/build/ENVIRONMENT_SETUP.md) 和 [`docs/build/ANDROID_RELEASE_CHECKLIST.md`](docs/build/ANDROID_RELEASE_CHECKLIST.md)。本版变更见 [`docs/CHANGELOG.md`](docs/CHANGELOG.md)，旧版本更新记录单独保存在 [`docs/CHANGELOG_HISTORY.md`](docs/CHANGELOG_HISTORY.md)，旧审计统一放在 [`docs/audit/archive/`](docs/audit/archive/)；历史材料不代表当前版本的验收结果。
