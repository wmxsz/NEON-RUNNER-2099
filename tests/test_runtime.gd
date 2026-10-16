extends Node
## 运行时模拟测试：装配完整 Main，模拟玩家输入跑一局，验证状态机全程。
## 运行：godot --headless --path . res://tests/test_runtime.tscn

var _pass := 0
var _fail := 0
var main: Node
var game: Game
var player: Player
var spawner: Spawner

func _ready() -> void:
        # 终检修复：档隔离（共享真档会被其他测试的设置写入污染）
        OS.set_environment("NR2099_TEST_MODE", "1")
        _clear_test_artifacts()
        # 后台可运行：禁音频（AudioStreamGenerator 无声卡 headless 下报错）
        await _boot()
        await _t_menu()
        await _t_run()
        await _t_death()
        await _t_revive_flow()
        await _t_dda()
        await _t_trace_storage()
        print("\n===== 运行时模拟汇总: %d passed, %d failed =====" % [_pass, _fail])
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

func _t_menu() -> void:
        _sec("菜单态")
        _ok(game.state == "menu", "初始为 menu")
        _ok(absf(game.speed - Config.SPEED.menu) < 2.0 or game.speed < 8.0, "菜单怠速")

func _t_run() -> void:
        _sec("起跑 → running")
        main._start_run()
        _ok(game.state == "running", "进入 running")
        await _sim_seconds(3.0)
        _ok(game.distance > 20.0, "3 秒跑出 %.0fm（速度曲线正常）" % game.distance)
        var speed_ok: bool = game.speed >= Config.SPEED.base - 5.0
        _ok(speed_ok, "速度爬升到 %.1f" % game.speed)

func _t_death() -> void:
        _sec("死亡 → dying → gameover")
        game.die("test")
        _ok(game.state == "dying", "进入 dying（hit-stop+慢动作）")
        await _sim_seconds(2.0)
        _ok(game.state == "gameover" or game.state == "revive", "死亡分流（实际 %s）" % game.state)

func _t_revive_flow() -> void:
        _sec("复活流")
        if game.state == "revive":
                game.prepare_revive()
                game.finish_revive()
                _ok(game.state == "running", "复活回到 running")
                _ok(game.invincible_t > 0.0, "复活无敌帧 %.1fs" % game.invincible_t)
                await _sim_seconds(3.0)
                _ok(game.state == "running" or game.state == "gameover", "复活后继续跑（实际 %s）" % game.state)
                if game.state == "running":
                        game.die("test2")
                        await _sim_seconds(2.0)
        _ok(game.state == "gameover", "二次死亡直接结算（免复活已用）")
        var result_text: String = main.menus.go_stats.text
        var expected_prefix: String = "狂奔 %dm" % int(game.distance)
        _ok(main.menus.gameover_root.visible, "结算界面实际显示")
        _ok(result_text.begins_with(expected_prefix) and result_text.contains("得分 %d" % int(game.score())),
                "结算距离/得分与本局状态一致（距离 %.0fm）" % game.distance)

func _t_dda() -> void:
        _sec("DDA 判定")
        main.progress.recent_runs = [300.0, 250.0, 350.0, 200.0, 280.0]
        _ok(main.compute_dda() == "gentle", "5 连败 → gentle 护航")
        main.progress.recent_runs = [1600.0, 1800.0, 1700.0, 2000.0, 1500.0]
        _ok(main.compute_dda() == "hardcore", "5 连胜 → hardcore 加压")
        main.progress.recent_runs = [800.0, 900.0, 700.0]
        _ok(main.compute_dda() == "", "样本不足 → 无 DDA")

func _t_trace_storage() -> void:
        _sec("输入回放原子保存与损坏恢复")
        var trace: Dictionary = {
                "schema": 2,
                "game_version": String(ProjectSettings.get_setting("application/config/version", "unknown")),
                "engine_version": String(Engine.get_version_info().get("string", "unknown")),
                "physics_hz": int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)),
                "ruleset_version": 1,
                "seed": 2099,
                "dda_enabled": false,
                "dda_mode": "",
                "frames": 3,
                "truncated": false,
                "replayable": true,
                "ineligibleReasons": [],
                "events": [{"frame": 1, "action": "jump"}, {"frame": 2, "action": "lane", "direction": 1}],
        }
        _ok(OS.get_environment("NR2099_TEST_MODE") == "1", "测试运行使用隔离 profile 环境")
        _ok(main._last_run_trace_path() == "user://nr2099_test_last_run_input_trace.json", "测试回放使用独立文件名")
        _ok(main._trace_document_is_well_formed(trace), "回放文档满足持久化 schema")
        _ok(main.input.validate_replay_trace(trace), "回放文档满足播放规则")
        var first_write_ok: bool = main._persist_last_run_trace(trace)
        _ok(first_write_ok, "第一份回放记录原子写入%s" % ("" if first_write_ok else "（%s）" % main._last_trace_persist_error))
        _ok(not main._persist_last_run_trace({"schema": 2}), "拒绝不完整记录而不覆盖上次有效记录")
        var preserved: Dictionary = main._read_valid_last_run_trace()
        _ok(int(preserved.get("seed", 0)) == 2099, "无效新记录不会污染有效主记录")
        var replacement := trace.duplicate(true)
        replacement["seed"] = 2100
        var replacement_ok: bool = main._persist_last_run_trace(replacement)
        _ok(replacement_ok, "覆盖时保留上一份有效备份%s" % ("" if replacement_ok else "（%s）" % main._last_trace_persist_error))
        var primary := FileAccess.open(main._last_run_trace_path(), FileAccess.WRITE)
        if primary != null:
                primary.store_string("{broken-json")
                primary.flush()
                primary.close()
        _ok(primary != null, "能够模拟中断造成的损坏主文件")
        var recovered: Dictionary = main._read_valid_last_run_trace()
        _ok(int(recovered.get("seed", 0)) == 2099, "主记录损坏时回退到上一份可验证记录")

func _sim_seconds(t: float) -> void:
        # headless 帧驱动：恒定 60fps 注入
        var frames := int(t * 60.0)
        for i in frames:
                if i % 37 == 0:
                        player.jump()      # 模拟玩家乱跳
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
                push_error("RUNTIME FAIL: %s" % m)
