class_name World
extends Node3D

const ARMOR_ALBEDO: Texture2D = preload("res://assets/textures/cyber_armor_albedo.png")
const ARMOR_NORMAL: Texture2D = preload("res://assets/textures/cyber_armor_normal.png")
const ARMOR_ROUGHNESS: Texture2D = preload("res://assets/textures/cyber_armor_roughness.png")
const SKY_COURIER_SCENE: PackedScene = preload("res://assets/models/sky_courier.glb")
const CARGO_SKIMMER_SCENE: PackedScene = preload("res://assets/models/cargo_skimmer.glb")
const PATROL_INTERCEPTOR_SCENE: PackedScene = preload("res://assets/models/patrol_interceptor.glb")
const BOSS_MODEL_SCENE: PackedScene = preload("res://assets/models/sentinel_boss.glb")
const NEON_LANDMARK_SCENE: PackedScene = preload("res://assets/models/neon_landmark.glb")
const NEON_ARCOLOGY_SCENE: PackedScene = preload("res://assets/models/neon_arcology.glb")
const NEON_SPIRE_SCENE: PackedScene = preload("res://assets/models/neon_spire.glb")

## ============================================================
## World 管理程序化城市、道路、环境、章节主题与动态交通。
## MultiMesh 建筑群（单 DC 96 栋）/ 程序窗 shader / 车道霓虹线 /
## 章节主题渐变（每 1000m）/ 数据拱门 / 能量甲板抛光高光近似
## ============================================================

const BUILDING_COUNT := 96
const ROAD_DECK_LENGTH := 420.0
const ROAD_DECK_CENTER_Z := -170.0
const GATE_GAP := 58.0
const GATE_COUNT := 4

var time: float = 0.0

var _env: Environment
var _sun_light: DirectionalLight3D
var _current_fog_density: float = 0.027
var _road_cycle_length: float = 42.0
var _road_distance: float = 0.0
# Shader uniforms do not participate in Node transform interpolation automatically.
# Keep the previous physics sample and delta so road scroll/window pulse can be rendered
# at display refresh rate using Godot's own interpolation fraction.
var _road_distance_previous: float = 0.0
var _road_distance_step: float = 0.0
var _deck_hardware_root: Node3D
var _deck_hardware_instances: int = 0
var _time_previous: float = 0.0
var _time_step: float = 0.0
var _theme_from: Dictionary
var _theme_to: Dictionary
var _theme_mix: float = 1.0
var _theme_update_accumulator: float = 0.0
var _building_root: Node3D
var _buildings: MultiMeshInstance3D
var _building_local_z: Array[float] = []
var _building_recycle_events: Array[Dictionary] = []
var _building_recycle_pointer: int = 0
var _far_skylines: Array[MultiMeshInstance3D] = []
var _far_skyline_local_z: Array = []
var _far_skyline_recycle_events: Array = []
var _far_skyline_recycle_pointer: Array[int] = []
var _base_glow: float = 0.48
var _perf_profile: String = "high"
var _overclocking: bool = false
var _lane_lines: Array[MeshInstance3D] = []
var _gates: Array[MeshInstance3D] = []
var _grid_mat: ShaderMaterial
var _building_mat: ShaderMaterial
var _gate_mat: StandardMaterial3D
var _boss_drone: Node3D      # BOSS 哨戒机 3D
var _building_rng := RandomNumberGenerator.new()
var _detail_rng := RandomNumberGenerator.new()
var _building_detail_flags: Array[Dictionary] = []
var _building_masts: MultiMeshInstance3D
var _building_roofs: MultiMeshInstance3D
var _building_tops: MultiMeshInstance3D
var _building_beacons: MultiMeshInstance3D
var _building_facades: MultiMeshInstance3D
var _building_shelves: MultiMeshInstance3D
var _air_traffic: Array[Node3D] = []
var _air_traffic_data: Array[Dictionary] = []
var _city_signs: Array[Label3D] = []
var _city_sign_rails: Array[MeshInstance3D] = []
var _city_sign_last_colors: Array[Color] = []
var _city_sign_roots: Array[Node3D] = []
var _city_sign_data: Array[Dictionary] = []
var _themeable_materials: Array[Dictionary] = []
var _landmarks: Array[Node3D] = []
var _landmark_data: Array[Dictionary] = []

func _ready() -> void:
        _build_environment()
        _build_road()
        _build_buildings()
        _build_far_skyline()
        _build_landmarks()
        _build_air_traffic()
        _build_city_signage()
        _build_gates()
        _theme_from = Config.THEMES[0]
        _theme_to = Config.THEMES[0]
        _current_fog_density = float(Config.THEMES[0].fogDensity)

# ---------- 构建 ----------

func _build_environment() -> void:
        var env_res := Environment.new()
        _env = env_res
        # Use Godot's native procedural sky instead of a flat background color.
        # Keep the sky static for stable mobile rendering; chapter identity remains
        # in fog, ambient tint, neon architecture, skyline and the running deck.
        var cyber_sky := Sky.new()
        var cyber_sky_material := ProceduralSkyMaterial.new()
        cyber_sky_material.sky_top_color = Color("030717")
        cyber_sky_material.sky_horizon_color = Color("170D38")
        cyber_sky_material.ground_horizon_color = Color("073342")
        cyber_sky_material.ground_bottom_color = Color("02040B")
        cyber_sky_material.sky_curve = 0.22
        cyber_sky_material.ground_curve = 0.035
        cyber_sky_material.sky_energy_multiplier = 0.86
        cyber_sky_material.ground_energy_multiplier = 0.35
        cyber_sky_material.sun_angle_max = 0.0
        cyber_sky_material.use_debanding = true
        cyber_sky.sky_material = cyber_sky_material
        cyber_sky.radiance_size = Sky.RADIANCE_SIZE_128
        # Incremental mode spreads static radiance generation over several frames.
        cyber_sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
        env_res.background_mode = Environment.BG_SKY
        env_res.sky = cyber_sky
        env_res.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
        env_res.ambient_light_color = Config.PALETTE.bg
        env_res.ambient_light_energy = 1.28
        env_res.tonemap_mode = Environment.TONE_MAPPER_FILMIC
        env_res.tonemap_exposure = 1.02
        env_res.adjustment_enabled = true
        env_res.adjustment_brightness = 1.0
        env_res.adjustment_contrast = 1.035
        env_res.adjustment_saturation = 1.055
        # 2077 暖橙大气雾；Fog retains depth without washing out near objects.
        env_res.fog_enabled = true
        env_res.fog_light_color = Color("3A1C10")
        env_res.fog_density = float(Config.THEMES[0].fogDensity)
        # One configuration source drives Godot Environment glow parameters.
        env_res.glow_enabled = true
        env_res.glow_intensity = float(Config.RUNTIME.bloomStrength)
        env_res.glow_strength = float(Config.RUNTIME.glowSpread)
        env_res.glow_bloom = 0.045
        env_res.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
        env_res.glow_hdr_threshold = float(Config.RUNTIME.glowThreshold)
        var we := WorldEnvironment.new()
        we.environment = env_res
        add_child(we)
        # 主光（冷色月光补暖橙雾）
        var sun := DirectionalLight3D.new()
        _sun_light = sun
        sun.light_color = Color(0.75, 0.82, 1.0)
        sun.light_energy = 0.9
        sun.rotation_degrees = Vector3(-38, -24, 0)
        sun.shadow_enabled = true   # final device profile is applied by Telemetry after scene assembly
        sun.directional_shadow_max_distance = 60.0
        sun.shadow_blur = 0.65
        add_child(sun)
        _build_boss_drone()
        # Apply a complete native rendering budget immediately; Telemetry will then
        # replace this high-quality default with the detected device tier.
        set_perf_profile(_perf_profile)

