class_name Effects
extends Node3D
## 游戏反馈效果：雨、速度线、碎裂反馈、尾迹、冲击波与粒子预算。
## 高成本节点按设备性能档位配置；跨局复位由 reset_fx 统一处理。

var time: float = 0.0

var _rain: GPUParticles3D
var _rain_ratio_cache: float = -1.0
var _speed_lines: GPUParticles3D
var _speed_lines_material: StandardMaterial3D
var _speed_lines_active_cache: bool = false
var _speed_lines_boost_cache: bool = false
var _speed_lines_cache_valid: bool = false
var _shards: Array[MeshInstance3D] = []
var _shard_data: Array[Dictionary] = []
var _active_shard_slots: Array[int] = []
var _trail: Array[MeshInstance3D] = []
var _trail_data: Array[Dictionary] = []
var _active_trail_slots: Array[int] = []
var _trail_materials: Array[StandardMaterial3D] = []
var _trail_mat: StandardMaterial3D
var _oc_active: bool = false
var _shock_ring: MeshInstance3D   # outer warm pulse ring
var _shock_ring_inner: MeshInstance3D # inner cool-energy ring for a layered impact read
var _shock_t: float = 0.0
var _trail_idx: int = 0
var _trail_cd: float = 0.0

func _ready() -> void:
        _build_rain()
        _build_speed_lines()
        _build_shard_pool()
        _build_trail_pool()


## Public performance-profile hook. Telemetry must not reach into private particle nodes.
func apply_perf_profile(grade: String) -> void:
        var rain_count: int = int(Config.WORLD.rainCount)
        var speed_line_count: int = 260
        match grade:
                "low":
                        rain_count = 500
                        speed_line_count = 120
                "mid":
                        rain_count = 900
                        speed_line_count = 180
                "high":
                        pass
                _:
                        push_warning("未知粒子性能档位：%s" % grade)
        if is_instance_valid(_rain):
                _rain.amount = rain_count
        if is_instance_valid(_speed_lines):
                _speed_lines.amount = speed_line_count

func _build_rain() -> void:
        _rain = GPUParticles3D.new()
        _rain.amount = int(Config.WORLD.rainCount)   # default particle budget; Telemetry may lower it by device profile
        _rain.lifetime = 1.0
        _rain.preprocess = 1.0
        var pm := ParticleProcessMaterial.new()
        pm.direction = Vector3(0.06, -1, -0.22)
        pm.spread = 4.0
        pm.initial_velocity_min = 26.0
        pm.initial_velocity_max = 34.0
        pm.gravity = Vector3(0, -8, 0)
        pm.scale_min = 0.5
        pm.scale_max = 1.0
        _rain.process_material = pm
        var qm := QuadMesh.new()
        qm.size = Vector2(0.016, 0.62)
        var m := StandardMaterial3D.new()
        m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD   # 发光雨丝（赛博雨 = 光）
        m.albedo_color = Color(0.55, 0.80, 1.0, 0.42)
        m.emission_enabled = true
        m.emission = Color(0.3, 0.65, 1.0)
        m.emission_energy_multiplier = 1.4
        m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
        qm.material = m
        _rain.draw_pass_1 = qm
        _rain.visibility_aabb = AABB(Vector3(-12, 0, -30), Vector3(24, 18, 36))
        _rain.position = Vector3(0, 12, -8)
        _rain.emitting = false
        add_child(_rain)

func _build_speed_lines() -> void:
        _speed_lines = GPUParticles3D.new()
        _speed_lines.amount = 260   # 速度线增密
        _speed_lines.lifetime = 0.4
        var pm := ParticleProcessMaterial.new()
        pm.direction = Vector3(0, 0, -1)
        pm.spread = 180.0
        pm.flatness = 1.0
        pm.initial_velocity_min = 40.0
        pm.initial_velocity_max = 60.0
        pm.gravity = Vector3.ZERO
        _speed_lines.process_material = pm
        var qm := QuadMesh.new()
        qm.size = Vector2(0.045, 2.2)
        var m := StandardMaterial3D.new()
        m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        m.albedo_color = Color(1, 1, 1, 0.0)
        m.emission_enabled = true
        m.emission = Config.PALETTE.cyan
        m.emission_energy_multiplier = 2.0
        qm.material = m
        _speed_lines_material = m
        _speed_lines.draw_pass_1 = qm
        _speed_lines.visibility_aabb = AABB(Vector3(-14, -8, -40), Vector3(28, 18, 50))
        _speed_lines.position = Vector3(0, 2, -14)
        _speed_lines.emitting = false
        add_child(_speed_lines)

