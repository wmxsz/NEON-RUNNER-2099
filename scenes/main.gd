extends Node3D
## 主场景编排入口：连接 Game、World、Player、Spawner、Effects、Audio、Progress、Input、HUD、Menus 与相机。
## 跨系统状态迁移通过明确的公共接口和信号完成；各系统保留自己的复位职责。

var game: Game
var world: World
var player: Player
var spawner: Spawner
var effects: Effects
var audio: AudioEngine
var progress: Progress
var input: Node
var hud: HUD
var post_fx: PostFX   # 赛博后期层
var menus: Menus

var cam: Camera3D
var cam_look := Vector3(0, 1.1, -10)
var _camera_base_position: Vector3 = Vector3.ZERO
var _camera_shake_phase: float = 0.0
var _camera_shake_envelope: float = 0.0
var _camera_shake_strength: float = 0.75
var _revive_t: float = 0.0
var _settings: Dictionary
var _starting_run: bool = false
var _is_replay_run: bool = false
var _app_suspended: bool = false
var _app_bgm_was_playing: bool = false
# Reuse the small effects payload instead of allocating a Dictionary + Vector3 on every physics tick.
var _effect_player_info: Dictionary = {"pos": Vector3.ZERO, "boost": false}
# Last low-level write failure is retained for diagnostics/tests; never shown to players.
var _last_trace_persist_error: String = ""

func _ready() -> void:
        game = Game.new()
        add_child(game)
        world = World.new()
        add_child(world)
        player = Player.new()
        add_child(player)
        spawner = Spawner.new()
        add_child(spawner)
        effects = Effects.new()
        add_child(effects)
        audio = AudioEngine.new()
        add_child(audio)
        progress = Progress.new()
        progress.save_failed.connect(_on_save_failed)
        add_child(progress)
        input = preload("res://systems/input.gd").new()
        add_child(input)
        post_fx = preload("res://fx/post_fx.tscn").instantiate()
        add_child(post_fx)
        hud = HUD.new()
        add_child(hud)
        menus = Menus.new()
        add_child(menus)
        cam = Camera3D.new()
        add_child(cam)
        _setup_cam()
        player.apply_skin(progress.current_skin)
        Telemetry.configure_targets(world, effects) # Telemetry owns its internal grade application.
        _bind_signals()
        _settings = progress.settings
        _camera_shake_strength = clampf(float(_settings.get("cameraShake", 0.75)), 0.0, 1.0)
        audio.apply_volumes(_settings.musicVol, _settings.sfxVol)
        var show_perf := bool(_settings.get("showFps", false))
        Telemetry.set_enabled(show_perf)
        hud.set_perf_visible(show_perf)
        menus.refresh_meta(progress.stats.best, progress.wallet)
        game.enter_menu()

func _setup_cam() -> void:
        # Camera smoothing/aiming is deliberately render-rate driven in _process.
        # Disable native physics interpolation on this node to avoid double smoothing.
        cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
        cam.fov = Config.CAMERA.fovPortrait
        cam.near = 0.1
        cam.far = float(Config.RUNTIME.viewDistance)
        cam.position = Vector3(Config.CAMERA.pos.x, Config.CAMERA.pos.y, Config.CAMERA.pos.z)
        _camera_base_position = cam.position
        cam_look = Vector3(Config.CAMERA.lookAt.x, Config.CAMERA.lookAt.y, Config.CAMERA.lookAt.z)

## 固定时步架构（大厂标准）：
## _physics_process @60Hz —— 全部游戏模拟（确定性，高刷机/低刷机手感一致）
## _process —— 纯渲染：相机跟随 + UI（吃插值平滑）
## 物理插值：玩家视觉位置 = 上两物理帧位姿 lerp（Runner 的障碍移动由渲染帧驱动补偿）
const SIM_HZ := 60.0
const SIM_DT := 1.0 / SIM_HZ

var _last_theme_idx: int = -1   # 章节曲防重切；每局开始/复活时强制重新选曲

