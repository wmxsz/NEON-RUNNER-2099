extends Node
class_name AudioEngine
## AudioEngine
## - OGG tracks handle background music and chapter/BOSS transitions.
## - Pre-rendered short WAV effects are played through a small voice pool, so
## simultaneous events do not overwrite one shared oscillator.
## - Keeps the public API used by Main/HUD unchanged.

const MUSIC_TRACKS := [
        "theme_0_downtown", "theme_1_industrial", "theme_2_skyport",
        "theme_3_electric", "theme_4_golden", "theme_5_deepsea",
        "theme_6_polar", "theme_7_sunset", "boss_theme",
]
# Preload the complete short playlist as stream resources so the first transition
# into a chapter/BOSS theme never performs a path-based load in the gameplay loop.
# OGG remains compressed; this removes repeated lookup/load work at transition time.
const MUSIC_STREAMS := [
        preload("res://assets/music/theme_0_downtown.ogg"),
        preload("res://assets/music/theme_1_industrial.ogg"),
        preload("res://assets/music/theme_2_skyport.ogg"),
        preload("res://assets/music/theme_3_electric.ogg"),
        preload("res://assets/music/theme_4_golden.ogg"),
        preload("res://assets/music/theme_5_deepsea.ogg"),
        preload("res://assets/music/theme_6_polar.ogg"),
        preload("res://assets/music/theme_7_sunset.ogg"),
        preload("res://assets/music/boss_theme.ogg"),
]
const SFX_STREAMS := {
        "chip": preload("res://assets/sfx/chip.wav"),
        "jump": preload("res://assets/sfx/jump.wav"),
        "land": preload("res://assets/sfx/land.wav"),
        "slide": preload("res://assets/sfx/slide.wav"),
        "die": preload("res://assets/sfx/die.wav"),
        "powerup": preload("res://assets/sfx/powerup.wav"),
        "overclock": preload("res://assets/sfx/overclock.wav"),
        "ui": preload("res://assets/sfx/ui.wav"),
        "achv": preload("res://assets/sfx/achv.wav"),
        "ready": preload("res://assets/sfx/ready.wav"),
        "boss": preload("res://assets/sfx/boss.wav"),
        "revive": preload("res://assets/sfx/revive.wav"),
}
const MAX_SFX_VOICES := 8
const COMBO_GAIN_DB := 0.55
const SFX_PRIORITY := {
        "chip": 0, "land": 1, "jump": 1, "slide": 1, "ui": 1,
        "powerup": 2, "ready": 3, "achv": 3, "boss": 4,
        "overclock": 4, "revive": 4, "die": 5,
}
# Global makeup gain restores perceived loudness after bus compression. The
# hard limiter after reverb catches summed peaks without turning the whole mix down.
const MIX_MAKEUP_GAIN_DB := 3.0
const MIX_LIMITER_CEILING_DB := -1.0
# Quiet/short UI cues get a little more trim than naturally louder impacts.
# These are offsets on top of the user SFX slider, not replacements for it.
const SFX_GAIN_DB := {
        "chip": 1.0,
        "jump": 1.5,
        "land": 1.0,
        "slide": 1.5,
        "die": 1.0,
        "powerup": 1.5,
        "overclock": 1.0,
        "ui": 4.0,
        "achv": 3.5,
        "ready": 3.5,
        "boss": 0.5,
        "revive": 1.5,
}
const MUSIC_CROSSFADE_OUT := 0.18
const MUSIC_CROSSFADE_IN := 0.35

var music_vol: float = 0.8
var sfx_vol: float = 1.0
var _combo_lvl: int = 0

var _music: AudioStreamPlayer
var _music_idx: int = -1
var _wanted_theme: int = 0
var _music_tween: Tween
var _music_target_db: float = -1.94
var _music_transitioning: bool = false
var _boss_lock: bool = false
var _overclock_lock: bool = false
var _legacy_lock: bool = false