func _build_shard_pool() -> void:
        for i in 48:   # Reuse three distinct fragment silhouettes; avoid a field of identical square chips.
                var shard := MeshInstance3D.new()
                match i % 3:
                        0:
                                var shard_mesh := CylinderMesh.new()
                                shard_mesh.top_radius = 0.006
                                shard_mesh.bottom_radius = 0.075
                                shard_mesh.height = 0.26
                                shard_mesh.radial_segments = 5
                                shard_mesh.rings = 1
                                shard.mesh = shard_mesh
                        1:
                                var prism := PrismMesh.new()
                                prism.size = Vector3(0.12, 0.18, 0.10)
                                shard.mesh = prism
                        _:
                                var crystal := SphereMesh.new()
                                crystal.radius = 0.5
                                crystal.height = 1.0
                                crystal.radial_segments = 5
                                crystal.rings = 3
                                shard.mesh = crystal
                                shard.scale = Vector3(0.11, 0.17, 0.08)
                # Each pooled fragment has a unique material instance so its fade never leaks to another shard.
                var shard_material := StandardMaterial3D.new()
                shard_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                shard_material.albedo_color = Color.WHITE
                shard_material.metallic = 0.42
                shard_material.roughness = 0.36
                shard_material.emission_enabled = true
                shard_material.emission = Color.WHITE
                shard_material.emission_energy_multiplier = 1.2
                shard.material_override = shard_material
                shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                shard.visible = false
                add_child(shard)
                _shards.append(shard)
                _shard_data.append({"vx": 0.0, "vy": 0.0, "vz": 0.0, "rx": 0.0, "ry": 0.0, "life": 0.0})
        # 超频冲击波环（激活时从玩家位置扩散）
        _shock_ring = MeshInstance3D.new()
        var tm := TorusMesh.new()
        tm.inner_radius = 0.9
        tm.outer_radius = 1.15
        tm.rings = 6
        tm.ring_segments = 40
        _shock_ring.mesh = tm
        var sm := StandardMaterial3D.new()
        sm.albedo_color = Color(0.988, 0.933, 0.039)
        sm.emission_enabled = true
        sm.emission = Color(0.988, 0.933, 0.039)
        sm.emission_energy_multiplier = 4.0
        sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _shock_ring.material_override = sm
        _shock_ring.visible = false
        add_child(_shock_ring)
        _shock_ring_inner = MeshInstance3D.new()
        var inner_tm := TorusMesh.new()
        inner_tm.inner_radius = 0.48
        inner_tm.outer_radius = 0.62
        inner_tm.rings = 6
        inner_tm.ring_segments = 32
        _shock_ring_inner.mesh = inner_tm
        var inner_mat := StandardMaterial3D.new()
        inner_mat.albedo_color = Config.PALETTE.cyan
        inner_mat.emission_enabled = true
        inner_mat.emission = Config.PALETTE.cyan
        inner_mat.emission_energy_multiplier = 3.0
        inner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        inner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        inner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        _shock_ring_inner.material_override = inner_mat
        _shock_ring_inner.visible = false
        _shock_ring_inner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        add_child(_shock_ring_inner)

## Layered overclock shockwave: warm outer ring plus cool inner ring.
## 开局复位（截图回归揪出：上局冲击波残留贴脸）
func reset_fx() -> void:
        _shock_t = 0.0
        _shock_ring.visible = false
        _shock_ring_inner.visible = false
        _oc_active = false
        _trail_cd = 0.0
        _trail_idx = 0
        _speed_lines.emitting = false
        _speed_lines_active_cache = false
        _speed_lines_boost_cache = false
        _speed_lines_cache_valid = true
        if is_instance_valid(_speed_lines_material):
                _speed_lines_material.albedo_color = Color(1, 1, 1, 0.12)
        _rain.emitting = false
        _active_trail_slots.clear()
        _active_shard_slots.clear()
        for i in _trail_data.size():
                _trail_data[i].life = 0.0
                _trail_data[i].pos = Vector3.ZERO
                _trail[i].visible = false
        for i in _shards.size():
                _shard_data[i].life = 0.0
                _shards[i].visible = false

func set_rain_active(on: bool) -> void:
        if is_instance_valid(_rain) and _rain.emitting != on:
                _rain.emitting = on
                if on:
                        _rain_ratio_cache = -1.0

