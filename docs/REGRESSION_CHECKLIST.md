# 统一回归验收清单

> 当前开发基线：v4.3.0-G（Android versionCode=39）。


## v4.3.0-G 当前维护约定

- 回放写入必须先写 `.tmp`、flush、重新解析并检查关键字段，再替换正式文件；保留 `.bak`，损坏时尝试恢复。
- 任何测试入口都必须设置 `NR2099_TEST_MODE=1`，不得在测试中删除或写入 `user://nr2099_save.cfg`。
- 输入层在 `NOTIFICATION_APPLICATION_FOCUS_OUT`、`NOTIFICATION_APPLICATION_PAUSED` 和窗口失焦时必须清理触点与队列。
- 道路实体装甲横肋和紧固件须使用 MultiMesh、关闭投影，并与 `road_cycle_length` 同步，避免回环跳动。

## 归档维护约定：v4.2.0-G 原生渲染预算与跑道抗闪烁

- 方向光和辉光必须通过 `World.set_perf_profile()` 分档，并可从 Telemetry 的 `renderBudget` 诊断快照确认实际生效配置。
- 道路细小蚀刻/导轨的屏幕空间抗闪烁必须使用 `cyber_line_coverage()`，不能以降低渲染分辨率或关闭 4× MSAA 替代。
本清单是当前唯一活跃的回归入口。历史审计记录统一归档在 `docs/audit/archive/`，但不能代替本轮测试结果。

## A. 每次改动必做：离线门禁

```bash
sh tools/run_offline_checks.sh
```

打包后必须解压到一个新的干净目录，再运行相同命令。必须确认：

- [ ] `RELEASE_MANIFEST.json`、`project.godot`、Android `versionName` 与 `versionCode` 一致。
- [ ] 资源清单数量匹配：9 个 GLB、6 张 PBR 贴图、9 首 OGG、12 个 WAV。
- [ ] 所有字面 `res://` 路径存在；`.import` 的源路径存在；脚本和 Shader UID sidecar 存在且无重复。
- [ ] 模型网格/UV/材质、贴图尺寸/接缝、音频完整解码检查通过；通用微粗糙度只能填补空材质槽，不覆盖源 GLB 已有 roughness map。
- [ ] 障碍模式目录无未知类型、非法车道/偏移和明显同深度三车道硬封路。
- [ ] DDA 类型、回放兼容元数据、安全道具投放、音频优先级、存档事务、输入队列和新局生命周期合同通过。
- [ ] 60/90/120 FPS 上限及未知刷新率 60 FPS 回退检查通过；章节材质更新节流与强制重置接口存在。
- [ ] 当前文档本地链接有效，活跃文档开头的基线是 v4.2.0-G，历史文件没有重复留在项目根目录。
- [ ] Python 工具可编译，GDScript 词法扫描通过；必须在报告中明确词法扫描不是语义编译。
- [ ] 核心 HUD/菜单图标采用 assets/ui/icons 下的 64×64 SVG；不得依赖 Unicode pictogram 字体回退；SVG XML 检查与 Godot 实际导入分开记录。
- [ ] 装甲细节法线只进入 `StandardMaterial3D.detail_normal`，不能覆盖导入材质基础 normal；生成器振幅与 detail-normal 原生全强度的实际结果单独检查。
- [ ] 设置页 HSlider/CheckButton/ScrollContainer 保留原生交互并使用赛博主题；设置文字行和开关状态都能触摸，音量拖动仅在提交边界写盘。
- [ ] 二级弹窗在桌面鼠标及 Android `InputEventScreenTouch` 下都能点击/触摸空白遮罩关闭；弹窗内部控件不应误触发关闭。
- [ ] Esc/P 与 Android 系统返回按模态优先处理：先关闭最上层设置/商店/任务/成就面板，不改变后方跑局状态；无子面板时再按 running/paused/revive/gameover/menu 状态执行对应返回行为。
- [ ] 相机 follow 基线不包含 shake 位移；震动使用连续渲染波形且不可每帧随机重置；`cameraShake` 默认 0.75，范围仅接受有限数值 `[0,1]`，验证实时预览/提交/保存失败回滚。
- [ ] 有正确 Godot 时执行 `sh tools/run_godot_tests.sh`，覆盖 Editor 导入/解析、headless/content/mechanics/runtime 四个场景和主场景启动；如跳过必须记录原因。
- [ ] 视觉质量合同检查：cyber deck 装甲板/电路/roughness Alpha 与独立源图一致；cyber armor RGBA Alpha detail mask 只作用于刻线区域、未遮罩区域近白，player/spawner/world/GLB 均使用原生 StandardMaterial3D detail MUL 层，GLB 2×2 白占位图已核验；六角复合装甲细节及楼宇分段能量脊线存在；常态不绘制 screen-reading 后处理层；高速/超频色差层才做屏幕采样；原生物理插值开启并且所有传送/对象池状态边沿调用插值重置；窗格 hash 数量保持预算；近景/远景楼群事件队列坐标回收无漂移；辉光层数按档位为高 5/中 3/低 0；低档超频仅恢复两层且结束后清零。
- [ ] 原生天空回归：WorldEnvironment 使用 BG_SKY / ProceduralSkyMaterial，深蓝顶色、紫红天际、冷青地平下沿与去色带生效；radiance 128 并增量生成，章节更新不得每帧变更 sky material。
- [ ] 测试执行可靠性：headless `_ready()` 必须 await 所有异步断言；测试源不得包含 `or true`、`_ok(true, ...)` 或 `assert(true)`；content 长跑使用专门 5400 帧预算，Godot headless 场景固定 `--fixed-fps 60` 并使用 Dummy 音频驱动。激光权重使用确定性候选池测试，不能依赖单次随机频数比较。