var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_voice_stamps: Array[int] = []
var _sfx_voice_kinds: Array[String] = []
var _sfx_voice_priorities: Array[int] = []
var _sfx_serial: int = 0
var _sfx_dropped_count: int = 0

func _ready() -> void:
        _ensure_mix_bus()
        _music = AudioStreamPlayer.new()
        _music.name = "BackgroundMusic"
        _music.bus = "Music"
        add_child(_music)
        for i in MAX_SFX_VOICES:
                var voice := AudioStreamPlayer.new()
                voice.name = "SFXVoice%d" % i
                voice.bus = "SFX"
                add_child(voice)
                _sfx_players.append(voice)
                _sfx_voice_stamps.append(-1)
                _sfx_voice_kinds.append("")
                _sfx_voice_priorities.append(0)
        _update_music_target_db()

func _ensure_mix_bus() -> void:
        var music_idx := _ensure_bus("Music")
        var sfx_idx := _ensure_bus("SFX")
        _ensure_bus("UI")

        var music_comp := _get_or_add_effect(music_idx, AudioEffectCompressor.new()) as AudioEffectCompressor
        music_comp.threshold = -9.0
        music_comp.ratio = 2.5
        music_comp.attack_us = 250
        music_comp.release_ms = 160
        music_comp.gain = MIX_MAKEUP_GAIN_DB
        var music_reverb := _get_or_add_effect(music_idx, AudioEffectReverb.new()) as AudioEffectReverb
        music_reverb.room_size = 0.24
        music_reverb.wet = 0.08
        music_reverb.damping = 0.8

        var sfx_comp := _get_or_add_effect(sfx_idx, AudioEffectCompressor.new()) as AudioEffectCompressor
        sfx_comp.threshold = -8.0
        sfx_comp.ratio = 2.2
        sfx_comp.attack_us = 180
        sfx_comp.release_ms = 110
        sfx_comp.gain = 1.5
        var sfx_reverb := _get_or_add_effect(sfx_idx, AudioEffectReverb.new()) as AudioEffectReverb
        sfx_reverb.room_size = 0.14
        sfx_reverb.wet = 0.035
        sfx_reverb.damping = 0.86

        # UI cues stay dry and intelligible. Limit only the final summed output;
        # the limiter is kept last even if the host project already has effects.
        var master_idx := AudioServer.get_bus_index("Master")
        var limiter_index := -1
        for i in AudioServer.get_bus_effect_count(master_idx):
                if AudioServer.get_bus_effect(master_idx, i) is AudioEffectHardLimiter:
                        limiter_index = i
                        break
        var limiter: AudioEffectHardLimiter
        if limiter_index >= 0:
                limiter = AudioServer.get_bus_effect(master_idx, limiter_index) as AudioEffectHardLimiter
                if limiter_index != AudioServer.get_bus_effect_count(master_idx) - 1:
                        AudioServer.remove_bus_effect(master_idx, limiter_index)
                        AudioServer.add_bus_effect(master_idx, limiter)
        else:
                limiter = AudioEffectHardLimiter.new()
                AudioServer.add_bus_effect(master_idx, limiter)
        limiter.ceiling_db = MIX_LIMITER_CEILING_DB
        limiter.release = 0.12

func _ensure_bus(bus_name: String) -> int:
        var bus_idx := AudioServer.get_bus_index(bus_name)
        if bus_idx == -1:
                bus_idx = AudioServer.bus_count
                AudioServer.add_bus()
                AudioServer.set_bus_name(bus_idx, bus_name)
        AudioServer.set_bus_send(bus_idx, "Master")
        return bus_idx

func _get_or_add_effect(bus_idx: int, desired: AudioEffect) -> AudioEffect:
        var desired_class := desired.get_class()
        for i in AudioServer.get_bus_effect_count(bus_idx):
                var existing := AudioServer.get_bus_effect(bus_idx, i)
                if existing.get_class() == desired_class:
                        return existing
        AudioServer.add_bus_effect(bus_idx, desired)
        return desired

