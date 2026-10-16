# 环境准备与本地验收

> 当前开发基线：v4.3.0-G（Android versionCode=39）。

## 需要的工具

- Godot 4.7.2-stable 编辑器/命令行（当前最新稳定补丁；项目 `config/features` 保持兼容系列 `4.7`）。不要使用 4.8 beta 作为发布验收基线。
- 若要导出 Android：匹配版本的 Godot Android Export Templates、Android SDK 和 JDK，并完成官方导出配置。
- 若只做离线检查：Python 3、NumPy、Pillow、trimesh。

## 打开与运行

1. 解压完整源码包，不要只复制 `.gd` 文件；保留 `assets/`、`world/`、`scenes/` 和导入 sidecar。
2. 用 Godot 打开 `project.godot`，等待首次资源导入。
3. 运行主场景，实际体验换道、跳跃、滑铲、碰撞、道具、超频、BOSS、死亡/复活、结算、商店、任务及音乐切换。
4. 游戏结算数据包含本局 seed；若出现特定随机序列问题，先记录 seed，再在同一版本与相同执行路径下复现。

## 可执行的离线校验

```bash
python3 -m py_compile tools/*.py
python3 tools/validate_visual_assets.py
sh tools/run_godot_tests.sh  # 需要清单指定的 Godot 4.7.2-stable；无引擎时只报告 SKIP
```

校验包括 GLB 几何/UV、PBR 贴图、字面资源引用、导入 UID、OGG/WAV 文件、SFX 名称映射、项目与 Android 全套发布身份、玩法随机种子接线、存档 guard、车道控制数值模型，以及全部 GDScript 文件的基础词法结构。

词法结构检查不是 GDScript 解析器；离线通过不能证明引擎导入、脚本语义、Shader、实际音效、碰撞或帧率正确。

## Android 调试版导出

在已配置完整的 Godot Android 环境中，从项目根目录执行：

```bash
godot --headless --path . --export-debug Android build/NEON_RUNNER_2099_debug.apk
```

导出后确认 APK 文件存在、可安装、能够进入主菜单并完成一次完整跑局。当前 Release keystore 字段为空，正式发布需要用户自己的签名配置。源码包本身不包含 APK。

## 测试基础设施说明

之前要求移除的、在当前环境无法实际执行的 Godot 测试场景、测试入口和 CI 测试工作流不在本交付中。当前 Python 离线校验器会继续作为源代码/资源护栏，但不能替代引擎测试。

## 当前环境限制

本次编辑环境没有可用的 Godot 命令行、Android `adb` 或已配置的 SDK，因此未在此处进行引擎导入、GDScript/Shader 语义编译、渲染运行、设备性能实测或 APK 导出。
