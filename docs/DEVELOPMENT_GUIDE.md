# 开发与维护规约

> 当前开发基线：v4.3.0-G（Android versionCode=39）。


## v4.2.0-G 当前维护约定

- 方向光和辉光必须通过 `World.set_perf_profile()` 分档，并可从 Telemetry 的 `renderBudget` 诊断快照确认实际生效配置。
- 道路细小蚀刻/导轨的屏幕空间抗闪烁必须使用 `cyber_line_coverage()`，不能以降低渲染分辨率或关闭 4× MSAA 替代。
- 高频 HUD/菜单图示使用自带 SVG 资源和原生 TextureRect，不依赖系统字体 emoji；控制按钮交互状态由原生 Button/StyleBox 表达。新增矢量图标必须经过 SVG/XML 资源合同与目标设备尺寸验收。

## 修改前

- 先审查 Godot 原生功能：Environment/WorldEnvironment、StandardMaterial3D、GPUParticles3D、MultiMesh 插值、Tween、Control/Theme、AudioServer 等；只有原生功能不足以实现明确的赛博美术/玩法目标时，才新增自定义系统。
- 全屏 `hint_screen_texture` Shader 是成本敏感的例外；应在不需要时完全隐藏，而不是让“参数为零”的全屏层持续复制屏幕。
- **主 Albedo 不要被通用微细节贴图替换：**原生 `StandardMaterial3D.detail_albedo` / `detail_mask` / `detail_blend_mode` 用来叠加接缝与刻纹；只有确认输入底色是生成器占位图时才清除占位 sampler，并用验证器确保导入色因子/玩家皮肤色未丢。
- **细节法线不要覆盖基础法线：**通用装甲微法线应使用 `StandardMaterial3D.detail_normal` 与 detail albedo 的遮罩范围一致；因 detail-normal 没有独立 strength slider，必须从生成器控制法线 XY 幅度并保留统计护栏。
- **原生天空不应退回纯色背景：**主 3D 场景使用 `Sky`/`ProceduralSkyMaterial` 表达深蓝、紫红和冷青的赛博大气渐变；radiance 保持 128 并增量生成。主题插值不直接反复改 sky material，章节色彩由 fog/ambient/建模与霓虹材质承载。
- **异步测试必须真正等待：**测试 `_ready()` 调用含 `await` 的协程时必须 `await` 返回值之后才汇总/退出；禁止 `or true`、`_ok(true, ...)` 与 `assert(true)` 等常量真值弱断言。随机平衡机制优先验证可预测的权重/候选池，不以单次 Monte Carlo 抽样作为发布门槛。长时间模拟场景需要与其帧数匹配的 `--quit-after` 预算，并固定 headless 调度 FPS，且必须使用 Dummy 音频驱动。
- **设置页保持原生控件、赛博外观：**HSlider/CheckButton/ScrollContainer 使用主题覆盖而非自绘输入系统；设置标签也应能触摸切换，Modal dimmer 必须通过 PASS 把外部事件传给根 Control。
- 打开 physics interpolation 后，每个传送/对象池跳转必须在变换写入后 reset node 或 MultiMesh instance interpolation。相机如在 `_process()` 独立平滑，应显式关闭原生插值。
- 相机跟随基线与震动必须分开；不可把随机偏移后的 Camera3D.position 再用于下一帧阻尼。新增相机强度设置需覆盖默认值、有限数字校验、范围夹制、实时预览、保存失败回滚与旧存档迁移。

1. 先识别状态所有者和事件方向，优先改所有者，不在多个脚本复制状态。
2. 搜索所有读写位置（变量名、信号和 UI 回调），而不只改眼前的一处。
3. 先写清楚可观察的验收条件，再改实现。
4. 保持 `res://` 路径稳定；搬动文件要同步检查 PackedScene、`preload`、`.uid` 和导出配置。

## 代码风格

- GDScript 采用明确类型：跨模块信号参数、公开方法参数/返回值优先标注类型；缩进统一为空格，每级 8 空格（由 `.editorconfig` 声明）。
- 常量用 `UPPER_SNAKE_CASE`，私有字段/辅助方法用 `_leading_underscore`，信号表达发生过的事件（过去式或已完成事件）。
- 一个函数只做一种操作；初始化顺序使用带编号/阶段名的注释块说明。
- 避免在 `60 Hz` 热循环中反复创建临时数组、字典、节点或材质；先用分析器确认热点再优化。
- 让重置方法完整、自包含、可重复调用；不要要求调用者记住某个隐藏的前置顺序。
- 不使用没有消费者的信号、写了却无人读取的状态字段或“预备未来用”的死代码；删除前先全仓搜索。

## 跨系统通信

- **同一系统内部**：直接调用私有/公开方法。
- **协调层之间**：通过 `Main` 绑定信号或显式调用。
- **全局跨模块动作事件**：才使用 `EventBus`。
- **UI**：发出用户意图信号，由协调层检查状态与权限，再调用系统。
- 不从 `Player` 直接写 `Progress`；不从 `Spawner` 直接操作 HUD/音频；不从 `AudioEngine` 反向推测 Boss 是否存在。

## 版本/交付

- 改动代码后先执行 `sh tools/run_offline_checks.sh`。它组合了 Python 工具语法检查和离线资源/源码/文档契约校验。
- 只有离线检查通过才生成交付 ZIP；生成后必须从 ZIP 干净解压，再执行一次同样的检查。
- 这两项都是离线检查，不等于 Godot 编译。真实引擎检查必须使用 Godot 4.7.2-stable；Android 导出和设备验证是独立阶段。
- 改动用户可见行为或源码结构时，更新 `README.md` 和本目录相关文档。

## 版本与历史文档单一来源

- 改动发布版本时，先更新根目录 `RELEASE_MANIFEST.json`，再同步 `project.godot` 与 `export_presets.cfg`，由 `tools/validate_project_integrity.py` 检查；不要再复制旧版校验脚本并硬编码一个新版本字符串。
- 使用 Godot 原生物理插值时，除 Node/MultiMesh 位姿外，还要单独审查 Shader uniform 动画。跑道滚动、窗格脉冲等固定步长值若要求高刷平滑，应使用 `Engine.get_physics_interpolation_fraction()` 做渲染帧插值；暂停状态必须冻结。任何瞬移、循环回收、对象池重新激活都要复位插值历史。
- 当前 README 只描述当前基线；当前说明写入 `docs/CHANGELOG.md`，完整旧版日志保存在 `docs/CHANGELOG_HISTORY.md`，旧审计只存放在 `docs/audit/archive/`。不要把旧审计副本放回项目根目录。
- 对有运行时/性能影响的改动，报告必须区分源码级结论、引擎编译结果和真机实测结果。静态检查通过不得替代后两者。
