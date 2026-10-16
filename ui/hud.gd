class_name HUD
extends CanvasLayer
## 游玩 HUD：距离、分数、芯片、连击、超频、道具、Toast 与性能信息。
## 触屏控制位于安全区域内；相同显示文本只在值改变时更新。

const POWERUP_UI_KEYS := ["magnet", "double", "board"]
const ICON_CHIP: Texture2D = preload("res://assets/ui/icons/chip.svg")
const ICON_PAUSE: Texture2D = preload("res://assets/ui/icons/pause.svg")
const ICON_OVERCLOCK: Texture2D = preload("res://assets/ui/icons/overclock.svg")
## HUD 负责跑局过程中的状态展示与触屏快捷操作。
## 顶部信息包括距离、分数、芯片、连击、超频槽、道具槽与提示消息。
## 触屏控制包含右上暂停按钮与充能满时显示的超频按钮。

signal pause_pressed
signal oc_pressed

var score_label: Label
var dist_label: Label
var chips_label: Label
var combo_label: Label
var oc_bar: ColorRect
var pu_icons: HBoxContainer
var toast_label: Label
var _toast_plate: Panel
var pause_btn: Button
var oc_btn: Button
var _dying_overlay: ColorRect   # 濒死故障色
var ui_root: Control
var perf_label: Label           # 遥测行（showFps 驱动）
var _last_perf_text: String = ""

var _toast_ms: float = 0.0
var _last_score_value: int = -1
var _last_distance_value: int = -1
var _last_chips_value: int = -1
var _last_combo_value: int = -1

func _ready() -> void:
        # UI is canvas/layout driven; do not interpolate its Control transforms.
        physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
        layer = 10
        _build()
        if not Telemetry.report_updated.is_connected(_on_telemetry_report_updated):
                Telemetry.report_updated.connect(_on_telemetry_report_updated)
        if not get_viewport().size_changed.is_connected(_apply_safe_area):
                get_viewport().size_changed.connect(_apply_safe_area)
        _apply_safe_area()

