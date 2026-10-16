> 历史记录说明（2026-10-15）：本文包含此前版本内容；当前源码包已按要求移除 Godot 测试场景/runner。

# 霓虹疾驰 2099 · v1.4.0-G 视觉升级记录

日期：2026-10-15
基线：`霓虹疾驰2099_源码_v1.3.0-G_统一修复源码.zip` 对应的统一修复项目

## 已直接改进的源码

- `entities/player.gd`：改造角色的几何构成，使用球体/胶囊体/圆柱体/分层装甲组合人体；加入面罩、胸口能源核心、背部推进器、细节光带、金属关节与滑板组件。六套皮肤分别添加幽灵翼片、鬼武士头角、魅影背翼、黄金光环、合金肩甲等独立配件，同时保留既有角色动画/输入接口；按材质角色把各运动枢轴下的静态子网格合并，并重建切线以控制 draw call 和确保法线贴图有效。
- `assets/textures/cyber_asphalt_*.png`：新增 3 张 1024×1024 无缝道路材质贴图（底色、法线、粗糙度），可由 `tools/generate_road_textures.py` 重新生成。纹理边界已做数值检查：底色与粗糙度贴图首尾边缘的平均差低于 0.5 灰阶值，法线图低于 3 灰阶值。
- `assets/textures/cyber_armor_*.png`：新增 2 张 1024×1024 无缝护甲贴图，包含微刻纹理和法线细节；角色、障碍与城市的非发光金属材质会使用它们，皮肤本身的颜色仍由原配色系统控制。可由 `tools/generate_armor_textures.py` 重新生成。
- `world/road_grid.gdshader`：路面采用材质贴图、法线细节和粗糙度变化，保留较低强度车道线，减轻原来纯平面网格的“塑料/马赛克”观感。
- `world/building_windows.gdshader`：窗格密度提高，增加建筑立面分缝、窗框、细小亮窗随机变化和细长招牌光带。
- `world/world.gd`：收敛常态 Bloom，使用 Filmic 色调映射；建筑群按速度滚动回收，新增 64 栋远景城市天际线（视差层）、三艘程序化空中载具和五块动态立体霓虹招牌，并为部分近景楼体增加阶梯式顶部、天线、设备箱、信标灯和立面发光边条（通过五组细节 MultiMesh 合批）；道路两侧增加金属护边和有颜色区分的连续发光灯管。
- `entities/spawner.gd`：将障碍 MultiMesh 的部件描述扩展为可使用任意 Mesh、局部旋转/缩放；障碍加入圆柱防护管、角部灯、警戒条、扫描锥、旋翼环；芯片采用多段晶体与核心环，道具采用核心体与环形外框。非发光护甲材质共享细节底色和法线贴图；碰撞判定仍沿用原逻辑数据。
- `fx/effects.gd`：碎片从正方体改为低面数锥形碎屑，随机旋转/尺寸，尾迹由方块状片段改成细长光带。
- `fx/post_fx.gd` / `fx/post_fx.gdshader`：正常状态下色差和胶片颗粒降至近乎不可见；超频时才短时增强色差，降低扫描线/暗角对细节的侵蚀。
- `project.godot` / `core/config.gd` / `export_presets.cfg`：版本统一升至 1.4.0-G（Android version code 8）；设定 4× MSAA、原生 3D 比例、各向异性过滤；配置 Bloom 数值与实际默认强度保持一致。
- `tests/test_content.gd`：加入贴图存在、六套皮肤、芯片/无人机部件、城市飞行器与招牌数量的视觉资产检查。

## 必须谨慎理解的内容

本次是程序化美术与材质层升级，并非从商业游戏提取或购买的高面数原生角色模型，也不是照片级 PBR 资产包。它能显著减少简单方块感、增加层次和表面细节；但若后续追求接近大型商业游戏的角色动画/材质质量，仍需要正式的骨骼化 GLB/FBX、专用贴图、动画剪辑和在目标手机上的逐项调优。

## 检查状态

已完成：三张纹理生成、纹理首尾边界检查、源文件语法结构粗检、资源路径存在检查、重复函数名检查、测试脚本 Shell 语法检查、ZIP 完整性检查。

尚未完成：Godot 4.7.2 脚本/Shader 编译、项目导入、主场景运行、截图实测、四套 headless 测试、Android 导出与目标设备性能测试。当前环境未找到 Godot 二进制，下载端也无法获取二进制，因此不会声称上述引擎验证已通过。


## 第二轮画质精修（v1.5.0-G）
- 重制 1024×1024 盔甲平铺底色与法线纹理：低对比面板接缝、细微加工刻线与紧固件细节，避免原贴图过度重复的四格大面板观感。
- 3D MSAA 从 2× 调整到 4×，以改善角色、栏杆和霓虹边缘的锯齿；实际 GPU 成本仍需设备实测。
- 将常态色差从较明显的速度驱动值降低，并降低超频色差、暗角和胶片颗粒，减少彩边和画面发糊。
- 保持 3D 原生比例（1.0）、各向异性过滤（4）与原有玩法/碰撞/对象池不变。
- 本轮仅完成源码与资源静态修改；尚未通过 Godot 4.7.2 引擎编译或手机实测。


