# 霓虹疾驰 2099 — v2.8.1-G 全项目升级机会审计

- **审计对象**：`v2.8.1-G`，Android `versionCode=23`
- **审计模式**：只扫描与登记问题；本轮没有修改游戏源码、资源或项目配置
- **审计日期**：2026-10-16
- **检查方式**：源码路径/调用关系审读、资源与模式目录校验、音频解码/元信息、离线回归脚本、项目导出配置核对
- **边界**：当前容器未发现可用的 Godot/Godot 4、GDScript 专用解析器或 Android ADB，因此不能做 Godot 语义编译、运行场景、GPU/音频实机测量或 APK 安装测试。

## 摘要

本轮记录 **35 项升级/风险/质量改进项**：

- **P0：1 项** — 高置信度的脚本类型契约冲突，可能阻断 GDScript 编译。
- **P1：6 项** — 玩法正确性、回放语义、关卡公平性、运行验收、Android 发布准备和高刷新率运动平滑。
- **P2：21 项** — 性能热路径、音频架构、存档可靠性、设备适配、可维护性等。
- **P3：7 项** — 美术升级路线、无障碍、构建可重复性和低风险清理。

**结论：当前离线检查通过不等于 Godot 可编译。P0 应是下一轮统一修复的第一项。** 本报告不将“建议测量”的性能候选项冒充为已证实的帧率问题。

## 证据与基线检查

执行命令：

```sh
sh tools/run_offline_checks.sh
```

本次基线检查输出：

- 9 个 GLB 模型、6 张 1024×1024 PBR 贴图通过现有资源检查；模型资产统计合计约 25,596 个三角面。
- 9 首 OGG 背景音乐、12 个 WAV 音效通过现有资源/音频检查；9 首 OGG 文件合计约 12.12 MB（文件字节大小之和，不代表解码后的驻留内存）。
- 55 处字面资源引用、30 个唯一导入 UID、版本字段 `2.8.1-G / versionCode 23` 一致。
- 26 个障碍模式、47 个障碍定义、24 条芯片线通过结构性目录扫描；该扫描器自己注明不模拟跳跃/滑铲时间和连续碰撞。
- 16 个 GDScript 文件通过基础引号/括号/空白扫描；这不能替代 Godot 语法和语义编译。
- 音频格式/解码、随机数参考向量、车道数值契约、新局状态契约与现有回归护栏通过。

## P0 — 必须先处理

### A01. DDA 模式字符串与布尔值混用（高置信度类型契约错误）