func _physics_process(_dt: float) -> void:
        if _app_suspended:
                return
        # 输入队列消费在模拟帧头部（渲染帧入队 → 此处统一消费，时序合一）
        input.drain_inputs()
        # project.godot configures the engine at SIM_HZ; use the same fixed delta here.
        game.tick(SIM_DT)                # Game applies time_scale/hit-stop internally.
        var dt: float = game.frame_dt    # 缩放后的模拟 dt
        if game.state == "menu":
                world.update(dt, Config.SPEED.menu, "menu")
                world.apply_theme(0.0, dt)
        elif game.state == "running" or game.state == "dying":
                game.update_mech()   # 章节机制刷新
                player.mech = game.current_mech
                spawner.mech = game.current_mech
                var spd: float = game.eff_speed()
                world.update(dt, spd, game.state)
                world.apply_theme(game.distance, dt)
                player.update(dt, spd, game.state)
                spawner.update(dt, spd, game.distance, game.state)
                effects.set_rain_active(game.state == "running" and game.current_mech == "rain")
                if game.state == "running":
                        # check owns the per-frame result; avoid constructing a throwaway result first.
                        var res: Spawner.HitResult = spawner.check(player, game.overclock.active, game.powerups.magnet > 0.0, game.powerups.board > 0.0, dt)
                        if res.smashed > 0:
                                game.on_smash(res.smashed, res.overclock_smashed)
                        _handle_hits(res)
                        if res.near_miss:
                                game.on_near_miss()
                                if not _is_replay_run:
                                        progress.on_near_miss()
                        if res.chips > 0:
                                audio.play_sfx("chip")
                else:
                        effects.set_rain_active(false)
                _update_effects(dt, spd)
                hud.update_run(game.score(), game.distance, game.chips, game.combo)
                hud.update_oc(game.overclock.charge, Config.OVERCLOCK.chipsNeeded, game.overclock.active)
                hud.update_powerups(game.powerups)
                audio.set_combo_lvl(int(game.combo / 8.0))   #：数据链连击驱动 BGM 亮度
                var theme_idx: int = int(game.distance / Config.THEME_LEN) % Config.THEMES.size()
                if theme_idx != _last_theme_idx:   #：变更才切曲（去每帧 spam + 防 BOSS 曲被覆盖）
                        _last_theme_idx = theme_idx
                        audio.set_theme(theme_idx)
        elif game.state == "revive":
                if _revive_t > 0.0:
                        _revive_t -= _dt
                        menus.show_revive(_revive_t)
                else:
                        game.decline_revive()   # 倒计时结束时自动放弃复活。

func _process(raw_dt: float) -> void:
        if _app_suspended:
                return
        _update_camera(raw_dt)
        var world_advancing: bool = game.state == "menu" or game.state == "running" or game.state == "dying"
        # Transforms use native physics interpolation; shader-only motion needs the same
        # interpolation fraction explicitly or the cyber-deck lines would still step at 60 Hz.
        world.update_render_interpolation(world_advancing)
        if game.state == "running" or game.state == "dying":
                # Let native Environment handle the normal image. The optional screen
                # pass draws only after PostFX detects high speed/overclock.
                post_fx.update(raw_dt, game.speed_norm(), game.overclock.active)
        elif post_fx.is_active():
                post_fx.set_active(false)

func _update_effects(dt: float, spd: float) -> void:
        _effect_player_info["pos"] = Vector3(player.x, player.y, 0.0)
        _effect_player_info["boost"] = game.powerups.board > 0.0
        effects.update(dt, spd, _effect_player_info, game.overclock.active)

# ---------- 信号编排：按系统职责分组连接 ----------

func _bind_signals() -> void:
        # Keep binding groups small so an interaction can be traced to its owner.
        _bind_input_signals()
        _bind_menu_signals()
        _bind_player_signals()
        _bind_game_signals()
        _bind_spawner_signals()
        _bind_progress_signals()

# ---------- Input and action statistics ----------

func _bind_input_signals() -> void:
        input.input_lane.connect(func(d: int): if game.is_running(): player.move_lane(d))
        input.input_jump.connect(func(): if game.is_running(): player.jump())
        input.input_slide.connect(func(): if game.is_running(): player.slide())
        # Count actions at the Player action source, so keyboard and touch share the same path.
        EventBus.jumped.connect(func():
                if game.is_running():
                        game.run_stats.jumps += 1
                        if not _is_replay_run:
                                progress.stats.jumps += 1
                                progress.on_run_progress("jumps", 1.0))
        EventBus.slid.connect(func():
                if game.is_running():
                        game.run_stats.slides += 1
                        if not _is_replay_run:
                                progress.stats.slides += 1)
        input.input_pause.connect(_on_pause)
        input.input_retry.connect(func(): if game.state == "gameover": _start_run())
        input.input_overclock.connect(_activate_overclock)
        hud.pause_pressed.connect(func(): if game.is_running(): _on_pause())
        hud.oc_pressed.connect(_activate_overclock)

# ---------- Menu intents ----------

