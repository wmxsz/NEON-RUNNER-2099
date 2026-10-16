extends Node
## 机制测试：章节机制/音频总线/粒子预算/设备分级感知断言。
## 运行：godot --headless --fixed-fps 60 --path . res://tests/test_mechanics.tscn

var _pass := 0
var _fail := 0
var main: Node
var game: Game
var player: Player
var spawner: Spawner
var audio: AudioEngine
var world: World

func _ready() -> void:
        OS.set_environment("NR2099_TEST_MODE", "1")
        _clear_test_artifacts()
        await _boot()
        await _t_mech_by_distance()
        await _t_low_grav_jump()
        await _t_rain_slow()
        await _t_laser_weight_pool()
        await _t_native_cyber_sky()
        await _t_render_budget_profiles()
        await _t_input_focus_loss()
        await _t_audio_and_visual()
        print("\n===== 机制测试汇总: %d passed, %d failed =====" % [_pass, _fail])
        get_tree().quit(1 if _fail > 0 else 0)

func _clear_test_artifacts() -> void:
        for base_path in ["user://nr2099_test_save.cfg", "user://nr2099_test_last_run_input_trace.json"]:
                for suffix in ["", ".bak", ".tmp", ".corrupt"]:
                        var relative_path: String = base_path + suffix
                        if FileAccess.file_exists(relative_path):
                                DirAccess.remove_absolute(ProjectSettings.globalize_path(relative_path))

func _boot() -> void:
        var ps: PackedScene = load("res://scenes/main.tscn")
        main = ps.instantiate()
        get_tree().root.add_child.call_deferred(main)
        await get_tree().process_frame
        await get_tree().process_frame
        game = main.game
        player = main.player
        spawner = main.spawner
        audio = main.audio
        world = main.world

func _t_mech_by_distance() -> void:
        _sec("章节机制 · 距离驱动")
        main._start_run()
        game.invincible_t = 999.0
        # 各章节距离点验证 mech 字段兑现
        var checks := [[100.0, ""], [1100.0, "rain"], [2100.0, "lowg"], [3100.0, "laser"], [4100.0, ""],
                [5100.0, "float"], [6100.0, "ice"], [7100.0, ""]]   # 新三章
        for c in checks:
                game.distance = c[0]
                game.update_mech()
                _ok(game.current_mech == c[1], "%dm → mech=%s（期望 %s）" % [c[0], game.current_mech, c[1]])
        game.distance = 0.0
        game.update_mech()
        _ok(game.current_mech == "", "复位")

func _t_low_grav_jump() -> void:
        _sec("天港低重力跳（更高更飘）")
        player.reset()
        player.mech = "lowg"
        player.jump()
        var vy_lowg: float = player.vy
        var jump_v: float = Config.PHYSICS.jumpVel * Config.MECH_CFG.lowJumpMult
        _ok(absf(vy_lowg - jump_v) < 0.01, "起跳速度 %.2f（期望 %.2f）" % [vy_lowg, jump_v])
        # 低重力滞空时长对比（解析法）
        var g_norm: float = absf(Config.PHYSICS.gravity)
        var g_low: float = absf(Config.PHYSICS.gravity) * Config.MECH_CFG.lowGravMult
        var t_norm: float = 2.0 * Config.PHYSICS.jumpVel / g_norm
        var t_low: float = 2.0 * jump_v / g_low
        _ok(t_low > t_norm * 1.5, "滞空 %.2fs > 常规 %.2fs ×1.5" % [t_low, t_norm])
        player.mech = ""

func _t_rain_slow() -> void:
        _sec("酸雨减速")
        game.speed = 20.0
        game.overclock.active = false
        game.current_mech = "rain"
        var spd_rain: float = game.eff_speed()
        game.current_mech = ""
        var spd_norm: float = game.eff_speed()
        _ok(absf(spd_rain - spd_norm * Config.MECH_CFG.rainSpeedMult) < 0.001, "雨天 %.2f = 常规 %.2f × %.2f" % [spd_rain, spd_norm, Config.MECH_CFG.rainSpeedMult])

