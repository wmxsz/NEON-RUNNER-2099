class_name Menus
extends CanvasLayer
## 菜单与交互面板：主菜单、暂停、结算、复活、设置、商店、任务与成就。
## 设置预览与持久化提交使用不同信号；购买/领奖结果由 Progress 的保存结果确认。

signal start_pressed
signal retry_pressed
signal home_pressed
signal resume_pressed
signal revive_accept
signal revive_decline
signal settings_changed(key: String, value: Variant) # 持久化提交
signal settings_previewed(key: String, value: Variant) # 即时预览，不写盘
signal skin_action(id: int, action: String)     # action: "buy" | "equip"
signal mission_claim(id: String)

const ICON_CHIP: Texture2D = preload("res://assets/ui/icons/chip.svg")
const ICON_PLAY: Texture2D = preload("res://assets/ui/icons/play.svg")
const ICON_SHOP: Texture2D = preload("res://assets/ui/icons/shop.svg")
const ICON_MISSION: Texture2D = preload("res://assets/ui/icons/mission.svg")
const ICON_ACHIEVEMENT: Texture2D = preload("res://assets/ui/icons/achievement.svg")
const ICON_SETTINGS: Texture2D = preload("res://assets/ui/icons/settings.svg")
const ICON_OVERCLOCK: Texture2D = preload("res://assets/ui/icons/overclock.svg")
const ICON_HOME: Texture2D = preload("res://assets/ui/icons/home.svg")
const ICON_SLIDER_GRABBER: Texture2D = preload("res://assets/ui/icons/slider_grabber.svg")
const ICON_TOGGLE_ON: Texture2D = preload("res://assets/ui/icons/toggle_on.svg")
const ICON_TOGGLE_OFF: Texture2D = preload("res://assets/ui/icons/toggle_off.svg")

var menu_root: Control
var gameover_root: Control
var pause_root: Control
var revive_root: Control
var settings_root: Control
var shop_root: Control
var missions_root: Control
var achv_root: Control

var go_title: Label
var go_stats: Label
var go_dda: Label
var revive_countdown: Label
var menu_best: Label
var menu_wallet: Label

var _safe_layout_shift: Vector2 = Vector2.ZERO

func _ready() -> void:
        # UI is canvas/layout driven; do not interpolate its Control transforms.
        physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
        layer = 20
        _build_menu()
        _build_gameover()
        _build_pause()
        _build_revive()
        _build_secondary()
        if not get_viewport().size_changed.is_connected(_apply_safe_area):
                get_viewport().size_changed.connect(_apply_safe_area)
        show_menu()
        call_deferred("_apply_safe_area")

# ---------- 构建基件 ----------

func _mk_panel(parent: Control) -> PanelContainer:
        var p := PanelContainer.new()
        p.set_anchors_preset(Control.PRESET_CENTER)
        var viewport_size: Vector2 = get_viewport().get_visible_rect().size
        p.custom_minimum_size = Vector2(minf(340.0, maxf(220.0, viewport_size.x - 24.0)), 0.0)
        parent.add_child(p)
        var sb := StyleBoxFlat.new()
        sb.bg_color = Color(0.055, 0.043, 0.1, 0.96)
        sb.border_color = Color(0, 0.941, 1, 0.55)
        sb.set_border_width_all(2)
        sb.set_corner_radius_all(14)
        sb.set_content_margin_all(14 if p.custom_minimum_size.x < 310.0 else 22)
        p.add_theme_stylebox_override("panel", sb)
        return p

