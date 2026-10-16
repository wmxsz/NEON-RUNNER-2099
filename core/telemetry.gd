extends Node
## 设备遥测与性能预算：帧率、帧时间、绘制调用、三角形、视频内存和物理耗时。
## 采样通过 report_updated 通知 HUD；设备档位通过公开接口配置 World 与 Effects。

signal report_updated(report: Dictionary)

var enabled: bool = true           # 设置面板可关（showFps 联动）
var report: Dictionary = {}
var perf_grade: String = "high"    # 设备分级：high | mid | low
var _target_fps: int = 60
var world: Variant                  # 分级接线目标（main 注入）
var effects: Variant

var _acc: float = 0.0
var _frames: int = 0
var _fps_ema: float = 0.0
var _sample_slow_frames: int = 0
var _sample_frame_dts: Array[float] = []
var _quality_acc: float = 0.0
var _quality_frame_sum: float = 0.0
var _quality_frames: int = 0
var _quality_slow_frames: int = 0
var _quality_bad_windows: int = 0

func _ready() -> void:
        _detect_grade()

## Public wiring point for Main; keeps the performance controller from exposing
## its internal _apply_grade method to other systems.
func configure_targets(world_target: Node, effects_target: Node) -> void:
        world = world_target
        effects = effects_target
        _apply_grade()

func set_enabled(on: bool) -> void:
        if enabled == on:
                return
        enabled = on
        _acc = 0.0
        _frames = 0
        _fps_ema = 0.0
        _sample_slow_frames = 0
        _sample_frame_dts.clear()
        _quality_acc = 0.0
        _quality_frame_sum = 0.0
        _quality_frames = 0
        _quality_slow_frames = 0
        _quality_bad_windows = 0
        report = {}
        report_updated.emit({"sampling": on, "grade": perf_grade})

func _process(dt: float) -> void:
        _monitor_frame_budget(dt) # tiny timing accumulator stays active even when HUD is hidden
        if not enabled:
                return
        _frames += 1
        _acc += dt
        _sample_frame_dts.append(dt)
        if dt * 1000.0 >= _slow_frame_threshold_ms():
                _sample_slow_frames += 1
        if _acc < 0.5:
                return
        var fps: float = float(_frames) / maxf(_acc, 0.001)
        _fps_ema = fps if _fps_ema <= 0.0 else U.lerpf(_fps_ema, fps, 0.4)
        var sample_seconds := _acc
        var sample_frames := _frames
        _frames = 0
        _acc = 0.0
        var rs := RenderingServer
        var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
        var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
        var sorted_dts: Array[float] = _sample_frame_dts.duplicate()
        sorted_dts.sort()
        var p95_index: int = clampi(int(ceil(float(sorted_dts.size()) * 0.95)) - 1, 0, maxi(sorted_dts.size() - 1, 0))
        var p95_ms: float = sorted_dts[p95_index] * 1000.0 if not sorted_dts.is_empty() else 0.0
        var sample_slow_pct: float = float(_sample_slow_frames) / maxf(float(sample_frames), 1.0) * 100.0
        report = {
                "fps": int(round(_fps_ema)),
                "frameMs": sample_seconds * 1000.0 / maxf(float(sample_frames), 1.0),
                "frameP95Ms": p95_ms,
                "processMs": process_ms,
                "physicsMs": physics_ms,
                "slowFramePct": sample_slow_pct,
                "drawCalls": rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
                "primitives": rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
                "videoMem": rs.get_rendering_info(rs.RENDERING_INFO_VIDEO_MEM_USED),
                "textureMem": rs.get_rendering_info(rs.RENDERING_INFO_TEXTURE_MEM_USED),
                "objects": rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
                "grade": perf_grade,
                "targetFps": _target_fps,
                "renderBudget": world.get_render_budget_snapshot() if is_instance_valid(world) and world.has_method("get_render_budget_snapshot") else {},
        }
        report_updated.emit(report)
        _sample_slow_frames = 0
        _sample_frame_dts.clear()