func shockwave(x: float) -> void:
        _shock_ring.position = Vector3(x, 0.9, 0.0)
        _shock_ring.scale = Vector3.ONE
        _shock_ring.reset_physics_interpolation()
        var outer_material := _shock_ring.material_override as StandardMaterial3D
        outer_material.albedo_color.a = 0.85
        outer_material.emission_energy_multiplier = 4.0
        _shock_ring.visible = true
        _shock_ring_inner.position = Vector3(x, 0.93, 0.0)
        _shock_ring_inner.scale = Vector3.ONE * 0.82
        _shock_ring_inner.reset_physics_interpolation()
        var inner_material := _shock_ring_inner.material_override as StandardMaterial3D
        inner_material.albedo_color.a = 0.68
        inner_material.emission_energy_multiplier = 3.0
        _shock_ring_inner.visible = true
        _shock_t = 0.55

func _build_trail_pool() -> void:
        _trail_mat = StandardMaterial3D.new()
        _trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        _trail_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
        _trail_mat.albedo_color = Color(Config.PALETTE.cyan, 0.5)
        _trail_mat.emission_enabled = true
        _trail_mat.emission = Config.PALETTE.cyan
        _trail_mat.emission_energy_multiplier = 1.8
        _trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        for i in 22:
                var seg := MeshInstance3D.new()
                # Tapered low-poly light ribbon instead of a hard-ended square quad.
                var ribbon := CylinderMesh.new()
                ribbon.top_radius = 0.004
                ribbon.bottom_radius = 0.055
                ribbon.height = 1.35
                ribbon.radial_segments = 7
                ribbon.rings = 1
                seg.mesh = ribbon
                seg.rotation.x = PI / 2.0
                var segment_material := _trail_mat.duplicate() as StandardMaterial3D
                seg.material_override = segment_material
                seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                seg.visible = false
                add_child(seg)
                _trail.append(seg)
                _trail_materials.append(segment_material)
                _trail_data.append({"life": 0.0, "max_life": 0.3, "pos": Vector3.ZERO, "boost": false})

# ---------- 公共接口 ----------

func shatter(x: float, y: float, z: float, color: Color, count: int = 16) -> void:
        var spawned: int = 0
        for i in _shards.size():
                if spawned >= count:
                        break
                var d: Dictionary = _shard_data[i]
                if d.life > 0.0:
                        continue
                spawned += 1
                _active_shard_slots.append(i)
                d.life = 0.8
                d.vx = U.randf_range(-4, 4)
                d.vy = U.randf_range(2, 8)
                d.vz = U.randf_range(-3, 1)
                d.rx = U.randf_range(-9, 9)
                d.ry = U.randf_range(-9, 9)
                _shards[i].position = Vector3(x, y, z)
                _shards[i].rotation = Vector3(U.randf_range(-PI, PI), U.randf_range(-PI, PI), U.randf_range(-PI, PI))
                _shards[i].scale = Vector3(U.randf_range(0.72, 1.42), U.randf_range(0.72, 1.5), U.randf_range(0.58, 1.18))
                _shards[i].reset_physics_interpolation()
                _shards[i].visible = true
                var im := _shards[i].material_override as StandardMaterial3D
                im.albedo_color = color
                im.emission = color
                im.albedo_color.a = 1.0
                im.emission_energy_multiplier = 1.6

