# 游戏生命周期契约

> 当前开发基线：v4.3.0-G（Android versionCode=39）。


## v4.2.0-G 当前维护约定

- 方向光和辉光必须通过 `World.set_perf_profile()` 分档，并可从 Telemetry 的 `renderBudget` 诊断快照确认实际生效配置。
- 道路细小蚀刻/导轨的屏幕空间抗闪烁必须使用 `cyber_line_coverage()`，不能以降低渲染分辨率或关闭 4× MSAA 替代。
本文件是处理“刚开局有上局残留/输入/特效/音乐状态不一致”时的首要参考。修正开始流程必须保留这里的顺序，并由离线校验器保护。

## 新局的两阶段提交

### 阶段 A：准备（不广播 `running`）

1. 只接受 `menu` 或 `gameover` 状态的新局请求；拒绝运行中重复点击，并用 `_starting_run` 防止重入。
2. 立刻关闭输入并清空输入队列，避免重开时排队的旧动作落到第一帧。
3. 生成并记录本局 seed，读取 DDA 模式，重置章节音乐索引与复活倒计时。
4. 根据 DDA 模式设置障碍间距/解锁距离，然后 `Spawner.reset(seed)` 清空活动对象和模式缓存。
5. `Player.reset()` 完整清除物理、动作缓冲、动画/死亡姿态、章节机制与皮肤轮廓的瞬时旋转；随后应用存档皮肤。
6. `Effects.reset_fx()` 并关闭雨效；复位世界中的 Boss/超频表现和音频 Boss/超频锁、连击增益。
7. `Progress.on_run_start()` 处理持久化局数和单局任务进度。

### 阶段 B：提交新局

8. 最后调用 `Game.start_run(dda, seed)`。该方法清空 Game 自己拥有的局内状态，再发出 `state_changed("running")`。
9. 之后显示游戏 HUD，启动背景音乐并解锁音频。状态事件此时才启用输入；所有子系统已完成准备。

**禁止**将 `Game.start_run()` 移回重置步骤开头。状态事件是提交点，不是初始化命令。

## 状态转移

| 当前状态 | 允许动作 | 目标状态 | 状态信号要求 |
|---|---|---|---|
| `menu` | 新局 | `running` | `Game.start_run()` 发出 |
| `gameover` | 重开 | `running` | 先清场，再 `Game.start_run()` 发出 |
| `running` | 暂停 | `paused` | `Game.pause_run()` 发出 |
| `paused` | 继续 | `running` | `Game.resume_run()` 发出 |
| `running` | 撞击死亡 | `dying` | `Game.die()` 发出 |
| `dying` | 复活决策 | `revive` | `Game.offer_revive_or_gameover()` 发出 |
| `revive` | 接受 | `running` | `Game.accept_revive()` 发出 |
| `dying/revive` | 结束 | `gameover` | `_finish_gameover()` 发出 |
| 任意适当状态 | 回主菜单 | `menu` | `Game.enter_menu()` 发出 |

## 新增跨局状态时的规则

每加一项新状态（例如冲刺、护甲、临时视觉闪光或音频锁），必须明确回答：

- 谁拥有它？
- 在哪个 `reset()` 或状态转移中清除？
- 复活时是否保留？新局是否必须清除？
- 它是否会影响下一局的首帧？
- 有什么离线/引擎回归检查覆盖它？

不允许只靠“等下一帧会自然改回来”。