## BOSS 哨戒机 3D 化：赛道上空悬停的巨型猎杀单元（boss_started/survived 驱动）
func _build_boss_drone() -> void:
        _boss_drone = Node3D.new()
        _boss_drone.name = "SentinelBossRoot"
        _boss_drone.visible = false
        add_child(_boss_drone)

        # Imported low-poly PBR model replaces the old three-box boss silhouette.
        # It is a real GLB scene with separate material groups, not a promotional image.
        var boss_model: Node3D = BOSS_MODEL_SCENE.instantiate() as Node3D
        if boss_model != null:
                boss_model.name = "SentinelBossModel"
                _set_model_shadows(boss_model, false)
                _apply_pbr_detail(boss_model)
                _boss_drone.add_child(boss_model)

        # Preserve the existing gameplay feedback: the transparent scan cone remains
        # attached to the same boss root and is still hidden/shown by boss_show.
        var cone := MeshInstance3D.new()
        var cm := CylinderMesh.new()
        cm.top_radius = 0.5
        cm.bottom_radius = 3.4
        cm.height = 7.0
        cm.radial_segments = 32
        cone.mesh = cm
        var cmat := StandardMaterial3D.new()
        cmat.albedo_color = Color(1, 0.13, 0.2, 0.10)
        cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        cmat.emission_enabled = true
        cmat.emission = Color(1, 0.13, 0.2)
        cmat.emission_energy_multiplier = 0.65
        cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
        cone.material_override = cmat
        cone.position = Vector3(0, -4.0, 0.45)
        cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _boss_drone.add_child(cone)

        # Keep the established boss framing and movement path unchanged.
        _boss_drone.position = Vector3(0, 6.2, -46)
        _boss_drone.reset_physics_interpolation()

func _set_model_shadows(node: Node, enabled: bool) -> void:
        if node is GeometryInstance3D:
                (node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        for child in node.get_children():
                _set_model_shadows(child, enabled)

func _apply_pbr_detail(node: Node) -> void:
        # Imported GLB surfaces have their own base colors/emission. Enrich only opaque,
        # non-emissive StandardMaterial3D surfaces with the seamless micro-detail PBR set.
        # This is safe only because the model generator guarantees TEXCOORD_0 on every group.
        if node is MeshInstance3D:
                var mesh_instance := node as MeshInstance3D
                if mesh_instance.mesh != null:
                        for surface_idx in mesh_instance.mesh.get_surface_count():
                                var source_material: Material = mesh_instance.get_active_material(surface_idx)
                                if source_material is StandardMaterial3D:
                                        var source_standard := source_material as StandardMaterial3D
                                        if source_standard.emission_enabled or source_standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
                                                continue
                                        var detailed := source_standard.duplicate() as StandardMaterial3D
                                        # The procedural GLBs carry 2x2 pure-white albedo placeholders only
                                        # to force TEXCOORD_0 export. Remove that redundant sampler while
                                        # keeping albedo_color (the authored faction/chapter tint) intact.
                                        # If a future model adds a real albedo texture, preserve it.
                                        var base_texture := detailed.albedo_texture
                                        if base_texture != null and base_texture.get_width() == 2 and base_texture.get_height() == 2 and base_texture.resource_path.begins_with("res://assets/models/"):
                                                detailed.albedo_texture = null
                                        # Use Godot's native detail layer for engraved ceramic/metal seams.
                                        # The albedo alpha masks both detail color and detail normal, leaving base normals intact.
                                        # This is important for imported GLBs: never replace an authored normal map.
                                        detailed.detail_enabled = true
                                        detailed.detail_albedo = ARMOR_ALBEDO
                                        detailed.detail_normal = ARMOR_NORMAL
                                        detailed.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
                                        # Never discard an authored GLB roughness map; use the shared
                                        # micro-roughness only when the source material has no map.
                                        if detailed.roughness_texture == null:
                                                detailed.roughness_texture = ARMOR_ROUGHNESS
                                        # GLB UVs are normalized over each material batch. Repeating the
                                        # tileable micro-surface map makes brushed alloy/ceramic detail
                                        # visible on the model without adding geometry or draw calls.
                                        detailed.uv1_scale = Vector3(0.85, 0.85, 1.0)
                                        mesh_instance.set_surface_override_material(surface_idx, detailed)
        for child in node.get_children():
                _apply_pbr_detail(child)

func _register_themeable_materials(node: Node) -> void:
        # Store stable base colors once so chapter tinting never compounds frame to frame.
        if node is MeshInstance3D:
                var mesh_instance := node as MeshInstance3D
                if mesh_instance.mesh != null:
                        for surface_idx in mesh_instance.mesh.get_surface_count():
                                var source: Material = mesh_instance.get_active_material(surface_idx)
                                if not source is StandardMaterial3D:
                                        continue
                                var themed := (source as StandardMaterial3D).duplicate() as StandardMaterial3D
                                mesh_instance.set_surface_override_material(surface_idx, themed)
                                _themeable_materials.append({
                                        "material": themed,
                                        "base_albedo": themed.albedo_color,
                                        "base_emission": themed.emission,
                                        "emission_enabled": themed.emission_enabled,
                                })
        for child in node.get_children():
                _register_themeable_materials(child)

func boss_show(on: bool) -> void:
        _boss_drone.visible = on

func _build_road() -> void:
        # 赛博跑道：碳陶装甲板、能量导流线、同步标记与主题色电路
        _grid_mat = ShaderMaterial.new()
        _grid_mat.shader = preload("res://world/road_grid.gdshader")
        _grid_mat.set_shader_parameter("grid_color", Config.PALETTE.cyan)
        _grid_mat.set_shader_parameter("bg_color", Color(0.025, 0.035, 0.075))
        _grid_mat.set_shader_parameter("road_albedo_tex", preload("res://assets/textures/cyber_deck_albedo.png"))
        _grid_mat.set_shader_parameter("road_normal_tex", preload("res://assets/textures/cyber_deck_normal.png"))
        _grid_mat.set_shader_parameter("normal_strength", 0.62)
        _grid_mat.set_shader_parameter("grid_strength", 0.90)
        _road_cycle_length = maxf(float(Config.WORLD.roadCycleLength), 1.0)
        _grid_mat.set_shader_parameter("road_cycle_length", _road_cycle_length)
        _grid_mat.set_shader_parameter("scroll", 0.0)
        var pm := PlaneMesh.new()
        pm.size = Vector2(9.2, ROAD_DECK_LENGTH)
        pm.subdivide_depth = 2
        var mi := MeshInstance3D.new()
        mi.mesh = pm
        mi.material_override = _grid_mat
        mi.position.z = ROAD_DECK_CENTER_Z
        add_child(mi)
        # Machined deck lips and dual-spectrum energy tubing define the three-lane silhouette at phone size.
        var curb_mat := StandardMaterial3D.new()
        curb_mat.albedo_color = Color("172238")
        curb_mat.metallic = 0.78
        curb_mat.roughness = 0.31
        var left_edge_mat := _make_city_material(Color("00E8FF"), 0.0, 0.32, 1.8)
        var right_edge_mat := _make_city_material(Color("FF2B88"), 0.0, 0.32, 1.6)
        for side in [-1.0, 1.0]:
                var curb := MeshInstance3D.new()
                var curb_mesh := BoxMesh.new()
                curb_mesh.size = Vector3(0.18, 0.18, ROAD_DECK_LENGTH)
                curb.mesh = curb_mesh
                curb.material_override = curb_mat
                curb.position = Vector3(side * 4.50, 0.075, ROAD_DECK_CENTER_Z)
                curb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                add_child(curb)
                var edge_tube := MeshInstance3D.new()
                var tube_mesh := BoxMesh.new()
                tube_mesh.size = Vector3(0.027, 0.026, ROAD_DECK_LENGTH)
                edge_tube.mesh = tube_mesh
                edge_tube.material_override = left_edge_mat if side < 0.0 else right_edge_mat
                edge_tube.position = Vector3(side * 4.39, 0.166, ROAD_DECK_CENTER_Z)
                edge_tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                add_child(edge_tube)
        # 车道能量导轨（2 条）
        for lx in [-1.15, 1.15]:
                var line := MeshInstance3D.new()
                var qm := QuadMesh.new()
                qm.size = Vector2(0.08, ROAD_DECK_LENGTH)
                line.mesh = qm
                var m := StandardMaterial3D.new()
                m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
                m.albedo_color = Config.PALETTE.cyan
                m.emission_enabled = true
                m.emission = Config.PALETTE.cyan
                m.emission_energy_multiplier = 2.6
                m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                m.cull_mode = BaseMaterial3D.CULL_DISABLED
                line.material_override = m
                line.rotation.x = -PI / 2
                line.position = Vector3(lx, 0.012, ROAD_DECK_CENTER_Z)
                add_child(line)
                _lane_lines.append(line)
        _build_road_deck_hardware()

func _build_road_deck_hardware() -> void:
        # Physically modeled panel ribs + recessed titanium fasteners add close-range
        # specular cues while keeping the entire deck detail to two instanced draw calls.
        # Eight detail rows fit exactly in the 42 m shader cycle, so rebasing is seamless.
        _deck_hardware_root = Node3D.new()
        _deck_hardware_root.name = "RoadDeckHardware"
        add_child(_deck_hardware_root)

        var row_pitch: float = _road_cycle_length / 8.0
        var row_count: int = int(ceil((ROAD_DECK_LENGTH + _road_cycle_length) / row_pitch))
        _deck_hardware_instances = row_count
        var first_row_z: float = ROAD_DECK_CENTER_Z + ROAD_DECK_LENGTH * 0.5 - row_pitch * 0.5

        var rib_mesh := BoxMesh.new()
        rib_mesh.size = Vector3(8.76, 0.018, 0.036)
        var rib_material := StandardMaterial3D.new()
        rib_material.albedo_color = Color("142238")
        rib_material.metallic = 0.84
        rib_material.roughness = 0.28
        var ribs := MultiMesh.new()
        ribs.transform_format = MultiMesh.TRANSFORM_3D
        ribs.mesh = rib_mesh
        ribs.instance_count = row_count
        var rib_instance := MultiMeshInstance3D.new()
        rib_instance.name = "MachinedDeckRibs"
        rib_instance.multimesh = ribs
        rib_instance.material_override = rib_material
        rib_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _deck_hardware_root.add_child(rib_instance)

        var fastener_mesh := CylinderMesh.new()
        fastener_mesh.top_radius = 0.045
        fastener_mesh.bottom_radius = 0.052
        fastener_mesh.height = 0.012
        fastener_mesh.radial_segments = 8
        var fastener_material := StandardMaterial3D.new()
        fastener_material.albedo_color = Color("8EA8C4")
        fastener_material.metallic = 0.9
        fastener_material.roughness = 0.23
        var fasteners := MultiMesh.new()
        fasteners.transform_format = MultiMesh.TRANSFORM_3D
        fasteners.mesh = fastener_mesh
        var lane_fastener_x: Array[float] = [-3.08, -1.52, -0.78, 0.78, 1.52, 3.08]
        fasteners.instance_count = row_count * lane_fastener_x.size()
        var fastener_instance := MultiMeshInstance3D.new()
        fastener_instance.name = "TitaniumDeckFasteners"
        fastener_instance.multimesh = fasteners
        fastener_instance.material_override = fastener_material
        fastener_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _deck_hardware_root.add_child(fastener_instance)

        var instance_index := 0
        for row in row_count:
                var row_z: float = first_row_z - float(row) * row_pitch
                ribs.set_instance_transform(row, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.009, row_z)))
                for x in lane_fastener_x:
                        fasteners.set_instance_transform(instance_index, Transform3D(Basis.IDENTITY, Vector3(x, 0.024, row_z)))
                        instance_index += 1
        ribs.reset_instances_physics_interpolation()
        fasteners.reset_instances_physics_interpolation()
        _deck_hardware_root.reset_physics_interpolation()