func _mk_btn(parent: Control, txt: String, col: Color, cb: Callable, icon_texture: Texture2D = null) -> Button:
        var b := Button.new()
        b.text = txt if icon_texture == null else ""
        b.tooltip_text = txt if icon_texture != null else ""
        b.custom_minimum_size = Vector2(0, 48)
        b.focus_mode = Control.FOCUS_ALL
        b.add_theme_font_size_override("font_size", 18)
        b.add_theme_color_override("font_color", Color(1, 1, 1))
        b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
        b.add_theme_color_override("font_focus_color", Color(1, 1, 1))
        b.add_theme_color_override("font_pressed_color", col.lightened(0.35))
        b.add_theme_color_override("font_disabled_color", Color(0.52, 0.55, 0.64))

        var normal := StyleBoxFlat.new()
        normal.bg_color = col.darkened(0.62)
        normal.border_color = col.darkened(0.12)
        normal.set_border_width_all(1)
        normal.set_corner_radius_all(10)
        normal.set_content_margin_all(10)
        normal.content_margin_top = 12
        normal.content_margin_bottom = 12
        b.add_theme_stylebox_override("normal", normal)

        var hover := normal.duplicate() as StyleBoxFlat
        hover.bg_color = col.darkened(0.42)
        hover.border_color = col.lightened(0.18)
        hover.set_border_width_all(2)
        b.add_theme_stylebox_override("hover", hover)

        var pressed := normal.duplicate() as StyleBoxFlat
        pressed.bg_color = col.darkened(0.30)
        pressed.border_color = col.lightened(0.28)
        pressed.set_border_width_all(2)
        pressed.content_margin_top = 14
        pressed.content_margin_bottom = 10
        b.add_theme_stylebox_override("pressed", pressed)

        var focus := normal.duplicate() as StyleBoxFlat
        focus.border_color = Color(0.28, 0.93, 1.0, 1.0)
        focus.set_border_width_all(2)
        b.add_theme_stylebox_override("focus", focus)

        var disabled := normal.duplicate() as StyleBoxFlat
        disabled.bg_color = Color(0.075, 0.085, 0.12, 0.9)
        disabled.border_color = Color(0.22, 0.25, 0.32, 0.75)
        disabled.set_border_width_all(1)
        b.add_theme_stylebox_override("disabled", disabled)
        b.pressed.connect(cb)
        parent.add_child(b)
        if icon_texture != null:
                var content := HBoxContainer.new()
                content.name = "CyberButtonContent"
                content.set_anchors_preset(Control.PRESET_FULL_RECT)
                content.offset_left = 12.0
                content.offset_right = -12.0
                content.offset_top = 0.0
                content.offset_bottom = 0.0
                content.alignment = BoxContainer.ALIGNMENT_CENTER
                content.add_theme_constant_override("separation", 9)
                content.mouse_filter = Control.MOUSE_FILTER_IGNORE
                var icon := TextureRect.new()
                icon.texture = icon_texture
                icon.custom_minimum_size = Vector2(20, 20)
                icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
                icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
                icon.modulate = col.lightened(0.35)
                icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(icon)
                var caption := Label.new()
                caption.text = txt
                caption.add_theme_font_size_override("font_size", 17)
                caption.add_theme_color_override("font_color", Color(1, 1, 1))
                caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
                caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(caption)
                b.add_child(content)
        return b

func _mk_label(parent: Control, txt: String, size: int, col: Color) -> Label:
        var l := Label.new()
        l.text = txt
        l.add_theme_font_size_override("font_size", size)
        l.add_theme_color_override("font_color", col)
        l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        parent.add_child(l)
        return l

func _dim_root(name_txt: String) -> Control:
        var r := Control.new()
        r.name = name_txt
        r.set_anchors_preset(Control.PRESET_FULL_RECT)
        # The modal root consumes outside taps after the dim layer passes them upward.
        r.mouse_filter = Control.MOUSE_FILTER_STOP
        r.visible = false
        add_child(r)
        var dim := ColorRect.new()
        dim.name = "ModalDimmer"
        dim.color = Color(0, 0, 0, 0.82)
        dim.set_anchors_preset(Control.PRESET_FULL_RECT)
        # PASS is essential: STOP here prevents the root's outside-tap close handler firing.
        dim.mouse_filter = Control.MOUSE_FILTER_PASS
        r.add_child(dim)
        return r

# ---------- 各面板构建 ----------