func update(dt: float, spd: float, player_info: Dictionary, overclock_active: bool) -> void:
        time += dt
        _oc_active = overclock_active
        # Rain is usually disabled during normal running. Skip both the ratio
        # calculation and a renderer-facing property write while its emitter is off;
        # while active, quantize density updates below a perceptual threshold.
        if _rain.emitting:
                var desired_rain_ratio: float = U.clampf(0.45 + spd / 33.0 * 0.55, 0.3, 1.0)
                if _rain_ratio_cache < 0.0 or absf(desired_rain_ratio - _rain_ratio_cache) >= 0.015:
                        _rain.amount_ratio = desired_rain_ratio
                        _rain_ratio_cache = desired_rain_ratio
        # 冲击波扩散动画
        if _shock_t > 0.0:
                _shock_t -= dt
                var k: float = 1.0 - _shock_t / 0.55
                _shock_ring.scale = Vector3.ONE * (1.0 + k * 14.0)
                var outer_material := _shock_ring.material_override as StandardMaterial3D
                outer_material.albedo_color.a = (1.0 - k) * 0.85
                outer_material.emission_energy_multiplier = 4.0 * (1.0 - k)
                _shock_ring_inner.scale = Vector3.ONE * (0.82 + k * 10.5)
                var inner_material := _shock_ring_inner.material_override as StandardMaterial3D
                inner_material.albedo_color.a = (1.0 - k) * 0.68
                inner_material.emission_energy_multiplier = 3.0 * (1.0 - k)
                if _shock_t <= 0.0:
                        _shock_ring.visible = false
                        _shock_ring_inner.visible = false
        var should_emit_speed_lines: bool = overclock_active or spd > 26.0
        if not _speed_lines_cache_valid or should_emit_speed_lines != _speed_lines_active_cache:
                _speed_lines.emitting = should_emit_speed_lines
                _speed_lines_active_cache = should_emit_speed_lines
        if not _speed_lines_cache_valid or overclock_active != _speed_lines_boost_cache:
                _speed_lines_material.albedo_color = Color(1, 1, 1, 0.2 if overclock_active else 0.12)
                _speed_lines_boost_cache = overclock_active
        _speed_lines_cache_valid = true
        # Active-slot lists avoid touching all 48 pooled shards every frame when
        # no collisions are happening. Expired entries are removed with swap-pop.
        var shard_cursor: int = 0
        while shard_cursor < _active_shard_slots.size():
                var shard_slot: int = _active_shard_slots[shard_cursor]
                var d: Dictionary = _shard_data[shard_slot]
                d.life -= dt
                if d.life <= 0.0:
                        _shards[shard_slot].visible = false
                        _active_shard_slots[shard_cursor] = _active_shard_slots.back()
                        _active_shard_slots.pop_back()
                        continue
                d.vy -= 26.0 * dt
                _shards[shard_slot].position += Vector3(d.vx, d.vy, d.vz + spd) * dt
                _shards[shard_slot].rotation.x += d.rx * dt
                _shards[shard_slot].rotation.y += d.ry * dt
                var im := _shards[shard_slot].material_override as StandardMaterial3D
                var shard_fade: float = U.clampf(d.life * 1.6, 0.0, 1.0)
                var shard_color: Color = im.albedo_color
                shard_color.a = shard_fade
                im.albedo_color = shard_color
                im.emission_energy_multiplier = 1.2 * shard_fade
                shard_cursor += 1
        if player_info.is_empty():
                # Trails must continue to decay even during short state transitions without a player sample.
                _update_trail(dt, spd)
                return
        var boost: bool = overclock_active or player_info.get("boost", false)
        _emit_trail(dt, player_info.pos, boost)
        _update_trail(dt, spd)

func _emit_trail(dt: float, p: Vector3, boost: bool) -> void:
        _trail_cd -= dt
        if _trail_cd > 0.0:
                return
        _trail_cd = 0.018 if boost else 0.035
        var seg := _trail[_trail_idx]
        var d: Dictionary = _trail_data[_trail_idx]
        # A ring slot can be overwritten before its old lifetime ends during overclock.
        # Keep one active-list entry per slot; the existing entry already follows the new life.
        if float(d.life) <= 0.0:
                _active_trail_slots.append(_trail_idx)
        d.life = 0.42 if boost else 0.28
        d.max_life = d.life
        d.boost = boost
        d.pos = p + Vector3(0, 0.9, 1.2)
        seg.position = d.pos
        seg.scale = Vector3.ONE
        seg.reset_physics_interpolation()
        seg.visible = true
        _trail_idx = (_trail_idx + 1) % _trail.size()

func _update_trail(dt: float, spd: float) -> void:
        var active_cursor: int = 0
        while active_cursor < _active_trail_slots.size():
                var slot: int = _active_trail_slots[active_cursor]
                var d: Dictionary = _trail_data[slot]
                d.life -= dt
                var seg := _trail[slot]
                var segment_material := _trail_materials[slot]
                if d.life <= 0.0:
                        seg.visible = false
                        segment_material.albedo_color.a = 0.0
                        segment_material.emission_energy_multiplier = 0.0
                        _active_trail_slots[active_cursor] = _active_trail_slots.back()
                        _active_trail_slots.pop_back()
                        continue
                seg.position.z += spd * dt
                var life_scale: float = U.clampf(d.life / maxf(float(d.max_life), 0.001), 0.0, 1.0)
                var boost: bool = bool(d.boost)
                var width_scale: float = (1.0 if boost else 0.72) * (0.40 + life_scale * 0.60)
                var length_scale: float = (1.0 if boost else 0.72) * (0.45 + life_scale * 0.55)
                seg.scale = Vector3(width_scale, length_scale, width_scale)
                var alpha: float = (0.52 if boost else 0.34) * life_scale
                segment_material.albedo_color = Color(Config.PALETTE.cyan.r, Config.PALETTE.cyan.g, Config.PALETTE.cyan.b, alpha)
                segment_material.emission = Config.PALETTE.cyan.lerp(Color.WHITE, 0.16 if boost else 0.0)
                segment_material.emission_energy_multiplier = (2.1 if boost else 1.25) * life_scale
                active_cursor += 1