func _build() -> void:
        var root := Control.new()
        ui_root = root
        root.set_anchors_preset(Control.PRESET_FULL_RECT)
        root.mouse_filter = Control.MOUSE_FILTER_IGNORE
        add_child(root)

        # Subtle translucent glass plate keeps score text readable over bright city signs.
        var top_plate := PanelContainer.new()
        top_plate.name = "HUDGlassPlate"
        top_plate.set_anchors_preset(Control.PRESET_TOP_WIDE)
        top_plate.offset_left = 9
        top_plate.offset_right = -58
        top_plate.offset_top = 7
        top_plate.offset_bottom = 59
        top_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var plate_style := StyleBoxFlat.new()
        plate_style.bg_color = Color(0.012, 0.022, 0.052, 0.78)
        plate_style.border_color = Color(0.0, 0.82, 1.0, 0.45)
        plate_style.set_border_width_all(1)
        plate_style.set_corner_radius_all(9)
        plate_style.content_margin_left = 12.0
        plate_style.content_margin_right = 8.0
        plate_style.content_margin_top = 4.0
        plate_style.content_margin_bottom = 4.0
        top_plate.add_theme_stylebox_override("panel", plate_style)
        root.add_child(top_plate)

        var top := HBoxContainer.new()
        top.set_anchors_preset(Control.PRESET_TOP_WIDE)
        top.offset_left = 20
        top.offset_right = -66
        top.offset_top = 12
        top.offset_bottom = 50
        top.add_theme_constant_override("separation", 15)
        root.add_child(top)

        score_label = _mk_label(top, "", 30, Color(0.988, 0.933, 0.039))
        dist_label = _mk_label(top, "0m", 20, Color(0.9, 0.9, 0.95))
        # Vector icon + numeric value avoids platform-dependent Unicode glyph metrics.
        var chips_group := HBoxContainer.new()
        chips_group.name = "CyberChipCounter"
        chips_group.add_theme_constant_override("separation", 5)
        chips_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        top.add_child(chips_group)
        chips_label = _mk_label(chips_group, "0", 20, Color(0, 0.941, 1))
        _add_vector_icon(chips_group, ICON_CHIP, Vector2(19, 19), Color(0.0, 0.941, 1.0), true)
        chips_group.move_child(chips_group.get_child(1), 0)
        combo_label = _mk_label(top, "", 24, Color(1, 0, 0.239))
        combo_label.visible = false

        # 触屏暂停按钮（右上，48×48 最小命中区域）
        pause_btn = Button.new()
        pause_btn.text = ""
        pause_btn.name = "CyberPauseButton"
        pause_btn.tooltip_text = "暂停游戏"
        pause_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
        pause_btn.offset_left = -60
        pause_btn.offset_right = -12
        pause_btn.offset_top = 8
        pause_btn.offset_bottom = 56
        pause_btn.add_theme_font_size_override("font_size", 20)
        pause_btn.add_theme_color_override("font_color", Color(0.95, 0.95, 1))
        pause_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
        pause_btn.add_theme_constant_override("outline_size", 4)
        pause_btn.flat = false
        pause_btn.focus_mode = Control.FOCUS_NONE
        _apply_icon_button_style(pause_btn, Color(0.0, 0.86, 1.0))
        _add_vector_icon(pause_btn, ICON_PAUSE, Vector2(25, 25), Color(0.0, 0.94, 1.0), false)
        pause_btn.pressed.connect(func(): pause_pressed.emit())
        root.add_child(pause_btn)

        # 超频充能条（右上）
        var oc_wrap := VBoxContainer.new()
        oc_wrap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
        oc_wrap.offset_left = -116
        oc_wrap.offset_right = -16
        oc_wrap.offset_top = 60
        root.add_child(oc_wrap)
        var oc_tag := _mk_label(oc_wrap, "超频 OVERCLOCK", 11, Color(1, 0, 0.239))
        oc_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        var bar_bg := Panel.new()
        bar_bg.custom_minimum_size = Vector2(100, 10)
        var bar_style := StyleBoxFlat.new()
        bar_style.bg_color = Color(0.035, 0.045, 0.09, 0.92)
        bar_style.border_color = Color(0.0, 0.78, 1.0, 0.55)
        bar_style.set_border_width_all(1)
        bar_style.set_corner_radius_all(4)
        bar_bg.add_theme_stylebox_override("panel", bar_style)
        oc_wrap.add_child(bar_bg)
        oc_bar = ColorRect.new()
        oc_bar.color = Color(0.988, 0.933, 0.039, 0.9)
        oc_bar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
        oc_bar.offset_right = 0
        bar_bg.add_child(oc_bar)

        # 触屏超频按钮（右下，充能满时才可见）
        oc_btn = Button.new()
        oc_btn.text = ""
        oc_btn.name = "CyberOverclockButton"
        oc_btn.tooltip_text = "触发超频"
        oc_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
        oc_btn.offset_left = -96
        oc_btn.offset_right = -20
        oc_btn.offset_top = -116
        oc_btn.offset_bottom = -40
        oc_btn.add_theme_font_size_override("font_size", 34)
        oc_btn.add_theme_color_override("font_color", Color(0.988, 0.933, 0.039))
        oc_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
        oc_btn.add_theme_constant_override("outline_size", 8)
        oc_btn.flat = false
        oc_btn.focus_mode = Control.FOCUS_NONE
        _apply_icon_button_style(oc_btn, Color(1.0, 0.78, 0.16))
        _add_vector_icon(oc_btn, ICON_OVERCLOCK, Vector2(49, 49), Color(1.0, 0.82, 0.20), false)
        oc_btn.visible = false
        oc_btn.pressed.connect(func(): oc_pressed.emit())
        root.add_child(oc_btn)

        pu_icons = HBoxContainer.new()
        pu_icons.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
        pu_icons.offset_left = 16
        pu_icons.offset_top = -60
        pu_icons.offset_bottom = -20
        pu_icons.add_theme_constant_override("separation", 8)
        root.add_child(pu_icons)

        # A plain Panel behind the fixed label improves contrast without taking over its layout.
        _toast_plate = Panel.new()
        _toast_plate.name = "ToastGlassPlate"
        _toast_plate.set_anchors_preset(Control.PRESET_CENTER_TOP)
        _toast_plate.offset_top = 110
        _toast_plate.offset_bottom = 158
        _toast_plate.offset_left = -174
        _toast_plate.offset_right = 174
        _toast_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var toast_style := StyleBoxFlat.new()
        toast_style.bg_color = Color(0.012, 0.022, 0.052, 0.88)
        toast_style.border_color = Color(0.0, 0.82, 1.0, 0.65)
        toast_style.set_border_width_all(1)
        toast_style.set_corner_radius_all(9)
        toast_style.content_margin_left = 8.0
        toast_style.content_margin_right = 8.0
        _toast_plate.add_theme_stylebox_override("panel", toast_style)
        _toast_plate.visible = false
        root.add_child(_toast_plate)

        toast_label = _mk_label(root, "", 18, Color(0.9, 0.95, 1))
        toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
        toast_label.offset_top = 150   # 下移避开远景 BOSS 观察区（VLM 构图反馈）
        toast_label.offset_left = -160
        toast_label.offset_right = 160
        toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        toast_label.visible = false

        # 濒死故障色：红色脉冲覆盖层（dying 态驱动）
        _dying_overlay = ColorRect.new()
        _dying_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
        _dying_overlay.color = Color(1, 0.05, 0.1, 0.0)
        _dying_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _dying_overlay.visible = false
        root.add_child(_dying_overlay)