func _build_menu() -> void:
        menu_root = _dim_root("menu")
        var box := VBoxContainer.new()
        box.set_anchors_preset(Control.PRESET_CENTER)
        var menu_width: float = minf(340.0, maxf(220.0, get_viewport().get_visible_rect().size.x - 24.0))
        box.offset_left = -menu_width * 0.5
        box.offset_right = menu_width * 0.5
        box.add_theme_constant_override("separation", 14)
        menu_root.add_child(box)
        _mk_label(box, "NEON RUNNER", 40, Color(0.988, 0.933, 0.039))
        _mk_label(box, "2099", 30, Color(0, 0.941, 1))
        box.add_child(HSeparator.new())
        menu_best = _mk_label(box, "最远狂奔 0m", 17, Color(0.75, 0.78, 0.9))
        menu_wallet = _mk_label(box, "芯片资金 · 0", 17, Color(0, 0.941, 1))
        _mk_btn(box, "开始狂奔", Color(0.988, 0.933, 0.039), func(): start_pressed.emit(), ICON_PLAY)
        _mk_btn(box, "义体商店", Color(1, 0, 0.239), func(): show_shop_requested.emit(), ICON_SHOP)
        _mk_btn(box, "任务 / 成就", Color(0.545, 0.55, 0.62), func(): _toggle_missions_achv(), ICON_MISSION)
        _mk_btn(box, "系统设置", Color(0, 0.941, 1), func(): show_settings_requested.emit(), ICON_SETTINGS)
        _mk_label(box, "上滑跳跃 · 下滑滑铲 · 左右换道\n收集 12 芯片，启动超频协议", 13, Color(0.6, 0.63, 0.75))

signal show_shop_requested
signal show_missions_requested
signal show_achv_requested
signal show_settings_requested

func _toggle_missions_achv() -> void:
        if missions_root.visible or achv_root.visible:
                missions_root.visible = false
                achv_root.visible = false
        else:
                show_missions_requested.emit()

func _build_gameover() -> void:
        gameover_root = _dim_root("gameover")
        var box := VBoxContainer.new()
        box.set_anchors_preset(Control.PRESET_CENTER)
        var dialog_width: float = minf(340.0, maxf(220.0, get_viewport().get_visible_rect().size.x - 24.0))
        box.offset_left = -dialog_width * 0.5
        box.offset_right = dialog_width * 0.5
        box.add_theme_constant_override("separation", 12)
        gameover_root.add_child(box)
        go_title = _mk_label(box, "信号丢失", 34, Color(1, 0, 0.239))
        _mk_label(box, "连接中断 // 神经链路离线", 15, Color(0.6, 0.63, 0.75))
        box.add_child(HSeparator.new())
        go_stats = _mk_label(box, "", 18, Color(0.95, 0.95, 1))
        go_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        go_dda = _mk_label(box, "", 13, Color(0, 0.941, 1))
        go_dda.visible = false
        _mk_btn(box, "再来一局 (R)", Color(0.988, 0.933, 0.039), func(): retry_pressed.emit(), ICON_PLAY)
        _mk_btn(box, "回主菜单", Color(0, 0.941, 1), func(): home_pressed.emit(), ICON_HOME)

func _build_pause() -> void:
        pause_root = _dim_root("pause")
        var box := VBoxContainer.new()
        box.set_anchors_preset(Control.PRESET_CENTER)
        var dialog_width: float = minf(300.0, maxf(220.0, get_viewport().get_visible_rect().size.x - 24.0))
        box.offset_left = -dialog_width * 0.5
        box.offset_right = dialog_width * 0.5
        box.add_theme_constant_override("separation", 12)
        pause_root.add_child(box)
        _mk_label(box, "暂停", 30, Color(0.988, 0.933, 0.039))
        _mk_btn(box, "继续 (P)", Color(0, 0.941, 1), func(): resume_pressed.emit(), ICON_PLAY)
        _mk_btn(box, "系统设置", Color(0, 0.941, 1), func(): show_settings_requested.emit(), ICON_SETTINGS)
        _mk_btn(box, "回主菜单", Color(1, 0, 0.239), func(): home_pressed.emit(), ICON_HOME)

func _build_revive() -> void:
        revive_root = _dim_root("revive")
        var box := VBoxContainer.new()
        box.set_anchors_preset(Control.PRESET_CENTER)
        var dialog_width: float = minf(340.0, maxf(220.0, get_viewport().get_visible_rect().size.x - 24.0))
        box.offset_left = -dialog_width * 0.5
        box.offset_right = dialog_width * 0.5
        box.add_theme_constant_override("separation", 12)
        revive_root.add_child(box)
        _mk_label(box, "系统崩溃", 30, Color(1, 0, 0.239))
        revive_countdown = _mk_label(box, "5", 56, Color(0.988, 0.933, 0.039))
        _mk_btn(box, "神经重启（复活）", Color(0.988, 0.933, 0.039), func(): revive_accept.emit(), ICON_OVERCLOCK)
        _mk_btn(box, "放弃连接", Color(0.6, 0.63, 0.75), func(): revive_decline.emit())