func _build_buildings() -> void:
        # 城市建筑与窗格以 MultiMesh 和共享 Shader 批量渲染，控制绘制调用与材质数量。
        _building_mat = ShaderMaterial.new()
        _building_mat.shader = preload("res://world/building_windows.gdshader")
        _building_mat.set_shader_parameter("base_color", Color("0B0B22"))
        _building_mat.set_shader_parameter("window_color", Color("FFD9A0"))
        _building_mat.set_shader_parameter("neon_color", Config.PALETTE.cyan)
        _building_root = Node3D.new()
        _building_root.name = "BuildingCityRoot"
        add_child(_building_root)
        var mm := MultiMesh.new()
        mm.transform_format = MultiMesh.TRANSFORM_3D
        mm.mesh = BoxMesh.new()
        # Per-instance custom data breaks the identical window grids across all 96 towers.
        # This must be enabled before instance_count, as required by MultiMesh.
        mm.use_custom_data = true
        mm.instance_count = BUILDING_COUNT
        var mmi := MultiMeshInstance3D.new()
        mmi.multimesh = mm
        mmi.material_override = _building_mat
        # Hundreds of moving city surfaces do not need real-time shadow casting on mobile.
        # Character/BOSS silhouettes keep their own shadow decisions.
        mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _building_root.add_child(mmi)
        _buildings = mmi
        # 楼群布局：两侧 6.2-16m，滚动回收
        _building_rng.seed = 2099
        _detail_rng.seed = 73421
        for i in BUILDING_COUNT:
                var side: float = -1.0 if i % 2 == 0 else 1.0
                var h: float = _building_rng.randf_range(Config.WORLD.buildingMinH, Config.WORLD.buildingMaxH)
                var width: float = _building_rng.randf_range(3.0, 6.0)
                var depth: float = _building_rng.randf_range(3.0, 6.0)
                var pos := Vector3(side * _building_rng.randf_range(7.5, 17.0), h / 2.0, -fmod(i * 12.5, 200.0) - _building_rng.randf_range(0, 8))
                var t := Transform3D(Basis().scaled(Vector3(width, h, depth)), pos)
                mm.set_instance_transform(i, t)
                _building_local_z.append(pos.z)
                # R/G/B/A encode seed, warmth, local contrast, and window-density variation.
                mm.set_instance_custom_data(i, Color(_building_rng.randf(), _building_rng.randf(), _building_rng.randf(), _building_rng.randf()))
                _building_detail_flags.append(_new_building_detail_flags(width, h, depth))
        # Initial placement happens after the MultiMesh node has entered the scene tree.
        # Reset the native interpolation buffers once so the first rendered frame cannot
        # blend from MultiMesh's default transforms into the authored city layout.
        mm.reset_instances_physics_interpolation()
        # Initial local-Z values define one sorted recycle threshold per tower.
        # Every tower is recycled once before the 220 m root rebase, so the queue
        # can reset to the same thresholds without scanning all 96 towers each tick.
        _building_recycle_events.clear()
        for slot in _building_local_z.size():
                _building_recycle_events.append({"slot": slot, "threshold": 18.0 - _building_local_z[slot]})
        _building_recycle_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
                return float(a.threshold) < float(b.threshold)
        )
        _building_recycle_pointer = 0
        _build_building_details()

func _build_far_skyline() -> void:
        # Three procedural silhouette families break the single-box horizon while keeping
        # the total count at 80 and using only three instanced draw groups.
        var rng := RandomNumberGenerator.new()
        rng.seed = 2099_77
        var meshes: Array[Mesh] = []
        meshes.append(BoxMesh.new())
        var cylinder_mesh := CylinderMesh.new()
        cylinder_mesh.height = 1.0
        cylinder_mesh.top_radius = 0.40
        cylinder_mesh.bottom_radius = 0.50
        cylinder_mesh.radial_segments = 8
        cylinder_mesh.rings = 2
        meshes.append(cylinder_mesh)
        var spire_mesh := CylinderMesh.new()
        spire_mesh.height = 1.0
        spire_mesh.top_radius = 0.035
        spire_mesh.bottom_radius = 0.50
        spire_mesh.radial_segments = 7
        spire_mesh.rings = 2
        meshes.append(spire_mesh)
        var transforms: Array = [[], [], []]
        for i in 80:
                var side: float = -1.0 if i % 2 == 0 else 1.0
                var height: float = rng.randf_range(18.0, 58.0)
                var width: float = rng.randf_range(3.0, 8.0)
                var depth: float = rng.randf_range(3.0, 10.0)
                var x_pos: float = side * rng.randf_range(19.0, 66.0)
                var z_pos: float = -120.0 - rng.randf_range(0.0, 210.0)
                var xf := Transform3D(Basis().scaled(Vector3(width, height, depth)), Vector3(x_pos, height * 0.5, z_pos))
                transforms[i % 3].append(xf)
        for group_idx in 3:
                var mm := MultiMesh.new()
                mm.transform_format = MultiMesh.TRANSFORM_3D
                mm.mesh = meshes[group_idx]
                mm.use_custom_data = true
                mm.instance_count = transforms[group_idx].size()
                var skyline_local_zs: Array[float] = []
                for slot in mm.instance_count:
                        var instance_xf: Transform3D = transforms[group_idx][slot]
                        mm.set_instance_transform(slot, instance_xf)
                        skyline_local_zs.append(instance_xf.origin.z)
                        mm.set_instance_custom_data(slot, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
                var mmi := MultiMeshInstance3D.new()
                mmi.name = ["FarBoxTowers", "FarCylindricalTowers", "FarSpireTowers"][group_idx]
                mmi.multimesh = mm
                mmi.material_override = _building_mat
                mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                add_child(mmi)
                mm.reset_instances_physics_interpolation()
                _far_skylines.append(mmi)
                _far_skyline_local_z.append(skyline_local_zs)
                # A sorted event queue replaces scanning all 26-27 skyline meshes
                # every frame. Thresholds are based on immutable initial local-Z values;
                # each event fires once per 230 m root cycle and the cursor then advances.
                var recycle_events: Array[Dictionary] = []
                for slot in mm.instance_count:
                        recycle_events.append({"slot": slot, "threshold": -105.0 - skyline_local_zs[slot]})
                recycle_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
                        return float(a.threshold) < float(b.threshold)
                )
                _far_skyline_recycle_events.append(recycle_events)
                _far_skyline_recycle_pointer.append(0)