func _monitor_frame_budget(dt: float) -> void:
        _quality_acc += dt
        _quality_frame_sum += dt
        _quality_frames += 1
        if dt * 1000.0 >= _slow_frame_threshold_ms():
                _quality_slow_frames += 1
        if _quality_acc < 2.0:
                return
        var average_frame_ms: float = _quality_frame_sum * 1000.0 / maxf(float(_quality_frames), 1.0)
        var slow_ratio: float = float(_quality_slow_frames) / maxf(float(_quality_frames), 1.0)
        var frame_budget_ms: float = 1000.0 / maxf(float(_target_fps), 30.0)
        var budget_multiplier: float = float(Config.RUNTIME.qualityBudgetMultiplier)
        if average_frame_ms > frame_budget_ms * budget_multiplier or slow_ratio > 0.12:
                _quality_bad_windows += 1
        else:
                _quality_bad_windows = maxi(0, _quality_bad_windows - 1)
        _quality_acc = 0.0
        _quality_frame_sum = 0.0
        _quality_frames = 0
        _quality_slow_frames = 0
        # Hysteresis: only step down after sustained slow frames, never oscillate
        # quality upward mid-run. A fresh app launch can recalibrate the hardware tier.
        if _quality_bad_windows >= 2:
                _quality_bad_windows = 0
                if perf_grade == "high":
                        perf_grade = "mid"
                        _apply_grade()
                        report_updated.emit({"qualityDownshift": true, "grade": perf_grade})
                elif perf_grade == "mid":
                        perf_grade = "low"
                        _apply_grade()
                        report_updated.emit({"qualityDownshift": true, "grade": perf_grade})

func _target_fps_for_grade(grade: String) -> int:
        var configured: int = int(Config.RUNTIME.targetFpsHigh)
        match grade:
                "low": configured = int(Config.RUNTIME.targetFpsLow)
                "mid": configured = int(Config.RUNTIME.targetFpsMid)
                "high": configured = int(Config.RUNTIME.targetFpsHigh)
                _: configured = int(Config.RUNTIME.targetFpsUnknownRefresh)
        var refresh_rate: float = DisplayServer.screen_get_refresh_rate()
        if not is_nan(refresh_rate) and not is_inf(refresh_rate) and refresh_rate >= 30.0:
                return maxi(30, mini(configured, int(roundf(refresh_rate))))
        # An unavailable refresh-rate query falls back to a battery-safe cap rather
        # than an unlimited render loop.
        return maxi(30, int(Config.RUNTIME.targetFpsUnknownRefresh))

func _slow_frame_threshold_ms() -> float:
        var frame_budget_ms: float = 1000.0 / maxf(float(_target_fps), 30.0)
        return frame_budget_ms * float(Config.RUNTIME.qualityBudgetMultiplier)

## 设备分级（首帧粗检：内存 + 屏幕尺寸 + CPU 核数）
func _detect_grade() -> void:
        var total_mem: int = OS.get_memory_info().physical
        var cores: int = OS.get_processor_count()
        if total_mem >= 7000000000 and cores >= 6:
                perf_grade = "high"
        elif total_mem >= 3500000000 and cores >= 4:
                perf_grade = "mid"
        else:
                perf_grade = "low"
        print("[telemetry] 设备分级 %s · %d核 · %.1fGB 内存" % [
                perf_grade, cores, total_mem / 1000000000.0])
        _apply_grade()

## 应用当前设备性能档位的帧率、阴影、粒子与 Glow 预算。
func _apply_grade() -> void:
        _target_fps = _target_fps_for_grade(perf_grade)
        Engine.max_fps = _target_fps
        # Preserve edge clarity across automatic performance downshifts. The game
        # keeps native 3D resolution and 4x MSAA; budgets adapt via glow, shadows,
        # and particles before any anti-aliasing or resolution reduction is considered.
        get_viewport().msaa_3d = Viewport.MSAA_4X
        match perf_grade:
                "low":
                        if is_instance_valid(effects):
                                effects.apply_perf_profile("low")
                        if world:
                                world.set_perf_glow(0.42)
                                world.set_perf_profile("low")
                "mid":
                        if is_instance_valid(effects):
                                effects.apply_perf_profile("mid")
                        if world:
                                world.set_perf_glow(0.52)
                                world.set_perf_profile("mid")
                "high":
                        if is_instance_valid(effects):
                                effects.apply_perf_profile("high")
                        if world:
                                world.set_perf_glow(float(Config.RUNTIME.bloomStrength))
                                world.set_perf_profile("high")

## HUD 单行文本
func hud_line() -> String:
        if report.is_empty():
                return "…"
        return "%d fps · %.1fms p95 %.1fms · %d dc · %dk tri · %s" % [
                report.fps, float(report.get("frameMs", 0.0)), float(report.get("frameP95Ms", 0.0)), report.drawCalls, report.primitives / 1000, perf_grade]
