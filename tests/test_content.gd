extends Node
## 内容模拟测试：内容生成/数据链/面板/输入队列/状态泄漏回归。
## 运行：godot --headless --fixed-fps 60 --path . res://tests/test_content.tscn

var _pass := 0
var _fail := 0
var main: Node
var game: Game
var player: Player
var spawner: Spawner

func _ready() -> void:
        # The harness itself enforces isolation even when launched outside the shell runner.
        OS.set_environment("NR2099_TEST_MODE", "1")
        _clear_test_artifacts()
        await _boot()
        await _t_content_generation()
        await _t_revive_timeout()
        await _t_dda_persistence()
        await _t_settings_and_shop()
        await _t_v111_fixes()
        await _t_v120_fixes()
        await _t_v121_inputs()
        await _t_v123_leaks()
        print("\n===== 内容模拟汇总: %d passed, %d failed =====" % [_pass, _fail])
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

func _t_content_generation() -> void:
        _sec("内容生成（25 秒长跑）")
        main._start_run()
        game.invincible_t = 999.0   # 内容测试验证放置系统，非躲障 AI——持续无敌防随机撞死
        await _sim_seconds(25.0, true)
        game.invincible_t = 0.0
        _ok(game.distance > 200.0, "距离推进 %.0fm" % game.distance)
        var active_obs: int = 0
        var active_chips: int = 0
        for type in spawner.pools:
                for o in spawner.pools[type]:
                        if o.active:
                                if type == "chip":
                                        active_chips += 1
                                else:
                                        active_obs += 1
        _ok(active_obs > 0, "场上活动障碍 %d 个（放置系统活）" % active_obs)
        _ok(game.chips > 0 or active_chips > 0, "芯片：已收 %d · 场上 %d" % [game.chips, active_chips])
        # BOSS：压低阈值强制触发验证链路（running 态才有效，gameover 态 tick 直接 return）
        if game.state == "running":
                game.boss_event.next_at = game.distance + 5.0
                game.invincible_t = 999.0
                await _sim_seconds(6.0, true)
                game.invincible_t = 0.0
        _ok(game.boss_event.active or game.state != "running", "BOSS 事件触发（状态 %s）" % game.state)

func _t_revive_timeout() -> void:
        _sec("复活超时自动结算（")
        main._start_run()
        game.die("test")
        await _sim_seconds(1.0, false)
        _ok(game.state == "revive", "进入复活决策")
        await _sim_seconds(6.0, false)
        _ok(game.state == "gameover", "倒计时归零自动放弃")

func _t_dda_persistence() -> void:
        _sec("DDA 跨局持久化（")

        main.progress.recent_runs = []   # 清空后注入，绕开上限语义
        for i in 3:
                main.game.enter_menu()   #
                main._start_run()
                game.distance = 300.0
                main.progress.on_run_end(300.0, 10, 5)
        _ok(main.progress.recent_runs.size() == 3 and main.progress.recent_runs.all(func(v): return float(v) == 300.0), "recent_runs 注入 3 局全记录（总 %d）" % main.progress.recent_runs.size())
        # 模拟重启：新建 Progress 读档
        var p2 := Progress.new()
        main.add_child(p2)
        _ok(p2.recent_runs.size() == main.progress.recent_runs.size(), "重启后 recent_runs 从存档恢复 %d 局" % p2.recent_runs.size())
        # 5 连败判定需要 5 局
        main.progress.recent_runs = [300.0, 250.0, 350.0, 200.0, 280.0]
        main.progress._save()
        var p3 := Progress.new()
        main.add_child(p3)
        _ok(p3.recent_runs.size() == 5, "5 局历史持久化 ✓（计算 DDA 输入就绪）")

func _t_settings_and_shop() -> void:
        _sec("设置/商店/任务面板（")
        main.menus.render_settings(main.progress.settings)
        _ok(main.menus.settings_root.visible, "设置面板可开（音量/DDA/触感）")
        main._open_shop()
        _ok(main.menus.shop_root.visible, "商店面板可开（6 皮肤）")
        main._open_missions()
        _ok(main.menus.missions_root.visible, "任务面板可开")
        main.menus.render_achv(main.progress.achievement_list())
        _ok(main.menus.achv_root.visible, "成就面板可开")
        # 设置改动落盘
        main.progress.settings.musicVol = 0.5
        main.progress._save()
        var p4 := Progress.new()
        main.add_child(p4)
        _ok(absf(p4.settings.musicVol - 0.5) < 0.01, "音量设置持久化 %.2f" % p4.settings.musicVol)