func _bind_menu_signals() -> void:
        menus.show_shop_requested.connect(func(): _open_shop())
        menus.show_missions_requested.connect(func(): _open_missions())
        menus.show_settings_requested.connect(func(): _open_settings())
        menus.show_achv_requested.connect(func(): menus.render_achv(progress.achievement_list()))
        menus.settings_previewed.connect(_on_setting_previewed)
        menus.settings_changed.connect(_on_setting_committed)
        menus.skin_action.connect(func(id: int, action: String):
                if action == "buy":
                        if progress.buy_skin(id):
                                hud.toast("义体已入库 ⚡")
                else:
                        if progress.equip_skin(id):
                                player.apply_skin(progress.current_skin)
                                hud.toast("装备完成")
                        else:
                                hud.toast("装备未更改 · 检查存档状态")
                _open_shop())
        menus.mission_claim.connect(func(id: String):
                var reward: int = progress.claim(id)
                if reward > 0:
                        hud.toast("任务完成 · ◈+%d" % reward)
                _open_missions())
        menus.start_pressed.connect(_start_run)
        menus.retry_pressed.connect(_start_run)
        menus.home_pressed.connect(_go_home)
        menus.resume_pressed.connect(_on_pause)
        menus.revive_accept.connect(_accept_revive)
        menus.revive_decline.connect(_decline_revive)

func _on_setting_previewed(key: String, value: Variant) -> void:
        # Live audio preview without mutating persisted settings or touching disk.
        var music_value: float = float(value) if key == "musicVol" else float(progress.settings.musicVol)
        var sfx_value: float = float(value) if key == "sfxVol" else float(progress.settings.sfxVol)
        if key == "musicVol" or key == "sfxVol":
                audio.apply_volumes(music_value, sfx_value)
        elif key == "cameraShake":
                _camera_shake_strength = clampf(float(value), 0.0, 1.0)

func _on_setting_committed(key: String, value: Variant) -> void:
        if not progress.settings.has(key):
                return
        var previous: Variant = progress.settings[key]
        if previous == value:
                _apply_setting_runtime(key, previous)
                return
        progress.settings[key] = value
        if not progress.save():
                progress.settings[key] = previous
                _apply_setting_runtime(key, previous)
                if is_instance_valid(menus) and is_instance_valid(menus.settings_root) and menus.settings_root.visible:
                        menus.render_settings(progress.settings)
                return
        _apply_setting_runtime(key, value)

func _apply_setting_runtime(key: String, value: Variant) -> void:
        if key == "musicVol" or key == "sfxVol":
                audio.apply_volumes(float(progress.settings.musicVol), float(progress.settings.sfxVol))
        elif key == "showFps":
                Telemetry.set_enabled(bool(value))
                hud.set_perf_visible(bool(value))
        elif key == "cameraShake":
                _camera_shake_strength = clampf(float(value), 0.0, 1.0)

func _on_save_failed(message: String) -> void:
        push_warning(message)
        if hud != null and is_instance_valid(hud):
                hud.toast("存档失败 · 请确保设备有可用空间", 2600)

# ---------- Player feedback ----------

func _bind_player_signals() -> void:
        player.wall_hit.connect(func(_s: int):
                game.cam_shake = maxf(game.cam_shake, 0.25)
                audio.play_sfx("land"))
        player.landed.connect(func(impact: float):
                if impact > 4.0:
                        audio.play_sfx("land")
                        game.land_dip = 0.2)

# ---------- Game state and rule events ----------

func _bind_game_signals() -> void:
        game.state_changed.connect(_on_state)
        game.milestone_reached.connect(func(m: int):
                hud.toast("神经突破 · %dm 狂奔达成 ⚡" % m)
                _vibrate(25)
                audio.play_sfx("ready"))
        game.combo_lost.connect(func():
                audio.play_sfx("land")
                if game.combo >= 8: hud.toast("数据链断开"))
        game.boss_burst.connect(func():
                spawner.boss_burst()
                game.cam_shake = maxf(game.cam_shake, 0.3)
                audio.play_sfx("ready"))
        game.boss_started.connect(func():
                hud.toast("⚠ 帝国哨戒机逼近 · 数据拱门 30 秒突围", 3000)
                world.boss_show(true)
                spawner.boss_on = true
                audio.set_boss_lock(true)
                audio.play_sfx("boss"))
        game.boss_survived.connect(func(bonus: int):
                hud.toast("哨戒机撤离 · 奖励 +◈%d" % bonus)
                world.boss_show(false)
                spawner.boss_on = false
                if not _is_replay_run:
                        progress.on_boss_survived(bonus)
                audio.set_boss_lock(false)
                audio.play_sfx("achv"))
        game.died.connect(func(cause: String):
                hud.toast(cause, 1800)
                hud.set_dying(true))
        game.overclock_changed.connect(func(active: bool, _c: float):
                world.overclock_on(active)
                audio.set_overclock_lock(active)
                if active:
                        effects.shockwave(player.x)
                        _vibrate(40)
                        hud.toast("超频启动 ⚡ 无敌冲撞")
                        audio.play_sfx("overclock"))
        game.powerup_ended.connect(func(kind: String):
                hud.toast("%s 已失效" % Config.POWERUPS[kind].name)
                if kind == "board": player.set_board(false))

