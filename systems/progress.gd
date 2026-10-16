extends Node
class_name Progress
## 持久化与进度系统：存档、成就、每日任务、钱包和生涯统计。
## 使用 ConfigFile 写入 user://；保存结果必须由调用方处理，关键操作采用快照/回滚事务。

const SAVE_PATH := "user://nr2099_save.cfg"
const SAVE_SCHEMA := 2
var _save_error_active: bool = false
var _pending_achievement_events: Array[String] = []
var _pending_mission_events: Array[Dictionary] = []

var stats := {
        "totalRuns": 0, "best": 0.0, "chips": 0, "totalDist": 0.0,
        "bossKills": 0, "revives": 0, "powerups": 0, "overclocks": 0,
        "slideDodges": 0, "nearMisses": 0, "jumps": 0, "slides": 0, "bestCombo": 0,
}
var wallet := 0
var achv := {}            # id → true
var missions := {
        "day": 0, "sel": [], "progress": {}, "done": {}, "claimed": {},
}
var settings: Dictionary = Config.DEFAULT_SETTINGS.duplicate()
var current_skin := 0
var owned_skins := [0]
var recent_runs: Array = []     # 最近 8 局距离记录，用于动态难度判断。

signal wallet_changed(coins: int)
signal achievement_unlocked(id: String)
signal mission_completed(id: String, reward: int)
signal save_failed(message: String)

func _ready() -> void:
        _load()

# ---------- 持久化 ----------

func _save_path() -> String:
        return "user://nr2099_test_save.cfg" if _is_test_mode() else SAVE_PATH

func _is_test_mode() -> bool:
        # 可由外部验收工具显式隔离存档；正式运行不会自动切换存档路径。
        return OS.get_environment("NR2099_TEST_MODE") == "1"

func _load() -> void:
        var f := ConfigFile.new()
        var path := _save_path()
        var load_error := f.load(path)
        var recovered := false
        var needs_migration := false
        if load_error == OK and not _verify_config(f):
                load_error = ERR_FILE_CORRUPT
        if load_error != OK:
                var backup := ConfigFile.new()
                if backup.load(path + ".bak") == OK and _verify_config(backup):
                        f = backup
                        recovered = true
                        # Keep the only valid backup safe until the recovered data
                        # has been normalised and successfully written as the main save.
                        var gp := ProjectSettings.globalize_path(path)
                        var gp_corrupt := gp + ".corrupt"
                        if FileAccess.file_exists(gp):
                                if FileAccess.file_exists(gp_corrupt):
                                        DirAccess.remove_absolute(gp_corrupt)
                                DirAccess.rename_absolute(gp, gp_corrupt)
                else:
                        var gp_bad := ProjectSettings.globalize_path(path)
                        var gp_corrupt := gp_bad + ".corrupt"
                        if FileAccess.file_exists(gp_bad):
                                if FileAccess.file_exists(gp_corrupt):
                                        DirAccess.remove_absolute(gp_corrupt)
                                DirAccess.rename_absolute(gp_bad, gp_corrupt)
                        _rollover_missions()
                        return

        needs_migration = not _is_current_schema(f)
        # Treat persisted data as untrusted input. A syntactically readable
        # ConfigFile can still contain wrong types, NaN-like numbers, unknown IDs
        # or values from a future/partially-written save.
        for key in stats:
                var fallback: Variant = stats[key]
                var raw: Variant = f.get_value("stats", key, fallback)
                stats[key] = _safe_number(raw, fallback, typeof(fallback) == TYPE_INT)

        wallet = int(_safe_number(f.get_value("meta", "wallet", 0), 0, true))
        var valid_skin_ids: Array = []
        for skin in Player.SKINS:
                valid_skin_ids.append(int(skin.id))
        owned_skins = []
        var raw_owned: Variant = f.get_value("meta", "ownedSkins", [0])
        if raw_owned is Array:
                for raw_id in raw_owned:
                        if typeof(raw_id) == TYPE_INT and raw_id in valid_skin_ids and not (raw_id in owned_skins):
                                owned_skins.append(raw_id)
        if not (0 in owned_skins):
                owned_skins.push_front(0)
        owned_skins.sort()
        current_skin = int(_safe_number(f.get_value("meta", "currentSkin", 0), 0, true))
        if not (current_skin in owned_skins):
                current_skin = 0

        achv = {}
        if f.has_section("achv"):
                for achievement in Config.ACHIEVEMENTS:
                        var achv_id := String(achievement.id)
                        var raw_unlocked: Variant = f.get_value("achv", achv_id, false)
                        if typeof(raw_unlocked) == TYPE_BOOL and raw_unlocked:
                                achv[achv_id] = true

        _load_missions(f)
        _load_settings(f)
        recent_runs = []
        var raw_runs: Variant = f.get_value("meta", "recentRuns", [])
        if raw_runs is Array:
                for raw_distance in raw_runs:
                        var distance_value: Variant = _safe_number(raw_distance, -1.0, false)
                        if float(distance_value) >= 0.0:
                                recent_runs.append(float(distance_value))
        if recent_runs.size() > 8:
                recent_runs = recent_runs.slice(recent_runs.size() - 8)

        _rollover_missions()
        if recovered or needs_migration:
                _save()