func _t_laser_weight_pool() -> void:
        _sec("电磁禁区激光加密（确定性权重池）")
        var base_pool: Array = spawner._candidate_pattern_pool(1000.0, false)
        var laser_pool: Array = spawner._candidate_pattern_pool(1000.0, true)
        var base_laser_count: int = _count_laser_candidates(base_pool)
        var boosted_laser_count: int = _count_laser_candidates(laser_pool)
        var base_other_count: int = base_pool.size() - base_laser_count
        var boosted_other_count: int = laser_pool.size() - boosted_laser_count
        var weight_factor: int = int(Config.MECH_CFG.laserWeightMult)
        _ok(base_laser_count > 0, "基础候选池包含激光模式")
        _ok(boosted_laser_count == base_laser_count * weight_factor,
                "激光候选权重精确 ×%d（%d → %d）" % [weight_factor, base_laser_count, boosted_laser_count])
        _ok(boosted_other_count == base_other_count,
                "非激光候选数量不变（%d）" % boosted_other_count)
        spawner.mech = ""

func _count_laser_candidates(candidates: Array) -> int:
        var n: int = 0
        for pattern: Dictionary in candidates:
                if "laser" in JSON.stringify(pattern.get("obs", [])):
                        n += 1
        return n

func _t_native_cyber_sky() -> void:
        _sec("Godot 原生赛博天空与移动端辐射贴图预算")
        var found := world.find_children("*", "WorldEnvironment", true, false)
        _ok(not found.is_empty(), "WorldEnvironment 原生环境节点存在")
        if found.is_empty():
                return
        var world_env := found[0] as WorldEnvironment
        _ok(world_env.environment != null, "Environment 资源已绑定")
        if world_env.environment == null:
                return
        var env_res := world_env.environment
        _ok(env_res.background_mode == Environment.BG_SKY, "背景使用 Godot 原生 BG_SKY")
        _ok(env_res.sky != null, "天空资源已绑定")
        if env_res.sky == null:
                return
        var sky := env_res.sky
        _ok(sky.radiance_size == Sky.RADIANCE_SIZE_128, "环境辐射贴图尺寸限制为 128")
        _ok(sky.process_mode == Sky.PROCESS_MODE_INCREMENTAL, "环境辐射贴图增量生成")
        var sky_mat := sky.sky_material as ProceduralSkyMaterial
        _ok(sky_mat != null, "天空使用原生 ProceduralSkyMaterial")
        if sky_mat == null:
                return
        _ok(sky_mat.use_debanding, "天空渐变启用去色带")
        _ok(sky_mat.sky_top_color != sky_mat.sky_horizon_color and sky_mat.ground_horizon_color != sky_mat.ground_bottom_color, "赛博天空拥有多段色彩过渡")


func _t_render_budget_profiles() -> void:
        _sec("原生分档阴影与多层霓虹辉光预算")
        var env_nodes := world.find_children("*", "WorldEnvironment", true, false)
        _ok(not env_nodes.is_empty(), "渲染预算测试找到 WorldEnvironment")
        if env_nodes.is_empty() or not is_instance_valid(world._sun_light):
                return
        var deck_root := world.get_node_or_null("RoadDeckHardware") as Node3D
        _ok(deck_root != null, "道路实体横肋硬件根节点存在")
        if deck_root != null:
                var ribs := deck_root.get_node_or_null("MachinedDeckRibs") as MultiMeshInstance3D
                var fasteners := deck_root.get_node_or_null("TitaniumDeckFasteners") as MultiMeshInstance3D
                _ok(ribs != null and ribs.multimesh != null and ribs.multimesh.instance_count == world._deck_hardware_instances, "机械横肋经单个 MultiMesh 批量绘制")
                _ok(fasteners != null and fasteners.multimesh != null and fasteners.multimesh.instance_count == world._deck_hardware_instances * 6, "钛合金紧固件经单个 MultiMesh 批量绘制")
                if fasteners != null:
                        var fastener_material := fasteners.material_override as StandardMaterial3D
                        _ok(fastener_material != null and fastener_material.metallic >= 0.85 and fastener_material.roughness <= 0.25, "紧固件使用高金属度低粗糙度原生 PBR")
                _ok(ribs.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and fasteners.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "地面微细节关闭额外投影成本")
        var env_node := env_nodes[0] as WorldEnvironment
        var env_res := env_node.environment
        _ok(env_res != null, "渲染预算环境有效")
        if env_res == null:
                return
        world.set_perf_profile("high")
        var high_snapshot: Dictionary = world.get_render_budget_snapshot()
        _ok(world._sun_light.shadow_enabled, "高档启用方向光阴影")
        _ok(world._sun_light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "高档使用四分区原生阴影")
        _ok(is_equal_approx(world._sun_light.directional_shadow_max_distance, 60.0), "高档阴影覆盖 60m")
        _ok(high_snapshot.glowEnabled and high_snapshot.glowLevels.size() == 5, "高档使用 5 层辉光")

        world.set_perf_profile("mid")
        var mid_snapshot: Dictionary = world.get_render_budget_snapshot()
        _ok(world._sun_light.shadow_enabled, "中档保留阴影")
        _ok(world._sun_light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "中档降为双分区阴影")
        _ok(is_equal_approx(world._sun_light.directional_shadow_max_distance, 42.0), "中档阴影距离收敛到 42m")
        _ok(mid_snapshot.glowEnabled and mid_snapshot.glowLevels.size() == 3, "中档仅使用 3 层辉光")

        world.set_perf_profile("low")
        var low_snapshot: Dictionary = world.get_render_budget_snapshot()
        _ok(not world._sun_light.shadow_enabled, "低档禁用方向光阴影")
        _ok(not low_snapshot.glowEnabled and low_snapshot.glowLevels.is_empty(), "低档常态关闭全部辉光层")
        world.overclock_on(true)
        var low_boost: Dictionary = world.get_render_budget_snapshot()
        _ok(low_boost.glowEnabled and low_boost.glowLevels.size() == 2, "低档超频仅恢复两层局部辉光")
        world.overclock_on(false)
        _ok(not world._env.glow_enabled, "超频结束后恢复低档辉光策略")
        world.set_perf_profile(Telemetry.perf_grade)