func set_dying(on: bool) -> void:
        _dying_overlay.visible = on

func _add_vector_icon(parent: Control, texture: Texture2D, icon_size: Vector2, tint: Color, layout_managed: bool) -> TextureRect:
        var icon := TextureRect.new()
        icon.texture = texture
        icon.custom_minimum_size = icon_size
        icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
        icon.modulate = tint
        icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
        if not layout_managed:
                icon.set_anchors_preset(Control.PRESET_FULL_RECT)
                icon.offset_left = 5
                icon.offset_top = 5
                icon.offset_right = -5
                icon.offset_bottom = -5
        parent.add_child(icon)
        return icon

func _apply_icon_button_style(button: Button, accent: Color) -> void:
        var normal := StyleBoxFlat.new()
        normal.bg_color = Color(0.012, 0.027, 0.065, 0.92)
        normal.border_color = Color(accent.r, accent.g, accent.b, 0.82)
        normal.set_border_width_all(1)
        normal.set_corner_radius_all(11)
        normal.content_margin_left = 3.0
        normal.content_margin_right = 3.0
        normal.content_margin_top = 3.0
        normal.content_margin_bottom = 3.0
        button.add_theme_stylebox_override("normal", normal)
        var hover := normal.duplicate() as StyleBoxFlat
        hover.bg_color = Color(accent.r * 0.12, accent.g * 0.12, accent.b * 0.12, 0.98)
        hover.border_color = accent.lightened(0.18)
        hover.set_border_width_all(2)
        button.add_theme_stylebox_override("hover", hover)
        var pressed := normal.duplicate() as StyleBoxFlat
        pressed.bg_color = Color(accent.r * 0.18, accent.g * 0.18, accent.b * 0.18, 1.0)
        pressed.border_color = Color(1.0, 1.0, 1.0, 0.95)
        pressed.set_border_width_all(2)
        button.add_theme_stylebox_override("pressed", pressed)
        button.add_theme_stylebox_override("focus", hover)

func _mk_label(parent: Control, txt: String, size: int, col: Color) -> Label:
        var l := Label.new()
        l.text = txt
        l.add_theme_font_size_override("font_size", size)
        l.add_theme_color_override("font_color", col)
        l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
        l.add_theme_constant_override("outline_size", 6)
        parent.add_child(l)
        return l

func _process(dt: float) -> void:
        if _toast_ms > 0.0:
                _toast_ms -= dt * 1000.0
                if _toast_ms <= 0.0:
                        toast_label.visible = false
                        if is_instance_valid(_toast_plate):
                                _toast_plate.visible = false
        # Performance text is event-driven by Telemetry's 0.5s sampling signal,
        # not formatted and reassigned on every rendered frame.
        # 濒死状态使用 8Hz 红色脉冲作为危险提示。
        if _dying_overlay.visible:
                _dying_overlay.color.a = 0.10 + 0.10 * (1.0 + sin(Time.get_ticks_msec() * 0.05))

func _apply_safe_area() -> void:
        if not is_instance_valid(ui_root):
                return
        # Android reports safe insets in display pixel coordinates. Map them into
        # the fixed logical viewport; desktop testing keeps the full viewport.
        ui_root.offset_left = 0.0
        ui_root.offset_top = 0.0
        ui_root.offset_right = 0.0
        ui_root.offset_bottom = 0.0
        if OS.get_name() != "Android":
                return
        var screen_size: Vector2i = DisplayServer.screen_get_size()
        var safe: Rect2i = DisplayServer.get_display_safe_area()
        var viewport_size: Vector2 = get_viewport().get_visible_rect().size
        if screen_size.x <= 0 or screen_size.y <= 0 or safe.size.x <= 0 or safe.size.y <= 0:
                return
        var left_inset := float(safe.position.x) / float(screen_size.x) * viewport_size.x
        var top_inset := float(safe.position.y) / float(screen_size.y) * viewport_size.y
        var right_inset := float(screen_size.x - safe.end.x) / float(screen_size.x) * viewport_size.x
        var bottom_inset := float(screen_size.y - safe.end.y) / float(screen_size.y) * viewport_size.y
        ui_root.offset_left = clampf(left_inset, 0.0, viewport_size.x * 0.15)
        ui_root.offset_top = clampf(top_inset, 0.0, viewport_size.y * 0.12)
        ui_root.offset_right = -clampf(right_inset, 0.0, viewport_size.x * 0.15)
        ui_root.offset_bottom = -clampf(bottom_inset, 0.0, viewport_size.y * 0.12)

