# v3.8.0-G — 原生细节法线与赛博设置交互精修审计

> 当前开发基线：v3.8.0-G（Android versionCode=34）。推荐验收引擎：Godot 4.7.2-stable。

## 本轮目标

延续 v3.7.0-G 的赛博 PBR 与矢量界面基线，修复材质微法线接线和真实触屏操作边界，并让设置页每个控件也遵循统一的赛博设计语言。坚持使用 Godot 原生材质/控件/滚动与输入传播机制，不另造一套 UI 系统。

## 实际改动

1. **细节法线纠正。** `entities/player.gd`、`entities/spawner.gd` 和 `world/world.gd` 将复合装甲微法线统一接到 `StandardMaterial3D.detail_normal`。这样微法线跟随 detail overlay 的作用区域，不会替换导入 GLB 自带的基础法线。`tools/generate_armor_textures.py` 把 XY 偏移幅度校准为 `20.0`，大致对应以前 base-normal `normal_scale≈0.18` 的有效幅度；法线统计检查中心值、方差、通道配置和平铺接缝。
2. **模态交互边界。** 二级面板 dimmer 改用 `Control.MOUSE_FILTER_PASS`，让外部鼠标/触屏事件能到达面板根；`_on_panel_input()` 分别处理左键按下与 `InputEventScreenTouch.pressed`，通过弹窗全局矩形判断是否触碰外部。面板内按钮继续消费自身事件。暂停和结算面板的“回主菜单”按钮统一使用主页图标。
3. **模态优先返回栈。** `scenes/main.gd` 将键盘 Esc/P 与 Android `NOTIFICATION_WM_GO_BACK_REQUEST` 汇入统一返回处理；`Menus.close_topmost_secondary()` 每次只关闭最上层二级面板，后方运行/暂停状态不被误切换。无子面板时按 `running/paused/revive/gameover/menu` 执行暂停/继续、拒绝复活、返回主页或保存退出。
3. **设置滑块、开关与滚动条美术统一。** 为原生 `HSlider` 添加深色凹槽、青色填充与菱形 SVG 旋钮；为原生 `CheckButton` 添加开/关 SVG 状态和 normal/hover/pressed/focus 的 `StyleBoxFlat`；`ScrollContainer` 仍使用 Godot 原生手势，只有竖向滚动条的轨道和滑块被主题化。设置标签可以直接点击/触摸切换对应开关，音量持久化仍只在拖动完成或焦点离开时提交。
4. **命中区域。** 通用按钮最小高度 48 逻辑像素，设置行高度 48，CheckButton 预留 52×48，HUD 暂停按钮 48×48。没有将触控友好性换成小尺寸装饰按钮。
5. **质量门禁。** UI SVG 清单从 9 个扩展到 12 个；`RELEASE_MANIFEST.json`、版本配置与验收文档同步为 3.8.0-G/versionCode 34。`validate_visual_assets.py` 对 detail-normal 与基础法线隔离、法线振幅、鼠标/触屏模态关闭、整行设置点击、滑块/开关/滚动条原生主题覆盖增加静态护栏。

## 离线验证结果

- 9 个 GLB 模型：三角面、UV、法线、退化/重复面检查通过。
- 6 张 1024×1024 PBR 贴图：颜色/通道、接缝、粗糙度 Alpha 与源图一致性及装甲 detail-normal 振幅检查通过。
- 12 个 SVG：XML/viewBox/轻量矢量结构检查通过。
- 发布清单、Godot/Android 版本、资源引用、导入 UID、脚本词法结构、模式目录、玩法/存档/回放/生命周期/音频等离线合同通过。
- UI 门禁检查鼠标与 screen-touch 外部关闭、设置文字可点击、原生 HSlider/CheckButton/ScrollContainer 主题、至少 48px 的交互区域，以及 Esc/P/Android 系统返回的模态优先状态栈。
- 返回键门禁还检查执行顺序：无论由 Android 系统返回还是 Esc/P 进入暂停处理，必须先检查并关闭二级面板，再进入游戏状态转换；并检查 revive/gameover/menu 的返回映射。
- ZIP 已完整性校验；新建干净目录解压后，重新运行 `sh tools/run_offline_checks.sh`。引擎套件明确为 SKIP（见下方验收限制）。
- 维护验证器时出现一次静态正则误报：新增加的返回状态表先包含了字面量 `"revive"`，旧检查误把它当作 `_on_state()` 的 revive 分支。已将检查限定到 `_on_state()`，并新增模态关闭顺序护栏；修正规则后完整离线门禁通过。此项是验证器范围修复，不是跳过运行时失败。

## 验收限制

本执行环境无法解析外网域名，不能下载 Godot 4.7.2-stable。故本报告不宣称 GDScript 语义编译、着色器真实导入、Android 导出、主场景截图、触屏真机行为、平均/p95 FPS、GPU 时间或温度已经实测。离线检查不等于引擎编译；源代码事件合同不等于 Android 触屏验收。

## 下一步实测重点

1. 在 Godot 4.7.2-stable 中实际编译 `detail_normal` 材质，检查原有 GLB 法线是否保留、接缝是否过强，以及小尺寸载具的细节是否仍能辨识。
2. 在 Android 设备设置页测试触摸 HSlider、开关文字/开关图标、滚动条拖动、软键盘/焦点、系统返回与刘海安全区；尤其确认滑动音量只在结束时提交持久化。
3. 在暂停、设置、商店、任务、成就之间反复打开/关闭，确保遮罩外触摸关闭且内部点击不会误关闭；每个界面都按 Esc/P 与 Android 系统返回多次，确认第一次只关闭子面板，后方游戏状态不变。
4. 比较普通速度/超频下的材质与 UI 构成，再记录真实 FPS、p95 慢帧与长时间稳定性。