# ---------- 二级面板：设置、商店、任务与成就 ----------

func _build_secondary() -> void:
        settings_root = _dim_root("settings")
        shop_root = _dim_root("shop")
        missions_root = _dim_root("missions")
        achv_root = _dim_root("achv")
        for r in [settings_root, shop_root, missions_root, achv_root]:
                r.gui_input.connect(_on_panel_input.bind(r))

func _apply_safe_area() -> void:
        var viewport_size: Vector2 = get_viewport().get_visible_rect().size
        var target_shift := Vector2.ZERO
        if OS.get_name() == "Android":
                var screen_size: Vector2i = DisplayServer.screen_get_size()
                var safe: Rect2i = DisplayServer.get_display_safe_area()
                if screen_size.x > 0 and screen_size.y > 0 and safe.size.x > 0 and safe.size.y > 0:
                        var left := float(safe.position.x) / float(screen_size.x) * viewport_size.x
                        var top := float(safe.position.y) / float(screen_size.y) * viewport_size.y
                        var right := float(screen_size.x - safe.end.x) / float(screen_size.x) * viewport_size.x
                        var bottom := float(screen_size.y - safe.end.y) / float(screen_size.y) * viewport_size.y
                        target_shift = Vector2((left - right) * 0.5, (top - bottom) * 0.5)
        target_shift.x = clampf(target_shift.x, -viewport_size.x * 0.08, viewport_size.x * 0.08)
        target_shift.y = clampf(target_shift.y, -viewport_size.y * 0.08, viewport_size.y * 0.08)
        var delta := target_shift - _safe_layout_shift
        if delta.length_squared() > 0.001:
                for root in [menu_root, gameover_root, pause_root, revive_root, settings_root, shop_root, missions_root, achv_root]:
                        if not is_instance_valid(root):
                                continue
                        for child in root.get_children():
                                if child is Control and not (child is ColorRect):
                                        (child as Control).position += delta
        _safe_layout_shift = target_shift

func _on_panel_input(event: InputEvent, r: Control) -> void:
        # Android emits InputEventScreenTouch; desktop emits InputEventMouseButton.
        # Handle both so tapping the dimmed area closes secondary panels on real touchscreens.
        var is_primary_press := false
        var local_position := Vector2.ZERO
        if event is InputEventMouseButton:
                var mouse_event := event as InputEventMouseButton
                is_primary_press = mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT
                local_position = mouse_event.position
        elif event is InputEventScreenTouch:
                var touch_event := event as InputEventScreenTouch
                is_primary_press = touch_event.pressed
                local_position = touch_event.position
        if not is_primary_press:
                return
        var panel: Control = r.get_child(1) as Control if r.get_child_count() > 1 else null
        var click_global: Vector2 = r.get_global_transform() * local_position
        if panel == null or not panel.get_global_rect().has_point(click_global):
                r.visible = false   # 点/触碰面板外关闭

## UI 过场（引擎红利 D 包）：面板淡入+上滑入 / 大屏淡入——短促（0.15-0.22s）不拖操作
func _fade_in(c: Control, slide := true) -> void:
        c.modulate.a = 0.0
        if slide:
                c.position.y += 18.0
        var tw := c.create_tween()
        tw.set_parallel(true)
        tw.tween_property(c, "modulate:a", 1.0, 0.15)
        if slide:
                tw.tween_property(c, "position:y", c.position.y - 18.0, 0.22).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)

func _panel_content(root: Control, title: String) -> VBoxContainer:
        for other in [settings_root, shop_root, missions_root, achv_root]:
                if other != root:
                        other.visible = false
        root.visible = true
        for c in root.get_children():
                if c is PanelContainer:
                        root.remove_child(c)
                        c.queue_free()
        var p := _mk_panel(root)
        p.position += _safe_layout_shift
        _fade_in(p)   # 面板过场
        var box := VBoxContainer.new()
        box.add_theme_constant_override("separation", 10)
        p.add_child(box)
        _mk_label(box, title, 24, Color(0.988, 0.933, 0.039))
        var scroll := ScrollContainer.new()
        var viewport_size: Vector2 = get_viewport().get_visible_rect().size
        scroll.custom_minimum_size = Vector2(maxf(160.0, p.custom_minimum_size.x - 44.0), clampf(viewport_size.y * 0.42, 120.0, 320.0))
        scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
        box.add_child(scroll)
        _apply_cyber_scrollbar_style(scroll)
        var list := VBoxContainer.new()
        list.add_theme_constant_override("separation", 8)
        list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        scroll.add_child(list)
        _mk_btn(box, "关闭面板", Color(0.6, 0.63, 0.75), func(): root.visible = false)
        return list

