class_name Game
extends Node
## 核心状态机：跑局状态、速度曲线、计分、超频、BOSS、动态难度和复活。
## 场景编排与渲染由 Main 负责；状态改变通过 state_changed 信号统一发布。

signal state_changed(state: String)
signal died(cause: String)
signal revived
signal milestone_reached(m: int)
signal boss_started
signal boss_burst
signal boss_survived(bonus: int)
signal powerup_ended(kind: String)
signal combo_lost
signal toast(msg: String, ms: int)
signal overclock_changed(active: bool, charge: float)

# Avoid allocating a new key array in every 60Hz simulation tick.
const POWERUP_TIMER_KEYS := ["magnet", "double", "board"]

# —— 状态 ——
var state: String = "menu"
var elapsed: float = 0.0
var distance: float = 0.0
var chips: int = 0
var smashed: int = 0
var speed: float = 0.0
var death_cause: String = ""
var run_seed: int = 0  # Captured so difficult runs can be reproduced from logs.

# —— 时间控制（J-3 慢动作体系） ——
var time_scale: float = 1.0
var target_time_scale: float = 1.0
var frame_dt: float = 0.0   # tick 计算出的最终缩放 dt（含 hit-stop）
var _hit_stop: float = 0.0
var death_timer: float = 0.0

# —— 连击（数据链） ——
var combo: int = 0
var combo_timer: float = 0.0
var combo_peak: int = 0

# —— 超频 ——
var overclock := {"active": false, "t": 0.0, "charge": 0}

# —— 道具 / 无敌 / 复活 ——
var powerups := {"magnet": 0.0, "double": 0.0, "board": 0.0}
var shield: bool = false
var invincible_t: float = 0.0
var revive_used: bool = false
var gold_save_used: bool = false
var cam_shake: float = 0.0
var land_dip: float = 0.0

# —— BOSS ——
var boss_event := {"active": false, "t": 0.0, "next_at": 2500.0, "burst_t": 0.0, "chips": 0}

# —— DDA ——
var dda_mode: String = ""     # "" | gentle | hardcore
var current_mech: String = "" # 章节机制："" | rain | lowg | laser（由距离驱动）

# —— 里程 ——
var _milestone: int = 0
var _last_score: float = 0.0
var _score_total: float = 0.0
var run_stats := {"jumps": 0, "slides": 0, "overclockSmashes": 0, "shieldSaves": 0, "powerupKinds": {}}

## DDA 难度计算使用最近几局的表现，避免连续失败时难度持续失控。
static func compute_dda(recent_runs: Array) -> String:
        if recent_runs.size() < 5:
                return ""
        var last5: Array = recent_runs.slice(recent_runs.size() - 5, recent_runs.size())
        var short_runs := 0
        var long_runs := 0
        for value in last5:
                var d := float(value)
                if d < 400.0:
                        short_runs += 1
                if d > 1500.0:
                        long_runs += 1
        if short_runs >= 3:
                return "gentle"
        if long_runs >= 3:
                return "hardcore"
        return ""
static func dda_gap_for(mode: String) -> float:
        match mode:
                "gentle":
                        return 1.25
                "hardcore":
                        return 0.9
                _:
                        return 1.0

static func dda_unlock_for(mode: String) -> int:
        match mode:
                "gentle":
                        return -60
                "hardcore":
                        return 40
                _:
                        return 0

func dda_gap() -> float:
        return Game.dda_gap_for(dda_mode)

func dda_unlock() -> int:
        return Game.dda_unlock_for(dda_mode)

# ---------- 状态迁移 ----------