# ---------- Background music ----------

func start_bgm() -> void:
        if is_instance_valid(_music) and _music.playing and _music_idx >= 0:
                return
        if _music_lock_active():
                _play_music_idx(8)
        else:
                _play_music_idx(_wanted_theme)

func stop_bgm() -> void:
        if not is_instance_valid(_music):
                _music_idx = -1
                return
        _kill_music_tween()
        if not _music.playing:
                _music_idx = -1
                _music_transitioning = false
                return
        _music_transitioning = true
        _music_tween = _music.create_tween()
        _music_tween.tween_property(_music, "volume_db", -40.0, 0.22)
        _music_tween.tween_callback(func():
                if is_instance_valid(_music):
                        _music.stop()
                _music_idx = -1
                _music_transitioning = false)
        # Mark the requested state immediately. start_bgm can cancel this fade
        # if the player resumes before the fade-out finishes.
        _music_idx = -1

## Clear every piece of audio state owned by a previous run. New runs always
## begin on chapter zero and must not inherit a BOSS/overclock lock or old SFX.
func reset_run_state() -> void:
        _kill_music_tween()
        _boss_lock = false
        _overclock_lock = false
        _legacy_lock = false
        _combo_lvl = 0
        _wanted_theme = 0
        _music_idx = -1
        _music_transitioning = false
        _update_music_target_db()
        if is_instance_valid(_music):
                _music.stop()
                _music.volume_db = _music_target_db
        for i in _sfx_players.size():
                _sfx_players[i].stop()
                _sfx_voice_stamps[i] = -1
                _sfx_voice_kinds[i] = ""
                _sfx_voice_priorities[i] = 0
        _sfx_serial = 0
        _sfx_dropped_count = 0

func set_theme(idx: int) -> void:
        _wanted_theme = posmod(idx, MUSIC_TRACKS.size() - 1)
        if _music_lock_active():
                return
        _play_music_idx(_wanted_theme)

func set_chorus_lock(on: bool) -> void:
        # Compatibility alias for older callers; BOSS/overclock use independent locks.
        _legacy_lock = on
        _sync_music_lock()

func set_boss_lock(on: bool) -> void:
        _boss_lock = on
        _sync_music_lock()

func set_overclock_lock(on: bool) -> void:
        _overclock_lock = on
        _sync_music_lock()

func _music_lock_active() -> bool:
        return _boss_lock or _overclock_lock or _legacy_lock

func _sync_music_lock() -> void:
        if _music_lock_active():
                if _music_idx != MUSIC_TRACKS.size() - 1 or not is_instance_valid(_music) or not _music.playing:
                        _play_music_idx(MUSIC_TRACKS.size() - 1)
        elif _music_idx == MUSIC_TRACKS.size() - 1 or _music_idx < 0:
                _play_music_idx(_wanted_theme)

func _play_music_idx(idx: int) -> void:
        idx = clampi(idx, 0, MUSIC_TRACKS.size() - 1)
        if idx < MUSIC_TRACKS.size() - 1:
                _wanted_theme = idx
        if idx == _music_idx and is_instance_valid(_music) and _music.playing:
                return
        var stream: AudioStreamOggVorbis = MUSIC_STREAMS[idx] as AudioStreamOggVorbis
        if stream == null:
                push_error("背景音乐预载资源无效：%s" % MUSIC_TRACKS[idx])
                return
        stream.loop = true
        _kill_music_tween()
        _music_idx = idx
        _music_transitioning = true
        if _music.playing:
                _music_tween = _music.create_tween()
                _music_tween.tween_property(_music, "volume_db", -32.0, MUSIC_CROSSFADE_OUT)
                _music_tween.tween_callback(func(): _swap_and_fade_in(stream))
        else:
                _swap_and_fade_in(stream)

