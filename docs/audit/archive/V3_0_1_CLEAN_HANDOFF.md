# v3.0.1-G — 干净源码交付与稳定工具链基线

> 当前开发基线：v3.0.1-G（Android versionCode=26）。推荐验收引擎：Godot 4.7.2-stable。

当前审计报告路径由 `RELEASE_MANIFEST.json` 的 `current_audit_report` 字段指定，并由完整性检查器验证。

## 本版变更

1. 将推荐 Godot 稳定补丁写入 `RELEASE_MANIFEST.json`。截至 2026-10-16， [官方 Godot 下载归档](https://godotengine.org/download/archive/) 标明 Godot 4.7.2 为稳定版，而 Godot 4.8 仍为 beta；[4.7.2 官方维护公告](https://godotengine.org/article/maintenance-release-godot-4-7-2/) 建议升级。项目的 `config/features` 保持 `4.7`，这是兼容系列标识，不是引擎补丁版本。
2. 统一源码版本 `3.0.1-G` 与 Android `versionCode=26`，所有当前维护入口更新为同一基线；旧 `v3.0.0-G` 审计报告移入 `docs/audit/archive/`，历史记录保留。
3. 将离线检查器改为从发布清单读取推荐 Godot 稳定补丁，只有匹配补丁号的引擎才计为本版发布验收；缺少引擎或版本不匹配时明确显示 `SKIP`。
4. 清理交付内容中的 `.godot` 缓存、Python 字节码缓存、APK/临时构建产物和凭据；保留原生资源、导出预设和 `.uid` sidecar。

## 已执行的离线验收

- 发布清单 JSON、项目版本、Android 版本名/版本码、包名、主场景、渲染器、视口、ABI、备份策略与资源库存一致。
- 运行 Python 工具语法检查、固定 `res://` 引用、脚本/Shader UID sidecar、模型/PBR、美术库存、音频资源、障碍模式库、DDA/回放/存档/生命周期/性能合同、Markdown 本地链接与 GDScript 基础词法检查。
- 9 个 GLB、6 张 PBR 贴图、9 首 OGG 与 12 个 WAV 已从最终干净解压目录检查；音频使用 FFmpeg/FFprobe 完整解码。
- 最终 ZIP 完整性检查通过，并在干净解压目录再次运行全部离线检查。
- 清洁检查确认源码包不包含 APK、`.godot` 导入缓存、Python `__pycache__`/`.pyc`、Git 工作区元数据或发布签名私钥。

## 明确未完成的验收

当前容器无法解析/连接官方引擎分发地址，且没有 Godot、ADB 或 Android 导出工具。因此没有完成 Godot 4.7.2-stable 的 GDScript 语义编译、资源导入、Shader 编译、主场景运行、Android APK 导出安装或真机听感/帧率/温度测试。离线通过不等同于零缺陷或发布认证。

## 最终判断

本包是当前能在本环境中做到的干净、可追溯、静态检查通过的源码交付。任何声称“保证没有任何问题”的结论都需要以指定稳定引擎的语义编译与目标设备实测为依据；在这些运行验收没有完成前，本报告不做零缺陷承诺。
