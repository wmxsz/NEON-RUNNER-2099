# v3.5.0-G — Godot 原生功能优先与全项目赛博精致度审计

> 当前开发基线：v3.5.0-G（Android versionCode=31）。推荐验收引擎：Godot 4.7.2-stable。

## 本轮目标

这轮不是重做所有已合格的资产，也不是为“原生化”而删除赛博特色。目标是逐类确认：Godot 原生功能是否可以更稳定地完成常规任务；必须自定义的赛博表现是否只在需要时承担额外成本；所有改动是否具有对应回归门禁。当前源码审查基于项目中的实际场景、脚本、GLB/PBR 资源、生成器、验证工具和发布文档。由于当前执行容器没有 Godot 4.7.2-stable 可执行文件，下文会把静态确认与引擎/真机验收分开写。

## 本轮已落地的源码纠正

### 1. 启用 Godot 原生物理插值

- `project.godot` 保持固定 `60` 物理 tick，新增 `common/physics_interpolation=true`。其目标是让固定时步下的可见 3D 运动在 60/90/120 Hz 渲染频率之间更平顺，不是改变玩法模拟频率或碰撞逻辑。
- `Player.reset()` 在重置完位置、动画和皮肤姿态后调用 `reset_physics_interpolation()`，防止新局/复活时从上一局的旧位姿拉出拖影。
- 城市近景/远景根节点的循环重定位后重置根节点插值；楼体、导轨、窗台、天线、远景塔楼的 MultiMesh 槽位在回收或坐标基准重置时调用 `MultiMesh.reset_instance_physics_interpolation()`。
- 地标、飞行器、城市标牌和数据拱门在跨区回收后重置节点插值；冲击波、碎片、尾迹粒子在复用对象池槽位时也重置节点插值。
- 障碍、芯片和道具的 MultiMesh 只在“隐藏/重新激活”状态边沿重置具体槽位；对象正常移动期间仍使用原生插值，不每帧重置。道具的多部件槽位也统一进行初始化/隐藏，避免第二部件沿用默认位置。
- 相机继续在 `_process()` 中手动阻尼跟随与朝向，因此显式设置 `PHYSICS_INTERPOLATION_MODE_OFF`，避免对相机重复平滑；HUD、菜单和屏幕效果 CanvasLayer 同样不使用物理变换插值。

### 2. 移除常态全屏重复后处理

- Godot 原生 `Environment` / `WorldEnvironment` 已承担 Filmic 色调映射、环境光、雾与 Glow，项目还使用原生 4× MSAA、16× 各向异性过滤及 PBR `StandardMaterial3D`。
- 旧版自制屏幕 Shader 在每次游戏运行时都显示，会持续声明 `hint_screen_texture`，并对全屏重复计算锐化、对比度、饱和度和色彩偏移。这与原生 Environment 的色彩职责有重叠，也引入屏幕读取与额外绘制成本。
- 新版将其缩减为高速/超频专用的青/红蓝通道色差强调。正常速度时 `ColorRect` 完全隐藏，不绘制含 `hint_screen_texture` 的画面层；高速度/超频时只读取中心画面和两个色差偏移采样。不会把“零参数全屏处理”误称为无成本。
- 自定义 Shader 仍保留在确实需要程序化赛博表现的地方：能量跑道导轨/数据脉冲、楼宇窗格变化等。这些视觉不属于 Godot 原生 Environment 的职责，因而合理保留。

### 3. 全面复查补强：初始化姿态与所有建筑装饰槽位

第二遍核对原生插值调用点时，又找到容易漏掉的边界：建筑主楼在回收时已复位插值，但天线、屋顶单元和阶梯顶部三类装饰的槽位之前没有逐实例复位；部分 GLB 地标、飞行器、招牌、拱门及远景 MultiMesh 的初始姿态也在进入场景树前赋值。当前已补齐这些情况：初始实例缓冲在加入场景后显式复位；每次建筑回收时，主楼和所有关联装饰（顶部、天线、屋顶、信标、外立面导轨、檐线）都复位插值，避免旧位置残影或拉伸。

对应的离线回归门禁已扩展，明确要求顶部/天线/屋顶槽位具备复位调用，并保护地标、飞行器、标牌与拱门的初始姿态复位。这是本次复查中新抓出的边界问题，不能只用上一轮“城市队列模拟正确”替代这一层检查。

### 4. 高刷显示下的 Shader 运动同步

第二次全面复查还发现：即使 Node/MultiMesh 已启用原生物理插值，Shader uniform（赛博跑道 `scroll` 与楼宇窗格 `time_`）不会自动获得相同的变换插值。若只在 60Hz 物理 tick 更新，这两类视觉动画在 90/120Hz 屏幕上仍可能保留 60Hz 步进感。

