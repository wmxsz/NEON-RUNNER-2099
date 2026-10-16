# 美术资源生成与质量护栏

> 当前开发基线：v4.3.0-G（Android versionCode=39）。


## v4.2.0-G 当前维护约定

- 方向光和辉光必须通过 `World.set_perf_profile()` 分档，并可从 Telemetry 的 `renderBudget` 诊断快照确认实际生效配置。
- 道路细小蚀刻/导轨的屏幕空间抗闪烁必须使用 `cyber_line_coverage()`，不能以降低渲染分辨率或关闭 4× MSAA 替代。
## Godot 原生功能优先原则（v3.5.0-G）

- **环境与画面输出：**常规的 Filmic tonemapping、雾、环境光、Glow 和材质响应优先使用 Godot `Environment` / `WorldEnvironment` 与 `StandardMaterial3D`；MSAA、各向异性过滤与 Mobile renderer 用项目原生设置管理，不在全屏 Shader 里重复做调色/锐化。
- **动态平滑：**固定 60 Hz 模拟使用 Godot 原生 physics interpolation；玩家重置、循环场景传送、MultiMesh 实例池激活/隐藏必须 reset 对应插值历史，避免拖影。相机阻尼在 `_process()` 自行运行，必须单独关闭其原生插值，避免双重平滑。
- **特效/UI/音频：**GPUParticles3D、AudioServer buses / AudioEffect、Control、Theme/StyleBox、Tween、ConfigFile 等原生系统继续承担常规职责。自定义 Shader 只用于无法由原生参数表达的赛博导轨、窗格数据脉冲和高速色差；只有高速/超频才显示 screen-texture 后处理层。
- **判断标准：**不为原生而原生，也不为自定义而自定义。原生功能更稳、更容易维护且效果合适时优先使用；赛博视觉必须靠模型剪影、PBR、发光导线与主题设计落实，不能靠整个画面叠一层滤镜冒充精致。

## 原生赛博天空

- 3D 背景优先使用 `WorldEnvironment` + `Sky` + `ProceduralSkyMaterial` 的多段色彩渐变，不用一张平色把天空压成无层次的纯色块。
- 当前顶色为深墨蓝、天际为紫红、地平下沿为冷青；开启 debanding，radiance 限制 128 并设为 incremental 生成，以照顾移动端启动预算。
- 天空材质保持静态，章节气氛变化由雾、环境光、城市电力脊线、赛道网格和霓虹 PBR 共同完成；不要在 30Hz 主题回调里反复更改天空材质，否则会持续使环境辐射缓存失效。

## 当前目标

- **轮廓优先：**角色、交通飞行器、BOSS 和主要建筑在手机竖屏中首先要有容易识别的剪影，细节不能干扰玩法判读。
- **真实倒角：**`tools/generate_visual_models.py` 的 `beveled_box_mesh()` 基于凸包生成真实边缘切面，而非仅靠贴图绘制假描边。倒角宽度按最薄尺寸比例计算，并限制最大宽度，小灯条、细通风槽不会被过度削薄。
- **材质分批：**GLB 导出继续按材质分组合并；静态细节优先增加到现有材质批次，不为每块面板创建独立材质/运行时灯光。
- **赛博复合装甲：**`cyber_armor_albedo.png` 是带 Alpha detail mask 的 RGBA 微细节图；Godot 原生 `StandardMaterial3D.detail_enabled` + `detail_albedo` + `BLEND_MODE_MUL` 只让刻线/密封槽参与乘算，不再把它当作主 Albedo 覆盖材质底色。未遮罩区域接近纯白；复合装甲微法线进入原生 `detail_normal` 并在生成阶段校准幅度，绝不覆盖每类模型原有基础法线贴图；粗糙度继续使用独立原生通道。玩家、障碍和导入交通/地标共享这组 PBR 细节；导入模型约 `0.80×` UV，玩家约 `0.85×`，避免微表面过大。
- **赛博能量跑道：**`cyber_deck_albedo/normal/roughness` 表示碳陶装甲模块、加工倒角、内嵌精密边框、四点数据锁、机械接缝和蚀刻电路。运行时着色器增加分段导能线、左右青/洋红双谱轨道、中心同步刻度和随章节切换的霓虹反馈；碳陶面板保留漫反射，抛光导能区提高金属反射。roughness 线性值同时存于 albedo Alpha，独立灰度源图用于编辑。
- **数据拱门：**使用薄型主题主环、独立青/洋红能量导管及一个 MultiMesh 批次内的八个识别刻度；每个门独立淡出，全部关闭阴影，控制透明环与 emissive 的移动端成本。
- **发光节制：**导光条、状态灯用 emissive 材质表达，主要机身仍保留粗糙度和高光变化；避免给每个灯带增加实时 PointLight3D，保持移动端成本可控。

