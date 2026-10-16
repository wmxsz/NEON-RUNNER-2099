class_name PostFX
extends CanvasLayer
## 高速专用色差层。常态交给 Godot 原生 Environment/Glow/Filmic tonemapping；
## 只有高速或超频时才绘制屏幕采样，避免每帧做全屏拷贝与重复调色。

var _mat: ShaderMaterial
var _effect_active: bool = false

func _ready() -> void:
        # This CanvasLayer is driven from _process; don't let native physics
        # interpolation add another transform phase to the screen-space effect.
        physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
        # World effect is drawn below native HUD and menu CanvasLayers (10/20).
        layer = 5
        var rect := ColorRect.new()
        rect.set_anchors_preset(Control.PRESET_FULL_RECT)
        rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _mat = ShaderMaterial.new()
        _mat.shader = preload("res://fx/post_fx.gdshader")
        rect.material = _mat
        add_child(rect)
        _mat.set_shader_parameter("ca_amount", 0.0)
        _mat.set_shader_parameter("boost_vignette", 0.025)
        set_active(false)

func set_active(on: bool) -> void:
        if _effect_active == on:
                return
        _effect_active = on
        visible = on

func is_active() -> bool:
        return _effect_active

## 每帧驱动（speed_norm 0-1）：只在高速度/超频时启用屏幕色差。
## 常态隐藏 ColorRect，因此不触发 hint_screen_texture 的全屏采样路径。
func update(_dt: float, speed_norm: float, overclock: bool) -> void:
        var ca: float = 0.0
        if speed_norm > 0.72:
                ca = clampf((speed_norm - 0.72) * 0.25, 0.0, 0.07)
        if overclock:
                ca = maxf(ca, 0.14)
        var should_draw: bool = ca > 0.005
        if should_draw:
                _mat.set_shader_parameter("ca_amount", ca)
                set_active(true)
        else:
                set_active(false)