func _t_input_focus_loss() -> void:
        _sec("移动端失焦时取消半截触控手势")
        main.input._active_touch_index = 2
        main.input._touch_started_enabled = true
        main.input._moved = true
        main.input._queue.clear()
        main.input._queue.append({"a": "jump"})
        main.input._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
        _ok(main.input._active_touch_index == -1, "应用失焦复位活动触点")
        _ok(not main.input._touch_started_enabled and main.input._queue.is_empty(), "失焦同时丢弃旧手势与待处理输入")

func _t_audio_and_visual() -> void:
        _sec("音频进化 + 视觉常量")
        audio.set_chorus_lock(true)
        await get_tree().process_frame
        _ok(audio._music_idx == 8, "BOSS 战歌切换（music_idx=%d=8）" % audio._music_idx)
        audio.set_chorus_lock(false)
        await get_tree().process_frame
        _ok(audio._music_idx != 8, "战后回落章节曲（music_idx=%d）" % audio._music_idx)
        # 音频总线效果存在性

        var music_idx: int = AudioServer.get_bus_index("Music")
        var sfx_idx: int = AudioServer.get_bus_index("SFX")
        _ok(music_idx >= 0 and sfx_idx >= 0, "Music/SFX 双总线存在（")
        _ok(AudioServer.get_bus_effect_count(sfx_idx) >= 1, "SFX 总线带效果（≥1）")
        # 粒子预算
        # 分级感知：粒子预算随 Telemetry.perf_grade 缩放（low 500/120 · mid 900/180 · high 1200/260）
        var expect_rain: int = { "low": 500, "mid": 900, "high": 1200 }[Telemetry.perf_grade]
        var expect_lines: int = { "low": 120, "mid": 180, "high": 260 }[Telemetry.perf_grade]
        _ok(main.effects._rain.amount == expect_rain, "雨粒子 %d（%s 档）" % [expect_rain, Telemetry.perf_grade])
        _ok(main.effects._speed_lines.amount == expect_lines, "速度线 %d（%s 档）" % [expect_lines, Telemetry.perf_grade])
        _ok(main.effects._shards.size() == 48, "碎裂池 48（原 16）")
        # BOSS 3D
        world.boss_show(true)
        _ok(world._boss_drone.visible, "BOSS 哨戒机 3D 可显示")
        world.boss_show(false)
        # 冲击波
        main.effects.shockwave(0.0)
        _ok(main.effects._shock_ring.visible, "超频冲击波环激活")
        # 濒死覆盖层
        main.hud.set_dying(true)
        _ok(main.hud._dying_overlay.visible, "濒死故障色覆盖层激活")
        main.hud.set_dying(false)

func _sec(n: String) -> void:
        print("\n—— %s" % n)

func _ok(c: bool, m: String) -> void:
        if c:
                _pass += 1
                print("  ✓ %s" % m)
        else:
                _fail += 1
                print("  ✗ FAIL %s" % m)
                push_error("V110 FAIL: %s" % m)