# ---------- Spawner events ----------

func _bind_spawner_signals() -> void:
        spawner.chip_collected.connect(func(_x: float, _y: float):
                # Count at pickup time so a later double-score pickup cannot affect earlier chips.
                if game.state == "running":
                        game.on_chip_collected()
                effects.shatter(_x, _y + 1.0, 0.0, Config.PALETTE.cyan, 4))
        spawner.powerup_collected.connect(func(kind: String, x: float, y: float):
                _apply_powerup(kind)
                effects.shatter(x, y + 1.0, 0.0, Config.POWERUPS[kind].color, 12))
        spawner.slide_dodged.connect(func():
                if not _is_replay_run:
                        progress.on_slide_dodge()
                        progress.on_run_progress("slide", 1.0))
        spawner.laser_warning.connect(func():
                hud.toast("⚠ 电磁激光即将启动！立即躲避", 1100)
                audio.play_sfx("ready"))
        spawner.smashed.connect(func(x: float, y: float, col: Color):
                effects.shatter(x, y, 0.0, col, 16))

# ---------- Persistent progress events ----------

func _bind_progress_signals() -> void:
        progress.wallet_changed.connect(func(_c: int):
                menus.refresh_meta(progress.stats.best, progress.wallet))
        progress.achievement_unlocked.connect(func(id: String):
                var title := id
                for a in Config.ACHIEVEMENTS:
                        if a.id == id:
                                title = a.name
                                break
                hud.toast("成就解锁 · %s" % title, 2200)
                audio.play_sfx("achv"))
        progress.mission_completed.connect(func(id: String, _reward: int):
                hud.toast("任务达成 · %s（前往任务页领取）" % id, 2200))

func _open_shop() -> void:
        var skins: Array = []
        for s in Player.SKINS:
                var col: Color = Config.PALETTE.get(s.body, Color.YELLOW)
                skins.append({"id": s.id, "name": s.name, "skill": s.skill, "price": s.price, "color": col})
        menus.render_shop(skins, progress.wallet, progress.owned_skins, progress.current_skin)

func _open_missions() -> void:
        menus.render_missions(progress.mission_list())

func _open_settings() -> void:
        menus.render_settings(progress.settings)

## 超频激活：要求充能已满、尚未超频且当前处于跑局状态。
func _activate_overclock() -> void:
        if _is_replay_run:
                return # Replay consumes only its recorded action timeline.
        if not game.is_running() or game.overclock.active or game.overclock.charge < Config.OVERCLOCK.chipsNeeded:
                return
        if bool(input.call("is_recording")):
                input.call("mark_trace_ineligible", "overclock_activation_not_recorded")
        game.overclock.active = true
        game.overclock.t = Config.OVERCLOCK.duration
        game.overclock.charge = 0
        game.overclock_changed.emit(true, 0.0)
        if not _is_replay_run:
                progress.on_overclock()
        hud.toast("超频启动 ⚡ 无敌冲撞")
        audio.play_sfx("overclock")



# ---------- 游戏流程 ----------

func _create_run_seed() -> int:
        # Millisecond-scale uniqueness is sufficient for run seeding; the chosen
        # value is logged and carried into game-over stats for deterministic replay.
        var seed_value: int = int(Time.get_ticks_usec() & 0x7FFFFFFF)
        seed_value = (seed_value ^ int(Time.get_unix_time_from_system())) & 0x7FFFFFFF
        return maxi(1, seed_value)

func _start_run(seed_override: int = 0, input_trace: Dictionary = {}) -> void:
        # Only the menu and game-over screen may create a new run. This prevents
        # duplicate taps/signals from resetting a live run halfway through play.
        if _starting_run or (game.state != "menu" and game.state != "gameover"):
                return
        if not input_trace.is_empty() and not bool(input.call("validate_replay_trace", input_trace)):
                hud.toast("输入回放文件无效或不完整", 2400)
                return

        _starting_run = true
        _is_replay_run = not input_trace.is_empty()
        input.set_enabled(false)
        input.clear_queue()

        var run_seed: int = seed_override if seed_override > 0 else _create_run_seed()
        var dda_enabled: bool = bool(_settings.get("dda", true))
        var dda_mode: String = compute_dda() if dda_enabled else ""
        if not input_trace.is_empty():
                run_seed = int(input_trace.get("seed", run_seed))
                dda_enabled = bool(input_trace.get("dda_enabled", false))
                dda_mode = String(input_trace.get("dda_mode", ""))
        _last_theme_idx = -1
        _revive_t = 0.0
        # Do not let a prior run's impact envelope bleed into a fresh/retried run.
        _camera_shake_envelope = 0.0
        _camera_shake_phase = 0.0

        # Stage 1: reset/configure every run-owned subsystem before announcing
        # RUNNING. state_changed enables input and reveals the HUD, so it is the
        # final commit point—not the first line of new-run setup.
        spawner.dda_gap = Game.dda_gap_for(dda_mode)
        spawner.dda_unlock = Game.dda_unlock_for(dda_mode)
        spawner.reset(run_seed)
        player.reset()
        player.apply_skin(progress.current_skin)
        effects.reset_fx()
        effects.set_rain_active(false)
        world.boss_show(false)
        world.overclock_on(false)
        world.apply_theme(0.0, 0.0, true)
        audio.reset_run_state()
        hud.reset_run_ui()
        if not _is_replay_run:
                progress.on_run_start()

        # Stage 2: prepare either a fresh bounded trace or a validated replay
        # before publishing RUNNING, because the state signal enables input.
        if input_trace.is_empty():
                input.call("begin_run_recording", run_seed, dda_enabled, dda_mode)
        elif not bool(input.call("begin_replay", input_trace)):
                _is_replay_run = false
                _starting_run = false
                hud.toast("输入回放初始化失败", 2400)
                return
        game.start_run(dda_mode, run_seed)
        menus.show_running()
        audio.start_bgm()
        print("[run] seed=%d · dda_enabled=%s · dda_mode=%s" % [run_seed, dda_enabled, game.dda_mode])
        _starting_run = false