## B. Godot 4.7.2-stable 引擎验收

- [ ] 使用 Godot 4.7.2-stable（RELEASE_MANIFEST.json 中的推荐补丁）打开项目，等待导入完成；控制台无脚本、PackedScene、资源 UID、Shader 或导入错误。
- [ ] headless editor/import 检查通过，并实际运行主场景至少 180 模拟帧。
- [ ] 从菜单启动、快速连续重开 20 局、暂停/继续 10 次、死亡后拒绝/接受复活；各流程无状态残留。
- [ ] 复查 DDA 关闭/开启的实际模式；同一有效 seed 与构建下重复跑局/回放结果一致。
- [ ] 用至少 100 个固定 seed 做自动或人工跑局；覆盖最高速度、低重力、冰面、激光、雨效、滑板、护盾、BOSS 和超频组合。
- [ ] 逐一确认道具不会与障碍重叠，所有危险组合在实际碰撞盒和动作窗口下都有合理应对方式。
- [ ] 验证章节过渡在速度变化时无明显颜色阶梯、闪变或贴图卡顿；强制重开应立即复位到第一章配色。
- [ ] 运行帧率限制行为：60Hz、90Hz、120Hz、刷新率查询失败回退；性能自动降档保持迟滞、不反复抖动。
- [ ] 测量章节过渡前后 CPU/渲染耗时，确认 30Hz 视觉参数更新没有带来可见台阶。
- [ ] 存档模拟写入失败、主存档损坏/备份恢复、旧 schema 迁移；钱包/任务/成就/UI 状态一致。

## C. Android 真机与声音验收

- [ ] 使用兼容 Godot 版本的 Android Export Templates 与 SDK/JDK 导出 Debug APK；记录确切工具版本。
- [ ] APK 安装成功，启动器图标、包名、版本号和竖屏布局正确；刘海/挖孔屏安全区无裁切。
- [ ] 触屏换道/跳跃/滑铲、多点触控、快速连触、后台切回和锁屏恢复正常。
- [ ] 测试音乐/SFX/UI 总线：音乐章节切换、BOSS、超频、复活、死亡、UI、连续芯片音效；扬声器和耳机都无破音、泵动或关键音效被淹没。
- [ ] 在 25/50/75/100% 音量滑块下检查相对响度；同时检查 0% 真静音和高叠加场景限幅行为。
- [ ] 记录平均帧时间、p95、慢帧比例、内存、15 分钟温度/耗电；至少连续 20 局不崩溃。
- [ ] 发布包由开发者使用本地安全 keystore 签名；密钥、密码不得进入源码/审计压缩包。

## D. 发布门槛

离线检查通过是必要条件，不是充分条件。只有 B、C 项都留有可追溯结果，才可以把包标记为可安装候选。Release 签名和 Android 导出参数须在真实发布环境单独配置。

- [ ] 高/中/低档分别核对 DirectionalLight3D 阴影模式、阴影距离和有效 Glow 层数；低档超频仅临时恢复两层，结束后回到零层。
- [ ] 赛博跑道远景细线路 `cyber_line_coverage()` 保持 derivative AA；不增加纹理采样、不降低 3D 比例、不关闭 4× MSAA。
