# v3.6.0-G — 原生 PBR 细节遮罩与赛博材质颜色保真审计

> 当前开发基线：v3.6.0-G（Android versionCode=32）。推荐验收引擎：Godot 4.7.2-stable。

## 本轮目标与核心发现

本轮不是把纹理再“加亮一点”或堆更多节点，而是复核材质在运行时究竟如何混合。检查发现，9 个程序化 GLB 的 53 张导入贴图侧车全部是 `2×2` 纯白图：生成器使用它们的目的只是促使 GLB 导出器保留 `TEXCOORD_0`，并不是作者绘制的材质底色。旧 runtime 却把 `cyber_armor_albedo.png` 设为主 Albedo。这会使整张微细节纹理参与每个表面像素的颜色乘算，即便平均值近白，也会让大面积皮肤/阵营色整体变暗；而且导入的白色占位纹理没有清理时还会保留一个不必要的基础色采样。

Godot 4.7 的 `BaseMaterial3D` 已原生提供 `detail_enabled`、`detail_albedo`、`detail_mask` 和 `detail_blend_mode`。因此这一轮改为使用引擎原生细节层，保留材质主色，同时只在刻线、接缝和装甲垫圈区域混合微细节。不为“原生”而移除赛博设计，而是用合适的内建 PBR 属性承载定制纹理。

## 已落地的源码与资源改造

### 1. 玩家、障碍、城市与导入 GLB 统一使用原生 detail overlay

- `entities/player.gd`：非发光的玩家机甲材质把 `ARMOR_ALBEDO` 改到 `detail_albedo`，启用 `detail_enabled` 和 `BaseMaterial3D.BLEND_MODE_MUL`；保留各皮肤自己的 `albedo_color`，并保留标准 `normal_texture`、`normal_scale=0.30`、粗糙度贴图和 UV 比例。
- `entities/spawner.gd`：障碍外壳继续使用顶点色/障碍色，只叠加局部装甲刻线；保留 `normal_scale=0.18`、粗糙度以及既有共享材质/实例池。
- `world/world.gd` 的城市材料：不再把装甲细节设为主 Albedo；碳陶大面仍由 `_make_city_material()` 的颜色/金属度/粗糙度控制。
- `world/world.gd` 的导入模型覆盖：先复制导入的 `StandardMaterial3D` 并保留 `albedo_color`、发光/透明表面原来的过滤规则，再添加原生 detail overlay。只有当源纹理尺寸为 `2×2` 且资源路径位于 `res://assets/models/` 下，才清除它；真实贴图不会因为尺寸之外的宽泛条件而被无条件删除。主法线与粗糙度继续使用标准材质通道。
- 该路径的运行时主要 PBR 贴图仍为三张：细节 Albedo（含 Alpha 遮罩）、法线、粗糙度；在 GLB 上清除已验证的纯白占位图，避免同时保留一张无内容的基础色贴图。

### 2. 装甲细节改成 RGBA 局部遮罩

`tools/generate_armor_textures.py` 现在输出 1024×1024 RGBA `cyber_armor_albedo.png`。RGB 仍绘制双切面六角陶瓷、机械接缝与嵌入式遥测线路；Alpha 是单独的细节覆盖遮罩，来自相同 SDF/刻线几何，并沿边缘连续衰减，减少 mipmap 中的硬切边。

- Alpha mask 覆盖率（`alpha >= 16`）：`22.514%`。
- 未遮罩大面平均 RGB：约 `251.6 / 252.7 / 254.4`，这些区域在材质上基本不改变原始主色。
- 遮罩刻线维持明确深色对比；法线/粗糙度图各自保留并可平铺，色彩 Alpha 与跑道的粗糙度 Alpha 是不同用途：`cyber_armor_albedo.png` 的 Alpha 是 detail mask，`cyber_deck_albedo.png` 的 Alpha 是 roughness 数据。
- 生成器固定随机种子，能重复生成相同结果；所有贴图仍是 `1024×1024`。

### 3. 增强离线护栏，防止颜色/材质退化

- 9/9 GLB 模型继续通过网格/UV/退化三角面/重复三角面/有限法线检查。
- 新增对 53 张 GLB 导入纹理侧车的逐文件检查：必须是 `2×2`、RGBA 所有通道为 255 的纯白占位图，以支撑 runtime 有条件地清理占位 Albedo。若将来生成器加入真实底色贴图，该规则会先失败，必须重审 runtime 逻辑，不能悄悄清除。
- PBR 校验器检查装甲 Alpha 遮罩不是全空/全满、未遮罩像素保持接近白色、遮罩刻线具有足够对比度，同时要求玩家/障碍/城市/导入模型使用原生 detail MUL 属性，不允许回退到 `albedo_texture = ARMOR_ALBEDO`。
- 将相关大图均值统计改为 float64。当前环境中对大量 1024² float32 纹理求和曾生成高于 255 的不可能均值；这不是贴图问题，而是检查器累加精度问题，现已修正并由像素范围/均值断言保护。
- 材质生成器、模型生成器注释、素材管线说明、回归清单和版本导航已同步。

## 离线验证结果

当前工作目录完整执行 `sh tools/run_offline_checks.sh` 时应检查：

- 9 个 GLB、6 张 PBR 贴图与 53 张 GLB 白色占位纹理通过。
- 装甲 RGBA Alpha 遮罩覆盖/色彩保真测试通过；赛博跑道 Albedo Alpha 与独立 roughness 源图仍逐像素一致。
- 近景 96 栋与远景 80 栋的 12,000 帧事件队列对照继续通过，世界坐标漂移为约 `10^-12` 米量级。
- 资源引用/UID、版本元数据、存档/回放/输入/生命周期/音频/发布合同与 GDScript 词法结构检查通过。
- 版本身份为 `3.6.0-G` / Android `versionCode=32`；当前报告路径为本文件。

## 尚未完成的引擎/设备验收（不能用离线检查替代）

当前工作环境没有 Godot 4.7.2-stable 可执行文件，因此本轮未执行真实的 GDScript 语义编译、GLB/PNG 引擎导入、Shader 编译、截图/录屏、Android APK 导出或设备 FPS/p95/温度测试。离线检查能验证资源结构和源码连接关系，但不能保证运行时画面一定如预期。

发布前应在 Godot 4.7.2-stable 中确认 `detail_albedo` Alpha mask 在材质上正确生效，玩家皮肤/障碍顶点色没有被压暗；截取正常速度、冲刺/超频和 8 个章节主题画面；在 Android 设备记录平均帧时间/p95/慢帧比率与持续运行温度。

## Godot 官方 API 参考

- [Godot 4.7 BaseMaterial3D](https://docs.godotengine.org/en/4.7/classes/class_basematerial3d.html)：`detail_enabled`、`detail_albedo` Alpha mask、`detail_normal` 和 `detail_blend_mode`（包括 `BLEND_MODE_MUL`）的原生材质属性。
- [Godot 标准材质教程](https://docs.godotengine.org/en/4.7/tutorials/3d/standard_material_3d.html)：StandardMaterial3D 常规 PBR 工作流程。

---

本报告描述的是源码和资源级改动与离线验证状态。不得把脚本词法扫描说成引擎语义编译，也不得将材质路径改进推断为实测帧率提升或“完全无 Bug”。