func _apply_cyber_scrollbar_style(scroll: ScrollContainer) -> void:
        # Keep Godot's native ScrollContainer gestures; only skin its native bar.
        var bar := scroll.get_v_scroll_bar()
        bar.custom_minimum_size.x = 10.0
        var trough := StyleBoxFlat.new()
        trough.bg_color = Color(0.01, 0.02, 0.045, 0.80)
        trough.border_color = Color(0.0, 0.52, 0.72, 0.28)
        trough.set_border_width_all(1)
        trough.set_corner_radius_all(5)
        bar.add_theme_stylebox_override("scroll", trough)
        bar.add_theme_stylebox_override("scroll_focus", trough.duplicate())
        var thumb := StyleBoxFlat.new()
        thumb.bg_color = Color(0.0, 0.72, 0.92, 0.78)
        thumb.border_color = Color(0.26, 0.92, 1.0, 0.95)
        thumb.set_border_width_all(1)
        thumb.set_corner_radius_all(5)
        bar.add_theme_stylebox_override("grabber", thumb)
        var thumb_hover := thumb.duplicate() as StyleBoxFlat
        thumb_hover.bg_color = Color(0.13, 0.88, 1.0, 0.95)
        bar.add_theme_stylebox_override("grabber_highlight", thumb_hover)
        var thumb_pressed := thumb.duplicate() as StyleBoxFlat
        thumb_pressed.bg_color = Color(0.0, 0.38, 0.54, 1.0)
        bar.add_theme_stylebox_override("grabber_pressed", thumb_pressed)

# —— 设置面板 ——

func render_settings(s: Dictionary) -> void:
        var list := _panel_content(settings_root, "系统设置 // SYSTEM")
        _mk_setting_slider(list, "音乐音量", s.get("musicVol", 0.8) * 100.0, "musicVol")
        _mk_setting_slider(list, "音效音量", s.get("sfxVol", 1.0) * 100.0, "sfxVol")
        _mk_setting_slider(list, "镜头震动强度", float(s.get("cameraShake", 0.75)) * 100.0, "cameraShake")
        _mk_setting_check(list, "动态难度（DDA）", s.get("dda", true), "dda")
        _mk_setting_check(list, "触感反馈", s.get("haptics", true), "haptics")
        _mk_setting_check(list, "显示 FPS", s.get("showFps", false), "showFps")

func _mk_setting_slider(list: VBoxContainer, txt: String, val: float, key: String) -> void:
        var row := HBoxContainer.new()
        list.add_child(row)
        var l := Label.new()
        l.text = "%s  %d%%" % [txt, int(val)]
        l.add_theme_font_size_override("font_size", 15)
        l.add_theme_color_override("font_color", Color(0.9, 0.92, 1))
        var logical_width: float = get_viewport().get_visible_rect().size.x
        l.custom_minimum_size = Vector2(minf(150.0, maxf(92.0, logical_width * 0.36)), 0.0)
        row.add_child(l)
        l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        var sl := HSlider.new()
        sl.min_value = 0
        sl.max_value = 100
        sl.step = 1
        sl.value = val
        sl.custom_minimum_size = Vector2(0, 44)
        sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        sl.focus_mode = Control.FOCUS_ALL
        sl.tooltip_text = "%s：左右拖动调整" % txt
        _apply_cyber_slider_style(sl)
        row.custom_minimum_size.y = 48
        # Volume preview stays responsive, but storage is committed only when the
        # user finishes dragging or leaves the control (keyboard/accessibility path).
        # No debounce timer is used: slowly dragging must not trigger repeated disk writes.
        var dirty := [false]
        var commit_slider := func() -> void:
                if dirty[0]:
                        dirty[0] = false
                        settings_changed.emit(key, sl.value / 100.0)
        sl.value_changed.connect(func(v: float):
                l.text = "%s  %d%%" % [txt, int(v)]
                dirty[0] = true
                settings_previewed.emit(key, v / 100.0))
        sl.drag_ended.connect(func(changed: bool):
                if changed:
                        commit_slider.call())
        sl.focus_exited.connect(func(): commit_slider.call())
        row.add_child(sl)