当前在 `World.update()` 中保存前一物理样本与本步增量，在 `Main._process()` 中通过官方 `Engine.get_physics_interpolation_fraction()` 在渲染帧插值这两个 uniform；菜单/游戏进行时启用，暂停、结算/复活等待态冻结在最新物理样本。跑道周期使用正模数处理，确保滚动跨越周期边界不会倒跳。新增合同检查锁定这一连接点。该改动属于源代码层的时间采样同步，是否实际消除所有视觉抖动仍要在 Godot 运行时和 60/90/120Hz 设备上观察。

### 5. 为什么没有把玩家强行换成 CharacterBody3D

项目的跑酷角色是固定物理步长下的三车道动作模型：横移、跳跃、滑铲、受击与回放由确定性逻辑计算，障碍命中也是按玩法窗口计算；角色不是依靠刚体推挤、斜坡行走或复杂物理接触来控制。把它重写成 `CharacterBody3D` 并不会自动提高精度，反而会引入碰撞求解、滑动/地面判定和回放确定性的新变量。这里更合适的做法是保留明确的玩法运动模型，使用 Godot 原生节点变换/物理插值做表现，再由离线/引擎测试分别验证。若将来要增加真实碰撞物理、复杂地形或物理推动，再重新评估 `CharacterBody3D`。

### 6. 原生功能判定原则

- **优先采用原生：**`Environment`/`WorldEnvironment`/Filmic/Glow/Fog、`StandardMaterial3D` PBR、4× MSAA、各向异性过滤、`MultiMesh` 批处理、`GPUParticles3D`、CanvasLayer/Control/StyleBox、Tween、AudioStreamPlayer/AudioServer 总线、ConfigFile，以及物理插值和 reset API。
- **保留自定义：**赛博能量跑道和窗格的定制 Shader、程序化装甲/障碍外观、章节主题混合、固定步长的跑酷运动/输入记录与分析逻辑。它们承担明确的美术/玩法职责；不应为了“原生”而把独特视觉改成通用默认效果。
- **暂不新增：**没有设备基准时，不给每个霓虹件叠加实时灯光，也不加深度/屏幕读取类全屏效果，不盲目提高阴影分辨率或粒子数量。先用真机 GPU/CPU 测量定位瓶颈，再提升对应效果。

## 全项目功能分类与结论

| 子系统 | 实际实现/现有能力 | 本轮结论 |
|---|---|---|
| 项目/显示 | Godot 4.7 系列、Mobile renderer、竖屏 412×915、原生 3D 比例 1.0、4× MSAA、16× 各向异性过滤 | 保留；这些是清晰度基线，不为降档轻易关闭抗锯齿/缩小分辨率 |
| 物理/运动 | 固定 60 Hz 玩法更新，Player/World/Spawner 在物理循环移动，Main 相机在渲染循环平滑 | 启用原生物理插值；相机单独关闭；传送/对象池边沿复位 |
| 相机 | 自制逐渲染帧阻尼、FOV 随速度变化、受控震屏与 look-at | 保留：这是跟随风格/手感逻辑，不适合与原生插值叠加；相机插值模式明确关闭 |
| 环境/光照 | 原生 `Environment`、`WorldEnvironment`、Filmic tonemapper、fog、glow、环境光、一个 DirectionalLight3D | 原生路径正确；暂不盲目给每条霓虹添加实时 OmniLight3D，以免移动端光源限制/成本引入新问题；需设备截图验证灯光是否充足 |
| 主角/载具/地标 | 9 个 GLB、程序化玩家装甲、PBR 微表面、共享材质细节 | 保留 GLB/自制造型；模型离线网格检查合格。近景动画穿插、细节比例与实机光照仍需截图验收 |
| 跑道 | `cyber_deck_*` PBR、两次纹理读取、装甲分区、内嵌线路、动态能量导轨 | 保留定制 Shader：这是世界观核心视觉，不适合替换成无特性的通用平面材质 |
| 楼宇与远景 | 96 栋近景楼、80 个远景建筑实例、分段电力脊线、窗格 Shader、深度队列回收 | 保留 MultiMesh/自定义窗格 Shader；回收模型模拟仍通过；真实 GPU/LOD 表现须在引擎测量 |
| 障碍/道具 | 稳定类型的 MultiMesh 池、共享 PBR 材质、实例颜色/变换数据 | 保留原生 MultiMesh；补齐对象池激活/隐藏的实例插值复位 |
| 粒子/瞬时效果 | 原生 GPUParticles3D、StandardMaterial3D 发光材质与对象池 MeshInstance3D | 原生粒子继续使用；自定义碎片/尾迹形状因视觉需求保留，复用时复位插值 |
| 后处理 | WorldEnvironment 负责常态调色/雾/Glow；屏幕 Shader 仅速度色差 | 纠正重复常态全屏处理；色差只用于冲刺反馈 |
| HUD/菜单 | 原生 CanvasLayer、Control、Label、Button、PanelContainer、StyleBoxFlat、Theme | 保留：用原生 UI 节点实现赛博皮肤，比用自绘整屏 UI 更容易维护/适配/辅助操作 |
| 动画/过渡 | 原生 Tween 与 GDScript 程序化动作 | 保留：Tween 用于 UI/过渡，逐帧 Player 姿态属于游戏逻辑；没有必要改成一套复杂自定义动画框架 |
| 音频 | AudioStreamPlayer、AudioServer 音频总线、效果链/限幅器、OGG/WAV 资源与优先级音效池 | 保留原生音频总线与播放器；音色/混音结果需要在设备/耳机实听，离线波形检查不等于主观听感验收 |
| 配置/存档 | ConfigFile、原子写盘/校验、输入回放与版本元数据 | 保留：Godot 原生 ConfigFile 适合此类用户配置，现有完整性保护也不应为“原生”而移除 |
| Android 交付 | Android 导出预设，当前只启用 arm64-v8a，签名字段为空 | 当前 ZIP 仍为源码包，不含 APK；需目标机器的 Godot、Export Templates、SDK/JDK 与本地签名完成后才可测安装 |