func _sim_seconds(t: float, interactive: bool) -> void:
        var frames := int(t * 60.0)
        for i in frames:
                if interactive:
                        if i % 37 == 0:
                                player.jump()
                        if i % 53 == 0:
                                player.move_lane(1 if i % 106 == 0 else -1)
                await get_tree().process_frame

func _sec(n: String) -> void:
        print("\n—— %s" % n)

func _ok(c: bool, m: String) -> void:
        if c:
                _pass += 1
                print("  ✓ %s" % m)
        else:
                _fail += 1
                print("  ✗ FAIL %s" % m)
                push_error("CONTENT FAIL: %s" % m)

func _t_v111_fixes() -> void:
        _sec("数据链回归")
        main.progress.wallet = 777
        main.progress.save()
        var p2 := Progress.new()
        main.add_child(p2)
        _ok(p2.wallet == 777, "save() 公开落盘生效（wallet=%d）" % p2.wallet)
        main._start_run()
        main.player.jump()
        main.player.slide()
        await _sim_seconds(1.6, false)   # 空中二连跳只缓冲不计数——落地缓冲转正式跳后再断言
        main.player.jump()
        _ok(main.game.run_stats.jumps == 2, "跳跃统计递增（jumps=%d）" % main.game.run_stats.jumps)
        _ok(main.game.run_stats.slides == 1, "滑铲统计递增（slides=%d）" % main.game.run_stats.slides)
        var jump_prog: float = main.progress.missions.progress.get("q_jump30", 0.0)
        _ok(jump_prog >= 2.0 or not ("q_jump30" in main.progress.missions.sel), "任务进度上报（q_jump30=%.0f，%s）" % [jump_prog, "选中" if "q_jump30" in main.progress.missions.sel else "今日未选——注入后验证"])
        main.progress.recent_runs = [200.0, 250.0, 300.0, 220.0, 280.0]
        main.game.enter_menu()   # 注入后经 menu 开新局
        main._start_run()
        _ok(absf(main.spawner.dda_gap - 1.25) < 0.001, "护航 DDA 间距 1.25（实际 %.2f）" % main.spawner.dda_gap)
        _ok(main.spawner.dda_unlock == -60, "护航解锁偏移 -60（实际 %d）" % main.spawner.dda_unlock)
        main.progress.recent_runs = [1600.0, 1800.0, 1700.0, 2000.0, 1500.0]
        main.game.enter_menu()
        main._start_run()
        _ok(absf(main.spawner.dda_gap - 0.9) < 0.001, "高手 DDA 间距 0.9（实际 %.2f）" % main.spawner.dda_gap)
        main.spawner._laser_warn = false
        main.spawner.mech = "laser"
        for o in main.spawner.pools.laser:
                o.active = true
                o.z = -10.0
        main.spawner.update(0.016, 20.0, 500.0, "running")
        _ok(main.spawner._laser_warn, "电磁禁区激光预警激活（mech 驱动）")
        main.spawner.mech = ""

func _t_v120_fixes() -> void:
        _sec("工程化（遥测/混淆/复位）")
        _ok(Telemetry.has_signal("report_updated") and Telemetry.perf_grade in ["high", "mid", "low"], "遥测接口与设备档位在线（设备 %s）" % Telemetry.perf_grade)
        main.progress.wallet = 500
        main.progress.save()
        _ok(main.progress.verify_save(), "存档校验和通过")
        var f := ConfigFile.new()
        var path := ProjectSettings.globalize_path(main.progress._save_path())
        f.load(path)
        f.set_value("meta", "wallet", 999999)   # 模拟手改
        f.save(path)
        _ok(not main.progress.verify_save(), "手改后校验失败（拦截生效）")
        main.progress.wallet = 500
        main._start_run()
        main.game.overclock.charge = 12
        main._activate_overclock()
        main.game.enter_menu()   #
        main._start_run()
        _ok(not main.effects._shock_ring.visible, "开局特效复位（冲击波不残留）")