func _mk_setting_check(list: VBoxContainer, txt: String, val: bool, key: String) -> void:
        var row := HBoxContainer.new()
        list.add_child(row)
        var l := Label.new()
        l.text = txt
        l.add_theme_font_size_override("font_size", 15)
        l.add_theme_color_override("font_color", Color(0.9, 0.92, 1))
        l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        row.add_child(l)
        l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        l.mouse_filter = Control.MOUSE_FILTER_STOP
        row.custom_minimum_size.y = 48
        var cb := CheckButton.new()
        cb.name = "CyberToggle_" + key
        cb.button_pressed = val
        cb.custom_minimum_size = Vector2(52, 48)
        cb.focus_mode = Control.FOCUS_ALL
        cb.tooltip_text = "%s：%s" % [txt, "开启" if val else "关闭"]
        _apply_cyber_check_style(cb)
        cb.toggled.connect(func(on: bool):
                cb.tooltip_text = "%s：%s" % [txt, "开启" if on else "关闭"]
                settings_changed.emit(key, on))
        l.gui_input.connect(_on_check_label_input.bind(cb))
        row.add_child(cb)

func _apply_cyber_slider_style(sl: HSlider) -> void:
        # Native Godot slider primitives, themed as a recessed cyber control.
        var track := StyleBoxFlat.new()
        track.bg_color = Color(0.012, 0.024, 0.055, 0.98)
        track.border_color = Color(0.0, 0.62, 0.82, 0.70)
        track.set_border_width_all(1)
        track.set_corner_radius_all(4)
        track.content_margin_top = 4.0
        track.content_margin_bottom = 4.0
        sl.add_theme_stylebox_override("slider", track)

        var fill := StyleBoxFlat.new()
        fill.bg_color = Color(0.0, 0.78, 0.98, 0.96)
        fill.border_color = Color(0.34, 0.96, 1.0, 0.95)
        fill.set_border_width_all(1)
        fill.set_corner_radius_all(4)
        fill.content_margin_top = 4.0
        fill.content_margin_bottom = 4.0
        sl.add_theme_stylebox_override("grabber_area", fill)
        var fill_hover := fill.duplicate() as StyleBoxFlat
        fill_hover.bg_color = Color(0.28, 0.94, 1.0, 1.0)
        sl.add_theme_stylebox_override("grabber_area_highlight", fill_hover)
        sl.add_theme_icon_override("grabber", ICON_SLIDER_GRABBER)
        sl.add_theme_icon_override("grabber_highlight", ICON_SLIDER_GRABBER)
        sl.add_theme_icon_override("grabber_disabled", ICON_SLIDER_GRABBER)
        sl.add_theme_constant_override("grabber_offset", 1)

func _apply_cyber_check_style(cb: CheckButton) -> void:
        cb.add_theme_icon_override("checked", ICON_TOGGLE_ON)
        cb.add_theme_icon_override("checked_disabled", ICON_TOGGLE_OFF)
        cb.add_theme_icon_override("unchecked", ICON_TOGGLE_OFF)
        cb.add_theme_icon_override("unchecked_disabled", ICON_TOGGLE_OFF)
        cb.add_theme_color_override("button_checked_color", Color(0.0, 0.94, 1.0))
        cb.add_theme_color_override("button_unchecked_color", Color(0.42, 0.48, 0.60))
        cb.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
        cb.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
        cb.add_theme_color_override("font_disabled_color", Color(0.48, 0.52, 0.62))
        cb.add_theme_constant_override("h_separation", 8)
        var normal := StyleBoxFlat.new()
        normal.bg_color = Color(0.025, 0.035, 0.075, 0.72)
        normal.border_color = Color(0.0, 0.62, 0.82, 0.35)
        normal.set_border_width_all(1)
        normal.set_corner_radius_all(8)
        normal.set_content_margin_all(4)
        cb.add_theme_stylebox_override("normal", normal)
        var hover := normal.duplicate() as StyleBoxFlat
        hover.bg_color = Color(0.035, 0.10, 0.17, 0.90)
        hover.border_color = Color(0.0, 0.85, 1.0, 0.85)
        cb.add_theme_stylebox_override("hover", hover)
        var pressed := normal.duplicate() as StyleBoxFlat
        pressed.bg_color = Color(0.0, 0.28, 0.36, 0.90)
        pressed.border_color = Color(0.35, 0.96, 1.0, 1.0)
        cb.add_theme_stylebox_override("pressed", pressed)
        var focus := normal.duplicate() as StyleBoxFlat
        focus.border_color = Color(0.35, 0.96, 1.0, 1.0)
        focus.set_border_width_all(2)
        cb.add_theme_stylebox_override("focus", focus)

