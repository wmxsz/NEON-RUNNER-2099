# v2.3.0-G 美术模型与材质升级审计

## 升级范围

本轮从 `v2.2.0-G` 的完整工程继续，重点改的是现有美术资源，不改变核心玩法、碰撞参数、相机路径和对象池架构。

### 硬表面模型

- `tools/generate_visual_models.py` 新增 `beveled_box_mesh()`：根据盒体最薄边计算倒角并限制最大倒角尺寸；普通 `box()` 建模零件和主要楼体由真实切面改善边缘反光。
- `sky_courier.glb` 加入主脊线、前进气框、进气凹槽/状态灯、翼面检修板、发动机检修盖/通风槽和尾部导光条。
- `cargo_skimmer.glb` 加入货舱顶边轨、舱盖缝线/状态灯、ID 板、侧面通风槽与升力舱警示片。
- `patrol_interceptor.glb` 加入传感器脊、前部传感器玻璃、尾部装甲边、翼面进气槽和武器舱侧甲。
- `sentinel_boss.glb` 加入肩部顶甲、肩灯导轨、光学舱眉、炮轨、背部散热框/百叶。
- `aerial_drone_core.glb` 改为包含背板、稳定翼、传感器脊在内的单合并网格，保持 `Spawner` 抽取单网格给 MultiMesh 的现有接口。
- `neon_landmark.glb`、`neon_arcology.glb` 和 `neon_spire.glb` 的大盒体部件改用倒角几何；原有窗格仍按材质批次合并。
- `entities/player.gd` 为 RUNNER-9 增加肩部层甲、腹部拼板、背部散热栅、膝甲与腕部细节，仍使用共享倒角模型，并保留现有动画 pivot 和 `skin_role` 皮肤重着色流程。

### 材质与 PBR

- 深色/中间/亮色金属重新平衡 base color 和 metalness，减少没有环境反射探针时深色金属压黑的问题。
- `world/world.gd` 中导入模型 PBR 贴图的 normal_scale 由 0.14 调到 0.19，UV 微表面重复比例从 1.0 调到 2.25。
- 没有新增每个零件的实时灯光，也没有拆分材质批次；材质发光仍只分配给导光条/窗灯等少量需要自发光的组。

## 资产面数

| 资产 | v2.2.0-G | v2.3.0-G |
|---|---:|---:|
| Sky Courier | 2,840 | 3,516 |
| Cargo Skimmer | 2,508 | 3,372 |
| Patrol Interceptor | 2,768 | 3,468 |
| Sentinel BOSS | 6,460 | 7,364 |
| Neon Landmark | 2,000 | 2,416 |
| Neon Arcology | 2,364 | 2,780 |
| Neon Spire | 1,652 | 2,292 |
| Aerial Drone Core | 80 | 344 |
| Chamfered Unit Box | 44 | 44 |
| **总计** | **20,716** | **25,596** |

总面数增加约 23.6%，主要交通模型仍约 3.3k–3.6k 三角形。模型生成输出保持 7–8 个材质网格组（无人机/倒角盒仍是单网格），未因为新细节生成大量场景节点。

## 离线验收

- 9 个 GLB 均非空、顶点有限、三角索引有效、材质存在，UV 均为有限的 0..1 范围。
- 9 个 GLB 三角数超过当前版本设定的最低预算，防止误将低细节旧模型覆盖进工程。
- 6 张 PBR 贴图仍为 1024×1024，各通道/接缝检查通过。
- 项目与 Android 导出版本一致：`2.3.0-G` / `versionCode=17`。
- 完整离线检查包含此前存档/随机种子/玩法契约/跨局生命周期/文档链接/脚本格式检查。

## 未完成验收

本轮执行环境没有 Godot 4.7.x 运行时和 Android 导出工具；以下内容没有宣称通过：GDScript 语义编译、场景/Shader 导入、最终引擎光照渲染、跑步动画穿插检查、Android GPU 帧时间、热量/内存和 APK 安装测试。需要按 `ART_PIPELINE.md` 与 `REGRESSION_CHECKLIST.md` 在真实引擎/设备验收。
