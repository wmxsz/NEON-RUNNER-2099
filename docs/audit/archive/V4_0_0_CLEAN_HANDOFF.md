# v4.0.0-G — 原生赛博天空与测试可信度升级审计

> 当前基线：v4.0.0-G / Android versionCode 36。目标引擎：Godot 4.7.2-stable。

## 本轮发现与改动

### 1. 3D 背景过于平，缺少赛博城市的大气层次

原 `WorldEnvironment` 使用 `Environment.BG_COLOR`，只显示单一背景色。改为 Godot 原生 `Environment.BG_SKY`，挂载 `Sky` 和 `ProceduralSkyMaterial`：

- 顶部深墨蓝 `030717`，天际紫红 `170D38`，地平下沿冷青 `073342`，底部接近黑色 `02040B`。
- 打开 `use_debanding`，减少平滑渐变在低位深/移动设备上的色带。
- `radiance_size` 固定 `Sky.RADIANCE_SIZE_128`，保持 PBR 环境反射足够细腻但不采用大尺寸辐射图。
- 使用 `Sky.PROCESS_MODE_INCREMENTAL`，将环境辐射图生成分散到多帧，避免一次性重建造成明显启动尖峰。
- 天空材质刻意保持静态；章节变化继续通过雾色、环境光、城市网格、建筑电力脊线和赛道霓虹表达。旧的每次主题更新写 `_env.background_color` 在 BG_SKY 下不会改变实际天空，因此移除，避免维护歧义和无效写入。

该改动只用 Godot 原生环境资源和材质，没有新增纹理、实时灯光节点或每帧天空 Shader，不改动固定步长玩法。

### 2. headless 测试可能在异步断言完成前就提前退出

`tests/test_headless.gd` 的 `_run_all()` 包含 `await get_tree().process_frame`，但 `_ready()` 原先以未等待的 `_run_all()` 启动协程，紧接着计算退出码并调用 `quit()`。这会使第一次挂起后的断言有可能不被执行。现在 `_ready()` 先 `await _run_all()`，再输出汇总/退出。

另移除两条始终为真的弱断言：
- 测试模式查询从 `... or true` 改为实际检查查询接口存在且返回 bool。
- 遥测检查从 `Telemetry.report.has("fps") or true` 改为检查真实的公共 `report_updated` 信号和 `high/mid/low` 性能档位。

### 3. 内容模拟测试的帧预算不足

`test_content` 至少包含 25 秒跑局、可选的 6 秒 BOSS 窗口、7 秒复活决策，以及后续生命周期/存档回归。旧测试执行器的 1800 帧上限在 60 FPS 下约为 30 秒，可能在断言全部完成前被 `--quit-after` 强制终止。

- 内容模拟单独使用 5400 帧预算。
- headless 测试场景与主场景启动 smoke test 均使用 `--fixed-fps 60`，匹配固定 60Hz 的测试假设。
- `validate_release_contracts.py` 新增合同：禁止测试使用 `or true`、确保 headless 协程确实 await、确保 content 有足够帧预算、确保场景使用固定 FPS。
- `test_mechanics.gd` 增加原生天空测试，运行时检查 WorldEnvironment、BG_SKY、ProceduralSkyMaterial、128 radiance、incremental 模式、去色带和多段颜色。

## 当前环境已执行的离线验证

- `sh tools/run_offline_checks.sh` 在源码改动后通过，覆盖 Python 工具语法、版本/文档/路径、9 个 GLB 模型、6 张 1024×1024 PBR、12 个 SVG、音效、UID、模式库、玩法/回放/存档/帧率与源码契约。
- 新增契约检查要求 sky 配置与其机制测试一致，headless 测试必须等待异步段，测试代码不能出现始终为真的 `or true`。
- Godot 执行器会明确显示 `SKIP`，因为当前环境找不到与清单匹配的 Godot 4.7.2-stable 可执行文件。

## 尚未完成的验收

当前无法在此容器真正编译 GDScript、导入并运行 sky material/Shader、观察章节过渡画面或测量 Android FPS。必须在 Godot 4.7.2-stable 中打开项目后检查：

1. 天空渐变是否和远景建筑/雾混合自然，没有水平色带、过亮地平或与镜头俯仰不匹配。
2. 首次启动辐射图增量生成是否导致反射在前几帧出现明显变化。
3. 4 个 headless 测试是否运行到自身 summary，并观察 content 是否在退出前完整结束，而不是由帧数上限终止。
4. Android 60/90/120Hz 下的实际平均帧时间、p95、GPU/CPU、内存与温度。

源码/离线检查通过不等于引擎语义编译或实机验收通过。本包是完整源码，不含 APK，也不含发布签名。