func _on_check_label_input(event: InputEvent, cb: CheckButton) -> void:
        # A wide text label must behave like the toggle, not a dead area on touchscreens.
        var activate := false
        if event is InputEventMouseButton:
                var mouse_event := event as InputEventMouseButton
                activate = mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT
        elif event is InputEventScreenTouch:
                activate = (event as InputEventScreenTouch).pressed
        if activate and is_instance_valid(cb) and cb.is_inside_tree() and not cb.disabled:
                cb.button_pressed = not cb.button_pressed

# —— 商店面板 ——

func render_shop(skins: Array, wallet: int, owned: Array, current: int) -> void:
        var list := _panel_content(shop_root, "义体商店 // 芯片资金 %d" % wallet)
        for s in skins:
                var row := HBoxContainer.new()
                row.add_theme_constant_override("separation", 8)
                list.add_child(row)
                var sw := ColorRect.new()
                sw.custom_minimum_size = Vector2(26, 26)
                sw.color = s.color
                row.add_child(sw)
                var info := VBoxContainer.new()
                info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
                row.add_child(info)
                var name_l := Label.new()
                name_l.text = "%s" % s.name
                name_l.add_theme_font_size_override("font_size", 16)
                name_l.add_theme_color_override("font_color", Color(0.95, 0.95, 1))
                info.add_child(name_l)
                if s.skill != "":
                        var sk := Label.new()
                        sk.text = "超频技能 / %s" % s.skill
                        sk.add_theme_font_size_override("font_size", 12)
                        sk.add_theme_color_override("font_color", Color(0, 0.941, 1))
                        info.add_child(sk)
                if s.id == current:
                        var eq := Label.new()
                        eq.text = "✓ 装备中"
                        eq.add_theme_font_size_override("font_size", 13)
                        eq.add_theme_color_override("font_color", Color(0.988, 0.933, 0.039))
                        row.add_child(eq)
                elif s.id in owned:
                        _mk_btn(row, "装备", Color(0, 0.941, 1), _skin_action_callback(int(s.id), "equip"))
                else:
                        var b := _mk_btn(row, "芯片 %d" % s.price, Color(1, 0, 0.239), _skin_action_callback(int(s.id), "buy"), ICON_CHIP)
                        if wallet < s.price:
                                b.disabled = true
                                b.modulate = Color(1, 1, 1, 0.4)

# —— 任务面板 ——

func render_missions(mlist: Array) -> void:
        var list := _panel_content(missions_root, "每日任务 // DAILY OPS")
        _mk_btn(list, "查看成就", Color(0.0, 0.941, 1.0), func(): show_achv_requested.emit(), ICON_ACHIEVEMENT)
        for m in mlist:
                var row := HBoxContainer.new()
                row.add_theme_constant_override("separation", 8)
                list.add_child(row)
                var info := VBoxContainer.new()
                info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
                row.add_child(info)
                var t := Label.new()
                t.text = "%s（%s）" % [m.name, m.desc]
                t.add_theme_font_size_override("font_size", 14)
                t.add_theme_color_override("font_color", Color(0.95, 0.95, 1))
                info.add_child(t)
                var p := Label.new()
                p.text = "%d / %d · 奖励 %d 芯片" % [int(m.cur), int(m.target), m.reward]
                p.add_theme_font_size_override("font_size", 12)
                p.add_theme_color_override("font_color", Color(0.6, 0.63, 0.75))
                info.add_child(p)
                if m.done and not m.claimed:
                        _mk_btn(row, "领取", Color(0.988, 0.933, 0.039), _mission_claim_callback(String(m.id)))
                elif m.claimed:
                        var d := Label.new()
                        d.text = "✓"
                        d.add_theme_font_size_override("font_size", 15)
                        d.add_theme_color_override("font_color", Color(0.988, 0.933, 0.039))
                        row.add_child(d)