const LAST_RUN_TRACE_PATH := "user://nr2099_last_run_input_trace.json"
const TEST_LAST_RUN_TRACE_PATH := "user://nr2099_test_last_run_input_trace.json"

func _last_run_trace_path() -> String:
        return TEST_LAST_RUN_TRACE_PATH if OS.get_environment("NR2099_TEST_MODE") == "1" else LAST_RUN_TRACE_PATH

func _trace_document_is_well_formed(candidate: Variant) -> bool:
        if not (candidate is Dictionary):
                return false
        var trace: Dictionary = candidate
        if typeof(trace.get("schema", null)) != TYPE_INT or int(trace.schema) != 2:
                return false
        if typeof(trace.get("game_version", null)) != TYPE_STRING or typeof(trace.get("engine_version", null)) != TYPE_STRING:
                return false
        if typeof(trace.get("physics_hz", null)) != TYPE_INT or int(trace.physics_hz) < 1:
                return false
        if typeof(trace.get("ruleset_version", null)) != TYPE_INT or int(trace.ruleset_version) != 1:
                return false
        if typeof(trace.get("seed", null)) != TYPE_INT or int(trace.seed) <= 0:
                return false
        if typeof(trace.get("frames", null)) != TYPE_INT or int(trace.frames) < 0:
                return false
        if typeof(trace.get("dda_enabled", null)) != TYPE_BOOL or typeof(trace.get("dda_mode", null)) != TYPE_STRING:
                return false
        if not (String(trace.dda_mode) in ["", "gentle", "hardcore"]):
                return false
        if not bool(trace.dda_enabled) and String(trace.dda_mode) != "":
                return false
        if typeof(trace.get("truncated", null)) != TYPE_BOOL or typeof(trace.get("replayable", null)) != TYPE_BOOL:
                return false
        if typeof(trace.get("ineligibleReasons", null)) != TYPE_ARRAY or typeof(trace.get("events", null)) != TYPE_ARRAY:
                return false
        var events: Array = trace.events
        if events.size() > 8000:
                return false
        var last_frame := 0
        for raw_event in events:
                if not (raw_event is Dictionary):
                        return false
                var frame_value: Variant = raw_event.get("frame", null)
                var action_value: Variant = raw_event.get("action", null)
                if typeof(frame_value) != TYPE_INT or int(frame_value) < 1 or int(frame_value) < last_frame or int(frame_value) > int(trace.frames):
                        return false
                if typeof(action_value) != TYPE_STRING or not (String(action_value) in ["lane", "jump", "slide"]):
                        return false
                if String(action_value) == "lane":
                        var direction_value: Variant = raw_event.get("direction", 0)
                        if typeof(direction_value) != TYPE_INT or not (int(direction_value) in [-1, 1]):
                                return false
                last_frame = int(frame_value)
        return true

func _trace_persist_failed(reason: String) -> bool:
        _last_trace_persist_error = reason
        return false