func _update_far_skyline(spd: float, dt: float) -> void:
        # Move each skyline family as a single root and process only towers whose
        # recycle threshold has actually been crossed. Normal ticks do O(1) threshold
        # checks per family instead of scanning all 80 local-Z values every frame.
        var dz: float = maxf(spd, 0.0) * dt * 0.22
        for skyline_idx in _far_skylines.size():
                var skyline: MultiMeshInstance3D = _far_skylines[skyline_idx]
                if not is_instance_valid(skyline) or skyline.multimesh == null:
                        continue
                skyline.position.z += dz
                var mm: MultiMesh = skyline.multimesh
                var local_zs: Array = _far_skyline_local_z[skyline_idx]
                var recycle_events: Array = _far_skyline_recycle_events[skyline_idx]
                var event_cursor: int = _far_skyline_recycle_pointer[skyline_idx]
                var did_rebase: bool = false
                # The while also handles a frame that crosses multiple tower thresholds.
                while true:
                        while event_cursor < recycle_events.size() and skyline.position.z > float(recycle_events[event_cursor].threshold):
                                var slot: int = int(recycle_events[event_cursor].slot)
                                var local_z: float = float(local_zs[slot]) - 230.0
                                local_zs[slot] = local_z
                                var xf: Transform3D = mm.get_instance_transform(slot)
                                xf.origin.z = local_z
                                mm.set_instance_transform(slot, xf)
                                mm.reset_instance_physics_interpolation(slot)
                                event_cursor += 1
                        if skyline.position.z < 230.0:
                                break
                        # Rebase all local transforms only once per complete root cycle.
                        # Split very large dt jumps into cycles instead of accumulating drift.
                        skyline.position.z -= 230.0
                        did_rebase = true
                        for slot in local_zs.size():
                                var rebased_z: float = float(local_zs[slot]) + 230.0
                                local_zs[slot] = rebased_z
                                var xf: Transform3D = mm.get_instance_transform(slot)
                                xf.origin.z = rebased_z
                                mm.set_instance_transform(slot, xf)
                                mm.reset_instance_physics_interpolation(slot)
                        event_cursor = 0
                if did_rebase:
                        skyline.reset_physics_interpolation()
                _far_skyline_recycle_pointer[skyline_idx] = event_cursor

func _new_building_detail_flags(width: float, height: float, depth: float) -> Dictionary:
        return {
                "top": _detail_rng.randf() < 0.28,
                "top_h": _detail_rng.randf_range(0.8, 2.4),
                "top_sx": _detail_rng.randf_range(0.42, 0.78),
                "top_sz": _detail_rng.randf_range(0.48, 0.86),
                "top_dx": _detail_rng.randf_range(-width * 0.12, width * 0.12),
                "top_dz": _detail_rng.randf_range(-depth * 0.12, depth * 0.12),
                "mast": _detail_rng.randf() < 0.30,
                "mast_h": _detail_rng.randf_range(0.7, 2.3),
                "beacon": _detail_rng.randf() < 0.22,
                "roof": _detail_rng.randf() < 0.46,
                "roof_sx": _detail_rng.randf_range(0.38, 0.95),
                "roof_sz": _detail_rng.randf_range(0.35, 0.85),
                "roof_dx": _detail_rng.randf_range(-width * 0.18, width * 0.18),
                "roof_dz": _detail_rng.randf_range(-depth * 0.18, depth * 0.18),
                "edge_l": _detail_rng.randf() < 0.36,
                "edge_r": _detail_rng.randf() < 0.36,
                # A 3-bit layout gives each building a different number/placement of facade ledges.
                "shelf_mask": _detail_rng.randi_range(1, 7),
                "height": height,
        }

func _make_detail_multimesh(mesh: Mesh, mat: Material, count: int, node_name: String) -> MultiMeshInstance3D:
        var mm := MultiMesh.new()
        mm.transform_format = MultiMesh.TRANSFORM_3D
        mm.mesh = mesh
        mm.instance_count = count
        var mmi := MultiMeshInstance3D.new()
        mmi.name = node_name
        mmi.multimesh = mm
        mmi.material_override = mat
        mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        _building_root.add_child(mmi)
        return mmi

func _build_building_details() -> void:
        # Instanced rooftop hardware, facade rails, and sparse horizontal ledges create varied silhouettes with a fixed small set of extra draw calls.
        var mast_mesh := CylinderMesh.new()
        mast_mesh.top_radius = 0.035
        mast_mesh.bottom_radius = 0.055
        mast_mesh.height = 1.0
        mast_mesh.radial_segments = 8
        var roof_mesh := BoxMesh.new()
        roof_mesh.size = Vector3(0.8, 0.28, 0.65)
        var top_mesh := BoxMesh.new()
        top_mesh.size = Vector3.ONE
        var beacon_mesh := SphereMesh.new()
        beacon_mesh.radius = 0.5
        beacon_mesh.height = 1.0
        beacon_mesh.radial_segments = 12
        beacon_mesh.rings = 8
        var facade_mesh := BoxMesh.new()
        facade_mesh.size = Vector3(0.035, 1.0, 0.028)
        _building_masts = _make_detail_multimesh(mast_mesh, _make_city_material(Color("1A2A42"), 0.72, 0.32), BUILDING_COUNT, "BuildingAntennae")
        _building_tops = _make_detail_multimesh(top_mesh, _make_city_material(Color("253247"), 0.76, 0.38), BUILDING_COUNT, "BuildingSteppedTops")
        _building_roofs = _make_detail_multimesh(roof_mesh, _make_city_material(Color("11192B"), 0.78, 0.36), BUILDING_COUNT, "BuildingRoofUnits")
        _building_beacons = _make_detail_multimesh(beacon_mesh, _make_city_material(Color("FF8A42"), 0.0, 0.38, 2.2), BUILDING_COUNT, "BuildingBeaconLights")
        _building_facades = _make_detail_multimesh(facade_mesh, _make_city_material(Color("00DDF8"), 0.0, 0.36, 1.8), BUILDING_COUNT * 2, "BuildingNeonEdgeRails")
        var shelf_mesh := BoxMesh.new()
        shelf_mesh.size = Vector3(1.0, 0.055, 0.11)
        var shelf_mat := _make_city_material(Color("26364A"), 0.82, 0.42, 0.08)
        _building_shelves = _make_detail_multimesh(shelf_mesh, shelf_mat, BUILDING_COUNT * 3, "BuildingFacadeShelves")
        for i in BUILDING_COUNT:
                _write_building_detail_transforms(i, _buildings.multimesh.get_instance_transform(i), _building_detail_flags[i])
        for detail_instance in [_building_masts, _building_tops, _building_roofs, _building_beacons, _building_facades, _building_shelves]:
                if detail_instance != null and detail_instance.multimesh != null:
                        detail_instance.multimesh.reset_instances_physics_interpolation()