func _safe_number(value: Variant, fallback: Variant, integer: bool) -> Variant:
        if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
                return fallback
        var number := float(value)
        if is_nan(number) or is_inf(number) or number < 0.0:
                return fallback
        if integer:
                if number != floor(number):
                        return fallback
                return clampi(int(minf(number, 2147483647.0)), 0, 2147483647)
        return minf(number, 1000000000000.0)

func _load_settings(f: ConfigFile) -> void:
        settings = Config.DEFAULT_SETTINGS.duplicate(true)
        for key in settings.keys():
                var fallback: Variant = settings[key]
                var raw: Variant = f.get_value("settings", key, fallback)
                settings[key] = _safe_setting(String(key), raw, fallback)

func _safe_setting(key: String, value: Variant, fallback: Variant) -> Variant:
        match key:
                "musicVol", "sfxVol", "cameraShake":
                        if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
                                var setting_value := float(value)
                                if not is_nan(setting_value) and not is_inf(setting_value):
                                        return clampf(setting_value, 0.0, 1.0)
                        return fallback
                "haptics", "showFps", "dda":
                        return value if typeof(value) == TYPE_BOOL else fallback
                _:
                        return fallback

func _load_missions(f: ConfigFile) -> void:
        var valid_ids: Array = []
        for definition in Config.MISSION_DEFS:
                valid_ids.append(String(definition.id))
        var loaded: Dictionary = {"day": 0, "sel": [], "progress": {}, "done": {}, "claimed": {}}
        loaded.day = _safe_number(f.get_value("missions", "day", 0), 0, true)
        var raw_selected: Variant = f.get_value("missions", "sel", [])
        if raw_selected is Array:
                for raw_id in raw_selected:
                        if typeof(raw_id) == TYPE_STRING and raw_id in valid_ids and not (raw_id in loaded.sel):
                                loaded.sel.append(raw_id)
        var raw_progress: Variant = f.get_value("missions", "progress", {})
        if raw_progress is Dictionary:
                for raw_id in raw_progress.keys():
                        var mission_id := String(raw_id)
                        if mission_id in valid_ids and mission_id in loaded.sel:
                                var progress_value: Variant = _safe_number(raw_progress[raw_id], 0.0, false)
                                loaded.progress[mission_id] = progress_value
        for field in ["done", "claimed"]:
                var raw_map: Variant = f.get_value("missions", field, {})
                if raw_map is Dictionary:
                        for raw_id in raw_map.keys():
                                var mission_id := String(raw_id)
                                var raw_flag: Variant = raw_map[raw_id]
                                if mission_id in valid_ids and mission_id in loaded.sel and typeof(raw_flag) == TYPE_BOOL:
                                        loaded[field][mission_id] = raw_flag
        missions = loaded

func save() -> bool:
        return _save()

func _atomic_save(f: ConfigFile) -> bool:
        var path := _save_path()
        var tmp := path + ".tmp"
        var bak := path + ".bak"
        var gp := ProjectSettings.globalize_path(path)
        var gt := ProjectSettings.globalize_path(tmp)
        var gb := ProjectSettings.globalize_path(bak)
        var err := f.save(tmp)
        if err != OK or not FileAccess.file_exists(gt):
                _cleanup_tmp_save(gt)
                push_error("存档临时文件写入失败：%s" % error_string(err))
                return false
        if FileAccess.file_exists(gp):
                if FileAccess.file_exists(gb):
                        var remove_err := DirAccess.remove_absolute(gb)
                        if remove_err != OK:
                                _cleanup_tmp_save(gt)
                                push_error("无法替换存档备份：%s" % error_string(remove_err))
                                return false
                var backup_err := DirAccess.rename_absolute(gp, gb)
                if backup_err != OK:
                        _cleanup_tmp_save(gt)
                        push_error("无法备份旧存档：%s" % error_string(backup_err))
                        return false
        var install_err := DirAccess.rename_absolute(gt, gp)
        if install_err != OK:
                if not FileAccess.file_exists(gp) and FileAccess.file_exists(gb):
                        DirAccess.rename_absolute(gb, gp)
                _cleanup_tmp_save(gt)
                push_error("安装新存档失败：%s" % error_string(install_err))
                return false
        return true

