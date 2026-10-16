extends Node
## ============================================================
## headless 逻辑测试（CI 自证层）：配置/数值/信号契约断言。
## 运行：godot --headless --path . res://tests/test_headless.tscn
## 原则：只断言当前生效配置（历史迁移语义进 docs/CHANGELOG）；
##
## ============================================================

var _pass := 0
var _fail := 0
var _section := ""

func _init() -> void:
        OS.set_environment("NR2099_TEST_MODE", "1")

func _ready() -> void:
        await _run_all()
        var code := 1 if _fail > 0 else 0
        print("\n=========== 测试汇总: %d passed, %d failed ===========" % [_pass, _fail])
        get_tree().quit(code)

func _run_all() -> void:
        _sec("Config · 调色板与车道")
        _ok(Config.PALETTE.size() == 11, "调色板 11 色")
        _ok(Config.LANES.size() == 3, "三车道")
        _ok(Config.LANES[1] == 0.0 and is_equal_approx(Config.LANES[0], -Config.LANES[2]), "车道中心对称")
        _ok(is_equal_approx(Config.LANES[2] - Config.LANES[1], 2.3), "车道间距 2.3m")

        _sec("Config · 手感物理（跳跃抛物线）")
        var g: float = absf(Config.PHYSICS.gravity)
        var v: float = Config.PHYSICS.jumpVel
        var t_air: float = 2.0 * v / g
        var h_apex: float = v * v / (2.0 * g)
        _ok(t_air > 0.5 and t_air < 0.8, "滞空 %.3fs ∈ (0.5, 0.8) 可玩区间" % t_air)
        _ok(h_apex > 1.6 and h_apex < 2.6, "跳高 %.2fm ∈ (1.6, 2.6) 障碍可跨越" % h_apex)
        _ok(Config.PHYSICS.slideTime > 0.3 and Config.PHYSICS.slideTime < 1.0, "滑铲时长可玩")
        _ok(Config.PHYSICS.laneImpulse > 0.0 and Config.PHYSICS.laneFriction > 0.0, "车道脉冲/摩擦为正")
        _ok(Config.PHYSICS.laneWallBounce > 0.0 and Config.PHYSICS.laneWallBounce < 1.0, "撞墙反弹系数 ∈ (0,1)")

        _sec("Config · 速度曲线")
        var t_max: float = (Config.SPEED.max - Config.SPEED.base) / Config.SPEED.accel
        _ok(is_equal_approx(t_max, 90.9090909) or absf(t_max - 91.0) < 0.1, "到极速 %.1fs（" % t_max)
        _ok(Config.SPEED.menu < Config.SPEED.base, "菜单怠速 < 基础速度")
        _ok(Config.SPEED.base < Config.SPEED.max, "基础 < 极速")
        var oc_top: float = Config.SPEED.max * Config.SPEED.overclockMult
        _ok(oc_top < 50.0, "超频极速 %.1f < 50 合理上限" % oc_top)

        _sec("Config · 章节主题")
        _ok(Config.THEMES.size() == 8, "8 章主题（")
        var names := {}
        for t in Config.THEMES:
                _ok(t.fogDensity >= 0.015 and t.fogDensity <= 0.05, "章『%s』雾密度 %.3f ∈ [0.015, 0.05]" % [t.name, t.fogDensity])
                _ok(t.fog != Config.PALETTE.bg, "章『%s』雾色 ≠ 背景" % t.name)
                names[t.name] = true
        _ok(names.size() == 8, "章节名唯一")
        _ok(Config.THEME_LEN == 1000.0, "每章 1000m")

        _sec("Config · 超频 / 计分 / 世界")
        _ok(Config.OVERCLOCK.chipsNeeded > 0 and Config.OVERCLOCK.duration > 0.0, "超频参数为正")
        _ok(Config.SCORING.perMeter > 0.0 and Config.SCORING.perChip > 0.0, "计分率为正")
        _ok(Config.WORLD.roadCycleLength > 0.0, "路面周期为正")
        _ok(Config.WORLD.buildingMinH < Config.WORLD.buildingMaxH, "楼高区间有效")
        _ok(Config.WORLD.rainCount > 0, "雨粒子数为正")

        _sec("Config · 镜头")
        _ok(Config.CAMERA.fovPortrait > Config.CAMERA.fovLandscape, "竖屏 FOV > 横屏 FOV")
        _ok(Config.DEFAULT_SETTINGS.cameraShake == 0.75, "相机震动默认强度 75%")
        _ok(Config.CAMERA.followX > 0.0 and Config.CAMERA.followX <= 1.0, "横向跟随比例 ∈ (0,1]")
        _ok(Config.CAMERA.fovOverclockBoost > 0.0, "超频 FOV 增幅为正")

        _sec("Config · 道具系统")
        var d: Dictionary = Config.POWERUPS
        _ok(d.magnet.duration > 0.0 and d.double.duration > 0.0 and d.board.duration > 0.0, "磁/倍/板时长为正")
        _ok(d.shield.duration == 0.0, "护盾为一次性（时长 0）")
        _ok(d.board.duration > d.double.duration and d.double.duration > d.magnet.duration, "时长排序 板>倍>磁")
        _ok(String(d.magnet.name).length() > 0 and String(d.shield.desc).length() > 0, "道具文案非空")
        _ok(Config.POWERUP_CFG.spawnChance > 0.0 and Config.POWERUP_CFG.spawnChance < 1.0, "道具出现率 ∈ (0,1)")
        _ok(Config.POWERUP_CFG.minInterval >= 1, "道具最小间隔 ≥ 1 模式")

        _sec("Config · 复活")
        _ok(Config.REVIVE.countdown == 5.0, "复活决策窗 5s")
        _ok(Config.REVIVE.invincible > 1.0, "复活无敌 > 1s")
        _ok(Config.REVIVE.clearRadius > 0.0, "复活清障半径为正")

        _sec("Config · 成就 / 任务 / 存档键")
        _ok(Config.ACHIEVEMENTS.size() == 13, "成就 13 枚")
        var ids := {}
        for a in Config.ACHIEVEMENTS:
                ids[a.id] = true
        _ok(ids.size() == 13, "成就 id 唯一")
        var pool: Array = Config.MISSION_DEFS.filter(func(m): return m.has("run"))
        _ok(pool.size() == 6, "单局任务池 6 条")
        var mid := {}
        for m in Config.MISSION_DEFS:
                _ok(m.target > 0.0 and m.reward > 0, "任务『%s』目标/奖励为正" % m.id)
                mid[m.id] = true
        _ok(mid.size() == Config.MISSION_DEFS.size(), "任务 id 唯一")

        var p_probe := Progress.new()
        get_tree().root.add_child.call_deferred(p_probe)
        await get_tree().process_frame
        _ok(p_probe.SAVE_PATH.begins_with("user://nr2099_"), "存档路径前缀 %s" % p_probe.SAVE_PATH)
        _ok(p_probe.has_method("_is_test_mode"), "测试模式查询接口存在")
        var test_mode_value: Variant = p_probe.call("_is_test_mode")
        _ok(typeof(test_mode_value) == TYPE_BOOL, "测试模式查询返回布尔值")
        _ok(Config.DEFAULT_SETTINGS.musicVol > 0.0 and Config.DEFAULT_SETTINGS.sfxVol > 0.0, "默认音量为正")

        _sec("EventBus · 信号契约（")
        for sig_name in ["jumped", "slid"]:
                _ok(EventBus.has_signal(sig_name), "信号 %s" % sig_name)
        _ok(not EventBus.has_signal("game_state_changed"), "死信号已清（game_state_changed）")
        var local_sigs: Array = []
        for s in Game.new().get_signal_list():
                local_sigs.append(String(s.name))
        for need in ["state_changed", "died", "revived", "boss_started", "boss_burst", "boss_survived"]:
                _ok(need in local_sigs, "Game 本地信号 %s" % need)

func _sec(name: String) -> void:
        _section = name
        print("\n—— %s" % name)

func _ok(cond: bool, msg: String) -> void:
        if cond:
                _pass += 1
                print("  ✓ %s" % msg)
        else:
                _fail += 1
                print("  ✗ FAIL %s" % msg)
                push_error("TEST FAIL [%s] %s" % [_section, msg])