func start_run(dda: String = "", seed_value: int = 0) -> void:
        dda_mode = dda
        run_seed = seed_value
        state = "running"
        elapsed = 0.0
        distance = 0.0
        chips = 0
        smashed = 0
        combo = 0
        combo_timer = 0.0
        combo_peak = 0
        _milestone = 0
        _last_score = 0.0
        _score_total = 0.0
        current_mech = ""
        death_cause = ""
        death_timer = 0.0
        cam_shake = 0.0
        land_dip = 0.0
        target_time_scale = 1.0
        time_scale = 1.0
        _hit_stop = 0.0
        gold_save_used = false
        boss_event = {"active": false, "t": 0.0, "next_at": 2500.0 + (100.0 if dda_mode == "gentle" else (-100.0 if dda_mode == "hardcore" else 0.0)), "burst_t": 0.0, "chips": 0}
        overclock = {"active": false, "t": 0.0, "charge": 0}
        powerups = {"magnet": 0.0, "double": 0.0, "board": 0.0}
        shield = false
        invincible_t = 0.0
        revive_used = false
        run_stats = {"jumps": 0, "slides": 0, "overclockSmashes": 0, "shieldSaves": 0, "powerupKinds": {}}
        speed = Config.SPEED.base - 4.0   #：起步渐升（damp 到 base ~2s）
        state_changed.emit(state)

func die(cause: String = "obstacle") -> void:
        if state != "running":
                return
        death_cause = cause
        state = "dying"
        death_timer = 0.0
        _hit_stop = 0.09            # J-3：hit-stop 90ms
        target_time_scale = 0.25    # J-3：慢动作死亡
        state_changed.emit(state)
        died.emit(death_cause)

## 濒死演出结束 → 可复活则进入复活决策，否则结算
func offer_revive_or_gameover() -> void:
        if state != "dying":
                return
        if not revive_used:
                state = "revive"
                target_time_scale = 0.35
                state_changed.emit(state)
        else:
                _finish_gameover()

func prepare_revive() -> bool:
        # Prepare all gameplay state without publishing RUNNING to listeners.
        if state != "revive" or revive_used:
                return false
        revive_used = true
        target_time_scale = 1.0
        invincible_t = Config.REVIVE.invincible
        return true

func finish_revive() -> void:
        # Main calls this only after player, board, and obstacle state are reset.
        if state != "revive" or not revive_used:
                return
        state = "running"
        state_changed.emit(state)
        revived.emit()

func decline_revive() -> void:
        if state != "revive":
                return
        _finish_gameover()

## All state changes notify the scene/UI coordinator; avoid assigning `state` externally.
func pause_run() -> bool:
        if state != "running":
                return false
        state = "paused"
        state_changed.emit(state)
        return true

func resume_run() -> bool:
        if state != "paused":
                return false
        state = "running"
        state_changed.emit(state)
        return true

func _finish_gameover() -> void:
        if state == "gameover":
                return
        _last_score = score()
        if overclock.active:
                overclock.active = false
                overclock_changed.emit(false, overclock.charge)
        state = "gameover"
        target_time_scale = 1.0
        state_changed.emit(state)   # 修复：漏发导致结算界面从未显示（死亡后画面冻结）

# ---------- 主循环 tick ----------