- **位置**：`scenes/main.gd:400–434, 673–676`；`core/game.gd:73–90, 116–119`；`systems/input.gd:54–81`
- **证据**：`compute_dda() -> String` 返回 `""`、`"gentle"` 或 `"hardcore"`；但 `_start_run()` 声明 `var run_dda: bool = compute_dda()`。同一个布尔变量随后被传入 `Game.dda_gap_for(mode: String)`、`Game.dda_unlock_for(mode: String)` 和 `Game.start_run(dda: String)`。
- **影响**：GDScript 静态类型契约不一致，可能在语义编译时直接失败；即使改成动态值，也无法正确维持 DDA 模式。
- **统一修复方向**：拆成 `dda_mode: String` 与 `dda_enabled: bool`；前者只传给 Game/Spawner，后者只记录用户开关；加类型/行为单测。
- **验证要求**：Godot 4.7.x headless editor/import/主场景启动实际编译。Godot 的静态类型提示用于约束变量类型，见[官方 GDScript 静态类型文档](https://docs.godotengine.org/en/latest/tutorials/scripting/gdscript/static_typing.html)。

## P1 — 高优先级正确性与交付问题

### A02. 回放格式保存 DDA 布尔值而不是实际模式

- **位置**：`systems/input.gd:69–81, 250–301`；`scenes/main.gd:400–434, 440–460`
- **证据**：录制格式的 `dda` 字段是 `_recording_dda: bool`；重放时 `main.gd` 将 `trace.dda` 转成 bool，再把结果当作 Game 的 DDA mode 字符串使用。
- **影响**：除了 A01 的类型冲突，回放文件也无法重建原局到底使用了默认、`gentle` 还是 `hardcore` 模式。
- **方向**：回放 schema 升级，分开保存 `dda_enabled` 和 `dda_mode`；新增 `game_version`、`config_hash`/玩法规则版本，拒绝不兼容记录；校验所有字段类型。

### A03. 道具避障尝试用尽后仍无条件投放

- **位置**：`entities/spawner.gd:615–641`
- **证据**：循环最多尝试 6 次并不断修改 `dz`；循环结束后不管 `_lane_blocked()` 是否仍为真，都立即将 `pu.active = true` 并放置道具。
- **影响**：极端密集/重叠对象场景下，可能将道具放进仍被障碍占据的深度窗口，造成难以拾取或视觉重叠。
- **方向**：用候选车道+深度列表做有限搜索；最终必须再次验证；无安全位置就跳过/延迟投放，而不是强制放置。添加“所有候选都被阻挡”的回归测试。

### A04. 现有障碍库检查不是完整的动态可解性证明

- **位置**：`tools/validate_pattern_catalog.py`；`docs/REGRESSION_CHECKLIST.md`
- **证据**：现有检查覆盖模式数量、障碍类型、车道以及部分同深度硬障碍组合，但脚本明确说明它不是连续时间碰撞求解器。
- **影响**：无法证明玩家在最高速度、低重力、冰面、移动障碍、激光、BOSS 波、换道惯性等条件下总有可行路线。
- **方向**：新增离线离散动作可达性模拟/确定性 Godot 集成测试，测量最小反应时间、轨迹可达性与碰撞盒；对失败 seed 自动保存最小复现记录。

### A05. 缺少真实 Godot 语义编译与运行验收

- **位置**：整个项目；`tools/run_offline_checks.sh`、`tools/validate_visual_assets.py`
- **证据**：现有 GDScript 检查为词法结构和自定义契约；工具报告明确说明它们不覆盖 Godot 语义编译、场景/着色器编译或设备性能。
- **影响**：A01 这样的类型问题可以绕过现有离线扫描，不能以当前 PASS 作为“源码可运行”的证明。
- **方向**：在固定 Godot 4.7.x 构建中加入 `--headless --editor --path ... --quit` 导入/解析步骤、主场景 smoke test、日志错误门禁和导出冒烟测试。

### A06. Android 发布签名与构建参数尚未形成可交付闭环

- **位置**：`export_presets.cfg:28–35, 64–69`
- **证据**：Android release keystore、release alias/password 为空；min SDK / target SDK 字段为空；目前仅启用 `arm64-v8a`；仓库 `build/` 下没有已验收的 APK。
- **影响**：不能证明可导出可发布的签名版本；支持设备范围和系统版本下限不够明确。
- **方向**：发布签名信息通过本地/CI secrets 配置（不要把 keystore 或密码提交进仓库）；明确 min/target SDK、ABI 策略，构建后检查签名、包名、版本号、安装与启动。Godot 官方 Android 导出文档要求配置 release keystore 以发布非调试签名包：[Android 导出文档](https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_android.html)。

### A07. 固定 60 Hz 物理模拟没有启用物理插值

- **位置**：`project.godot:37–39`；`scenes/main.gd:78–106`；`entities/spawner.gd:397–477`；`world/world.gd:308–372`
- **证据**：项目设置了 60 次/秒物理 tick，但未发现 `physics/common/physics_interpolation` 开启；障碍、移动交通和 MultiMesh 变换主要在物理 tick 写入。
- **影响**：在 90/120 Hz 屏幕或渲染帧率与物理 tick 不同步时，运动可能出现 60 Hz 阶梯感，尤其是高速移动对象。
- **方向**：先在真机采集 60/90/120 Hz 对比；评估启用 Godot 物理插值，并对回收/传送位置正确调用 reset；MultiMesh/动态实例需单独确认插值正确性。官方说明见[物理插值快速入门](https://docs.godotengine.org/en/4.7/tutorials/physics/interpolation/physics_interpolation_quick_start_guide.html)和[2D/3D 插值说明](https://docs.godotengine.org/en/4.7/tutorials/physics/interpolation/2d_and_3d_physics_interpolation.html)。

## P2 — 高价值性能、可靠性与架构升级

### A08. 背景音乐与音效共用一个带压缩/混响的 `GameMix`

- **位置**：`systems/audio.gd:86–130`
- **证据**：背景音乐播放器和 8 个短音效播放器都路由到 `GameMix`；压缩器、混响和硬限幅器串在同一个总线上。
- **影响**：SFX 瞬态可能触发整条总线压缩，使背景音乐音量随爆发音效一起泵动；混响也无法分别控制音乐和短音效。
- **方向**：拆分 `Music`、`SFX`、`UI` 总线，分别控制音量/动态处理，最终通过 Master limiter 保护总峰值；实际以扬声器与耳机听感验收。压缩器会降低越过阈值的声音，见[Godot AudioEffectCompressor 文档](https://docs.godotengine.org/en/stable/classes/class_audioeffectcompressor.html)。

### A09. 8 声道音效池用“最老声音优先回收”，无事件优先级

- **位置**：`systems/audio.gd:282–310`
- **证据**：8 个 voice 全忙时直接选择时间戳最老的声道，不区分死亡、BOSS、复活、重要提示和芯片拾取。
- **影响**：高密度音效同时发生时，关键反馈可能被普通音效截断。
- **方向**：增加音效优先级、同类冷却/合并、不可打断事件标记，并统计 voice stealing 的次数。

### A10. 九首 OGG 全部预载，启动/常驻内存成本需测量

- **位置**：`systems/audio.gd:9–27`
- **证据**：全部 9 首 OGG 通过常量 `preload` 引入，文件字节合计约 12.12 MB（压缩资源大小）。
- **收益/代价**：避免章节首次切换时加载路径，但可能增加启动加载工作与资源常驻内存；实际峰值内存不等于压缩文件大小。
- **方向**：测量冷启动、首曲时间和低内存设备峰值后，考虑只预载当前曲/BOSS 曲，下一章异步预取；没有数据前不盲目改回。

### A11. 存档同步文件 I/O 可能造成局内短卡

- **位置**：`systems/progress.gd:190–263, 361–420, 427–449`
- **证据**：`ConfigFile.save()`、备份删除/重命名都同步执行；开局、BOSS、生涯结算、超频、复活和任务重置等路径会触发保存。
- **影响**：慢闪存/系统繁忙时可能在游戏线程产生尖峰帧时间。
- **方向**：加入 dirty 标志和节流合并；对货币/购买等关键事务仍需确保提交可靠，并在暂停/后台/结算安全点冲刷；测量真实磁盘尾延迟。

### A12. 存档失败回滚不是所有统计更新的完整事务

- **位置**：`systems/progress.gd:361–420` 与 `537–564`
- **证据**：购买、装备和任务领取做了局部回滚；但 `on_run_end()` 修改 `recent_runs`、统计与任务进度后调用 `_save()`，未整体恢复原状态；`on_run_start()` 等调用也没有完整事务快照。
- **影响**：存档写盘失败时，内存中显示的统计/任务可能已变化，持久化却没提交；后续再次保存还可能间接写入它们。
- **方向**：明确各事件的提交语义：快照/事务回滚，或保留 dirty 数据并显示“尚未保存”、重试；覆盖磁盘满、权限失败、临时文件重命名失败的故障注入测试。

### A13. 章节过渡期间每个物理帧重复更新大量材质/环境参数

- **位置**：`world/world.gd:790–845`；调用处 `scenes/main.gd:97,104`
- **证据**：章节末 15% 的 `mix` 随距离每个模拟 tick 变化，触发环境雾/背景/日光、道路参数、车道材质、门框材质和 `_themeable_materials` 列表的遍历写入。
- **影响**：过渡窗口内产生 CPU/渲染服务器参数更新开销；具体是否造成瓶颈必须测量。
- **方向**：考虑合并全局 shader 参数、共享材质变体、按可见对象更新或以合适误差阈值更新；保持色彩过渡连续并对比画面。

### A14. 障碍警示脉冲每个物理 tick 写多个材质参数

- **位置**：`entities/spawner.gd:658–660, 715–720`
- **证据**：每次 Spawner 更新都遍历 `GLOW_PHASES`，执行 `sin()` 并设置每个材质的 `emission_energy_multiplier`。
- **方向**：在材质 shader 中以统一时间参数表达脉冲，或按可见/活跃状态降低 CPU 更新；需保证实例间相位与颜色正确。

### A15. 碰撞、近身闪避和滑铲统计分别遍历障碍池

- **位置**：`entities/spawner.gd:756–877`
- **证据**：先遍历全部障碍池收集碰撞，再分别遍历障碍池统计 near-miss 与 slide-dodge。
- **影响**：每个 60 Hz 模拟帧出现重复遍历；对象池规模扩大时成本随池规模线性增加多次。
- **方向**：用性能采样确认是否为热点；若是，将 near-miss/slide-dodge 状态融合进单次候选遍历，或维护活动对象列表，必须保留统计不重复和碰撞早退语义。

### A16. 全屏后处理每像素多次屏幕采样与噪声计算

- **位置**：`fx/post_fx.gd:29–38`；`fx/post_fx.gdshader:18–44`
- **证据**：运行/濒死时整屏处理，主色以外还对偏移 UV 采样 R/B 通道，并做每像素 hash grain、sin scanline 和色调/暗角计算。
- **方向**：按设备等级/设置测量 GPU 帧时间；低档可关闭色差/颗粒或使用简化通道；对照截图确认画面提升是否值得成本。

### A17. 建筑窗灯 shader 的像素级噪声/波形成本需要 GPU Profiling

- **位置**：`world/building_windows.gdshader`
- **证据**：窗格生成包含多次 hash、周期函数、导数/边缘计算；建筑是大面积背景，屏幕覆盖率会放大成本。
- **方向**：在低/中档降低远景窗口细节、减少动态噪声、预生成静态变体或使用 LOD；需在低/中端 Android GPU 实测。

### A18. 没有明确的 shader/材质预热验收

- **位置**：所有 `.gdshader`、动态场景/章节入口、`fx/post_fx.gd`
- **影响**：首次进入章节、首次出现特效或切换材质变体时可能出现 shader compilation/PSO 卡顿（需设备实测，不认定为已发生）。
- **方向**：记录冷启动与首次出现特效的帧时间；必要时建立渐进预热路径并避免一次性预热造成启动更慢。

### A19. 设备画质分级只看内存/CPU 核数，未充分考虑 GPU、刷新率和热降频

- **位置**：`core/telemetry.gd:123–166`
- **证据**：首轮等级按内存和核心数选择，运行中只看平均帧时间/慢帧比例下调等级；高档设置 `Engine.max_fps = 0`。
- **影响**：相同 RAM/CPU 核心数的设备可能有不同 GPU 能力；高档不设明确帧率目标可能增加耗电/发热；当前也没有热状态读取与长时间负载验证。
- **方向**：基于真实设备矩阵设计 60/90/120 FPS 目标、GPU 热点与温度/电量测试；保留滞回防抖，加入省电/高刷明确选项。

### A20. Telemetry/Main 直接访问其他系统的私有字段/私有方法

- **位置**：`scenes/main.gd:59–62`；`core/telemetry.gd:137–166`
- **证据**：Main 调用 `Telemetry._apply_grade()`；Telemetry 直接写 `effects._rain`、`effects._speed_lines`。
- **影响**：模块内部改名/重构会破坏其他模块，测试需要构造完整对象图。
- **方向**：公开 `apply_quality_profile()`、`set_rain_budget()`、`set_speed_line_budget()` 之类的稳定接口；减少私有状态跨模块引用。

### A21. 输入队列满时静默丢弃最旧操作

- **位置**：`systems/input.gd:191–194`
- **证据**：队列达到 `QUEUE_MAX=16` 时直接 `remove_at(0)`，无计数、告警或合并策略。
- **影响**：极端连触/设备卡顿期间，用户已发出的动作可能被静默丢弃；虽然被丢动作不会进入已执行输入回放，但手感难排查。
- **方向**：记录溢出计数，按动作类型合并冗余 lane input、优先保留 jump/slide 时序，并把溢出状态打入遥测。

### A22. 触屏距离阈值与安全区需要真实多屏测试

- **位置**：`systems/input.gd` 中的触控阈值与 `project.godot:26–30`；`scenes/main.gd` 的安全区适配逻辑
- **影响**：逻辑 viewport 固定 412×915 且强制竖屏，刘海/圆角/短屏、平板、不同密度和高刷新率设备的触控容差/面板空间未被自动化覆盖。
- **方向**：构建 360×740、390×844、412×915、432×960、平板和挖孔屏布局测试；触控阈值按逻辑像素或屏幕短边比例统一并实测。

### A23. 主角仍是程序化网格+代码驱动动作，不是完整骨骼动画管线

- **位置**：`entities/player.gd`（约 785 行）
- **影响**：可以靠网格部件和 pivot 做状态动作，但跑动、跳跃、滑铲、落地、受击、死亡、滑板和不同皮肤动作的连贯程度存在上限。
- **方向**：在碰撞盒与模型比例验收完成后，建立骨骼模型、AnimationPlayer/AnimationTree 和状态混合；保持触屏响应优先于动画长度。

### A24. 缺乏按距离/屏幕占比设计的 LOD 和低档资产变体

- **位置**：`world/world.gd` 的楼宇/交通/地标生成；`assets/models/*.glb`
- **影响**：远景建筑和重复飞行器可使用更低细节；单一模型变体不一定是所有机型/距离的最优方案。
- **方向**：以实际 GPU 和屏幕占比测量为准，增加远景简化模型、实例化/剔除规则与低档材质；保持中近景不模糊、不破坏清晰度。

### A25. 回放缺少构建/配置指纹，跨版本回放可能误导

- **位置**：`systems/input.gd:69–81, 250–301`
- **证据**：schema 只含 `schema/seed/dda/frames/events` 等；没有游戏版本、物理参数版本、配置哈希、引擎版本。
- **方向**：记录 game version、build id、config hash、physics tick rate、DDA 模式，回放前检查兼容性；不要把跨版本不一致误认成随机非确定性。

### A26. 大型脚本承担职责过多，继续迭代的回归成本高

- **位置**：`entities/spawner.gd`（约 891 行）、`world/world.gd`（约 861 行）、`entities/player.gd`（约 785 行）、`scenes/main.gd`（约 676 行）、`systems/progress.gd`（约 583 行）、`ui/menus.gd`（约 511 行）
- **方向**：在 P0 与引擎编译稳定后，按行为边界拆成 `PatternCatalog/ObstaclePool/CollisionQuery`、`CityThemeController/BuildingField/TrafficSystem`、`RunLifecycle/ReplayRecorder/SettingsCoordinator` 等；先加接口测试再搬代码，避免大规模一次性重写。

### A27. 音频预载/音量调整还缺少启动、混音和低端设备实测

- **位置**：`systems/audio.gd:9–27, 43–63, 102–130`
- **证据**：v2.8.1 增加统一 3 dB makeup gain、每类 SFX gain 与 -1 dBFS limiter；混音和声道逻辑离线通过但未实际听音。
- **方向**：用手机扬声器/耳机测量音乐、UI、跳跃、撞击、BOSS、复活在滑块 25/50/75/100% 的相对响度和瞬态；分总线后再校准目标响度，不要无限增加总增益。

### A28. 高档 MSAA 4x、1024 PBR 贴图与全屏后处理组合需要设备数据

- **位置**：`project.godot:41–49`、`core/telemetry.gd:137–166`
- **影响**：这些单项设置不一定有问题，但叠加后可能增加 GPU 带宽/功耗；当前分级依据不是实测 GPU 时间。
- **方向**：以低中高端设备矩阵采集 GPU/CPU frame time、p95/1% low、内存、温度和耗电后设定默认档，不以“画质高”推断性能好或以模糊画面换性能。

## P3 — 长期产品与维护质量

### A29. 菜单缺少可配置控制与减少动态效果选项

- **位置**：`ui/menus.gd`、`systems/input.gd`、`fx/post_fx.gdshader`
- **方向**：补齐减少运动/关闭色差与闪光、振动开关、触控灵敏度、操作可访问性和高对比 UI 选项；验证不会降低重要危险预警清晰度。

### A30. 八章的差异需要从色调扩展到独特场景/玩法语言

- **位置**：`core/config.gd` 的 `THEMES`；`world/world.gd:790–845`
- **证据**：章节已改变颜色、雾、光照和部分素材着色；但主要世界结构由同一程序化城市/道路系统复用。
- **方向**：在稳定后增加少量高辨识度地标、建筑轮廓、环境元素和机制组合，而不是简单增加霓虹颜色或多边形数量。

### A31. 模型/材质验证缺少自动截图与视觉差异对比

- **位置**：`tools/validate_visual_assets.py`、`tools/generate_visual_models.py`、`docs/ART_PIPELINE.md`
- **证据**：现有验证覆盖模型三角面数、贴图尺寸/接缝与资源接线，但不评估实际渲染下的比例、法线、材质反射、过曝、动画/碰撞盒一致性。
- **方向**：Godot headless/虚拟屏幕条件允许时生成固定相机角度的 golden screenshots，做图像差异；人工验收角色、BOSS、夜/雨/章末过渡。

### A32. 导出 SDK/架构和版本信息应固定为可复现构建策略

- **位置**：`export_presets.cfg:28–35, 64–69`、`project.godot:11–13`
- **方向**：决定只支持 ARM64 还是增加 ABI；明确 min/target SDK；记录 Godot 精确版本/导出模板版本；发布 APK/AAB 后自动检查版本号、签名、包体积并在设备安装启动。Google Play 的新应用发布格式要求及签名细节会随平台规则变化，发布前以[官方 Godot Android 导出文档](https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_android.html)和当前商店要求为准。

### A33. 音频总线初始化假设过强

- **位置**：`systems/audio.gd:102–130`
- **证据**：只有当 `GameMix` 总线 effect count 为 0 时，才一次性加 compressor/reverb/limiter。若以后项目/插件预先放了一个效果，这个分支会跳过所有三种预期效果，而不是按名称补齐。
- **方向**：改为显式 mixer layout 或逐项检测/创建效果，按名称和顺序确认总线，避免宿主配置变化造成音量行为差异。

### A34. 世界光照存在重复赋值

- **位置**：`world/world.gd:108–110`
- **证据**：`sun.shadow_enabled = true` 连续赋值两次。
- **影响**：目前不太可能造成运行错误，属于维护噪声。
- **方向**：统一由质量档控制阴影，把注释与真正执行的设备 profile 对齐。

### A35. 动态菜单重复创建 UI 节点的成本应测量

- **位置**：`ui/menus.gd:render_missions()`、`render_achv()`、商店渲染函数和 `_panel_content()`
- **影响**：切换面板时创建/销毁多组 Label/Button/容器会产生短时分配；不是每帧热路径，优先级低于运行中渲染与碰撞。
- **方向**：先测面板打开瞬间的帧时间；只有确实卡顿时，才改为列表项池化或缓存节点。

## 建议的统一修复顺序

1. **批次一：P0/P1 正确性** — A01–A07：DDA 类型/回放 schema、道具安全投放、引擎语义编译、障碍可达性、物理插值实验、Android 导出验收。
2. **批次二：数据/音频可靠性** — A08–A12、A25、A33：总线拆分、音效优先级、预载策略测量、保存事务和回放指纹。
3. **批次三：运行时性能** — A13–A21、A28：先接 profiler，再决定主题材质、警示脉冲、碰撞遍历、全屏后处理、窗灯 shader、预热和质量档策略。
4. **批次四：美术/架构/用户体验** — A22–A24、A26、A29–A35：多屏验收、角色骨骼动画、LOD、脚本拆分、无障碍、章节差异和视觉回归。
5. 每批修复完成后，用 Godot 4.7.x 语义编译与真实设备回归重新验收，再冻结/打包；不要只依靠源码搜索或词法扫描声明完成。

## 本轮结论

本轮没有修改游戏源码，项目基线仍为 v2.8.1-G。现有离线检查通过，但 A01 已表明离线护栏不足以判定源码可运行；下一轮应先统一修正 DDA 的类型与回放契约，然后使用真实 Godot 编译器验证全工程，再按优先级批量修复。