## 赛博 UI 图标与交互状态

- 高频图示必须使用 `assets/ui/icons/*.svg`，统一 64×64 viewBox、线宽、转角与留白；不能依赖 Android 系统字体提供的 Unicode emoji/pictogram 作为主交互图标。
- SVG 只用轻量矢量路径，不使用嵌入位图、滤镜或运行时全屏绘制。呈现继续使用 Godot 原生 `TextureRect`，按需由 `Control` 的 `StyleBoxFlat` 管理深色玻璃底、主题色边缘、hover/pressed/focus 状态。
- 设置项使用原生 `HSlider`、`CheckButton` 与 `ScrollContainer`，由项目 SVG 旋钮/开关状态、`StyleBoxFlat` 统一赛博样式；标签行可触摸切换，不得因主题精修缩小实际命中区域。
- 图标需在目标竖屏的实际控件尺寸下验收：触摸命中面积优先，图形居中、边缘留白一致、文本基线不与图标相互挤压；SVG 通过 XML 门禁不等于 Godot 引擎的实际导入已经验收。

## 生成与检查

需要 Python 3、NumPy、Pillow 和 trimesh。项目根目录执行：

```bash
python3 tools/generate_visual_models.py
python3 tools/validate_visual_assets.py
```

完整检查入口：

```bash
sh tools/run_offline_checks.sh
```

模型校验会检查：非空几何、有限顶点、有效三角索引、有效 0..1 UV、材质存在、关键资产的最低三角形预算、6 张 1024×1024 PBR 贴图的尺寸/通道/接缝风险、源码资源引用，以及模型/版本契约。

## 当前资产预算与历史对比

当前资源清单由 `RELEASE_MANIFEST.json` 作为发布库存基准，并由 `tools/validate_visual_assets.py` 实际读取 GLB 几何与 PBR 贴图数据；升级时应先检查当前 GLB 面数、材质组、UV、贴图尺寸和导入引用，再决定是否增加模型细节。

历史模型增量表已归档，仅用于追溯，不代表当前资产规模或当前帧率表现。当前资产的最终材质/LOD/GPU 成本必须在 Godot 4.7.2-stable 与目标 Android 设备上测量。

## 视觉验收要求

1. 在 Godot 中检查角色正面/侧面/背面；确认新增肩甲、腹板、膝甲不会穿透动画动作。
2. 检查三种飞行器和 BOSS 在远景、近景、章节换色状态下的轮廓、发光颜色和材质反差。
3. 检查建筑倒角不能扩大实际玩法碰撞范围（地标仍是纯装饰，障碍碰撞由 Spawner 数据表决定）。
4. Android 设备至少记录 60 秒常态和 BOSS/超频高特效场景的帧时间、GPU/CPU 温度与内存；不能以三角形数单独推断性能。
5. 若细节在 412×915 竖屏预览中不可辨认，优先放大关键标志/简化噪点，而不是继续堆小零件。

> 目前没有 Godot 引擎的语义编译/渲染运行结果；离线模型检查通过不代表 Godot 导入后的最终画面已经通过实机验收。

## v3.2.0-G 视觉与帧预算验收边界

本版不因增加模型细节而盲目提高多边形数；模型/贴图校验继续使用 `tools/validate_visual_assets.py`，但实际材质高光、法线表现、后处理过曝和 LOD 选择都必须在 Godot 4.7.2-stable 的目标 GPU 上截图/测时。章节主题材质写入节流到配置的 30 Hz，必须对慢速与极速过渡做录屏对比，确认没有可见台阶后才能关闭此项验收。


本版新增源码级成本合同：常态后处理只保留中心与四邻域采样，色差在高速/超频时才增加采样；窗格着色器复用窗格随机值；近景/远景楼群滚动使用缓存本地坐标与根节点变换，重定位时才写实例缓冲。低性能档位关闭 Bloom 合成器而不降低原生渲染比例或 MSAA；该方案的真实帧率收益和 Bloom 关闭时的观感必须在目标 Android GPU 上记录，不能由静态代码推断。


## v3.4.0-G 赛博艺术资产基线

本版主跑道按未来赛道工程设计：蓝黑碳陶复合装甲、内嵌精密边框、数据锁接口、机械接缝、蚀刻电路、抛光能量通道和随跑动同步脉冲。装甲细节贴图接近中性高亮，避免将 GLB 原有阵营色压暗；机身表面包含双切面六角微结构与单元内遥测刻线。数据拱门采用多层薄环、分谱能量导管与批处理刻度，楼宇增加分段电力脊线。生成器和离线验证器同时守护贴图亮度/细节对比、PBR 通道、平铺边界和材质采样预算；最终反射、光照和细节辨识度仍必须在 Godot 4.7.2-stable 中实机截图确认。