func _swap_and_fade_in(stream: AudioStreamOggVorbis) -> void:
        if not is_instance_valid(_music):
                return
        _music.stream = stream
        _music.volume_db = -32.0
        _music.play()
        _music_transitioning = true
        _music_tween = _music.create_tween()
        _music_tween.tween_property(_music, "volume_db", _music_target_db, MUSIC_CROSSFADE_IN)
        _music_tween.tween_callback(_on_music_fade_complete)

func _on_music_fade_complete() -> void:
        _music_transitioning = false
        if is_instance_valid(_music) and _music.playing and absf(_music.volume_db - _music_target_db) > 0.15:
                _sync_music_volume(0.10)

func _kill_music_tween() -> void:
        if is_instance_valid(_music_tween):
                _music_tween.kill()
        _music_tween = null

func _update_music_target_db() -> void:
        if music_vol <= 0.0001:
                _music_target_db = -80.0
        else:
                _music_target_db = linear_to_db(music_vol) + float(_combo_lvl) * COMBO_GAIN_DB
                _music_target_db = minf(_music_target_db, 1.0)

func _sync_music_volume(duration: float = 0.16) -> void:
        if _music_transitioning or not is_instance_valid(_music) or not _music.playing:
                return
        _kill_music_tween()
        _music_tween = _music.create_tween()
        _music_tween.tween_property(_music, "volume_db", _music_target_db, duration)

func set_combo_lvl(level: int) -> void:
        var next_level := clampi(level, 0, 3)
        if next_level == _combo_lvl:
                return
        _combo_lvl = next_level
        _update_music_target_db()
        _sync_music_volume(0.22)

func is_bgm_playing() -> bool:
        return is_instance_valid(_music) and _music.playing

# ---------- Sound effects ----------

func play_sfx(kind: String) -> void:
        if not SFX_STREAMS.has(kind):
                push_warning("未知音效类型：%s" % kind)
                return
        var voice_index := -1
        for i in _sfx_players.size():
                if not _sfx_players[i].playing:
                        voice_index = i
                        break
        var requested_priority := int(SFX_PRIORITY.get(kind, 0))
        if voice_index < 0:
                # When saturated, evict the lowest-priority voice; among equal
                # priorities evict the oldest. Never let chip spam silence death/BOSS cues.
                var victim_priority := 2147483647
                var victim_stamp := 2147483647
                for i in _sfx_players.size():
                        var active_priority := _sfx_voice_priorities[i]
                        var active_stamp := _sfx_voice_stamps[i]
                        if active_priority < victim_priority or (active_priority == victim_priority and active_stamp < victim_stamp):
                                voice_index = i
                                victim_priority = active_priority
                                victim_stamp = active_stamp
                if voice_index < 0 or requested_priority < victim_priority:
                        _sfx_dropped_count += 1
                        return
        _sfx_serial += 1
        _sfx_voice_stamps[voice_index] = _sfx_serial
        _sfx_voice_priorities[voice_index] = requested_priority
        var voice := _sfx_players[voice_index]
        voice.stop()
        _sfx_voice_kinds[voice_index] = kind
        voice.bus = "UI" if kind in ["ui", "achv", "ready"] else "SFX"
        voice.stream = SFX_STREAMS[kind] as AudioStream
        voice.volume_db = _sfx_voice_volume_db(kind)
        voice.play()

func dropped_sfx_count() -> int:
        return _sfx_dropped_count

func _sfx_voice_volume_db(kind: String) -> float:
        if sfx_vol <= 0.0001:
                return -80.0
        return linear_to_db(sfx_vol) + float(SFX_GAIN_DB.get(kind, 0.0))

func apply_volumes(music: float, sfx: float) -> void:
        music_vol = clampf(music, 0.0, 1.0)
        sfx_vol = clampf(sfx, 0.0, 1.0)
        _update_music_target_db()
        _sync_music_volume(0.12)
        for i in _sfx_players.size():
                _sfx_players[i].volume_db = _sfx_voice_volume_db(_sfx_voice_kinds[i])