func _write_building_detail_transforms(index: int, base: Transform3D, flags: Dictionary) -> void:
        var dim: Vector3 = base.basis.get_scale()
        var base_roof_y: float = base.origin.y + dim.y * 0.5
        var top_y: float = base_roof_y
        var zero := Transform3D(Basis().scaled(Vector3.ZERO), base.origin)
        if flags.top:
                var top_h: float = float(flags.top_h)
                var top_basis: Basis = Basis().scaled(Vector3(dim.x * float(flags.top_sx), top_h, dim.z * float(flags.top_sz)))
                var top_pos: Vector3 = Vector3(base.origin.x + float(flags.top_dx), base_roof_y + top_h * 0.5, base.origin.z + float(flags.top_dz))
                _building_tops.multimesh.set_instance_transform(index, Transform3D(top_basis, top_pos))
                top_y += top_h
        else:
                _building_tops.multimesh.set_instance_transform(index, zero)
        _building_tops.multimesh.reset_instance_physics_interpolation(index)
        if flags.mast:
                var mh: float = float(flags.mast_h)
                _building_masts.multimesh.set_instance_transform(index, Transform3D(Basis().scaled(Vector3(0.10, mh, 0.10)), Vector3(base.origin.x, top_y + mh * 0.5, base.origin.z)))
        else:
                _building_masts.multimesh.set_instance_transform(index, zero)
        _building_masts.multimesh.reset_instance_physics_interpolation(index)
        if flags.beacon and flags.mast:
                var mh2: float = float(flags.mast_h)
                _building_beacons.multimesh.set_instance_transform(index, Transform3D(Basis().scaled(Vector3(0.13, 0.13, 0.13)), Vector3(base.origin.x, top_y + mh2, base.origin.z)))
                _building_beacons.multimesh.reset_instance_physics_interpolation(index)
        elif flags.beacon:
                _building_beacons.multimesh.set_instance_transform(index, Transform3D(Basis().scaled(Vector3(0.13, 0.13, 0.13)), Vector3(base.origin.x, top_y + 0.10, base.origin.z)))
                _building_beacons.multimesh.reset_instance_physics_interpolation(index)
        else:
                _building_beacons.multimesh.set_instance_transform(index, zero)
                _building_beacons.multimesh.reset_instance_physics_interpolation(index)
        if flags.roof:
                var roof_basis: Basis = Basis().scaled(Vector3(float(flags.roof_sx), 1.0, float(flags.roof_sz)))
                var roof_pos: Vector3 = Vector3(base.origin.x + float(flags.roof_dx), top_y + 0.15, base.origin.z + float(flags.roof_dz))
                _building_roofs.multimesh.set_instance_transform(index, Transform3D(roof_basis, roof_pos))
        else:
                _building_roofs.multimesh.set_instance_transform(index, zero)
        _building_roofs.multimesh.reset_instance_physics_interpolation(index)
        for side_idx in 2:
                var side: float = -1.0 if side_idx == 0 else 1.0
                var active: bool = flags.edge_l
                if side_idx == 1:
                        active = flags.edge_r
                var idx: int = index * 2 + side_idx
                if active:
                        var rail_pos := Vector3(base.origin.x + side * dim.x * 0.465, base.origin.y, base.origin.z + dim.z * 0.505)
                        var rail_basis := Basis().scaled(Vector3(1.0, dim.y * 0.74, 1.0))
                        _building_facades.multimesh.set_instance_transform(idx, Transform3D(rail_basis, rail_pos))
                        _building_facades.multimesh.reset_instance_physics_interpolation(idx)
                else:
                        _building_facades.multimesh.set_instance_transform(idx, zero)
                        _building_facades.multimesh.reset_instance_physics_interpolation(idx)
        # Low-profile facade ledges catch highlights and break up the repeated flat box silhouette.
        var shelf_mask: int = int(flags.shelf_mask)
        for band_idx in 3:
                var shelf_idx: int = index * 3 + band_idx
                if (shelf_mask & (1 << band_idx)) != 0:
                        var fraction: float = 0.24 if band_idx == 0 else (0.53 if band_idx == 1 else 0.79)
                        var shelf_y: float = base.origin.y - dim.y * 0.5 + dim.y * fraction
                        var shelf_pos := Vector3(base.origin.x, shelf_y, base.origin.z + dim.z * 0.5 + 0.025)
                        var shelf_basis := Basis().scaled(Vector3(dim.x * 0.92, 1.0, 1.0))
                        _building_shelves.multimesh.set_instance_transform(shelf_idx, Transform3D(shelf_basis, shelf_pos))
                        _building_shelves.multimesh.reset_instance_physics_interpolation(shelf_idx)
                else:
                        _building_shelves.multimesh.set_instance_transform(shelf_idx, zero)
                        _building_shelves.multimesh.reset_instance_physics_interpolation(shelf_idx)

func _make_city_material(color: Color, metallic: float, roughness: float, emission: float = 0.0) -> StandardMaterial3D:
        var mat := StandardMaterial3D.new()
        mat.albedo_color = color
        mat.metallic = metallic
        mat.roughness = roughness
        if emission <= 0.0:
                mat.detail_enabled = true
                mat.detail_albedo = ARMOR_ALBEDO
                mat.detail_normal = ARMOR_NORMAL
                mat.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
                mat.roughness_texture = ARMOR_ROUGHNESS
                mat.uv1_scale = Vector3(0.80, 0.80, 1.0)
        if emission > 0.0:
                mat.emission_enabled = true
                mat.emission = color
                mat.emission_energy_multiplier = emission
        return mat

func _build_landmarks() -> void:
        # Three distinct imported landmark silhouettes break the repeated box skyline.
        # Each GLB batches geometry by PBR material; four instances stay inexpensive.
        var scenes: Array[PackedScene] = [NEON_LANDMARK_SCENE, NEON_ARCOLOGY_SCENE, NEON_SPIRE_SCENE]
        var placements: Array[Dictionary] = [
                {"x": -28.0, "z": -76.0, "scale": 0.58},
                {"x":  30.0, "z": -148.0, "scale": 0.62},
                {"x": -32.0, "z": -226.0, "scale": 0.62},
                {"x":  27.0, "z": -294.0, "scale": 0.66},
        ]
        for i in placements.size():
                var data: Dictionary = placements[i]
                var landmark: Node3D = scenes[i % scenes.size()].instantiate() as Node3D
                if landmark == null:
                        continue
                landmark.name = "NeonLandmark_%02d" % i
                var scale_value: float = float(data.scale)
                landmark.scale = Vector3.ONE * scale_value
                landmark.position = Vector3(float(data.x), 0.0, float(data.z))
                _set_model_shadows(landmark, false)
                _apply_pbr_detail(landmark)
                _register_themeable_materials(landmark)
                add_child(landmark)
                landmark.reset_physics_interpolation()
                _landmarks.append(landmark)
                _landmark_data.append({"x": float(data.x), "z": float(data.z), "scale": scale_value, "kind": i % scenes.size(), "phase": float(i) * 1.7})

func _landmark_profile(theme_key: Variant, kind: int) -> float:
        # Config.THEMES[].landmark now has a visible effect while all skyline silhouettes remain present.
        if not theme_key is String:
                return 1.0
        match String(theme_key):
                "billboard": return 1.14 if kind == 0 else 0.96
                "platform": return 1.14 if kind == 1 else 0.96
                "tesla": return 1.14 if kind == 2 else 0.96
                "towers": return 1.10 if kind != 0 else 0.94
                _: return 1.0

func _update_landmarks(spd: float, dt: float) -> void:
        # Distant structures move slowly to reinforce perspective without competing
        # with gameplay objects; wrap deterministically to avoid accumulating drift.
        for i in _landmarks.size():
                var landmark: Node3D = _landmarks[i]
                var data: Dictionary = _landmark_data[i]
                var z_pos: float = float(data.z) + spd * dt * 0.24
                var wrapped: bool = z_pos > 20.0
                if wrapped:
                        z_pos -= 350.0
                data.z = z_pos
                landmark.position = Vector3(float(data.x) + sin(time * 0.18 + float(data.phase)) * 0.35, 0.0, z_pos)
                landmark.rotation.y = sin(time * 0.16 + float(data.phase)) * 0.015
                var profile_a: float = _landmark_profile(_theme_from.get("landmark", null), int(data.kind))
                var profile_b: float = _landmark_profile(_theme_to.get("landmark", null), int(data.kind))
                var profile: float = lerpf(profile_a, profile_b, _theme_mix)
                var target_scale: float = float(data.scale) * profile
                # Chapter profile moves at themeUpdateHz, not every render frame. Do
                # not dirty the imported GLB transform when scale remains identical.
                if not is_equal_approx(landmark.scale.x, target_scale):
                        landmark.scale = Vector3.ONE * target_scale
                if wrapped:
                        landmark.reset_physics_interpolation()

