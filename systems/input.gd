extends Node
## 统一输入层：触屏手势与键盘输入进入有界队列，并在固定物理步消费。
## 上滑/点按=跳，下滑=滑铲，左右滑=换道，R=重开，P/Esc=暂停，O=超频。
## 队列对重复车道脉冲进行合并；溢出计数可供诊断，重要动作优先保留。

signal input_lane(dir: int)
signal input_jump
signal input_slide
signal input_pause
signal input_retry
signal input_overclock

var enabled := false
var _active_touch_index: int = -1
var _touch_started_enabled: bool = false

const SWIPE_PX := 26.0     # 位移阈值（超过即判 swipe，方向取位移主轴）
const TAP_MS := 240        # tap 时长判定
const QUEUE_MAX := 16
const MAX_RUN_INPUT_EVENTS := 8000
const TRACE_SCHEMA := 2
const TRACE_RULESET_VERSION := 1
const VALID_DDA_MODES := ["", "gentle", "hardcore"]

# 动作队列（渲染帧入队 → 模拟帧消费）
# 类型：{"a": "lane"|"jump"|"slide", "d": 方向（lane 用）}
var _queue: Array[Dictionary] = []

# 系统键（暂停/重开/超频）不走队列——即时发（UI 响应不依赖模拟帧）
var _sx := 0.0
var _sy := 0.0
var _st := 0
var _moved := false

# Bounded diagnostic trace: exact simulation frame + accepted player action.
# This is a reproduction aid; full physics determinism still depends on the same build/device.
var _recording_active: bool = false
var _recording_seed: int = 0
var _recording_dda_enabled: bool = true
var _recording_dda_mode: String = ""
var _recording_replayable: bool = true
var _queue_overflow_count: int = 0
var _recording_ineligible_reasons: Array[String] = []
var _replay_session_active: bool = false
var _replay_total_frames: int = 0
var _sim_frame_index: int = 0
var _run_input_events: Array[Dictionary] = []
var _run_input_trace_truncated: bool = false
var _replay_mode: bool = false
var _replay_events: Array[Dictionary] = []
var _replay_cursor: int = 0
var _replay_seed: int = 0

func begin_run_recording(seed_value: int, dda_enabled: bool = true, dda_mode: String = "") -> void:
        _recording_active = true
        _recording_seed = seed_value
        _recording_dda_enabled = dda_enabled
        _recording_dda_mode = dda_mode if dda_enabled else ""
        _recording_replayable = true
        _recording_ineligible_reasons.clear()
        _sim_frame_index = 0
        _run_input_events.clear()
        _run_input_trace_truncated = false
        _replay_mode = false
        _replay_session_active = false
        _replay_total_frames = 0
        _replay_events.clear()
        _replay_cursor = 0

func finish_run_recording() -> Dictionary:
        if not _recording_active:
                return {}
        _recording_active = false
        return {
                "schema": TRACE_SCHEMA,
                "game_version": String(ProjectSettings.get_setting("application/config/version", "unknown")),
                "engine_version": String(Engine.get_version_info().get("string", "unknown")),
                "physics_hz": int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)),
                "ruleset_version": TRACE_RULESET_VERSION,
                "seed": _recording_seed,
                "dda_enabled": _recording_dda_enabled,
                "dda_mode": _recording_dda_mode,
                "frames": _sim_frame_index,
                "truncated": _run_input_trace_truncated,
                "replayable": _recording_replayable and not _run_input_trace_truncated,
                "ineligibleReasons": _recording_ineligible_reasons.duplicate(),
                "events": _run_input_events.duplicate(true),
        }

func is_recording() -> bool:
        return _recording_active

func mark_trace_ineligible(reason: String) -> void:
        if _recording_active and not reason.is_empty():
                _recording_replayable = false
                if reason not in _recording_ineligible_reasons:
                        _recording_ineligible_reasons.append(reason)

func is_replaying() -> bool:
        return _replay_session_active

func finish_replay_run() -> void:
        _replay_session_active = false
        _replay_mode = false
        _replay_events.clear()
        _replay_cursor = 0
        _replay_total_frames = 0
        enabled = false
        clear_queue()

func _record_action(action: String, direction: int = 0) -> void:
        if not _recording_active or _replay_mode:
                return
        if _run_input_events.size() >= MAX_RUN_INPUT_EVENTS:
                _run_input_trace_truncated = true
                return
        var event := {"frame": _sim_frame_index, "action": action}
        if action == "lane":
                event["direction"] = direction
        _run_input_events.append(event)

func set_enabled(on: bool) -> void:
        if enabled == on:
                return
        enabled = on
        # A gesture may start before a pause/menu transition and end after resume.
        # Never let that stale finger-up become a jump in the next state.
        clear_queue()