## 第三轮美术与材质精修（v1.6.0-G）
- 角色身体、肩甲、头盔边框、四肢装备和悬浮板的盒状部件改用项目内共享的倒角网格，保留原有动画枢轴和碰撞/玩法逻辑；导入失败时回退到 BoxMesh。
- 护甲材质补齐粗糙度贴图，和现有底色/法线图共同形成 PBR 材质；障碍物、角色与城市非发光金属统一接入该贴图。
- 导入 GLB 网格的辅助提取路径在取出 Mesh 引用后释放临时根节点，避免初始化时遗留临时场景节点。
- 对齐项目版本号与 Android 导出预设：1.6.0-G / versionCode 10。
- 已新增资源静态验证脚本，用于检查 GLB 非空/边界/材质、贴图尺寸与可平铺边缘差；此脚本不代替 Godot 4.7.2 场景/Shader 编译和手机实测。

- 第三轮进一步为所有导入 GLB 的材质组生成有效 UV 坐标；世界场景中的空中载具、BOSS 和远景地标对不透明、非发光金属面接入同一套护甲微纹理/法线/粗糙度贴图，保留原始 PBR 颜色与发光面。

## 交付完整性核对
- 对照 v1.5.0-G 压缩包时发现，旧 ZIP 缺少源码已引用的 9 个 `assets/models/*.glb` 文件；v1.6.0-G 已将 9 个 GLB 和 `tools/generate_visual_models.py` 一并打入包内。
- 本次打包前运行 `python tools/validate_visual_assets.py`：9 个 GLB（所有网格均有有效 UV）、6 张 1024×1024 PBR 贴图、48 个字面 `res://` 资源引用、30 个唯一导入 UID、项目/Android 版本一致性均通过。
- 再次声明：该静态验证不替代 Godot 4.7.2 的实际项目导入、GDScript/Shader 编译、headless 测试及目标手机帧率/温度测试；当前环境无法下载或运行引擎。


## 第四轮实质性优化（v1.7.0-G）
- 章节主题同步影响楼群霓虹、环境漫反射色、背景色、数据拱门和城市招牌，修正主题只作用于道路/雾而楼群霓虹沿用旧色的问题。
- 低障碍、重型方块、激光门和无人机增加前向装甲面板、通风槽、角灯、导能发射条与传感器；这些是渲染部件，不改变既有碰撞尺寸、生成路径或对象池。
- 碎裂特效使用截锥、三角棱柱和低面水晶三类轮廓，全部预创建并关闭阴影，减少单一碎片外观与不必要阴影成本。
- HUD 增加半透明顶栏和超频槽边框，触屏按钮与原信号保持不变；充能条背景使用非容器 Control，保留百分比填充布局。
- `THEMES[].landmark` 现在影响地标轮廓的强调程度；章节色同步进入导入模型材质和路面底色，且基于保存的原始色做混合，避免连续改色导致漂移。
- 项目/Android 导出版本号升至 1.7.0-G / versionCode 11。
- 离线资源检查可通过；Godot 4.7.2 编译、场景运行与手机性能尚未实测。


## 第五轮实质性精修（v1.8.0-G）
- 修复皮肤材质更新遗漏双臂的问题，并将皮肤调色应用到悬浮板，保证六套外观不再留下初始配色残件。
- 为跑步循环加入受速度驱动的步幅、细微躯干反扭与头盔二级运动，滑铲/空中状态对这些附加运动做阻尼归零，避免夸张抖动。
- 远景天际线从单一盒体轮廓改为盒形、柱形和锥形三组 MultiMesh，共 64 个实例不增加到逐物体节点。
- 修复超频结束时雾浓度会跳回章节起始值的问题：结束后恢复到当前章节混合浓度；主光色温同步章节色调。
- 路面细节贴图横向重复 3 次、纵向重复 40 次，改善近景纹理拉伸；滚动改为按实际速度积分距离，避免加速/超频改变速度时出现纹理跳动。
- 关闭大批动态城市楼体的实时投影以减少移动端阴影渲染负担，保留人物/BOSS 的独立阴影设置。
- 项目与 Android 导出版本更新为 1.8.0-G / versionCode 12。
- 已运行离线模型/贴图/路径校验脚本；Godot 引擎编译与设备帧率仍需实际引擎环境验证。
- 复核发现章节渐变会每帧重写雾浓度，导致超频强化雾可能只持续一帧；现已在主题持续更新期间保护超频雾，并把“超频期间经过一次章节更新仍保持强化雾”加入回归测试。
- 测试入口加强：支持显式 GODOT_BIN/参数路径，打印引擎版本，并在回归测试前先执行 headless editor 资源导入；避免干净解压包因为尚未导入 GLB/贴图而产生误报。


## v2.0.0-G — 城市立面差异化与渲染架构收敛
- Enabled per-instance custom data on near/far city MultiMeshes and consumed it in `building_windows.gdshader` so each tower has different window seed, warmth, density, and contrast; recycled towers receive a fresh seed.
- Added a three-slot pooled ledge system that gives each building a different horizontal facade layout while avoiding individual nodes and real-time shadows.
- Roof equipment now uses a solid metal material rather than inheriting the repeated window shader.
- Removed dead legacy obstacle-node prototype code and unused tree prefix helper; the type-level MultiMesh renderer is now the sole visual construction path.
- Added regression assertions for varied window data, seed refresh on recycling, and shelf instance counts; CI now runs when assets change.
- Version bumped to 2.0.0-G / Android versionCode 14. Static asset and source checks passed; Godot engine compile/device QA still requires the engine runtime.
