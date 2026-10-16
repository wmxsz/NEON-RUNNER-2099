# v4.1.0-G 干净交付审计：确定性测试与原生 PBR 保真

## 本轮目标

从 v4.0.0-G 继续优化，重点修复可能“无条件通过”的测试、随机样本导致的偶发失败，以及通用材质增强覆盖模型原有 PBR 资源的问题。

## 实质修改

1. `tests/test_content.gd`：输入队列清空后检查队列确实为空，并验证同步 drain 没有改变玩家 y 与 air_time，而不再使用常量真值断言。
2. `tests/test_runtime.gd`：结算测试要求 `gameover_root` 实际显示，且结算文案的距离、分数与当前游戏状态匹配。
3. `tests/test_mechanics.gd` 与 `entities/spawner.gd`：将候选模式池构建提取为 `_candidate_pattern_pool()`，对激光加密机制进行确定性权重池测试，不再依赖一次性随机命中数比较。
4. `core/config.gd`：`laserWeightMult` 从 3.4 显示值改为 3.0。旧代码已经通过 `int()` 截断，所以有效重复入池数量和生成顺序保持不变。此配置是候选池采样权重，不代表最终命中概率精确乘以 3。
5. `world/world.gd`：仅当导入 GLB 的原材质没有 `roughness_texture` 时，才补充通用 `ARMOR_ROUGHNESS`；保留有真实粗糙度贴图的模型资源。
6. `run_tests.sh`：headless 测试统一添加 `--audio-driver Dummy`，降低无声卡 CI 环境差异。
7. `tools/validate_release_contracts.py`：新增禁止 `_ok(true, ...)`/`assert(true)` 的规则，并要求使用确定性激光候选池测试与源材质粗糙度保真条件。
8. 版本、README、发布状态、开发/回归说明和当前审计链接已更新到 `4.1.0-G` / Android `versionCode=37`。上一版审计移至 `docs/audit/archive/`。

## 离线验收范围

- Python 工具 `py_compile`、项目完整性、版本/导出身份一致性与源码合同。
- 9 个 GLB、6 张 PBR 贴图、9 首 OGG、12 个 WAV、12 个 SVG、资源引用和导入 UID。
- 确定性激光候选池合同、导入材质 roughness 保留规则、存档/回放/音频/玩法/生命周期门禁。
- 最终 ZIP 完整性和空白解压目录内的重复离线检查。

## 真实验收边界

当前执行环境没有 Godot 4.7.2-stable 可执行文件，并且无法解析官方分发主机。因此本报告不声称 GDScript 语义编译、Shader 导入、真实场景运行或 Android FPS/p95 已通过。`tools/run_godot_tests.sh` 在引擎缺失时会明确报告 `SKIP`。