func _reset_touch() -> void:
        _active_touch_index = -1
        _touch_started_enabled = false
        _moved = false
        _st = 0
        _sx = 0.0
        _sy = 0.0

func _notification(what: int) -> void:
        # Android can pause/defocus the app without delivering a final touch-up.
        # Discard the in-flight gesture so resuming can never synthesize a jump.
        if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
                clear_queue()

func _unhandled_input(event: InputEvent) -> void:
        if event is InputEventScreenTouch:
                var t: InputEventScreenTouch = event
                if t.pressed:
                        # A single active finger defines one gesture. Ignore secondary
                        # fingers rather than letting them overwrite the first touch.
                        if _active_touch_index != -1:
                                return
                        _active_touch_index = t.index
                        _touch_started_enabled = enabled
                        _sx = t.position.x
                        _sy = t.position.y
                        _st = Time.get_ticks_msec()
                        _moved = false
                else:
                        if t.index != _active_touch_index:
                                return
                        if enabled and _touch_started_enabled and not _moved and Time.get_ticks_msec() - _st < TAP_MS:
                                _enqueue({"a": "jump"})
                        _reset_touch()
        elif event is InputEventScreenDrag:
                var d: InputEventScreenDrag = event
                if d.index != _active_touch_index or not enabled or not _touch_started_enabled or _moved:
                        return
                var dx: float = d.position.x - _sx
                var dy: float = d.position.y - _sy
                if abs(dx) > SWIPE_PX or abs(dy) > SWIPE_PX:
                        _moved = true
                        if abs(dx) > abs(dy):
                                _enqueue({"a": "lane", "d": 1 if dx > 0 else -1})
                        elif dy < 0:
                                _enqueue({"a": "jump"})
                        else:
                                _enqueue({"a": "slide"})
        elif event is InputEventKey:
                var k: InputEventKey = event
                if not k.pressed or k.echo:
                        return
                match k.keycode:
                        KEY_R:
                                input_retry.emit()
                        KEY_ESCAPE, KEY_P:
                                input_pause.emit()
                        KEY_O:
                                if enabled and not _replay_mode:
                                        input_overclock.emit()
                        KEY_LEFT, KEY_A:
                                if enabled:
                                        _enqueue({"a": "lane", "d": -1})
                        KEY_RIGHT, KEY_D:
                                if enabled:
                                        _enqueue({"a": "lane", "d": 1})
                        KEY_UP, KEY_W, KEY_SPACE:
                                if enabled:
                                        _enqueue({"a": "jump"})
                        KEY_DOWN, KEY_S:
                                if enabled:
                                        _enqueue({"a": "slide"})

func _enqueue(action: Dictionary) -> void:
        if _queue.size() >= QUEUE_MAX:
                _queue_overflow_count += 1
                # Lane nudges are less important than jump/slide timing. Evict the
                # oldest lane pulse first; never silently erase a critical action
                # just because repeated steering filled the bounded queue.
                var lane_to_evict := -1
                for i in _queue.size():
                        if String(_queue[i].get("a", "")) == "lane":
                                lane_to_evict = i
                                break
                if lane_to_evict >= 0:
                        _queue.remove_at(lane_to_evict)
                elif String(action.get("a", "")) == "lane":
                        return
                else:
                        # If every queued action is jump/slide, accept the newest
                        # critical action while retaining a hard queue bound.
                        _queue.remove_at(0)
        _queue.append(action)

func queue_overflow_count() -> int:
        return _queue_overflow_count

## 模拟帧消费（main._physics_process 头部调用）——
## 连续 lane 同向合并（一次 60Hz 帧内多次同向滑 = 一脉冲，防过冲）；
## jump/slide 保序（缓冲语义由 Player._jump_buf/_want_slide 承接）
func drain_inputs() -> void:
        if _recording_active or (_replay_mode and enabled):
                _sim_frame_index += 1
        if _replay_mode:
                _queue.clear()
                if not enabled:
                        return
                while _replay_cursor < _replay_events.size():
                        var event: Dictionary = _replay_events[_replay_cursor]
                        if int(event.get("frame", -1)) > _sim_frame_index:
                                break
                        _replay_cursor += 1
                        _emit_action(String(event.get("action", "")), int(event.get("direction", 0)), false)
                if _sim_frame_index >= _replay_total_frames:
                        _replay_mode = false
                        enabled = false
                        clear_queue()
                return
        if not enabled:
                _queue.clear()
                return
        if _queue.is_empty():
                return
        var previous_action: String = ""
        var previous_lane_dir: int = 0
        for ev: Dictionary in _queue:
                var action: String = String(ev.get("a", ""))
                match action:
                        "lane":
                                var dir: int = int(ev.get("d", 0))
                                if previous_action == "lane" and dir == previous_lane_dir:
                                        continue
                                _emit_action("lane", dir, true)
                                previous_action = "lane"
                                previous_lane_dir = dir
                        "jump":
                                _emit_action("jump", 0, true)
                                previous_action = "jump"
                        "slide":
                                _emit_action("slide", 0, true)
                                previous_action = "slide"
        _queue.clear()

