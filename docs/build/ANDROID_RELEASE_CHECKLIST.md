# Android 导出与交付检查

> 当前开发基线：v4.3.0-G（Android versionCode=39）。

## 环境

- 使用项目目标版本 Godot 4.7.2-stable。
- 安装与所选 Godot 版本匹配的 Android Export Templates。
- 配置 Android SDK、平台工具与 Godot 所需 Java/JDK 版本。
- 首次打开工程后等待所有 GLB、贴图、音频和 Shader 资源导入完成。

在导出 APK 前先运行 `sh tools/run_offline_checks.sh` 与 `sh tools/run_godot_tests.sh`。若第二条因引擎缺失而 SKIP，不能把该结果视为引擎验收通过。

## 调试 APK

```bash
godot --headless --path . --export-debug Android build/NEON_RUNNER_2099_debug.apk
```

## 发布 APK

1. 在 Godot Android 导出设置中配置发布 keystore 与 alias。
2. 密码和 keystore 不提交到公共仓库、不放入源码 ZIP。
3. 先导出 debug APK 验证安装/启动，再导出 release APK。
4. 安装到目标设备，执行 `REGRESSION_CHECKLIST.md` 的真机测试。
5. 记录 Godot 版本、导出时间、APK SHA-256、设备型号/Android 版本与已知限制。

## 本项目的当前边界

当前 Android 导出预设只启用 `arm64-v8a`；如果目标发行渠道仍要求支持 32 位 ARM 设备，应按 `RELEASE_MANIFEST.json` 修改 ABI 配置并重新跑项目完整性检查。包名、版本号、版本码、自动备份与 APK 文件名也必须与该清单同步。源码包内没有 APK。只有在具有 Godot 4.7.2-stable、导出模板和 SDK 的机器上实际执行并安装成功后，才能把 APK 标记为完成。