## 离线检查结果

- GLB 模型：9/9 通过网格、退化面/重复面和有限法线检查。
- PBR 贴图：6/6 通过尺寸、通道与接缝检查；赛博甲板 albedo Alpha 与独立 roughness 源图逐像素一致。
- 资源/导入：字面 `res://` 资源引用、`.import` source 路径、UID 唯一性、版本镜像/文档链接通过。
- 玩法/存档/回放/音频/场景生命周期和对象池合同通过；96 栋近景与 80 个远景的 12,000 帧回收算法模拟仍通过。
- 新增 Native Godot 合同：检查原生物理插值设置、相机例外、玩家与世界循环复位、MultiMesh 初始及回收槽位重置、瞬时效果池重置、Shader 参数按渲染帧插值和滚动周期数学连续性，以及常态不绘制屏幕采样层。
- 新增发布工具可移植性检查：`run_tests.sh` 不再依赖开发者电脑的绝对路径，优先读参数/`GODOT_BIN`/`PATH`，同时对引擎版本进行保护。
- 版本/Android：`3.5.0-G` / `versionCode=31`。
- 完整源码 ZIP 在全新解压目录中复跑 `tools/run_offline_checks.sh` 通过；压缩包不包含 `.godot` 导入缓存、Python 字节码缓存、APK 或签名私钥。

## 仍未完成的验收（不能用静态检查替代）

| 项目 | 状态 | 所需动作 |
|---|---|---|
| Godot GDScript 语义编译/资源导入 | 未运行：当前环境没有 `godot 4.7.2-stable` | 用目标版本打开工程，运行 headless editor/import 与主场景冒烟测试 |
| Shader 编译/渲染输出 | 未运行 | 检查屏幕色差只在高速出现；正常速度无额外后处理；8 个章节及超频颜色不过曝 |
| 物理插值视觉验收 | 未运行 | 临时降到 10–20 physics TPS 调试拖影/复位边界，再恢复 60 TPS；此为诊断流程，不是发布设置 |
| 真机帧率 | 未实测 | 记录 60/90/120 Hz 设备平均帧时间、p95、慢帧比例、CPU/GPU 时间与降档行为 |
| 美术精致度 | 未实机截图 | 竖屏近/中/远景检查模型轮廓、PBR 高光、跑道装甲细节、门框相交、招牌可读性与远景雾化 |
| 音频与温度 | 未实测 | 扬声器/耳机听感，高特效持续 15 分钟与多局重开稳定性 |
| APK | 未构建/安装 | 配好 Android 工具链后导出、签名、安装并执行真机清单 |

## 官方参考

- Godot 4.7 物理插值快速入门：启用项目设置，尽量在 `_physics_process()` 中移动，并在传送/重放置后调用 `reset_physics_interpolation()`。<https://docs.godotengine.org/en/4.7/tutorials/physics/interpolation/physics_interpolation_quick_start_guide.html>
- Godot 4.7 MultiMesh 的 `reset_instance_physics_interpolation()` / `reset_instances_physics_interpolation()` 为实例级传送提供复位入口。<https://docs.godotengine.org/en/stable/classes/class_multimesh.html>
- Godot Engine 的 `get_physics_interpolation_fraction()` 返回渲染帧在当前物理周期中的插值分数，可用于固定时步 Shader 参数插值。<https://docs.godotengine.org/en/4.7/classes/class_engine.html#class-engine-method-get-physics-interpolation-fraction>
- Godot 屏幕读取 Shader 会使用 screen/back buffer；应将其视为成本敏感路径，而不是无成本的全屏后处理。<https://docs.godotengine.org/en/4.5/tutorials/shaders/screen-reading_shaders.html>

---

本报告反映 v3.5.0-G 当前源码/资源与离线回归状态。工作目录与完整源码 ZIP 的干净解压复验均通过：9 个 GLB、6 张 1024×1024 PBR 贴图、63 个字面资源引用、104 个 UID、21 个 GDScript 词法扫描，以及模型/贴图/玩法/存档/回放/生命周期/发布合同均通过。其真实性边界：源码门禁通过不代表引擎编译通过、不代表所有视觉效果已经在真实渲染中验收，也不代表 FPS 已提升。仍需目标 Godot 版本和 Android 实机验证。