func _emit_action(action: String, direction: int = 0, record: bool = true) -> void:
        if record:
                _record_action(action, direction)
        match action:
                "lane": input_lane.emit(direction)
                "jump": input_jump.emit()
                "slide": input_slide.emit()

func validate_replay_trace(trace: Dictionary) -> bool:
        var raw_events: Variant = trace.get("events", null)
        var raw_seed: Variant = trace.get("seed", null)
        var raw_frames: Variant = trace.get("frames", null)
        var raw_dda_enabled: Variant = trace.get("dda_enabled", null)
        var raw_dda_mode: Variant = trace.get("dda_mode", null)
        var raw_game_version: Variant = trace.get("game_version", null)
        var raw_engine_version: Variant = trace.get("engine_version", null)
        var raw_physics_hz: Variant = trace.get("physics_hz", null)
        var raw_ruleset: Variant = trace.get("ruleset_version", null)
        if typeof(trace.get("schema", null)) != TYPE_INT or int(trace.schema) != TRACE_SCHEMA:
                return false
        if typeof(raw_seed) != TYPE_INT or int(raw_seed) <= 0:
                return false
        if typeof(raw_frames) != TYPE_INT or int(raw_frames) < 1 or int(raw_frames) > 2000000:
                return false
        if typeof(raw_dda_enabled) != TYPE_BOOL or typeof(raw_dda_mode) != TYPE_STRING:
                return false
        if not (String(raw_dda_mode) in VALID_DDA_MODES):
                return false
        if not bool(raw_dda_enabled) and String(raw_dda_mode) != "":
                return false
        if typeof(raw_game_version) != TYPE_STRING or String(raw_game_version) != String(ProjectSettings.get_setting("application/config/version", "unknown")):
                return false
        if typeof(raw_engine_version) != TYPE_STRING or String(raw_engine_version) != String(Engine.get_version_info().get("string", "unknown")):
                return false
        if typeof(raw_physics_hz) != TYPE_INT or int(raw_physics_hz) != int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)):
                return false
        if typeof(raw_ruleset) != TYPE_INT or int(raw_ruleset) != TRACE_RULESET_VERSION:
                return false
        if bool(trace.get("truncated", false)) or not bool(trace.get("replayable", false)):
                return false
        if not (raw_events is Array) or raw_events.size() > MAX_RUN_INPUT_EVENTS:
                return false
        var last_frame := 0
        for raw_event in raw_events:
                if not (raw_event is Dictionary):
                        return false
                var frame_value: Variant = raw_event.get("frame", null)
                var action_value: Variant = raw_event.get("action", null)
                if typeof(frame_value) != TYPE_INT or int(frame_value) < 1 or int(frame_value) < last_frame or int(frame_value) > int(raw_frames):
                        return false
                if typeof(action_value) != TYPE_STRING or not (String(action_value) in ["lane", "jump", "slide"]):
                        return false
                if String(action_value) == "lane":
                        var dir_value: Variant = raw_event.get("direction", 0)
                        if typeof(dir_value) != TYPE_INT or not (int(dir_value) in [-1, 1]):
                                return false
                last_frame = int(frame_value)
        return true

func begin_replay(trace: Dictionary) -> bool:
        if not validate_replay_trace(trace):
                return false
        var checked: Array[Dictionary] = []
        for raw_event in trace.events:
                var event: Dictionary = {"frame": int(raw_event.frame), "action": String(raw_event.action)}
                if event.action == "lane":
                        event.direction = int(raw_event.direction)
                checked.append(event)
        _queue.clear()
        _reset_touch()
        _recording_active = false
        _replay_seed = int(trace.seed)
        _sim_frame_index = 0
        _replay_events = checked
        _replay_cursor = 0
        _replay_total_frames = int(trace.frames)
        _replay_mode = true
        _replay_session_active = true
        enabled = true
        return true

func replay_seed() -> int:
        return _replay_seed

func clear_queue() -> void:
        _queue.clear()   # 状态切换时丢弃残帧（死亡瞬间积压的滑铲不该在复活后触发）
        _reset_touch()