func set_perf_visible(on: bool) -> void:
        if perf_label == null:
                var root: Control = get_child(0)
                perf_label = _mk_label(root, "", 13, Color(0.5, 0.9, 0.6))
                perf_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
                perf_label.offset_left = 12
                perf_label.offset_top = -34
                perf_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
        perf_label.visible = on
        if on:
                _update_perf_label()
        else:
                _last_perf_text = ""

func _on_telemetry_report_updated(_report: Dictionary) -> void:
        if is_instance_valid(perf_label) and perf_label.visible:
                _update_perf_label()

func _update_perf_label() -> void:
        if not is_instance_valid(perf_label):
                return
        var next_text := "性能采样中…" if not Telemetry.report.has("fps") else Telemetry.hud_line()
        if next_text != _last_perf_text:
                perf_label.text = next_text
                _last_perf_text = next_text

func update_run(score: float, dist: float, chips: int, combo: int) -> void:
        # Most HUD values change less often than the 60Hz simulation. Avoid rebuilding
        # identical text strings and reapplying unchanged Label properties each tick.
        var score_value: int = int(score)
        var distance_value: int = int(dist)
        if score_value != _last_score_value:
                score_label.text = "%d" % score_value
                _last_score_value = score_value
        if distance_value != _last_distance_value:
                dist_label.text = "%dm" % distance_value
                _last_distance_value = distance_value
        if chips != _last_chips_value:
                chips_label.text = "%d" % chips
                _last_chips_value = chips
        if combo != _last_combo_value:
                combo_label.visible = combo >= 3
                if combo >= 3:
                        combo_label.text = "×%d 连击" % combo
                _last_combo_value = combo

func update_oc(charge: float, needed: int, active: bool) -> void:
        var k: float = U.clampf(charge / needed, 0.0, 1.0)
        oc_bar.offset_right = 100.0 * k
        oc_bar.color = Color(1, 0, 0.239) if active else (Color(0.988, 0.933, 0.039) if k >= 1.0 else Color(0, 0.941, 1))
        # 触屏超频按钮：充能满且未激活时出现
        oc_btn.visible = k >= 1.0 and not active
        if oc_btn.visible:
                oc_btn.modulate.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.008)

func toast(msg: String, ms: int = 2400) -> void:
        toast_label.text = msg
        toast_label.visible = true
        if is_instance_valid(_toast_plate):
                _toast_plate.visible = true
        _toast_ms = ms

## Reset transient HUD state at the same lifecycle boundary as the player/world.
## This prevents last-run death/achievement toasts and item indicators leaking in.
func reset_run_ui() -> void:
        _toast_ms = 0.0
        toast_label.text = ""
        toast_label.visible = false
        _toast_plate.visible = false
        _dying_overlay.visible = false
        _dying_overlay.color.a = 0.0
        update_run(0.0, 0.0, 0, 0)
        update_oc(0.0, Config.OVERCLOCK.chipsNeeded, false)
        # Keep power-up controls alive across runs; reset by hiding and invalidating
        # displayed seconds, not by freeing/recreating Control nodes.
        for label: Label in _powerup_labels.values():
                label.visible = false
        _powerup_seconds.clear()
        update_powerups({})

var _powerup_labels: Dictionary = {}
var _powerup_seconds: Dictionary = {}

func update_powerups(active: Dictionary) -> void:
        # Reuse one Label per timed power-up. Only update the text when its displayed
        # second changes, and toggle visibility as effects start/end.
        for kind in POWERUP_UI_KEYS:
                var duration: float = float(active.get(kind, 0.0))
                var label: Label = _powerup_labels.get(kind) as Label
                if duration > 0.0:
                        if not is_instance_valid(label):
                                label = Label.new()
                                label.add_theme_font_size_override("font_size", 15)
                                label.add_theme_color_override("font_color", Config.POWERUPS[kind].color)
                                label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
                                label.add_theme_constant_override("outline_size", 5)
                                pu_icons.add_child(label)
                                _powerup_labels[kind] = label
                                _powerup_seconds.erase(kind)
                        if not label.visible:
                                label.visible = true
                        var seconds := int(duration)
                        if int(_powerup_seconds.get(kind, -1)) != seconds:
                                label.text = "%s %ds" % [Config.POWERUPS[kind].name, seconds]
                                _powerup_seconds[kind] = seconds
                else:
                        if is_instance_valid(label) and label.visible:
                                label.visible = false
                        if _powerup_seconds.has(kind):
                                _powerup_seconds.erase(kind)



func set_gameplay_visible(on: bool) -> void:
        if is_instance_valid(ui_root):
                ui_root.visible = on