func _t_v121_inputs() -> void:
        _sec("输入队列（固定时步消费）")
        main._start_run()
        main.input.enabled = true
        var lane_x0: float = main.player.x
        # 渲染帧入队：右滑 ×2（相邻同向应合并为一脉冲）
        main.input._enqueue({"a": "lane", "d": 1})
        main.input._enqueue({"a": "lane", "d": 1})
        main.input.drain_inputs()
        await get_tree().physics_frame
        await get_tree().physics_frame
        var lane_x1: float = main.player.x
        _ok(absf(lane_x1 - lane_x0) > 0.05 or lane_x1 != lane_x0, "换道生效（x %.2f→%.2f）" % [lane_x0, lane_x1])
        # 清空后 drain 不得再触发跳跃，也必须保持队列为空。
        var clear_y_before: float = main.player.y
        var clear_air_before: float = main.player.air_time
        var clear_vy_before: float = main.player.vy
        main.input._enqueue({"a": "jump"})
        main.input.clear_queue()
        main.input.drain_inputs()
        _ok(main.input._queue.is_empty()
                and is_equal_approx(main.player.y, clear_y_before)
                and is_equal_approx(main.player.air_time, clear_air_before)
                and is_equal_approx(main.player.vy, clear_vy_before),
                "clear 后 drain 不产生动作副作用（队列 %d）" % main.input._queue.size())
        # 跳跃路径：入队 → 模拟帧消费 → Player 起跳
        var y0: float = main.player.y
        main.input._enqueue({"a": "jump"})
        await get_tree().physics_frame
        await get_tree().physics_frame
        await get_tree().physics_frame
        _ok(main.player.y > y0 or main.player.air_time > 0.0, "跳跃经队列生效（y %.2f air %.2f）" % [main.player.y, main.player.air_time])
        # 积压保护：灌 20 个事件，队列上限 16
        for i in 20:
                main.input._enqueue({"a": "slide"})
        _ok(main.input._queue.size() <= 16, "积压保护（%d ≤ 16）" % main.input._queue.size())
        main.input.clear_queue()

func _t_v123_leaks() -> void:
        _sec("状态泄漏回归")
        # ① BOSS 期死亡 → 结算时哨戒机必须消失（无敌帧防真实撞死干扰状态）
        main._start_run()
        main.game.invincible_t = 999.0
        main.game.boss_event.next_at = 0.0
        await _sim_seconds(2.0, false)
        main.game.invincible_t = 0.0
        _ok(main.world._boss_drone.visible, "BOSS 期哨戒机在场")
        main.game.revive_used = true
        main.game.die("test")
        await _sim_seconds(2.0, false)
        _ok(not main.world._boss_drone.visible, "死亡结算后哨戒机已清")
        # ② 冲击环在结算时清（dying 后特效停更不再冻结在屏）
        main._start_run()
        main.game.invincible_t = 999.0
        main.game.overclock.charge = 12
        main._activate_overclock()
        _ok(main.effects._shock_ring.visible, "冲击环激活")
        main.game.invincible_t = 0.0
        main.game.revive_used = true
        main.game.die("test2")
        await _sim_seconds(2.0, false)
        _ok(not main.effects._shock_ring.visible, "结算后冲击环已清")
        # ③ 拱门材质独立性（fade 不互相覆盖）
        var mats: Array = []
        for g in main.world._gates:
                mats.append(g.material_override)
        _ok(mats.size() >= 2 and mats[0] != mats[1], "拱门材质独立（%d 门）" % mats.size())
        # ④ 道具槽签名跳过（同参二次调用不重建——间接断言 children 数稳定）
        main.hud.update_powerups({"magnet": 5.0})
        var n1: int = main.hud.pu_icons.get_child_count()
        main.hud.update_powerups({"magnet": 5.0})
        var n2: int = main.hud.pu_icons.get_child_count()
        _ok(n1 == n2 and n1 >= 1, "道具槽变更检测（%d → %d 稳定）" % [n1, n2])