func _build_air_traffic() -> void:
        # Three distinct GLB craft replace the old repeated sphere/box shuttles.
        # Meshes are merged by PBR material in the generator to limit draw calls.
        var scenes: Array[PackedScene] = [SKY_COURIER_SCENE, CARGO_SKIMMER_SCENE, PATROL_INTERCEPTOR_SCENE]
        var labels: Array[String] = ["SkyCourier", "CargoSkimmer", "PatrolInterceptor"]
        var scales: Array[float] = [0.86, 0.76, 0.82]
        var start_x: Array[float] = [-9.0, 8.5, 12.0]
        var start_y: Array[float] = [5.8, 8.0, 4.4]
        var start_z: Array[float] = [-38.0, -91.0, -142.0]
        for i in scenes.size():
                var craft := Node3D.new()
                craft.name = "%s_%02d" % [labels[i], i]
                craft.position = Vector3(start_x[i], start_y[i], start_z[i])
                craft.rotation.y = 0.05 if i % 2 == 0 else -0.08
                var model: Node3D = scenes[i].instantiate() as Node3D
                if model == null:
                        craft.free()
                        continue
                model.scale = Vector3.ONE * scales[i]
                _set_model_shadows(model, false)
                _apply_pbr_detail(model)
                _register_themeable_materials(model)
                craft.add_child(model)
                add_child(craft)
                craft.reset_physics_interpolation()
                _air_traffic.append(craft)
                _air_traffic_data.append({"x": start_x[i], "y": start_y[i], "z": start_z[i], "phase": float(i) * 2.1, "speed": 0.22 + float(i) * 0.035})

func _build_gates() -> void:
        # 数据拱门：细密的主题主环、双谱能量副环与批处理识别刻度。
        _gate_mat = StandardMaterial3D.new()
        _gate_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _gate_mat.albedo_color = Color(Config.PALETTE.purple.r, Config.PALETTE.purple.g, Config.PALETTE.purple.b, 0.34)
        _gate_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        _gate_mat.emission_enabled = true
        _gate_mat.emission = Config.PALETTE.purple
        _gate_mat.emission_energy_multiplier = 1.25
        for i in GATE_COUNT:
                var g := MeshInstance3D.new()
                g.name = "CyberEnergyGate_%02d" % i
                var tm := TorusMesh.new()
                tm.inner_radius = 2.56
                tm.outer_radius = 2.82
                tm.rings = 48
                tm.ring_segments = 12
                g.mesh = tm
                # Each gate owns its alpha because the near-camera fade is independent per gate.
                g.material_override = _gate_mat.duplicate()
                g.set_meta("gate_base_alpha", 0.34)
                g.set_meta("gate_near_alpha", 0.06)
                g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                g.position = Vector3(3.6, 4.4, -i * GATE_GAP - 30.0)
                # TorusMesh lies in XZ around Godot's Y-up axis; rotate it upright to face the runner.
                g.rotation_degrees = Vector3(76, 18, 0)
                add_child(g)

                var inner_ring := MeshInstance3D.new()
                inner_ring.name = "GateCyanConduit"
                var inner_torus := TorusMesh.new()
                inner_torus.inner_radius = 2.40
                inner_torus.outer_radius = 2.49
                inner_torus.rings = 48
                inner_torus.ring_segments = 10
                inner_ring.mesh = inner_torus
                # Offset along the ring normal (local Y), not the ring plane, to avoid z-fighting.
                inner_ring.position.y = 0.045
                var inner_mat := _make_city_material(Color("00EFFF"), 0.0, 0.25, 1.55)
                inner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                inner_ring.material_override = inner_mat
                inner_ring.set_meta("gate_base_alpha", 0.92)
                inner_ring.set_meta("gate_near_alpha", 0.18)
                inner_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                g.add_child(inner_ring)

                var outer_ring := MeshInstance3D.new()
                outer_ring.name = "GateMagentaConduit"
                var outer_torus := TorusMesh.new()
                outer_torus.inner_radius = 2.92
                outer_torus.outer_radius = 3.01
                outer_torus.rings = 48
                outer_torus.ring_segments = 10
                outer_ring.mesh = outer_torus
                outer_ring.position.y = -0.045
                var outer_mat := _make_city_material(Color("FF2B88"), 0.0, 0.27, 1.35)
                outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                outer_ring.material_override = outer_mat
                outer_ring.set_meta("gate_base_alpha", 0.88)
                outer_ring.set_meta("gate_near_alpha", 0.16)
                outer_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                g.add_child(outer_ring)

                # Eight slim identity ticks in one MultiMesh draw keep the complex portal cheap.
                var marker_multi := MultiMesh.new()
                marker_multi.transform_format = MultiMesh.TRANSFORM_3D
                var marker_box := BoxMesh.new()
                marker_box.size = Vector3(0.22, 0.10, 0.065)
                marker_multi.mesh = marker_box
                marker_multi.instance_count = 8
                for marker_idx in 8:
                        var angle := TAU * float(marker_idx) / 8.0
                        var marker_position := Vector3(cos(angle) * 2.70, 0.075, sin(angle) * 2.70)
                        var marker_basis := Basis(Vector3(0.0, 1.0, 0.0), angle + PI / 2.0)
                        marker_multi.set_instance_transform(marker_idx, Transform3D(marker_basis, marker_position))
                var marker_instance := MultiMeshInstance3D.new()
                marker_instance.name = "GateSignalTicks"
                marker_instance.multimesh = marker_multi
                var marker_mat := _make_city_material(Color("BDFBFF"), 0.0, 0.24, 1.2)
                marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                marker_instance.material_override = marker_mat
                marker_instance.set_meta("gate_base_alpha", 0.90)
                marker_instance.set_meta("gate_near_alpha", 0.18)
                marker_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                g.add_child(marker_instance)
                g.reset_physics_interpolation()
                marker_multi.reset_instances_physics_interpolation()
                _gates.append(g)

# ---------- 帧更新 ----------

func update(dt: float, spd: float, state: String) -> void:
        # Store two fixed-step samples. Shader uniforms aren't Node transforms, so the
        # native renderer can't interpolate them automatically between physics ticks.
        _time_previous = time
        _time_step = maxf(dt, 0.0)
        time += dt
        # Integrate travelled distance instead of multiplying absolute time by the current
        # speed; preserve a wrap-safe delta for smooth shader animation at high refresh rates.
        _road_distance_previous = _road_distance
        _road_distance_step = maxf(spd, 0.0) * maxf(dt, 0.0)
        _road_distance = fposmod(_road_distance_previous + _road_distance_step, _road_cycle_length)
        if is_instance_valid(_deck_hardware_root):
                _deck_hardware_root.position.z = _road_distance
                if _road_distance < _road_distance_previous:
                        # The screw/rib pattern repeats every 5.25 m; 42 m is an exact
                        # eight-row cycle, so reset interpolation without a visible pop.
                        _deck_hardware_root.reset_physics_interpolation()
        _update_building_recycling(spd, dt)
        _update_far_skyline(spd, dt)
        _update_landmarks(spd, dt)
        _update_air_traffic(spd, dt)
        _update_city_signage(spd, dt)
        # BOSS 哨戒机：悬停呼吸 + 随世界推进（不回收，玩家永远被追猎）
        if _boss_drone.visible:
                _boss_drone.position.y = 6.2 + sin(time * 2.0) * 0.5
                _boss_drone.position.z = -46.0 + sin(time * 0.7) * 2.5
                _boss_drone.rotation.y = sin(time * 1.3) * 0.12
        # 拱门推进回收
        for g in _gates:
                g.position.z += spd * dt
                # 拱门贴脸淡出（每门独立材质）：z∈[-14,10] 线性降至 0.06
                var near_k: float = U.clampf((g.position.z + 14.0) / 24.0, 0.0, 1.0)
                var gate_main_mat := g.material_override as StandardMaterial3D
                if gate_main_mat != null:
                        var main_color := gate_main_mat.albedo_color
                        main_color.a = lerpf(float(g.get_meta("gate_base_alpha", 0.34)), float(g.get_meta("gate_near_alpha", 0.06)), near_k)
                        gate_main_mat.albedo_color = main_color
                for gate_part in g.get_children():
                        if gate_part is GeometryInstance3D:
                                var gate_part_instance := gate_part as GeometryInstance3D
                                var gate_part_mat := gate_part_instance.material_override as StandardMaterial3D
                                if gate_part_mat != null:
                                        var part_color := gate_part_mat.albedo_color
                                        part_color.a = lerpf(float(gate_part.get_meta("gate_base_alpha", 0.90)), float(gate_part.get_meta("gate_near_alpha", 0.18)), near_k)
                                        gate_part_mat.albedo_color = part_color
                if g.position.z > 16.0:
                        g.position.z -= GATE_GAP * GATE_COUNT
                        g.reset_physics_interpolation()