func _cleanup_tmp_save(absolute_path: String) -> void:
        if FileAccess.file_exists(absolute_path):
                var remove_error := DirAccess.remove_absolute(absolute_path)
                if remove_error != OK:
                        push_warning("无法清理失败的存档临时文件：%s" % error_string(remove_error))

func _save() -> bool:
        var f := ConfigFile.new()
        for k in stats:
                f.set_value("stats", k, stats[k])
        f.set_value("meta", "wallet", wallet)
        f.set_value("meta", "currentSkin", current_skin)
        f.set_value("meta", "ownedSkins", owned_skins)
        f.set_value("meta", "recentRuns", recent_runs)
        f.set_value("meta", "saveSchema", SAVE_SCHEMA)
        for id in achv:
                f.set_value("achv", id, true)
        for k in missions:
                f.set_value("missions", k, missions[k])
        for k in settings:
                f.set_value("settings", k, settings[k])
        f.set_value("guard", "schema", SAVE_SCHEMA)
        f.set_value("guard", "sig", "")
        # Deterministic corruption check only; this checksum is not an anti-cheat boundary.
        f.set_value("guard", "sig", "v2:" + _canonical_config_payload(f).md5_text())
        var ok := _atomic_save(f)
        if ok:
                _save_error_active = false
                var pending_achievements := _pending_achievement_events.duplicate()
                var pending_missions := _pending_mission_events.duplicate(true)
                _pending_achievement_events.clear()
                _pending_mission_events.clear()
                for achievement_id in pending_achievements:
                        achievement_unlocked.emit(achievement_id)
                for mission_event in pending_missions:
                        mission_completed.emit(String(mission_event.get("id", "")), int(mission_event.get("reward", 0)))
        else:
                # Do not publish unlock/completion notifications for uncommitted data.
                for achievement_id in _pending_achievement_events:
                        achv.erase(achievement_id)
                _pending_achievement_events.clear()
                _pending_mission_events.clear()
                if not _save_error_active:
                        _save_error_active = true
                        save_failed.emit("本地存档写入失败；当前修改尚未可靠保存")
        return ok

func _is_current_schema(f: ConfigFile) -> bool:
        var guard_schema: Variant = f.get_value("guard", "schema", 0)
        var meta_schema: Variant = f.get_value("meta", "saveSchema", 0)
        return typeof(guard_schema) == TYPE_INT and int(guard_schema) == SAVE_SCHEMA \
                and typeof(meta_schema) == TYPE_INT and int(meta_schema) == SAVE_SCHEMA

func _canonical_config_payload(f: ConfigFile) -> String:
        # Stable ordering prevents Dictionary iteration order from changing the signature.
        var sections := f.get_sections()
        sections.sort()
        var lines := PackedStringArray()
        for section in sections:
                var keys := f.get_section_keys(section)
                keys.sort()
                for key in keys:
                        if section == "guard" and key == "sig":
                                continue
                        lines.append(section + "/" + key + "=" + _canonical_variant(f.get_value(section, key)))
        return "\n".join(lines)

func _canonical_variant(value: Variant) -> String:
        if value is Dictionary:
                var keys: Array = value.keys()
                keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
                var parts := PackedStringArray()
                for key in keys:
                        parts.append(_canonical_variant(key) + ":" + _canonical_variant(value[key]))
                return "{" + ",".join(parts) + "}"
        if value is Array:
                var parts := PackedStringArray()
                for item in value:
                        parts.append(_canonical_variant(item))
                return "[" + ",".join(parts) + "]"
        return var_to_str(value)

func _xor_crypt(s: String) -> String:
        var bytes := s.to_utf8_buffer()
        var key := "NEON".to_utf8_buffer()
        for i in bytes.size():
                bytes[i] = bytes[i] ^ key[i % key.size()]
        return bytes.hex_encode()

