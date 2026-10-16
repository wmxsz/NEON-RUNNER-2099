#!/usr/bin/env python3
"""Release-independent source contracts for the current project manifest.

This checks source invariants and catalogue/model resources offline. It does not
replace Godot parser/semantic compilation or Android runtime validation.
"""
from __future__ import annotations
import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def fail(message: str) -> None:
    raise SystemExit(f"FAIL release contracts: {message}")

def function_body(source: str, function_name: str) -> str:
    signature = rf"(?m)^func {re.escape(function_name)}\([^\n]*\)(?:\s*->\s*[^:\n]+)?:\s*\n"
    header = re.search(signature, source)
    if not header:
        fail(f"cannot locate function signature {function_name}()")
    body = re.search(r"(?m)(.*?)(?=^func \w+\(|\Z)", source[header.end():], re.S)
    match = body
    if not match:
        fail(f"cannot locate function {function_name}()")
    return match.group(1)

def main() -> int:
    manifest = json.loads((ROOT / "RELEASE_MANIFEST.json").read_text(encoding="utf-8"))
    expected_version = str(manifest["version"])
    expected_code = int(manifest["android_version_code"])
    recommended_engine = str(manifest["godot_recommended_version"])
    if not re.fullmatch(r"\d+\.\d+\.\d+-stable", recommended_engine):
        fail("RELEASE_MANIFEST.json must pin a stable Godot patch version")
    if not recommended_engine.startswith(str(manifest["godot_series"]) + "."):
        fail("recommended Godot patch must match godot_series")
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    export = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
    main_source = (ROOT / "scenes/main.gd").read_text(encoding="utf-8")
    game_source = (ROOT / "core/game.gd").read_text(encoding="utf-8")
    input_source = (ROOT / "systems/input.gd").read_text(encoding="utf-8")
    spawner = (ROOT / "entities/spawner.gd").read_text(encoding="utf-8")
    audio = (ROOT / "systems/audio.gd").read_text(encoding="utf-8")
    progress = (ROOT / "systems/progress.gd").read_text(encoding="utf-8")
    headless_test = (ROOT / "tests/test_headless.gd").read_text(encoding="utf-8")
    content_test = (ROOT / "tests/test_content.gd").read_text(encoding="utf-8")
    mechanics_test = (ROOT / "tests/test_mechanics.gd").read_text(encoding="utf-8")
    all_test_sources = "\n".join(path.read_text(encoding="utf-8") for path in sorted((ROOT / "tests").glob("*.gd")))
    godot_test_runner = (ROOT / "tools/run_godot_tests.sh").read_text(encoding="utf-8")

    # Async headless tests must be awaited before reporting/quit. Reject assertions
    # that are trivially true and therefore cannot detect regressions.
    if not re.search(r"(?m)^func _ready\(\) -> void:\n\s+await _run_all\(\)", headless_test):
        fail("headless test harness must await _run_all() before checking failures/quitting")
    if re.search(r"\bor\s+true\b", all_test_sources):
        fail("test suite contains an always-true 'or true' assertion")
    if re.search(r"\b_ok\s*\(\s*true\s*,", all_test_sources) or re.search(r"\bassert\s*\(\s*true\s*[,)]", all_test_sources):
        fail("test suite contains a constant-true _ok/assert check")
    if "func _t_laser_weight_pool() -> void:" not in mechanics_test or "_candidate_pattern_pool(1000.0, true)" not in mechanics_test:
        fail("laser weight mechanics test must compare deterministic candidate pools")
    if "_count_laser_picks" in mechanics_test or "n_laser >= n_norm" in mechanics_test:
        fail("flaky random-frequency laser test is still present")
    if 'main.menus.gameover_root.visible' not in (ROOT / "tests/test_runtime.gd").read_text(encoding="utf-8") or 'result_text.contains("得分 %d" % int(game.score()))' not in (ROOT / "tests/test_runtime.gd").read_text(encoding="utf-8"):
        fail("runtime game-over contract must check the visible panel and live score/distance")
    if "clear_vy_before" not in content_test or "is_equal_approx(main.player.vy, clear_vy_before)" not in content_test:
        fail("input-queue clear contract must detect a jump impulse, not only vertical displacement")
    if '"laserWeightMult": 3.0' not in (ROOT / "core/config.gd").read_text(encoding="utf-8"):
        fail("laserWeightMult must be an explicit 3.0 candidate-pool weight")
    if 'Telemetry.has_signal("report_updated")' not in content_test or 'Telemetry.perf_grade in ["high", "mid", "low"]' not in content_test:
        fail("content test must validate telemetry's actual public signal and grade")
    if "FRAME_BUDGET=5400" not in godot_test_runner or 'res://tests/test_content.tscn' not in godot_test_runner:
        fail("content soak test needs a dedicated frame budget long enough for its timed scenarios")
    # Tests must not erase or mutate real user data, even when the scene is launched manually.
    if "export NR2099_TEST_MODE=1" not in godot_test_runner or "export NR2099_TEST_MODE=1" not in (ROOT / "run_tests.sh").read_text(encoding="utf-8"):
        fail("both Godot shell runners must set NR2099_TEST_MODE=1")
    for rel in ("tests/test_content.gd", "tests/test_mechanics.gd", "tests/test_runtime.gd"):
        harness = (ROOT / rel).read_text(encoding="utf-8")
        if 'OS.set_environment("NR2099_TEST_MODE", "1")' not in harness or "_clear_test_artifacts()" not in harness:
            fail(f"{rel} must force an isolated save/replay namespace before Main is instantiated")
        if 'remove_absolute(ProjectSettings.globalize_path("user://nr2099_save.cfg"))' in harness:
            fail(f"{rel} must never delete the player's production save")
    for token in ("func _persist_last_run_trace(trace: Dictionary) -> bool:", "writer.flush()", "parser.parse(candidate_text)", 'target + ".bak"', "DirAccess.rename_absolute(temporary_abs, target_abs)", "func _read_valid_last_run_trace() -> Dictionary:"):
        if token not in main_source:
            fail(f"Atomic replay persistence/recovery contract missing: {token}")
    if 'OS.get_environment("NR2099_TEST_MODE") == "1" else LAST_RUN_TRACE_PATH' not in main_source:
        fail("Replay persistence must use a distinct test filename when test isolation is enabled")
    for token in ("NOTIFICATION_APPLICATION_FOCUS_OUT", "NOTIFICATION_APPLICATION_PAUSED", "clear_queue()"):
        if token not in input_source:
            fail(f"Touch interruption cleanup contract missing: {token}")
    if godot_test_runner.count("--fixed-fps 60") < 2:
        fail("headless test scenes and main-scene smoke test must run at deterministic 60 FPS")
    if "func _t_render_budget_profiles() -> void:" not in mechanics_test or "DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS" not in mechanics_test or "low_boost.glowLevels.size() == 2" not in mechanics_test:
        fail("Mechanics suite must exercise high/mid/low native shadows and glow level budgets")
    world_source = (ROOT / "world/world.gd").read_text(encoding="utf-8")
    telemetry_source = (ROOT / "core/telemetry.gd").read_text(encoding="utf-8")
    road_source = (ROOT / "world/road_grid.gdshader").read_text(encoding="utf-8")
    if "get_render_budget_snapshot()" not in telemetry_source or '"renderBudget": world.get_render_budget_snapshot()' not in telemetry_source:
        fail("Telemetry must report the native render budget so grade changes can be diagnosed")
    if "DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS" not in world_source or "_env.set_glow_level(index, levels[index])" not in world_source:
        fail("World must configure real native shadow modes and individual glow levels")
    if "cyber_line_coverage" not in road_source or "fwidth(distance_to_line)" not in road_source or "subpixel_coverage = clamp(half_width / max(aa_width, half_width)" not in road_source:
        fail("Road energy markings need derivative-aware anti-aliasing")
    for token in ("func _build_road_deck_hardware() -> void:", '"MachinedDeckRibs"', '"TitaniumDeckFasteners"', "ribs.instance_count = row_count", "fasteners.instance_count = row_count * lane_fastener_x.size()", "ROAD_DECK_LENGTH := 420.0", "ROAD_DECK_CENTER_Z := -170.0", "_deck_hardware_root.position.z = _road_distance", "ribs.reset_instances_physics_interpolation()", "fasteners.reset_instances_physics_interpolation()"):
        if token not in world_source:
            fail(f"Physical cyber-deck detail/rebase contract missing: {token}")
    if "func _t_trace_storage() -> void:" not in (ROOT / "tests/test_runtime.gd").read_text(encoding="utf-8"):
        fail("Runtime suite must test atomic replay recording and backup recovery")
    if "func _t_input_focus_loss() -> void:" not in mechanics_test:
        fail("Mechanics suite must test application-focus touch cancellation")
    def reference_line_coverage(distance: float, half_width: float, pixel_footprint: float) -> float:
        aa = max(pixel_footprint, 0.00045)
        low = max(0.0, half_width - aa)
        high = half_width + aa
        x = min(1.0, max(0.0, (distance - low) / max(high - low, 1e-12)))
        edge = 1.0 - (x * x * (3.0 - 2.0 * x))
        subpixel = min(1.0, max(0.0, half_width / max(aa, half_width)))
        return edge * subpixel
    close_line = reference_line_coverage(0.0, 0.00465, 0.001)
    distant_line = reference_line_coverage(0.0, 0.00465, 0.02)
    outside_line = reference_line_coverage(0.03, 0.00465, 0.02)
    if not (close_line > distant_line > 0.0 and outside_line == 0.0):
        fail("Road-line reference model must soften subpixel lines with distance and fully clear exterior fragments")

    # Version and export identity must agree.
    project_version = re.search(r'^config/version="([^"]+)"', project, re.M)
    export_version = re.search(r'^version/name="([^"]+)"', export, re.M)
    export_code = re.search(r'^version/code=(\d+)', export, re.M)
    if not project_version or not export_version or not export_code:
        fail("project or Android version fields are missing")
    if project_version.group(1) != expected_version or export_version.group(1) != expected_version or int(export_code.group(1)) != expected_code:
        fail(f"project.godot / Android identity must match RELEASE_MANIFEST.json ({expected_version} / {expected_code})")

    # Current maintainer entry points must advertise the same baseline.
    for rel in ("README.md", "docs/PROJECT_MAP.md", "docs/DEVELOPMENT_GUIDE.md", "docs/REGRESSION_CHECKLIST.md", "docs/README.md"):
        doc = (ROOT / rel).read_text(encoding="utf-8")
        if f"v{expected_version}" not in doc or f"versionCode={expected_code}" not in doc:
            fail(f"current version baseline is stale in {rel}")

    # Camera feedback/settings contract: stable baseline, smooth impulse, bounded persisted value.
    menus_source = (ROOT / "ui/menus.gd").read_text(encoding="utf-8")
    # Check in the owning source files explicitly (avoid relying on a single concatenated match).
    config_source = (ROOT / "core/config.gd").read_text(encoding="utf-8")
    if '"cameraShake": 0.75' not in config_source:
        fail("cameraShake default setting missing")
    for token in ('var _camera_base_position: Vector3 = Vector3.ZERO',
                  'var _camera_shake_envelope: float = 0.0',
                  '_camera_base_position.x = U.dampf(_camera_base_position.x, tx, 8.0, camera_dt)',
                  '_camera_base_position.y = U.dampf(_camera_base_position.y, ty, 6.0, camera_dt)',
                  '_camera_shake_envelope = U.dampf(_camera_shake_envelope, game.cam_shake, 18.0, camera_dt)',
                  'game.cam_shake - camera_dt * 1.9',
                  '_camera_shake_phase = fposmod(_camera_shake_phase + camera_dt, 10.0)',
                  'camera_dt: float = clampf(raw_dt, 0.0, 0.05)',
                  'game.land_dip = maxf(0.0, game.land_dip - camera_dt)',
                  'sin(_camera_shake_phase * TAU * 4.4)'):
        if token not in main_source:
            fail(f"camera impulse/follow contract missing: {token}")
    if 'U.randf_range(-s, s)' in main_source:
        fail("camera shake must not inject fresh random offsets into the damped transform")
    if 's.get("cameraShake", 0.75)' not in menus_source or '"cameraShake"' not in menus_source or '"镜头震动强度"' not in menus_source:
        fail("camera-shake setting slider is missing")
    if 'elif key == "cameraShake":' not in main_source:
        fail("camera-shake slider must support live preview and persistence rollback")
    start_run_body = function_body(main_source, "_start_run")
    if "_camera_shake_envelope = 0.0" not in start_run_body or "_camera_shake_phase = 0.0" not in start_run_body:
        fail("a new/retried run must clear the previous camera impact envelope")
    setting_body = function_body(progress, "_safe_setting")
    if '"musicVol", "sfxVol", "cameraShake"' not in setting_body or 'clampf(setting_value, 0.0, 1.0)' not in setting_body or 'is_nan(setting_value)' not in setting_body or 'is_inf(setting_value)' not in setting_body:
        fail("cameraShake setting must be finite and clamped to [0, 1]")

    # Numerical reference model for the implemented frame-rate-independent equations.
    # This is not a Godot runtime test, but catches accidental refresh-rate drift in the math.
    def simulate_camera_shake(fps: int, strength: float = 0.75, initial: float = 0.25, seconds: float = 0.6):
        dt = 1.0 / float(fps)
        t = target = 0.0
        target = initial
        envelope = 0.0
        phase = 0.0
        rows = [(0.0, 0.0, 0.0)]
        while t < seconds - 1e-12:
            step = min(dt, 0.05)
            target = max(0.0, target - step * 1.9)
            envelope += (target - envelope) * (1.0 - math.exp(-18.0 * step))
            phase = (phase + step) % 10.0
            amp = envelope * 0.35 * strength
            x = math.sin(phase * math.tau * 4.4) * amp
            y = (math.sin(phase * math.tau * 3.2 + 0.8) * 0.68 + math.sin(phase * math.tau * 6.1 + 1.6) * 0.14) * amp
            t += dt
            rows.append((t, x, y))
        return rows

    def sample_trace(rows, t, axis):
        if t <= rows[0][0]:
            return rows[0][axis]
        for first, second in zip(rows, rows[1:]):
            if first[0] <= t <= second[0]:
                fraction = (t - first[0]) / (second[0] - first[0])
                return first[axis] + (second[axis] - first[axis]) * fraction
        return rows[-1][axis]

    traces = {fps: simulate_camera_shake(fps) for fps in (60, 90, 120)}
    for fps in (90, 120):
        max_difference = 0.0
        for sample in range(1, 301):
            moment = sample / 600.0
            for axis in (1, 2):
                max_difference = max(max_difference, abs(sample_trace(traces[60], moment, axis) - sample_trace(traces[fps], moment, axis)))
        if max_difference > 0.005:
            fail(f"camera impulse reference differs at {fps}Hz (max delta {max_difference:.6f})")
    if any(abs(value) > 1e-12 for _, x, y in simulate_camera_shake(120, strength=0.0) for value in (x, y)):
        fail("cameraShake=0 must disable all rendered impact offsets")
    period_error = max(abs(math.sin((10.0 + sample) * math.tau * frequency) - math.sin(sample * math.tau * frequency))
                       for sample in (0.0, 0.001, 0.017, 0.137, 1.234, 9.75)
                       for frequency in (4.4, 3.2, 6.1))
    if period_error > 1e-9:
        fail(f"camera waveform 10-second wrap is discontinuous ({period_error:.3g})")
    print("PASS camera waveform reference model: 60/90/120Hz max position delta < 0.005 units; zero-strength path is motionless; 10s phase wrap is continuous")

    # DDA mode is a string; DDA enabled remains a separate bool.
    if "var dda_mode: String = compute_dda() if dda_enabled else \"\"" not in main_source:
        fail("Main must keep DDA mode String separate from the enabled setting")
    if "var run_dda: bool = compute_dda()" in main_source:
        fail("legacy DDA bool/String type collision remains")
    for token in ("Game.dda_gap_for(dda_mode)", "Game.dda_unlock_for(dda_mode)", "game.start_run(dda_mode, run_seed)", "begin_run_recording\", run_seed, dda_enabled, dda_mode"):
        if token not in main_source:
            fail(f"Main DDA mode isn't wired consistently: {token}")
    if "func start_run(dda: String = \"\", seed_value: int = 0) -> void:" not in game_source:
        fail("Game.start_run must accept DDA mode as a String")

    # Replay is versioned and stores the actual mode plus compatibility metadata.
    for token in (
        "const TRACE_SCHEMA := 2", "const TRACE_RULESET_VERSION := 1",
        '"game_version": String(ProjectSettings.get_setting("application/config/version", "unknown"))',
        '"engine_version": String(Engine.get_version_info().get("string", "unknown"))',
        '"physics_hz": int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))',
        '"dda_enabled": _recording_dda_enabled', '"dda_mode": _recording_dda_mode',
        "typeof(raw_dda_enabled) != TYPE_BOOL", "typeof(raw_dda_mode) != TYPE_STRING",
        "TRACE_RULESET_VERSION", "String(raw_engine_version) != String(Engine.get_version_info().get(\"string\", \"unknown\"))",
    ):
        if token not in input_source:
            fail(f"replay schema/compatibility guard missing: {token}")
    if '"dda": _recording_dda' in input_source or 'trace.get("dda",' in main_source:
        fail("obsolete ambiguous replay DDA bool field remains")

    # Avoid dropping a powerup after blocked placement attempts.
    if "while tries < 6 and _lane_blocked" in spawner:
        fail("legacy unsafe fixed-lane powerup retry remains")
    if "if chosen_lane >= 0 and not _lane_blocked(chosen_lane, next_spawn_z - chosen_dz):" not in spawner or "pu.active = false" not in spawner:
        fail("powerup spawn needs a final safety check and explicit skip path")
    for token in ("for lane_offset in 3:", "for depth_offset in 6:", "_lane_blocked(candidate_lane, next_spawn_z - candidate_dz)"):
        if token not in spawner:
            fail(f"bounded all-lane powerup search missing: {token}")

    # Audio mixer is resilient to pre-existing buses/effects and protects important cues.
    for token in ('_ensure_bus("Music")', '_ensure_bus("SFX")', '_ensure_bus("UI")',
                  "func _get_or_add_effect(bus_idx: int, desired: AudioEffect) -> AudioEffect:",
                  'voice.bus = "UI" if kind in ["ui", "achv", "ready"] else "SFX"',
                  'const SFX_PRIORITY := {', "requested_priority < victim_priority", "func dropped_sfx_count() -> int:",
                  "AudioEffectHardLimiter.new()"):
        if token not in audio:
            fail(f"audio bus/voice priority invariant missing: {token}")
    if 'voice.bus = "GameMix"' in audio or '"GameMix"' in function_body(audio, "_ensure_mix_bus"):
        fail("audio still routes all music and SFX through one shared GameMix bus")
    for key in ("chip", "die", "boss", "overclock", "revive", "ready", "achv"):
        if f'"{key}"' not in audio:
            fail(f"sound priority/type table missing {key}")

    # Transactional progress mutations: don't announce missions before durable save.
    for token in ("func _snapshot_state() -> Dictionary:", "func _restore_state(snapshot: Dictionary) -> void:",
                  "var snapshot := _snapshot_state()", "_restore_state(snapshot)",
                  "var _pending_mission_events: Array[Dictionary] = []",
                  'mission_completed.emit(String(mission_event.get("id", "")), int(mission_event.get("reward", 0)))',
                  '_pending_mission_events.append({"id": id, "reward": int(def.reward)})'):
        if token not in progress:
            fail(f"progress transaction / committed notification missing: {token}")
    mission_body = function_body(progress, "_run_mission")
    if "mission_completed.emit(" in mission_body:
        fail("mission completion is still emitted before persistence succeeds")
    run_end_body = function_body(progress, "on_run_end")
    if "if not _save():" not in run_end_body or "_restore_state(snapshot)" not in run_end_body:
        fail("run-end statistics and mission progress must roll back when saving fails")
    run_progress_body = function_body(progress, "on_run_progress")
    if "matching_ids.is_empty()" not in run_progress_body or "previous_missions: Dictionary = missions.duplicate(true)" not in run_progress_body:
        fail("per-action mission events must skip irrelevant snapshots and use a narrow transaction snapshot")

    world_source = (ROOT / "world/world.gd").read_text(encoding="utf-8")
    pbr_body = function_body(world_source, "_apply_pbr_detail")
    guarded_roughness_assignment = "if detailed.roughness_texture == null:\n                                                detailed.roughness_texture = ARMOR_ROUGHNESS"
    if guarded_roughness_assignment not in pbr_body:
        fail("shared micro-roughness must only fill an empty imported GLB roughness slot")
    if world_source.count("sun.shadow_enabled = true") != 1:
        fail("world sun shadow initialization should not repeat the same assignment")
    for token in (
        "env_res.background_mode = Environment.BG_SKY",
        "var cyber_sky := Sky.new()",
        "var cyber_sky_material := ProceduralSkyMaterial.new()",
        'cyber_sky_material.sky_horizon_color = Color("170D38")',
        'cyber_sky_material.ground_horizon_color = Color("073342")',
        "cyber_sky_material.use_debanding = true",
        "cyber_sky.radiance_size = Sky.RADIANCE_SIZE_128",
        "cyber_sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL",
    ):
        if token not in world_source:
            fail(f"native static cyber-sky contract missing: {token}")
    if "_env.background_color = backdrop_col.darkened(0.68)" in world_source:
        fail("chapter theme tick must not mutate the obsolete flat background behind BG_SKY")
    if "func _t_native_cyber_sky() -> void:" not in mechanics_test or "Environment.BG_SKY" not in mechanics_test or "Sky.PROCESS_MODE_INCREMENTAL" not in mechanics_test:
        fail("mechanics suite must inspect the active native cyber sky resource")

    # Cross-system performance coupling is routed through public APIs, not private node fields.
    if "Telemetry.configure_targets(world, effects)" not in main_source or "Telemetry._apply_grade()" in main_source:
        fail("Main must use Telemetry public target configuration, not its private grade method")
    if "func configure_targets(world_target: Node, effects_target: Node) -> void:" not in (ROOT / "core/telemetry.gd").read_text(encoding="utf-8"):
        fail("Telemetry public target configuration method is missing")
    effects_source = (ROOT / "fx/effects.gd").read_text(encoding="utf-8")
    if "func apply_perf_profile(grade: String) -> void:" not in effects_source:
        fail("Effects must expose a public performance profile API instead of private particle-node access")
    if "effects._rain" in (ROOT / "core/telemetry.gd").read_text(encoding="utf-8") or "effects._speed_lines" in (ROOT / "core/telemetry.gd").read_text(encoding="utf-8"):
        fail("Telemetry still mutates private Effects particle nodes")

    # Bounded queue reports overflow and preserves jump/slide over redundant steering.
    if "var _queue_overflow_count: int = 0" not in input_source or "func queue_overflow_count() -> int:" not in input_source:
        fail("input overflow counter is missing")
    enqueue_body = function_body(input_source, "_enqueue")
    if "lane_to_evict" not in enqueue_body or "_queue_overflow_count += 1" not in enqueue_body:
        fail("input queue overflow must be explicit and steering-first eviction")

    runtime = (ROOT / "core" / "config.gd").read_text(encoding="utf-8")
    telemetry = (ROOT / "core" / "telemetry.gd").read_text(encoding="utf-8")
    world_source = (ROOT / "world" / "world.gd").read_text(encoding="utf-8")
    for token in ('"targetFpsLow": 60', '"targetFpsMid": 90', '"targetFpsHigh": 120', '"targetFpsUnknownRefresh": 60', '"themeUpdateHz": 30.0'):
        if token not in runtime:
            fail(f"runtime budget setting missing: {token}")
    if "DisplayServer.screen_get_refresh_rate()" not in telemetry or "Engine.max_fps = _target_fps" not in telemetry or "Engine.max_fps = 0" in telemetry:
        fail("frame pacing must use a bounded refresh-aware target, not an unlimited loop")
    if "func apply_theme(dist: float, dt: float = 0.0, force: bool = false) -> void:" not in world_source or "_theme_update_accumulator" not in world_source:
        fail("theme material updates must use the configured cadence and force chapter transitions immediately")
    print(f"PASS {expected_version} release contracts: manifest/version identity, no constant-true assertions, deterministic laser weight pool, imported roughness preservation, typed DDA/replay, safe powerup placement, split audio buses, durable progress events, bounded FPS pacing and theme cadence")
    print("NOTE: Source contracts do not replace Godot semantic compilation or device tests.")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        raise SystemExit(1)