# 每个按钮经由独立工厂创建回调，避免循环中的字典变量被后续迭代覆盖。
func _skin_action_callback(skin_id: int, action: String) -> Callable:
        return func(): skin_action.emit(skin_id, action)

func _mission_claim_callback(mission_id: String) -> Callable:
        return func(): mission_claim.emit(mission_id)

# —— 成就面板 ——

func render_achv(alist: Array) -> void:
        var list := _panel_content(achv_root, "成就 // CYBER RECORDS")
        _mk_btn(list, "返回每日任务", Color(0.0, 0.941, 1.0), func(): show_missions_requested.emit(), ICON_MISSION)
        var unlocked: int = 0
        for a in alist:
                if a.unlocked:
                        unlocked += 1
                var row := HBoxContainer.new()
                row.add_theme_constant_override("separation", 8)
                list.add_child(row)
                var icon := TextureRect.new()
                icon.texture = ICON_ACHIEVEMENT
                icon.custom_minimum_size = Vector2(22, 22)
                icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
                icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
                icon.modulate = Color(0.988, 0.933, 0.039) if a.unlocked else Color(0.4, 0.42, 0.5)
                icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
                row.add_child(icon)
                var info := VBoxContainer.new()
                info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
                row.add_child(info)
                var t := Label.new()
                t.text = a.name
                t.add_theme_font_size_override("font_size", 15)
                t.add_theme_color_override("font_color", Color(0.95, 0.95, 1) if a.unlocked else Color(0.55, 0.58, 0.68))
                info.add_child(t)
                var d := Label.new()
                d.text = a.desc
                d.add_theme_font_size_override("font_size", 12)
                d.add_theme_color_override("font_color", Color(0.6, 0.63, 0.75))
                info.add_child(d)
        _mk_label(list, "已解锁 %d / %d" % [unlocked, alist.size()], 13, Color(0.6, 0.63, 0.75))

# ---------- 状态切换 ----------

func close_topmost_secondary() -> bool:
        # A single back press closes only the topmost secondary panel, never the paused run beneath it.
        for panel_root in [achv_root, missions_root, shop_root, settings_root]:
                if is_instance_valid(panel_root) and panel_root.visible:
                        panel_root.visible = false
                        return true
        return false

func show_menu() -> void:
        menu_root.visible = true
        gameover_root.visible = false
        pause_root.visible = false
        revive_root.visible = false
        for r in [settings_root, shop_root, missions_root, achv_root]:
                r.visible = false

func show_running() -> void:
        for c in [menu_root, gameover_root, pause_root, revive_root]:
                c.visible = false
        for r in [settings_root, shop_root, missions_root, achv_root]:
                r.visible = false

func show_pause() -> void:
        pause_root.visible = true

func hide_pause() -> void:
        pause_root.visible = false

func show_gameover(stats: Dictionary, dda: String) -> void:
        revive_root.visible = false
        pause_root.visible = false
        menu_root.visible = false
        for r in [settings_root, shop_root, missions_root, achv_root]:
                r.visible = false
        go_dda.visible = dda != ""
        gameover_root.visible = true
        _fade_in(gameover_root, false)   # 结算淡入
        go_stats.text = "狂奔 %dm · 得分 %d\n芯片 ×%d · 连击 ×%d · 最长 %dm" % [
                int(stats.distance), int(stats.score), stats.chips, stats.combo, int(stats.best)]
        if dda != "":
                go_dda.visible = true
                go_dda.text = ("↯ 动态难度 · 新手护航中" if dda == "gentle" else "↯ 动态难度 · 高手协议")

func show_revive(countdown: float) -> void:
        var first_show := not revive_root.visible
        revive_root.visible = true
        if first_show:
                _fade_in(revive_root, false)
        revive_countdown.text = "%d" % int(ceil(countdown))

func hide_revive() -> void:
        revive_root.visible = false

func refresh_meta(best: float, coins: int) -> void:
        menu_best.text = "最远狂奔 %dm" % int(best)
        menu_wallet.text = "芯片资金 · %d" % coins
