# 工程地图与系统职责

> 当前开发基线：v4.3.0-G（Android versionCode=39）。

## 运行入口

| 入口/目录 | 唯一主要职责 | 应避免的耦合 |
|---|---|---|
| `project.godot` | 引擎设置、主场景、Autoload、渲染/物理配置 | 不把运行时玩法逻辑写进配置文件 |
| `RELEASE_MANIFEST.json` | 当前发布版本、主场景、渲染器、视口、Android 包名/ABI/备份策略与资源库存唯一来源 | 不在其他校验脚本中硬编码当前版本或导出身份 |
| `scenes/main.tscn` | 创建主场景根节点 | 不在场景文件里复刻玩法状态 |
| `scenes/main.gd` | 装配对象、绑定信号、协调跨系统生命周期和相机 | 不承载大量独立游戏规则或存档实现 |
| `core/game.gd` | 运行状态机、时间/速度、分数、连击、道具计时、BOSS/DDA | 不直接创建 UI 节点或管理素材导入 |
| `core/config.gd` | 玩法参数、章节配置、任务/成就和默认设置 | 不存放每局可变状态 |
| `core/event_bus.gd` | 少量真正跨模块的动作事件 | 不把所有内部调用都改成全局广播 |
| `core/utils.gd` | 可复用数学/随机数辅助函数 | 不藏有玩法副作用 |
| `core/telemetry.gd` | 设备信息与性能等级 | 不参与关卡是否可解的决定 |
| `entities/player.gd` | 玩家物理、输入动作响应、碰撞体相关逻辑和动画 | 不直接修改任务、钱包或存档 |
| `entities/spawner.gd` | 障碍/芯片/道具的池、生成、碰撞检测和局种子随机 | 不直接操作 HUD、音量和存档 |
| `world/world.gd` | 城市、道路、章节视觉、环境与世界级效果 | 不管理游戏计分状态 |
| `fx/` | 可复位的瞬时视觉效果与后处理 | 效果结束后不能保留跨局可见状态 |
| `systems/input.gd` | 输入采集、手势分类、固定步长队列 | 不直接操作 Player 或 Game |
| `systems/audio.gd` | BGM、音效播放器池、音乐锁与音量 | 不自行推断游戏状态；由协调层通知 |
| `systems/progress.gd` | 持久化、钱包、皮肤归属、任务和成就 | 不读写 Player 的内部物理字段 |
| `ui/` | HUD、菜单、商店/任务/设置视图 | 不实现游戏碰撞和随机生成 |
| `tools/` | 可离线重复执行的资源检查/生成工具 | 不把离线脚本结果误称为 Godot 运行测试 |

## 主数据流

1. `Input` 在渲染帧采集触屏/键盘输入，将动作放入队列。
2. `Main._physics_process()` 在固定 60 Hz 步长排空队列，再驱动 `Game`、`Player`、`Spawner`、`World` 和 `Effects`。
3. `Player` 的真实动作通过 `EventBus` 记录跨模块动作统计；`Spawner` 通过本地信号报告拾取、闪避和击碎事件。
4. `Game.state_changed` 是状态变化的公共通知。`Main` 根据该事件统一切换输入、HUD、音频和菜单表现。
5. `Progress` 负责持久化与任务/成就规则；`Main` 将游戏事件转交给它。UI 发出意图信号，不直接修改存档。

## 状态所有权

- `Game` 是运行状态、距离、分数、连击、道具计时与 Boss/DDA 状态的唯一所有者。
- `Player` 是角色运动与动画瞬时状态的唯一所有者。
- `Spawner` 是活动障碍/拾取物及生成随机序列的唯一所有者。
- `World` 是章节环境和场景呈现状态的唯一所有者。
- `Progress` 是持久化数据的唯一所有者。
- `Main` 是跨系统协调者，不应成为另一份玩法状态的储存处。

## v4.2.0-G 当前维护约定

- 版本身份统一以项目根目录 `RELEASE_MANIFEST.json` 为准；`project.godot` 与 `export_presets.cfg` 是引擎/导出系统要求的镜像配置，由离线完整性工具确认同步。
- 高档目标帧率为 120 FPS，但会收敛到可检测的屏幕刷新率；若查询不可用则使用 60 FPS 保守值。低/中档目标分别为 60/90 FPS。
- 章节环境/材质渐变的参数写入按配置限制在 30 Hz，跨章节和强制复位立即更新；需要通过实际录屏确认平滑性。
- Android 系统返回 `NOTIFICATION_WM_GO_BACK_REQUEST` 与键盘 Esc/P 共用模态优先状态栈；返回时先关闭设置/商店/任务/成就二级面板，不应误恢复遮罩后的跑局。
- 原生物理插值已打开：常规 3D 位姿由 Godot 插值；所有传送/池对象重新定位后必须 reset 插值历史。相机以渲染帧手动平滑，因而单独设为 `PHYSICS_INTERPOLATION_MODE_OFF`；HUD/菜单是原生 Control 画布层，不参与物理插值。Shader-only 的跑道滚动与窗格闪烁使用 `Engine.get_physics_interpolation_fraction()` 单独对齐渲染帧；新增实例类别必须同步更新 native 插值门禁。
- 当前源码包不含 APK；Android 当前只启用 `arm64-v8a`，需要兼容 32 位 ARM 设备时应先重新评估 ABI。推荐使用 Godot 4.7.2-stable；没有该版本的实测记录时，不可标记为可发布。
- `WorldEnvironment` 使用 Godot 原生 `Sky` 与 `ProceduralSkyMaterial` 提供固定的深蓝/紫红/冷青赛博大气渐变；radiance 限制在 128 并增量生成。主题变化通过雾、环境光、网格、建筑与跑道材质表达，避免在主题插值每个 tick 中反复重置天空辐射图。
- `tests/test_headless.gd` 的 `_ready()` 必须 `await _run_all()` 后才能汇总退出；任何测试脚本不得使用 `or true`、`_ok(true, ...)` 或 `assert(true)`。内容长跑测试独立使用 5400 帧预算，所有 headless 场景固定 60 FPS 并使用 Dummy 音频驱动。
- 激光机制测试使用 `Spawner._candidate_pattern_pool()` 构建确定性权重池，不再用一次性随机命中率比较判断平衡。通用 GLB 微粗糙度不得覆盖导入材质已有的 roughness map。
- 本版渲染预算按 `World.set_perf_profile()` 统一设置 DirectionalLight3D 与 Environment Glow：高档四分区阴影/60m/五层辉光，中档双分区/42m/三层辉光，低档关闭阴影与常态辉光；低档超频仅两层辉光。遥测 `report.renderBudget` 应与实际设置一致。
- 赛博跑道高频接缝、刻线、能量导轨和同步标记统一经过 `cyber_line_coverage()`；其 `fwidth()` 边缘覆盖和亚像素淡出用于减少远景闪烁。新增线路不得增加纹理采样，也不得把 4× MSAA 或原生渲染比例降掉作为补救。
