# 霓虹疾驰 2099（NEON RUNNER 2099）

本仓库用于 Godot 原生项目《霓虹疾驰 2099》的源码管理。

## 当前状态

- 目标基线：`v4.3.0-G` 完整源码包
- 引擎路线：Godot 4.x
- 默认分支：`main`
- 本仓库与旧的 Three.js/Vite/Capacitor 网页项目 `wmxsz/cyber-run` 相互独立。

> 注意：仓库初始化不等于源码已导入。只有当完整项目文件（包括 `project.godot`、场景、脚本、资源和 `RELEASE_MANIFEST.json`）上传并核验后，才算完成源码导入。

## 项目导入验收

1. ZIP 完整性与 SHA-256 校验。
2. 检查 `project.godot`、主场景、资源引用和发布清单。
3. 使用目标 Godot 版本执行无界面导入/解析检查。
4. 检查 Shader 与 GDScript 错误。
5. 在具备 Android 导出模板和 SDK 的环境中验证 APK 导出。
6. 真机运行、帧率、画面与操作体验仍需单独验收；CI 通过不代表真机测试通过。

## 目录约定

导入完成后，Godot 项目文件应直接放在仓库根目录，确保根目录可找到 `project.godot`。