func _build_city_signage() -> void:
        var texts: Array[String] = ["NIGHT CITY", "NEON / 2099", "AFTERLIFE", "NO SIGNAL", "CYBER RUSH"]
        var colors: Array[Color] = [Color("00F0FF"), Color("FF2B88"), Color("FFD166"), Color("8B2FFF"), Color("00F0FF")]
        var positions: Array[Vector3] = [
                Vector3(-8.0, 7.0, -18.0),
                Vector3(9.2, 9.2, -43.0),
                Vector3(-9.5, 5.4, -74.0),
                Vector3(8.7, 11.0, -107.0),
                Vector3(-8.4, 8.0, -141.0),
        ]
        for i in texts.size():
                var sign_root := Node3D.new()
                sign_root.name = "CityNeonSignRoot_%02d" % i
                sign_root.position = positions[i]
                add_child(sign_root)
                sign_root.reset_physics_interpolation()
                # Dark inset display plate with a slim emissive top rail; Label3D keeps its font atlas material.
                var panel := MeshInstance3D.new()
                var panel_mesh := BoxMesh.new()
                panel_mesh.size = Vector3(3.25, 0.58, 0.075)
                panel.mesh = panel_mesh
                panel.position = Vector3(0, 0, -0.095)
                var panel_material := StandardMaterial3D.new()
                panel_material.albedo_color = Color("10182B")
                panel_material.metallic = 0.68
                panel_material.roughness = 0.33
                panel.material_override = panel_material
                panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                sign_root.add_child(panel)
                var rail := MeshInstance3D.new()
                var rail_mesh := BoxMesh.new()
                rail_mesh.size = Vector3(3.25, 0.026, 0.035)
                rail.mesh = rail_mesh
                rail.position = Vector3(0, 0.295, -0.045)
                var rail_material := _make_city_material(colors[i], 0.0, 0.32, 1.72)
                rail.material_override = rail_material
                rail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                sign_root.add_child(rail)
                _city_sign_rails.append(rail)
                _city_sign_last_colors.append(colors[i])
                var label := Label3D.new()
                label.name = "CityNeonText_%02d" % i
                label.text = texts[i]
                label.font_size = 44
                label.pixel_size = 0.008
                label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
                label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
                label.shaded = false
                label.outline_size = 4
                label.outline_modulate = Color(colors[i].r * 0.22, colors[i].g * 0.22, colors[i].b * 0.22, 0.9)
                label.modulate = colors[i]
                label.position = Vector3(0, -0.015, -0.005)
                label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                sign_root.add_child(label)
                _city_sign_roots.append(sign_root)
                _city_signs.append(label)
                _city_sign_data.append({"x": positions[i].x, "y": positions[i].y, "z": positions[i].z, "color": colors[i], "phase": float(i) * 1.37})

func _update_city_signage(spd: float, dt: float) -> void:
        for i in _city_sign_roots.size():
                var sign_root: Node3D = _city_sign_roots[i]
                var label: Label3D = _city_signs[i]
                var data: Dictionary = _city_sign_data[i]
                var z_pos: float = float(data.z) + spd * dt * 0.92
                var wrapped: bool = z_pos > 16.0
                if wrapped:
                        z_pos -= 185.0
                sign_root.position = Vector3(float(data.x), float(data.y) + sin(time * 0.7 + float(data.phase)) * 0.04, z_pos)
                if wrapped:
                        sign_root.reset_physics_interpolation()
                var pulse: float = 0.035 + 0.045 * (0.5 + 0.5 * sin(time * 1.8 + float(data.phase)))
                var theme_color: Color = _theme_from.get("neon", Config.PALETTE.cyan).lerp(_theme_to.get("neon", Config.PALETTE.cyan), _theme_mix)
                var sign_color: Color = data.color.lerp(theme_color, 0.42)
                label.modulate = sign_color.lerp(Color.WHITE, pulse)
                # Rail material tint changes only during chapter transitions. The label
                # retains its light pulse every frame; avoid rewriting three GPU-facing
                # material properties for five rails at 60/90/120 Hz when color is stable.
                if not sign_color.is_equal_approx(_city_sign_last_colors[i]):
                        var rail_material := _city_sign_rails[i].material_override as StandardMaterial3D
                        rail_material.albedo_color = sign_color
                        rail_material.emission = sign_color
                        _city_sign_last_colors[i] = sign_color
                data.z = z_pos

func _rebase_multimesh_root(root: Node3D, offset_z: float) -> void:
        # Keep world coordinates stable without letting the parent transform grow
        # forever. Rebase all attached instance buffers in one infrequent maintenance pass.
        for child in root.get_children():
                if not child is MultiMeshInstance3D:
                        continue
                var instance_node := child as MultiMeshInstance3D
                if instance_node.multimesh == null:
                        continue
                var mm: MultiMesh = instance_node.multimesh
                for slot in mm.instance_count:
                        var xf: Transform3D = mm.get_instance_transform(slot)
                        xf.origin.z += offset_z
                        mm.set_instance_transform(slot, xf)
                        mm.reset_instance_physics_interpolation(slot)
        if root == _building_root:
                for i in _building_local_z.size():
                        _building_local_z[i] += offset_z

func _update_building_recycling(spd: float, dt: float) -> void:
        if not is_instance_valid(_building_root) or not is_instance_valid(_buildings) or _buildings.multimesh == null:
                return
        # One parent transform moves all 96 towers and their attached decoration batches.
        # A depth-sorted event queue avoids scanning all towers on ordinary physics ticks.
        var root_z: float = _building_root.position.z + maxf(spd, 0.0) * dt * 0.92
        var mm: MultiMesh = _buildings.multimesh
        var event_cursor: int = _building_recycle_pointer
        var did_rebase: bool = false
        while true:
                # Process only towers whose recycle threshold has actually been crossed.
                while event_cursor < _building_recycle_events.size() and root_z > float(_building_recycle_events[event_cursor].threshold):
                        var slot: int = int(_building_recycle_events[event_cursor].slot)
                        var h: float = _building_rng.randf_range(Config.WORLD.buildingMinH, Config.WORLD.buildingMaxH)
                        var width: float = _building_rng.randf_range(3.4, 6.5)
                        var depth: float = _building_rng.randf_range(3.5, 7.0)
                        var side: float = -1.0 if slot % 2 == 0 else 1.0
                        var x_pos: float = side * _building_rng.randf_range(7.5, 17.5)
                        # Recycle in root-local space; rebase later preserves world-space motion.
                        var local_z: float = _building_local_z[slot] - 220.0
                        var xf := Transform3D(Basis().scaled(Vector3(width, h, depth)), Vector3(x_pos, h * 0.5, local_z))
                        _building_local_z[slot] = local_z
                        _building_detail_flags[slot] = _new_building_detail_flags(width, h, depth)
                        mm.set_instance_custom_data(slot, Color(_building_rng.randf(), _building_rng.randf(), _building_rng.randf(), _building_rng.randf()))
                        mm.set_instance_transform(slot, xf)
                        mm.reset_instance_physics_interpolation(slot)
                        _write_building_detail_transforms(slot, xf, _building_detail_flags[slot])
                        event_cursor += 1
                if root_z < 220.0:
                        break
                # Large frame gaps can cross multiple root cycles; rebase once per crossed cycle.
                root_z -= 220.0
                _building_root.position.z = root_z
                _rebase_multimesh_root(_building_root, 220.0)
                did_rebase = true
                event_cursor = 0
        _building_root.position.z = root_z
        if did_rebase:
                _building_root.reset_physics_interpolation()
        _building_recycle_pointer = event_cursor

func _update_air_traffic(spd: float, dt: float) -> void:
        for i in _air_traffic.size():
                var craft: Node3D = _air_traffic[i]
                var data: Dictionary = _air_traffic_data[i]
                data.z = float(data.z) + spd * dt * float(data.speed)
                var wrapped: bool = float(data.z) > 18.0
                if wrapped:
                        data.z = -155.0 - float(i) * 13.0
                var phase: float = time * 0.34 + float(data.phase)
                craft.position = Vector3(float(data.x) + sin(phase) * 1.1, float(data.y) + sin(phase * 0.73) * 0.28, float(data.z))
                craft.rotation.y = sin(phase) * 0.11
                craft.rotation.z = cos(phase * 0.6) * 0.025
                if wrapped:
                        craft.reset_physics_interpolation()