func _verify_config(f: ConfigFile) -> bool:
        if not f.has_section("guard"):
                return true # Unversioned saves are accepted for one-way migration.
        var raw_schema: Variant = f.get_value("guard", "schema", 0)
        var raw_sig: Variant = f.get_value("guard", "sig", "")
        if typeof(raw_schema) == TYPE_INT and int(raw_schema) == SAVE_SCHEMA:
                if typeof(raw_sig) != TYPE_STRING or not String(raw_sig).begins_with("v2:"):
                        return false
                var stored_schema: Variant = f.get_value("meta", "saveSchema", 0)
                if typeof(stored_schema) != TYPE_INT or int(stored_schema) != SAVE_SCHEMA:
                        return false
                return String(raw_sig) == "v2:" + _canonical_config_payload(f).md5_text()
        # Unknown future schemas are not silently interpreted as a legacy file.
        if typeof(raw_schema) == TYPE_INT and int(raw_schema) > SAVE_SCHEMA:
                return false
        return _verify_legacy_config(f)

func _verify_legacy_config(f: ConfigFile) -> bool:
        var raw_sig: Variant = f.get_value("guard", "sig", "")
        var raw_wallet: Variant = f.get_value("meta", "wallet", 0)
        var raw_best: Variant = f.get_value("stats", "best", 0.0)
        var raw_runs: Variant = f.get_value("stats", "totalRuns", 0)
        if typeof(raw_sig) != TYPE_STRING:
                return false
        if not _is_valid_guard_number(raw_wallet) or not _is_valid_guard_number(raw_best) or not _is_valid_guard_number(raw_runs):
                return false
        if float(raw_wallet) != floor(float(raw_wallet)) or float(raw_runs) != floor(float(raw_runs)):
                return false
        if float(raw_wallet) > 2147483647.0 or float(raw_runs) > 2147483647.0 or float(raw_best) > 1000000000000.0:
                return false
        var fw: int = int(raw_wallet)
        var fb: float = float(raw_best)
        var fr: int = int(raw_runs)
        var payload := "%d|%d|%d" % [fw, int(fb), fr]
        var key := "NR2099_" + payload.md5_text().substr(0, 4)
        return String(raw_sig) == _xor_crypt(key + "|" + payload)

func _is_valid_guard_number(value: Variant) -> bool:
        if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
                return false
        var number := float(value)
        return not is_nan(number) and not is_inf(number) and number >= 0.0

func verify_save() -> bool:
        var f := ConfigFile.new()
        var path := _save_path()
        var err := f.load(path)
        if err != OK:
                # 不存在存档代表首次启动；文件存在但读取失败则应判定为损坏。
                return not FileAccess.file_exists(path)
        return _verify_config(f)

func _snapshot_state() -> Dictionary:
        return {
                "stats": stats.duplicate(true),
                "wallet": wallet,
                "achv": achv.duplicate(true),
                "missions": missions.duplicate(true),
                "settings": settings.duplicate(true),
                "current_skin": current_skin,
                "owned_skins": owned_skins.duplicate(true),
                "recent_runs": recent_runs.duplicate(true),
                "pending_achievements": _pending_achievement_events.duplicate(),
                "pending_missions": _pending_mission_events.duplicate(true),
        }

func _restore_state(snapshot: Dictionary) -> void:
        var previous_wallet := wallet
        stats = snapshot.stats.duplicate(true)
        wallet = int(snapshot.wallet)
        achv = snapshot.achv.duplicate(true)
        missions = snapshot.missions.duplicate(true)
        settings = snapshot.settings.duplicate(true)
        current_skin = int(snapshot.current_skin)
        owned_skins = snapshot.owned_skins.duplicate(true)
        recent_runs = snapshot.recent_runs.duplicate(true)
        _pending_achievement_events = snapshot.pending_achievements.duplicate()
        _pending_mission_events = snapshot.pending_missions.duplicate(true)
        if previous_wallet != wallet:
                wallet_changed.emit(wallet)

# ---------- 局内事件 ----------

func on_run_start() -> void:
        _rollover_missions()
        var snapshot := _snapshot_state()
        stats.totalRuns += 1
        # 每局任务只清未完成的单局进度；已达成待领取的任务保持可领取。
        for m in _active_mission_defs():
                if String(m.get("id", "")).begins_with("q_") and not missions.done.get(m.id, false):
                        missions.progress.erase(m.id)
        if not _save():
                _restore_state(snapshot)

func on_slide_dodge() -> void:
        stats.slideDodges += 1

func on_near_miss() -> void:
        stats.nearMisses += 1