func tick(raw_dt: float) -> void:
        time_scale = U.dampf(time_scale, target_time_scale, 6.0, raw_dt)
        var dt := raw_dt * time_scale
        if _hit_stop > 0.0:
                _hit_stop -= raw_dt
                dt = raw_dt * 0.05
        frame_dt = dt   # 供 Main 驱动 World、Player 与 Spawner 的统一帧间隔。

        if state == "paused" or state == "gameover":
                return

        if state == "dying":
                death_timer += raw_dt
                if death_timer > 0.95:
                        offer_revive_or_gameover()

        # —— 道具计时 / 无敌帧 ——
        if state == "running":
                for kind in POWERUP_TIMER_KEYS:
                        if powerups[kind] > 0.0:
                                powerups[kind] -= dt
                                if powerups[kind] <= 0.0:
                                        powerups[kind] = 0.0
                                        powerup_ended.emit(kind)
                if invincible_t > 0.0:
                        invincible_t -= dt

        # —— 速度曲线 ——
        if state == "running":
                elapsed += dt
                var target: float = minf(Config.SPEED.max, Config.SPEED.base + elapsed * Config.SPEED.accel)
                speed = U.dampf(speed, target, 1.2, dt)
        elif state == "menu":
                speed = U.dampf(speed, Config.SPEED.menu, 2.0, dt)

        # —— 超频 ——
        if overclock.active:
                overclock.t -= dt
                if overclock.t <= 0.0:
                        overclock.active = false
                        overclock_changed.emit(false, overclock.charge)

        if state == "running":
                var distance_delta: float = eff_speed() * dt
                distance += distance_delta
                var distance_multiplier: float = 2.0 if powerups.double > 0.0 else 1.0
                _score_total += distance_delta * Config.SCORING.perMeter * distance_multiplier

        # —— 数据链衰减（3.2s 断链） ——
        if state == "running" and combo > 0:
                combo_timer -= dt
                if combo_timer <= 0.0:
                        var lost: bool = combo >= 8
                        if lost:
                                combo_lost.emit()   # 先发事件，订阅者仍可读取断链前的连击值
                        combo = 0
        combo_peak = maxi(combo_peak, combo)

        # —— 神经突破（每 250m） ——
        if state == "running":
                var ms: int = floori(distance / 250.0)
                if ms > _milestone:
                        _milestone = ms
                        milestone_reached.emit(ms * 250)

        # —— BOSS 围剿（每 2500m，30s） ——
        if state == "running":
                if not boss_event.active and distance >= boss_event.next_at:
                        boss_event.active = true
                        boss_event.t = 0.0
                        boss_event.burst_t = 0.0
                        boss_event.chips = 0
                        boss_started.emit()
                elif boss_event.active:
                        boss_event.t += dt
                        boss_event.burst_t -= dt
                        if boss_event.burst_t <= 0.0:
                                boss_event.burst_t = 1.1
                                boss_burst.emit()
                        if boss_event.t >= 30.0:
                                boss_event.active = false
                                boss_event.next_at += 2500.0
                                boss_survived.emit(boss_event.chips * 2)

# ---------- 计分与连击 ----------

func score() -> float:
        return _score_total

func on_chip_collected() -> void:
        chips += 1
        combo += 1
        combo_peak = maxi(combo_peak, combo)
        combo_timer = 3.2
        var combo_multiplier: float = 1.0 + minf(4.0, floor(float(combo) / 8.0))
        var powerup_multiplier: float = 2.0 if powerups.double > 0.0 else 1.0
        _score_total += Config.SCORING.perChip * combo_multiplier * powerup_multiplier
        if boss_event.active:
                boss_event.chips += 1
        if not overclock.active:
                overclock.charge = mini(int(overclock.charge) + 1, Config.OVERCLOCK.chipsNeeded)

func on_near_miss() -> void:
        combo += 1
        combo_peak = maxi(combo_peak, combo)
        combo_timer = maxf(combo_timer, 1.6)

func on_smash(count: int, overclock_count: int = 0) -> void:
        if count <= 0:
                return
        smashed += count
        # 只把由超频直接击碎的障碍计入超频成就；滑板击碎不混算。
        run_stats.overclockSmashes += clampi(overclock_count, 0, count)
        var multiplier: float = 2.0 if powerups.double > 0.0 else 1.0
        _score_total += count * Config.OVERCLOCK.smashScore * multiplier

func speed_norm() -> float:
        return U.clampf((speed - Config.SPEED.base) / (Config.SPEED.max - Config.SPEED.base), 0.0, 1.0)

func eff_speed() -> float:
        var s: float = speed * (Config.SPEED.overclockMult if overclock.active else 1.0)
        if current_mech == "rain":
                s *= Config.MECH_CFG.rainSpeedMult   # 酸雨湿滑减速
        return s

## 章节机制刷新（running 态每帧调用）
func update_mech() -> void:
        if state != "running":
                current_mech = ""
                return
        var idx: int = int(distance / Config.THEME_LEN) % Config.THEMES.size()
        current_mech = Config.THEMES[idx].get("mech", "") if Config.THEMES[idx].get("mech", "") != null else ""

func is_running() -> bool:
        return state == "running"

func enter_menu() -> void:
        if overclock.active:
                overclock.active = false
                overclock_changed.emit(false, overclock.charge)
        shield = false
        powerups = {"magnet": 0.0, "double": 0.0, "board": 0.0}
        current_mech = ""
        target_time_scale = 1.0
        time_scale = 1.0
        state = "menu"
        state_changed.emit(state)