## Shader uniforms are not interpolated by Godot as Node transforms are. Reuse the
## engine's interpolation fraction for scrolling deck lines and animated city windows.
## Set advance=false when gameplay is paused/game-over so shader motion freezes cleanly.
func update_render_interpolation(advance: bool = true) -> void:
        var render_scroll: float = _road_distance
        var render_time: float = time
        if advance:
                var fraction: float = clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
                render_scroll = fposmod(_road_distance_previous + _road_distance_step * fraction, _road_cycle_length)
                render_time = _time_previous + _time_step * fraction
        _grid_mat.set_shader_parameter("scroll", render_scroll)
        _building_mat.set_shader_parameter("time_", render_time)

## 章节渐变（main 每帧调用，距离驱动）
func apply_theme(dist: float, dt: float = 0.0, force: bool = false) -> void:
        var n_themes: int = Config.THEMES.size()
        var idx: int = int(dist / Config.THEME_LEN) % n_themes
        var frac: float = fmod(dist, Config.THEME_LEN) / Config.THEME_LEN
        # 章末 15% 渐变到下一主题
        var a: Dictionary = Config.THEMES[idx]
        var b: Dictionary = Config.THEMES[(idx + 1) % n_themes]
        var mix: float = 0.0 if frac < 0.85 else (frac - 0.85) / 0.15
        var theme_changed: bool = _theme_from != a or _theme_to != b
        var mix_changed: bool = not is_equal_approx(mix, _theme_mix)
        if not force and not theme_changed and not mix_changed:
                return
        # Theme blending touches Environment, lane/gate materials and many imported
        # materials. During a blend, cap these writes at the configured cadence; a
        # chapter boundary or an explicit reset is applied immediately.
        if not force and not theme_changed:
                _theme_update_accumulator += maxf(dt, 0.0)
                var update_interval: float = 1.0 / maxf(float(Config.RUNTIME.themeUpdateHz), 1.0)
                if _theme_update_accumulator < update_interval:
                        return
        _theme_update_accumulator = 0.0
        if theme_changed or mix_changed or force:
                _theme_from = a
                _theme_to = b
                _theme_mix = mix
                var fog_col: Color = a.fog.lerp(b.fog, mix)
                var backdrop_col: Color = a.backdrop.lerp(b.backdrop, mix)
                var hemi_col: Color = a.hemi.lerp(b.hemi, mix)
                var neon: Color = a.neon.lerp(b.neon, mix)
                var grid: Color = a.grid.lerp(b.grid, mix)
                _current_fog_density = lerpf(float(a.fogDensity), float(b.fogDensity), mix)
                _env.fog_light_color = fog_col
                # Theme transitions run continuously. Do not overwrite the temporary
                # overclock fog every frame; remember the current chapter value and
                # restore it only when overclock_on(false) is called.
                if not _overclocking:
                        _env.fog_density = _current_fog_density
                # Chapter changes now reach the actual city/environment, not just the road.
                _env.ambient_light_color = hemi_col
                # Keep the procedural sky static: mutating sky material every theme tick
                # would repeatedly invalidate its radiance map. Chapter variation remains
                # visible through fog, ambient light, grid, neon materials and skyline.
                if is_instance_valid(_sun_light):
                        var sun_tint: Color = Color(0.75, 0.82, 1.0).lerp(fog_col, 0.22).lerp(neon, 0.045)
                        _sun_light.light_color = sun_tint
                        _sun_light.light_energy = lerpf(0.82, 1.0, mix)
                _grid_mat.set_shader_parameter("grid_color", grid)
                _grid_mat.set_shader_parameter("bg_color", Color(0.025, 0.035, 0.075).lerp(backdrop_col, 0.22))
                _grid_mat.set_shader_parameter("grid_strength", 0.84 + 0.10 * mix)
                _building_mat.set_shader_parameter("neon_color", neon)
                for line in _lane_lines:
                        var m := line.material_override as StandardMaterial3D
                        m.albedo_color = grid
                        m.emission = grid
                var win: Color = Color("FFD9A0").lerp(neon, 0.66)
                _building_mat.set_shader_parameter("window_color", win)
                # The data arches are reused geometry, but their color is chapter-specific.
                for gate in _gates:
                        var gate_mat := gate.material_override as StandardMaterial3D
                        if gate_mat != null:
                                gate_mat.albedo_color = Color(grid.r, grid.g, grid.b, gate_mat.albedo_color.a)
                                gate_mat.emission = grid
                # Imported landmark/traffic PBR materials shift subtly with the chapter palette.
                # Base colors are captured once in _register_themeable_materials, preventing tint drift.
                for entry in _themeable_materials:
                        var themed_mat: StandardMaterial3D = entry.material
                        themed_mat.albedo_color = entry.base_albedo.lerp(neon, 0.12)
                        if bool(entry.emission_enabled):
                                themed_mat.emission = entry.base_emission.lerp(neon, 0.16)

## Device-tier glow is controlled by actual native compositor levels, not merely by
## brightness. Higher levels are wider and more expensive; keep only those that materially
## improve the cyber-neon silhouette on each device tier.
func set_perf_glow(value: float) -> void:
        _base_glow = clampf(value, 0.25, 1.0)
        _apply_glow_profile()

func _apply_glow_profile() -> void:
        if not is_instance_valid(_env):
                return
        var levels: Array[float] = []
        match _perf_profile:
                "high":
                        levels.assign([0.36, 0.56, 0.34, 0.18, 0.07, 0.0, 0.0])
                "mid":
                        levels.assign([0.42, 0.60, 0.24, 0.0, 0.0, 0.0, 0.0])
                _:
                        # Low tier normally skips bloom completely. During overclock, retain
                        # only two local glow levels for a readable energy burst at low cost.
                        levels.assign([0.52, 0.68, 0.0, 0.0, 0.0, 0.0, 0.0] if _overclocking else [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        for index in range(7):
                _env.set_glow_level(index, levels[index])
        _env.glow_enabled = _overclocking or _perf_profile != "low"
        _env.glow_intensity = 1.1 if _overclocking else _base_glow

func set_perf_profile(grade: String) -> void:
        # Native DirectionalLight3D offers real shadow-map budgets: PSSM four-split
        # for high tier, two-split compromise for mid, disabled on low-tier devices.
        # Keep 4x MSAA/resolution untouched; spend the adaptive budget on distant shadows
        # and broad glow passes instead of blurring geometry edges.
        _perf_profile = grade if grade in ["low", "mid", "high"] else "high"
        if is_instance_valid(_sun_light):
                match _perf_profile:
                        "high":
                                _sun_light.shadow_enabled = true
                                _sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
                                _sun_light.directional_shadow_max_distance = 60.0
                                _sun_light.directional_shadow_fade_start = 0.82
                                _sun_light.directional_shadow_blend_splits = true
                                _sun_light.shadow_blur = 0.65
                        "mid":
                                _sun_light.shadow_enabled = true
                                _sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
                                _sun_light.directional_shadow_max_distance = 42.0
                                _sun_light.directional_shadow_fade_start = 0.72
                                _sun_light.directional_shadow_blend_splits = false
                                _sun_light.shadow_blur = 0.42
                        _:
                                _sun_light.shadow_enabled = false
                                _sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
                                _sun_light.directional_shadow_max_distance = 24.0
                                _sun_light.directional_shadow_fade_start = 0.70
                                _sun_light.directional_shadow_blend_splits = false
                                _sun_light.shadow_blur = 0.0
        _apply_glow_profile()

func get_render_budget_snapshot() -> Dictionary:
        var glow_levels: Array[int] = []
        if is_instance_valid(_env):
                for index in range(7):
                        if _env.get_glow_level(index) > 0.001:
                                glow_levels.append(index + 1)
        return {
                "profile": _perf_profile,
                "shadowEnabled": is_instance_valid(_sun_light) and _sun_light.shadow_enabled,
                "shadowMode": int(_sun_light.directional_shadow_mode) if is_instance_valid(_sun_light) else -1,
                "shadowDistance": _sun_light.directional_shadow_max_distance if is_instance_valid(_sun_light) else 0.0,
                "glowEnabled": is_instance_valid(_env) and _env.glow_enabled,
                "glowLevels": glow_levels,
                "overclocking": _overclocking,
        }

func overclock_on(on: bool) -> void:
        _overclocking = on
        _env.fog_density = 0.055 if on else _current_fog_density
        _apply_glow_profile()