func on_overclock() -> void:
        var snapshot := _snapshot_state()
        stats.overclocks += 1
        _achv_unlock("oc_first")
        if not _save():
                _restore_state(snapshot)

func on_powerup(_kind: String) -> void:
        stats.powerups += 1

func on_revive() -> void:
        var snapshot := _snapshot_state()
        stats.revives += 1
        _achv_unlock("revived")
        if not _save():
                _restore_state(snapshot)

func on_boss_survived(bonus: int) -> void:
        var snapshot := _snapshot_state()
        stats.bossKills += 1
        wallet += maxi(0, bonus)
        _achv_unlock("boss_1")
        if _save():
                wallet_changed.emit(wallet)
        else:
                _restore_state(snapshot)

func on_run_end(distance: float, chips: int, best_combo: int, smashed_count: int = 0, run_stats: Dictionary = {}) -> void:
        var snapshot := _snapshot_state()
        recent_runs.append(distance)
        if recent_runs.size() > 8:
                recent_runs = recent_runs.slice(recent_runs.size() - 8)
        stats.totalDist += distance
        stats.chips += chips
        stats.bestCombo = maxi(stats.bestCombo, best_combo)
        if distance > stats.best:
                stats.best = distance
        # 单局任务在结算时按结果更新；芯片可在局内计数，不能重复加总。
        for m in _active_mission_defs():
                var key: String = m.get("run", "")
                var add: float = 0.0
                match key:
                        "dist": add = distance
                        "chips": add = chips
                        "combo": add = best_combo
                if add > 0.0:
                        _run_mission(m.id, add)
        # 三条常驻任务跨多局累计
        _run_mission("m_dist", distance)
        _run_mission("m_chips", chips)
        _run_mission("m_smash", smashed_count)
        _check_achievements(distance, chips, best_combo, run_stats)
        if not _save():
                _restore_state(snapshot)

func on_run_progress(field: String, value: float) -> void:
        if value <= 0.0:
                return
        var matching_ids: Array[String] = []
        for definition in Config.MISSION_DEFS:
                var mission_id := String(definition.get("id", ""))
                if String(definition.get("run", "")) != field or not (mission_id in missions.sel):
                        continue
                if missions.done.get(mission_id, false) or missions.claimed.get(mission_id, false):
                        continue
                matching_ids.append(mission_id)
        if matching_ids.is_empty():
                return
        # Progress events are called for individual jumps/slides. Snapshot only
        # the fields this operation can mutate instead of cloning all lifetime
        # stats/settings/skins/recent-run arrays on every action.
        var previous_missions: Dictionary = missions.duplicate(true)
        var previous_achievements: Dictionary = achv.duplicate(true)
        var previous_pending_achievements: Array[String] = _pending_achievement_events.duplicate()
        var previous_pending_missions: Array[Dictionary] = _pending_mission_events.duplicate(true)
        var previous_event_count := _pending_mission_events.size()
        for mission_id in matching_ids:
                _run_mission(mission_id, value)
        # Persist immediately when a mission crosses its completion boundary so
        # the UI never announces a reward that was not durably committed.
        if _pending_mission_events.size() > previous_event_count and not _save():
                missions = previous_missions
                achv = previous_achievements
                _pending_achievement_events = previous_pending_achievements
                _pending_mission_events = previous_pending_missions

func _rollover_missions() -> void:
        var previous_missions: Dictionary = missions.duplicate(true)
        var local_date: Dictionary = Time.get_datetime_dict_from_system(false)
        var today: int = int(local_date.year) * 10000 + int(local_date.month) * 100 + int(local_date.day)
        var has_base_missions: bool = "m_dist" in missions.sel and "m_chips" in missions.sel and "m_smash" in missions.sel
        var daily_count := 0
        for mission_id in missions.sel:
                if String(mission_id).begins_with("q_"):
                        daily_count += 1
        if int(missions.day) == today and missions.sel.size() == 6 and has_base_missions and daily_count == 3:
                return
        missions.day = today
        missions.sel = ["m_dist", "m_chips", "m_smash"]
        missions.progress = {}
        missions.done = {}
        missions.claimed = {}
        var pool: Array = []
        for m in Config.MISSION_DEFS:
                if String(m.id).begins_with("q_"):
                        pool.append(m)
        pool.shuffle()
        for m in pool.slice(0, 3):
                missions.sel.append(m.id)
        if not _save():
                missions = previous_missions