func _persist_last_run_trace(trace: Dictionary) -> bool:
        # Write + flush + parse back before touching the previous good record.
        # Keep a last-good .bak and roll it back if installing the new file fails.
        _last_trace_persist_error = ""
        if not _trace_document_is_well_formed(trace):
                return _trace_persist_failed("invalid_document")
        var target := _last_run_trace_path()
        var temporary := target + ".tmp"
        var backup := target + ".bak"
        var target_abs := ProjectSettings.globalize_path(target)
        var temporary_abs := ProjectSettings.globalize_path(temporary)
        var backup_abs := ProjectSettings.globalize_path(backup)
        var writer := FileAccess.open(temporary, FileAccess.WRITE)
        if writer == null:
                return _trace_persist_failed("open_temp:%s" % error_string(FileAccess.get_open_error()))
        writer.store_string(JSON.stringify(trace))
        writer.flush()
        var write_error := writer.get_error()
        writer.close()
        if write_error != OK or not FileAccess.file_exists(temporary):
                if FileAccess.file_exists(temporary):
                        DirAccess.remove_absolute(temporary_abs)
                return _trace_persist_failed("write_temp:%s" % error_string(write_error))
        var verifier := FileAccess.open(temporary, FileAccess.READ)
        if verifier == null:
                DirAccess.remove_absolute(temporary_abs)
                return _trace_persist_failed("reopen_temp:%s" % error_string(FileAccess.get_open_error()))
        var candidate_text := verifier.get_as_text()
        verifier.close()
        var parser := JSON.new()
        var parse_error := parser.parse(candidate_text)
        var parsed: Variant = parser.data
        if parse_error != OK or not _trace_document_is_well_formed(parsed):
                DirAccess.remove_absolute(temporary_abs)
                return _trace_persist_failed("verify_temp:%s" % error_string(parse_error))

        if FileAccess.file_exists(target):
                if FileAccess.file_exists(backup):
                        var remove_error := DirAccess.remove_absolute(backup_abs)
                        if remove_error != OK:
                                DirAccess.remove_absolute(temporary_abs)
                                return _trace_persist_failed("remove_old_backup:%s" % error_string(remove_error))
                var backup_error := DirAccess.rename_absolute(target_abs, backup_abs)
                if backup_error != OK:
                        DirAccess.remove_absolute(temporary_abs)
                        return _trace_persist_failed("rotate_backup:%s" % error_string(backup_error))
        var install_error := DirAccess.rename_absolute(temporary_abs, target_abs)
        if install_error != OK:
                if not FileAccess.file_exists(target) and FileAccess.file_exists(backup):
                        var restore_error := DirAccess.rename_absolute(backup_abs, target_abs)
                        if restore_error != OK:
                                return _trace_persist_failed("install_temp:%s; restore_backup:%s" % [error_string(install_error), error_string(restore_error)])
                if FileAccess.file_exists(temporary):
                        DirAccess.remove_absolute(temporary_abs)
                return _trace_persist_failed("install_temp:%s" % error_string(install_error))
        return true

func _read_valid_last_run_trace() -> Dictionary:
        # A torn/corrupt primary is never trusted; try the preserved last-good copy.
        var target := _last_run_trace_path()
        for candidate_path in [target, target + ".bak"]:
                if not FileAccess.file_exists(candidate_path):
                        continue
                var file := FileAccess.open(candidate_path, FileAccess.READ)
                if file == null:
                        continue
                var candidate_text := file.get_as_text()
                file.close()
                # Corrupt files are an expected recovery case; use JSON.parse() so
                # the recovery path does not emit a misleading engine ERROR log.
                var parser := JSON.new()
                if parser.parse(candidate_text) != OK:
                        continue
                var parsed: Variant = parser.data
                if not _trace_document_is_well_formed(parsed):
                        continue
                var trace: Dictionary = parsed
                if bool(input.call("validate_replay_trace", trace)):
                        return trace
        return {}

func replay_last_run_trace() -> bool:
        # Ignore corrupt primary files and recover from the validated last-good copy.
        var path := _last_run_trace_path()
        if not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak"):
                hud.toast("没有可回放的完整对局记录", 2200)
                return false
        var trace := _read_valid_last_run_trace()
        if trace.is_empty():
                hud.toast("对局记录损坏，或包含暂停/截断，不能精确回放", 2600)
                return false
        _start_run(int(trace.get("seed", 0)), trace)
        return game.state == "running"

func _notification(what: int) -> void:
        if what == NOTIFICATION_APPLICATION_PAUSED:
                if bool(input.call("is_recording")):
                        input.call("mark_trace_ineligible", "application_paused")
                _app_suspended = true
                input.clear_queue()
                _app_bgm_was_playing = audio.is_bgm_playing()
                if game.state == "running":
                        _on_pause() # Backgrounding a live run opens a deliberate pause state.
                else:
                        audio.stop_bgm()
                progress.save()
                get_tree().paused = true
        elif what == NOTIFICATION_APPLICATION_RESUMED:
                get_tree().paused = false
                _app_suspended = false
                input.clear_queue()
                if game.state == "paused":
                        menus.show_pause() # Never silently resume player movement after app switching.
                elif _app_bgm_was_playing and game.state in ["dying", "revive"]:
                        audio.start_bgm()
                _app_bgm_was_playing = false
        elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
                _handle_back_navigation()
        elif what == NOTIFICATION_WM_CLOSE_REQUEST:
                if is_instance_valid(progress):
                        progress.save()

func _handle_back_navigation() -> void:
        # Platform Back and keyboard Escape use the same predictable modal-first stack.
        if is_instance_valid(menus) and menus.close_topmost_secondary():
                return
        match game.state:
                "running", "paused":
                        _on_pause()
                "revive":
                        _decline_revive()
                "gameover":
                        _go_home()
                "menu":
                        if is_instance_valid(progress):
                                progress.save()
                        get_tree().quit()
                _:
                        pass # Keep the brief dying transition uninterrupted.

func _on_pause() -> void:
        # P/Escape closes a secondary panel before it can resume the run underneath.
        if is_instance_valid(menus) and menus.close_topmost_secondary():
                return
        if bool(input.call("is_recording")):
                input.call("mark_trace_ineligible", "game_pause_or_resume")
        if game.pause_run():
                input.clear_queue()
                menus.show_pause()
                audio.stop_bgm()
        elif game.resume_run():
                input.clear_queue()
                menus.hide_pause()
                _last_theme_idx = -1
                audio.start_bgm()

func _go_home() -> void:
        # 回到菜单时完全复位玩家表现状态，避免护盾板/滑铲姿态等跨局残留。
        player.reset()
        effects.reset_fx()
        game.enter_menu()
        progress.save()
        menus.refresh_meta(progress.stats.best, progress.wallet)
        menus.show_menu()
        audio.stop_bgm()

func _on_state(s: String) -> void:
        # The optional screen-reading pass is opt-in per rendered frame, not enabled
        # for the entire run. PostFX.update will enable it only when CA is visible.
        post_fx.set_active(false)
        input.clear_queue()   # 状态切换丢弃残帧（死亡瞬间的积压输入不该在复活后触发）
        if s != "dying":
                hud.set_dying(false)   # 撤濒死故障色
        input.set_enabled(s == "running")
        hud.set_gameplay_visible(s == "running" or s == "dying")
        if s == "gameover" or s == "menu":
                world.boss_show(false)
                world.overclock_on(false)
                spawner.boss_on = false
                audio.set_boss_lock(false)
                audio.set_overclock_lock(false)
                effects.reset_fx()
                effects.set_rain_active(false)
        match s:
                "gameover":
                        if bool(input.call("is_replaying")):
                                input.call("finish_replay_run")
                        else:
                                var trace: Dictionary = input.call("finish_run_recording")
                                if not trace.is_empty() and not _persist_last_run_trace(trace):
                                        push_warning("无法安全保存最近一局输入回放记录；旧记录保持不变")
                        if not _is_replay_run:
                                progress.on_run_end(game.distance, game.chips, game.combo_peak, game.smashed, game.run_stats)
                        menus.show_gameover({
                                "distance": game.distance, "score": game.score(),
                                "seed": game.run_seed,
                                "chips": game.chips, "combo": game.combo_peak,
                                "best": progress.stats.best,
                        }, game.dda_mode)
                        audio.stop_bgm()
                        _is_replay_run = false
                "dying":
                        audio.play_sfx("die")
                "revive":
                        if _is_replay_run:
                                # A valid trace cannot contain a revive choice; reaching this
                                # state means the current simulation diverged from the recording.
                                hud.toast("回放与当前模拟发生分歧，已提前终止", 2500)
                                game.decline_revive()
                                return
                        _revive_t = Config.REVIVE.countdown
                        menus.show_revive(_revive_t)

func _vibrate(ms: int) -> void:   # 触感反馈受 haptics 设置控制。
        if progress.settings.get("haptics", true):
                Input.vibrate_handheld(ms)

func _accept_revive() -> void:
        if bool(input.call("is_recording")):
                input.call("mark_trace_ineligible", "revive_choice_not_recorded")
        if not game.prepare_revive():
                return
        _vibrate(80)
        spawner.clear_zone(Config.REVIVE.clearRadius)
        player.reset()
        player.apply_skin(progress.current_skin)
        if game.powerups.board > 0.0:
                player.set_board(true)
        # This emits RUNNING only after the player and obstacle state are prepared.
        game.finish_revive()
        if not _is_replay_run:
                progress.on_revive()
        menus.hide_revive()
        menus.show_running()
        audio.play_sfx("revive")
        hud.toast("系统重启完成 · 短暂无敌", 1800)
        _last_theme_idx = -1
        audio.start_bgm()

func _decline_revive() -> void:
        if bool(input.call("is_recording")):
                input.call("mark_trace_ineligible", "revive_choice_not_recorded")
        if game.state == "revive":
                game.decline_revive()