func _active_mission_defs() -> Array:
        var out: Array = []
        for m in Config.MISSION_DEFS:
                if m.id in missions.sel:
                        out.append(m)
        return out

func _run_mission(id: String, value: float) -> void:
        if value <= 0.0 or not (id in missions.sel) or missions.done.get(id, false) or missions.claimed.get(id, false):
                return
        var def: Dictionary = {}
        for m in Config.MISSION_DEFS:
                if m.id == id:
                        def = m
                        break
        if def.is_empty():
                return
        var cur: float = float(missions.progress.get(id, 0.0)) + value
        missions.progress[id] = cur
        if cur >= float(def.target):
                missions.done[id] = true
                _pending_mission_events.append({"id": id, "reward": int(def.reward)})

func claim(id: String) -> int:
        _rollover_missions()
        var def: Dictionary
        for m in Config.MISSION_DEFS:
                if m.id == id:
                        def = m
                        break
        if def.is_empty() or not (id in missions.sel) or not missions.done.get(id, false) or missions.claimed.get(id, false):
                return 0
        var old_wallet := wallet
        missions.claimed[id] = true
        wallet += int(def.reward)
        if not _save():
                wallet = old_wallet
                missions.claimed[id] = false
                wallet_changed.emit(wallet)
                return 0
        wallet_changed.emit(wallet)
        return int(def.reward)

func mission_list() -> Array:
        _rollover_missions()
        var out: Array = []
        for m in Config.MISSION_DEFS:
                if m.id in missions.sel:
                        out.append({
                                "id": m.id, "name": m.name, "desc": m.desc, "target": m.target,
                                "unit": m.unit, "reward": m.reward,
                                "cur": floor(missions.progress.get(m.id, 0.0)),
                                "done": missions.done.get(m.id, false),
                                "claimed": missions.claimed.get(m.id, false),
                        })
        return out

# ---------- 成就 ----------

func _check_achievements(distance: float, chips: int, best_combo: int, run_stats: Dictionary) -> void:
        if stats.totalRuns >= 1: _achv_unlock("first_run")
        if distance >= 500.0: _achv_unlock("dist_500")
        if distance >= 1500.0: _achv_unlock("dist_1500")
        if distance >= 3000.0: _achv_unlock("dist_3000")
        if best_combo >= 24: _achv_unlock("combo_24")
        if best_combo >= 48: _achv_unlock("combo_48")
        if stats.overclocks >= 1: _achv_unlock("oc_first")
        if int(run_stats.get("overclockSmashes", 0)) >= 10: _achv_unlock("oc_smash10")
        if int(run_stats.get("shieldSaves", 0)) >= 1: _achv_unlock("shield_save")
        if chips >= 50: _achv_unlock("chips_50")
        var kinds: Dictionary = run_stats.get("powerupKinds", {})
        if ["magnet", "shield", "double", "board"].all(func(k): return kinds.get(k, false)):
                _achv_unlock("power_all")
        if stats.bossKills >= 1: _achv_unlock("boss_1")

func achievement_list() -> Array:
        var out: Array = []
        for a in Config.ACHIEVEMENTS:
                out.append({
                        "id": a.id, "name": a.name, "desc": a.desc,
                        "unlocked": achv.get(a.id, false),
                })
        return out

# ---------- 皮肤 / 商店 ----------

func buy_skin(id: int) -> bool:
        var def: Dictionary
        for s in Player.SKINS:
                if s.id == id:
                        def = s
                        break
        if def.is_empty() or id in owned_skins or wallet < def.price:
                return false
        var old_wallet := wallet
        wallet -= int(def.price)
        owned_skins.append(id)
        if not _save():
                wallet = old_wallet
                owned_skins.erase(id)
                wallet_changed.emit(wallet)
                return false
        wallet_changed.emit(wallet)
        return true

func equip_skin(id: int) -> bool:
        if not (id in owned_skins):
                return false
        var old_skin := current_skin
        current_skin = id
        if not _save():
                current_skin = old_skin
                return false
        return true

func unlock_achievement(id: String) -> void:
        if _achv_unlock(id):
                _save()

func _achv_unlock(id: String) -> bool:
        var known_id := false
        for item in Config.ACHIEVEMENTS:
                if String(item.get("id", "")) == id:
                        known_id = true
                        break
        if not known_id:
                return false
        if achv.get(id, false):
                return false
        achv[id] = true
        if not id in _pending_achievement_events:
                _pending_achievement_events.append(id)
        return true