func _handle_hits(res: Spawner.HitResult) -> void:
        if not res.hit or game.invincible_t > 0.0:
                return
        # 护盾抵消
        if game.shield:
                game.shield = false
                game.run_stats.shieldSaves += 1
                if not _is_replay_run:
                        progress.unlock_achievement("shield_save")
                game.invincible_t = 1.2
                hud.toast("离子护盾 · 抵挡一击")
                audio.play_sfx("powerup")
                return
        # 黄金霸主免死
        if player.skill_gold and not game.gold_save_used:
                game.gold_save_used = true
                game.invincible_t = 1.6
                hud.toast("黄金霸主 · 撞击豁免（每局一次）")
                audio.play_sfx("powerup")
                return
        # 滑板碾压低障碍
        if res.hit.type == "low" and game.powerups.board > 0.0:
                spawner.smash_obstacle(res.hit)
                game.on_smash(1, 0)
                return
        # 超频冲撞
        if game.overclock.active:
                spawner.smash_obstacle(res.hit)
                game.on_smash(1, 1)
                return
        game.die(res.hit.type)

func _apply_powerup(kind: String) -> void:
        _vibrate(20)
        var cfg: Dictionary = Config.POWERUPS[kind]
        game.run_stats.powerupKinds[kind] = true
        if kind == "shield":
                game.shield = true
        else:
                game.powerups[kind] = cfg.duration * (1.4 if player.skill_oni else 1.0)
                if kind == "board":
                        player.set_board(true)
        if not _is_replay_run:
                progress.on_powerup(kind)
        audio.play_sfx("powerup")
        hud.toast("%s · %s" % [cfg.name, cfg.desc], 1800)

# ---------- 相机（Game.js 相机逻辑并入） ----------

func _update_camera(raw_dt: float) -> void:
        # Keep target-follow state independent from rendered impact motion. A camera
        # offset must never become the input to the next frame's damping calculation.
        # Clamp unusually long render gaps so resume/hitch frames don't erase impacts.
        var camera_dt: float = clampf(raw_dt, 0.0, 0.05)
        var tx: float = Config.CAMERA.pos.x + player.x * Config.CAMERA.followX
        var ty: float = Config.CAMERA.pos.y + player.y * Config.CAMERA.followY
        var death_k: float = 1.0 - U.clampf(game.death_timer / 0.95, 0.0, 1.0)
        if game.state == "dying":
                ty -= death_k * 1.2
                tx += player.x * 0.15
        if game.land_dip > 0.0:
                game.land_dip = maxf(0.0, game.land_dip - camera_dt)
                ty -= 0.15 * sin((game.land_dip / 0.2) * PI)
        _camera_base_position.x = U.dampf(_camera_base_position.x, tx, 8.0, camera_dt)
        _camera_base_position.y = U.dampf(_camera_base_position.y, ty, 6.0, camera_dt)

        # Continuous multi-frequency impact pulse: no fresh random offset each frame,
        # stable in 60/90/120 Hz rendering. The envelope follows the game impulse
        # smoothly; the player can reduce it without changing collision/game logic.
        _camera_shake_phase = fposmod(_camera_shake_phase + camera_dt, 10.0)
        if game.cam_shake > 0.001:
                game.cam_shake = maxf(0.0, game.cam_shake - camera_dt * 1.9)
        _camera_shake_envelope = U.dampf(_camera_shake_envelope, game.cam_shake, 18.0, camera_dt)
        var shake_amp: float = _camera_shake_envelope * 0.35 * _camera_shake_strength
        var shake_x: float = sin(_camera_shake_phase * TAU * 4.4) * shake_amp
        var shake_y: float = (sin(_camera_shake_phase * TAU * 3.2 + 0.8) * 0.68 + sin(_camera_shake_phase * TAU * 6.1 + 1.6) * 0.14) * shake_amp
        cam.position = _camera_base_position + Vector3(shake_x, shake_y, 0.0)

        var portrait: bool = float(get_viewport().size.x) / get_viewport().size.y < 1.0
        var fov: float = Config.CAMERA.fovPortrait if portrait else Config.CAMERA.fovLandscape
        fov += game.speed_norm() * 6.0
        if game.overclock.active:
                fov += Config.CAMERA.fovOverclockBoost
        if game.state == "dying":
                fov -= 8.0 * minf(1.0, game.death_timer * 2.0)
        cam.fov = U.dampf(cam.fov, fov, 5.0, camera_dt)
        cam_look.x = U.dampf(cam_look.x, player.x * 0.5, 8.0, camera_dt)
        cam.look_at_from_position(cam.position, cam_look)

## DDA 根据最近 5 局的表现计算动态难度。
func compute_dda() -> String:
        if not _settings.get("dda", true):
                return ""
        return Game.compute_dda(progress.recent_runs)
