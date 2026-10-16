class_name Player
extends Node3D
## 玩家角色 RUNNER-9：程序化装配、分层硬表面材质与程序动画。
## 保留既有动作枢轴和玩法接口；横向移动采用冲量、惯性、阻尼与目标车道引导。

signal wall_hit(side: int)
signal landed(impact: float)

const ARMOR_ALBEDO: Texture2D = preload("res://assets/textures/cyber_armor_albedo.png")
const ARMOR_NORMAL: Texture2D = preload("res://assets/textures/cyber_armor_normal.png")
const ARMOR_ROUGHNESS: Texture2D = preload("res://assets/textures/cyber_armor_roughness.png")
const CHAMFERED_BOX_SCENE: PackedScene = preload("res://assets/models/chamfered_unit_box.glb")

var _chamfered_box_mesh: Mesh

const SKINS := [
        {"id": 0, "name": "经典", "body": "yellow", "light": "yellow", "eye": "cyan", "price": 0, "skill": ""},
        {"id": 1, "name": "幽灵", "body": "cyan", "light": "cyan", "eye": "white", "price": 300, "skill": "擦碰判定 -15%（高手向）"},
        {"id": 2, "name": "鬼武士", "body": "magenta", "light": "magenta", "eye": "magenta", "price": 800, "skill": "道具时长 +40%"},
        {"id": 3, "name": "魅影", "body": "blue", "light": "purple", "eye": "cyan", "price": 500, "skill": "磁吸范围 +50%"},
        {"id": 4, "name": "黄金霸主", "body": "gold", "light": "gold", "eye": "gold", "price": 1200, "skill": "每局一次撞击豁免"},
        {"id": 5, "name": "合金装备", "body": "dark", "light": "white", "eye": "cyan", "price": 999, "skill": "落地更稳（squash 减半）"},
]

# —— 物理状态 ——
var lane: int = 1
var x: float = 0.0
var y: float = 0.0
var vx: float = 0.0
var vy: float = 0.0
var on_ground: bool = true
var sliding: bool = false
var slide_t: float = 0.0
var air_time: float = 0.0

# —— 输入缓冲 ——
var _jump_buf: float = 0.0
var _want_slide: bool = false

# —— 动画状态 ——
var run_phase: float = 0.0
var land_squash: float = 0.0
var _stretch: float = 0.0
var _dying_pose: float = 0.0
var _fric_scale: float = 1.0     # v11 章节物理修正（外部注入）
var _jump_scale: float = 1.0
var _squash_scale: float = 1.0
var on_board: bool = false       # 滑板

# —— 皮肤技能（v11） ——
var skill_ghost: bool = false
var mech: String = ""     # 章节机制（main 每帧同步 game.current_mech）
var _blob_shadow: MeshInstance3D   # 假阴影（贴地暗斑）
var skill_oni: bool = false
var skill_phantom: bool = false
var skill_gold: bool = false
var _double_used: bool = false

# —— 视觉节点 ——
var body: Node3D
var leg_l: Node3D
var leg_r: Node3D
var arm_l: Node3D
var arm_r: Node3D
var head: Node3D
var board: Node3D
var _skin_variant_roots: Array[Node3D] = []
# Unique shared emissive materials are cached once; pulsing never allocates per frame.
var _skin_glow_materials: Array[StandardMaterial3D] = []
var _skin_glow_base_energy: Array[float] = []
var _skin_glow_time: float = 0.0

func _ready() -> void:
        _chamfered_box_mesh = _extract_first_mesh(CHAMFERED_BOX_SCENE)
        _build()
        reset()

func _extract_first_mesh(scene: PackedScene) -> Mesh:
        var imported_root: Node = scene.instantiate()
        var found_mesh: Mesh = null
        if imported_root is MeshInstance3D and (imported_root as MeshInstance3D).mesh != null:
                found_mesh = (imported_root as MeshInstance3D).mesh
        else:
                var mesh_nodes: Array[Node] = imported_root.find_children("*", "MeshInstance3D", true, false)
                for candidate in mesh_nodes:
                        if candidate is MeshInstance3D and (candidate as MeshInstance3D).mesh != null:
                                found_mesh = (candidate as MeshInstance3D).mesh
                                break
        imported_root.free()
        return found_mesh

# ---------- 程序化建模（以 Node3D 层级装配角色） ----------

func _mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
        var m := StandardMaterial3D.new()
        m.albedo_color = color
        m.metallic = 0.62 if emission == 0.0 else 0.0
        m.roughness = 0.30 if emission == 0.0 else 0.5
        if emission == 0.0:
                # Native StandardMaterial3D detail layer preserves each skin's authored base/faction tint.
                # detail_albedo alpha masks both engraved color and micro-normal to the cut/gasket regions.
                # Armor normal amplitude is calibrated in the generator for detail_normal's native full strength.
                m.detail_enabled = true
                m.detail_albedo = ARMOR_ALBEDO
                m.detail_normal = ARMOR_NORMAL
                m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
                m.roughness_texture = ARMOR_ROUGHNESS
                m.uv1_scale = Vector3(0.85, 0.85, 1.0)
        if emission > 0.0:
                m.emission_enabled = true
                m.emission = color
                m.emission_energy_multiplier = emission
        return m

func _box(w: float, h: float, d: float, mat: Material, px: float = 0.0, py: float = 0.0, pz: float = 0.0) -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        if _chamfered_box_mesh != null:
                mi.mesh = _chamfered_box_mesh
                mi.scale = Vector3(w, h, d)
        else:
                var bm := BoxMesh.new()
                bm.size = Vector3(w, h, d)
                mi.mesh = bm
        mi.material_override = mat
        mi.position = Vector3(px, py, pz)
        return mi

func _tag_skin(node: MeshInstance3D, role: String) -> MeshInstance3D:
        node.set_meta("skin_role", role)
        node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
        return node

func _sphere(rx: float, ry: float, rz: float, mat: Material, px: float, py: float, pz: float, role: String = "body") -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        var mesh := SphereMesh.new()
        mesh.radius = 0.5
        mesh.height = 1.0
        mesh.radial_segments = 28
        mesh.rings = 16
        mi.mesh = mesh
        mi.scale = Vector3(rx * 2.0, ry * 2.0, rz * 2.0)
        mi.material_override = mat
        mi.position = Vector3(px, py, pz)
        return _tag_skin(mi, role)

func _capsule(radius: float, height: float, mat: Material, pos: Vector3, role: String = "body") -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        var mesh := CapsuleMesh.new()
        mesh.radius = radius
        mesh.height = maxf(height, radius * 2.0 + 0.01)
        mesh.radial_segments = 18
        mesh.rings = 7
        mi.mesh = mesh
        mi.material_override = mat
        mi.position = pos
        return _tag_skin(mi, role)

func _cylinder(radius: float, height: float, mat: Material, pos: Vector3, role: String = "accent", radial_segments: int = 16) -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        var mesh := CylinderMesh.new()
        mesh.top_radius = radius
        mesh.bottom_radius = radius
        mesh.height = height
        mesh.radial_segments = radial_segments
        mesh.rings = 3
        mi.mesh = mesh
        mi.material_override = mat
        mi.position = pos
        return _tag_skin(mi, role)

func _skin_box(w: float, h: float, d: float, mat: Material, pos: Vector3, role: String = "body") -> MeshInstance3D:
        var mi := _box(w, h, d, mat, pos.x, pos.y, pos.z)
        return _tag_skin(mi, role)

func _merge_skin_parts(parent: Node3D) -> void:
        # Merge static primitive meshes by skin role within each moving pivot.
        # This preserves per-pivot animation and skin recoloring while cutting draw calls.
        var tools: Dictionary = {}
        var role_materials: Dictionary = {}
        var remove_list: Array[MeshInstance3D] = []
        for child in parent.get_children():
                if not child is MeshInstance3D:
                        continue
                var part_to_merge := child as MeshInstance3D
                if part_to_merge.mesh == null or not part_to_merge.has_meta("skin_role"):
                        continue
                var role: String = String(part_to_merge.get_meta("skin_role"))
                if not tools.has(role):
                        var surface_tool := SurfaceTool.new()
                        surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
                        tools[role] = surface_tool
                        role_materials[role] = part_to_merge.material_override
                var append_tool: SurfaceTool = tools[role]
                for surface_idx in part_to_merge.mesh.get_surface_count():
                        append_tool.append_from(part_to_merge.mesh, surface_idx, part_to_merge.transform)
                remove_list.append(part_to_merge)
        if remove_list.is_empty():
                return
        for obsolete_part in remove_list:
                parent.remove_child(obsolete_part)
                obsolete_part.free()
        for role in tools.keys():
                var commit_tool: SurfaceTool = tools[role]
                # SurfaceTool 合并路径缺法线源，先补法线再生成切线（armor normal map 依赖）。
                commit_tool.generate_normals()
                # Rebuild tangents for the merged UV mesh so the armor normal map remains valid.
                commit_tool.generate_tangents()
                var merged_mesh: ArrayMesh = commit_tool.commit()
                if merged_mesh == null or merged_mesh.get_surface_count() == 0:
                        continue
                var merged := MeshInstance3D.new()
                merged.name = "MergedSkinRole_%s" % String(role)
                merged.mesh = merged_mesh
                merged.material_override = role_materials[role]
                merged.set_meta("skin_role", String(role))
                merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
                parent.add_child(merged)

func _build() -> void:
        # Ground contact shadow: soft unlit ellipse, independent of model detail.
        _blob_shadow = MeshInstance3D.new()
        var sm := QuadMesh.new()
        sm.size = Vector2(1.25, 1.7)
        _blob_shadow.mesh = sm
        var smat := StandardMaterial3D.new()
        smat.albedo_color = Color(0.008, 0.012, 0.025, 0.43)
        smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        smat.cull_mode = BaseMaterial3D.CULL_DISABLED
        _blob_shadow.material_override = smat
        _blob_shadow.rotation_degrees.x = -90
        _blob_shadow.position.y = 0.015
        _blob_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        add_child(_blob_shadow)

        body = Node3D.new()
        body.position.y = 0.98
        add_child(body)

        var m_body := _mat(Color("FCEE0A"))
        var m_dark := _mat(Color("151827"))
        var m_armour := _mat(Color("9AA8BE"))
        var m_trim := _mat(Color("26324A"))
        var m_glow := _mat(Color("00F0FF"), 2.8)
        var m_glow2 := _mat(Color("FF2B88"), 2.1)
        var m_eye := _mat(Color("B7FFFF"), 3.4)
        var m_joint := _mat(Color("080D18"))

        # Waist and torso: rounded volumes under layered chest armour.
        body.add_child(_capsule(0.155, 0.47, m_dark, Vector3(0, 0.14, 0), "dark"))
        body.add_child(_skin_box(0.34, 0.19, 0.23, m_trim, Vector3(0, 0.035, 0.0), "dark"))
        body.add_child(_sphere(0.205, 0.255, 0.135, m_body, 0, 0.30, 0.015, "body"))
        body.add_child(_skin_box(0.34, 0.20, 0.08, m_armour, Vector3(0, 0.315, 0.12), "accent"))
        # Split pectoral plates and vents give the torso actual depth.
        for side in [-1.0, 1.0]:
                var pectoral := _sphere(0.105, 0.092, 0.052, m_body, side * 0.105, 0.365, 0.164, "body")
                pectoral.rotation.z = side * -0.13
                body.add_child(pectoral)
                body.add_child(_skin_box(0.026, 0.105, 0.026, m_glow2, Vector3(side * 0.235, 0.33, 0.105), "glow"))
                body.add_child(_skin_box(0.085, 0.018, 0.018, m_dark, Vector3(side * 0.11, 0.235, 0.169), "dark"))
                body.add_child(_skin_box(0.072, 0.012, 0.018, m_glow, Vector3(side * 0.11, 0.207, 0.17), "glow"))
        # Shoulder pauldrons use the shared chamfer mesh so the hero silhouette gets
        # real edge highlights; the short light inset stays readable at phone scale.
        for side in [-1.0, 1.0]:
                var shoulder_guard := _skin_box(0.19, 0.115, 0.19, m_armour, Vector3(side * 0.30, 0.425, 0.015), "accent")
                shoulder_guard.rotation.z = side * -0.12
                body.add_child(shoulder_guard)
                body.add_child(_skin_box(0.045, 0.105, 0.045, m_glow2, Vector3(side * 0.31, 0.426, 0.122), "glow"))
        # Three-piece abdominal plating breaks up the torso into readable hard-surface
        # layers rather than one smooth capsule. Keep all parts inside the old rig bounds.
        body.add_child(_skin_box(0.235, 0.064, 0.042, m_armour, Vector3(0, 0.165, 0.148), "accent"))
        body.add_child(_skin_box(0.18, 0.018, 0.018, m_dark, Vector3(0, 0.164, 0.174), "dark"))
        body.add_child(_skin_box(0.12, 0.014, 0.016, m_glow, Vector3(0, 0.133, 0.172), "glow"))
        # Central reactor: metallic bezel, luminous core and vertical status lights.
        var reactor_bezel := _cylinder(0.078, 0.035, m_dark, Vector3(0, 0.32, 0.194), "dark", 20)
        reactor_bezel.rotation.x = PI / 2.0
        body.add_child(reactor_bezel)
        var reactor := _sphere(0.043, 0.043, 0.02, m_glow, 0, 0.32, 0.22, "glow")
        body.add_child(reactor)
        body.add_child(_skin_box(0.065, 0.024, 0.018, m_armour, Vector3(0, 0.12, 0.142), "accent"))
        body.add_child(_skin_box(0.035, 0.012, 0.018, m_glow2, Vector3(0, 0.12, 0.155), "glow"))

        # Neck ring and head pivot.
        var neck := _cylinder(0.09, 0.075, m_joint, Vector3(0, 0.51, 0), "dark", 16)
        body.add_child(neck)
        head = Node3D.new()
        head.position = Vector3(0, 0.64, 0.015)
        body.add_child(head)
        head.add_child(_sphere(0.135, 0.152, 0.13, m_body, 0, 0.0, 0, "body"))
        # Helmet brow, jaw guard, side pods and visor as separate materials.
        head.add_child(_sphere(0.147, 0.073, 0.132, m_armour, 0, 0.083, 0.005, "accent"))
        head.add_child(_skin_box(0.205, 0.061, 0.045, m_dark, Vector3(0, -0.055, 0.095), "dark"))
        var visor := _sphere(0.102, 0.038, 0.027, m_eye, 0, 0.018, 0.116, "eye")
        visor.scale = Vector3(0.205, 0.075, 0.045)
        head.add_child(visor)
        head.add_child(_skin_box(0.18, 0.014, 0.014, m_glow, Vector3(0, 0.113, 0.098), "glow"))
        for side in [-1.0, 1.0]:
                head.add_child(_sphere(0.043, 0.054, 0.052, m_dark, side * 0.13, -0.015, -0.005, "dark"))
                head.add_child(_sphere(0.018, 0.025, 0.02, m_glow2, side * 0.15, -0.015, 0.015, "glow"))
        head.add_child(_skin_box(0.08, 0.018, 0.024, m_dark, Vector3(0, -0.102, 0.095), "dark"))

        # Backpack battery and twin exhausts on the rear (-Z).
        body.add_child(_skin_box(0.22, 0.30, 0.105, m_dark, Vector3(0, 0.28, -0.15), "dark"))
        body.add_child(_skin_box(0.17, 0.20, 0.045, m_trim, Vector3(0, 0.30, -0.216), "accent"))
        for side in [-1.0, 1.0]:
                var thruster := _cylinder(0.044, 0.17, m_trim, Vector3(side * 0.078, 0.18, -0.19), "dark", 12)
                body.add_child(thruster)
                var exhaust := _sphere(0.028, 0.04, 0.018, m_glow, side * 0.078, 0.18, -0.282, "glow")
                body.add_child(exhaust)
                body.add_child(_skin_box(0.022, 0.20, 0.024, m_glow2, Vector3(side * 0.115, 0.29, -0.21), "glow"))
        # Rear battery cooling louvers add a little depth on jumps and landing turns.
        for vent in range(3):
                body.add_child(_skin_box(0.115, 0.016, 0.018, m_trim, Vector3(0, 0.235 + float(vent) * 0.052, -0.211), "accent"))

        # Articulated limbs: shoulder/hip pivots remain unchanged for animation compatibility.
        arm_l = _make_limb(m_body, m_dark, true, false, m_trim)
        arm_r = _make_limb(m_body, m_dark, false, false, m_trim)
        body.add_child(arm_l)
        body.add_child(arm_r)
        leg_l = _make_limb(m_body, m_dark, true, true, m_trim)
        leg_r = _make_limb(m_body, m_dark, false, true, m_trim)
        add_child(leg_l)
        add_child(leg_r)
        _build_skin_variants()
        _merge_skin_parts(body)
        _merge_skin_parts(head)
        _merge_skin_parts(arm_l)
        _merge_skin_parts(arm_r)
        _merge_skin_parts(leg_l)
        _merge_skin_parts(leg_r)

        # Hover board: layered carbon deck, side rails and four anti-gravity emitters.
        board = Node3D.new()
        var deck := _skin_box(0.68, 0.075, 1.32, _mat(Color("18263C")), Vector3(0, 0.08, 0), "dark")
        board.add_child(deck)
        board.add_child(_skin_box(0.48, 0.018, 1.08, _mat(Color("1B3E55")), Vector3(0, 0.126, 0), "accent"))
        for side in [-1.0, 1.0]:
                board.add_child(_skin_box(0.035, 0.05, 1.22, m_glow, Vector3(side * 0.32, 0.095, 0), "glow"))
        for side in [-1.0, 1.0]:
                for front in [-1.0, 1.0]:
                        board.add_child(_sphere(0.07, 0.035, 0.07, m_glow, side * 0.23, 0.02, front * 0.48, "glow"))
        _merge_skin_parts(board)
        board.visible = false
        add_child(board)

func _variant_box(root: Node3D, size: Vector3, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
        var mi := _box(size.x, size.y, size.z, mat, pos.x, pos.y, pos.z)
        mi.rotation = rot
        root.add_child(mi)
        return mi

func _variant_mesh(root: Node3D, mesh: Mesh, pos: Vector3, scale: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        mi.mesh = mesh
        mi.position = pos
        mi.scale = scale
        mi.rotation = rot
        mi.material_override = mat
        mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
        root.add_child(mi)
        return mi

func _variant_sphere_mesh() -> SphereMesh:
        var mesh := SphereMesh.new()
        mesh.radius = 0.5
        mesh.height = 1.0
        mesh.radial_segments = 28
        mesh.rings = 16
        return mesh

func _variant_cone_mesh(base_radius: float, height: float, segments: int = 8) -> CylinderMesh:
        var mesh := CylinderMesh.new()
        mesh.bottom_radius = base_radius
        mesh.top_radius = 0.006
        mesh.height = height
        mesh.radial_segments = segments
        mesh.rings = 2
        return mesh

func _variant_torus_mesh(inner_radius: float, outer_radius: float) -> TorusMesh:
        var mesh := TorusMesh.new()
        mesh.inner_radius = inner_radius
        mesh.outer_radius = outer_radius
        mesh.rings = 16
        mesh.ring_segments = 28
        return mesh

func _build_skin_variants() -> void:
        # Six silhouette kits share the same animation rig, but are not palette-only swaps.
        for skin_id in SKINS.size():
                var variant := Node3D.new()
                variant.name = "SkinSilhouette_%d" % skin_id
                variant.visible = false
                body.add_child(variant)
                _skin_variant_roots.append(variant)
        var yellow := _mat(Color("FCEE0A"), 1.1)
        var cyan := _mat(Color("00F0FF"), 2.6)
        var magenta := _mat(Color("FF174F"), 2.0)
        var purple := _mat(Color("8B2FFF"), 2.2)
        var gold := _mat(Color("FFD166"), 2.1)
        var alloy_mat := _mat(Color("AFC0D7"), 0.35)
        # 0 Classic: shoulder reactor plates.
        var classic := _skin_variant_roots[0]
        for side in [-1.0, 1.0]:
                _variant_box(classic, Vector3(0.13, 0.11, 0.17), Vector3(side * 0.31, 0.43, 0.04), yellow, Vector3(0, 0, side * -0.12))
        # 1 Ghost: tapered swept fins and narrow side light rails.
        var ghost := _skin_variant_roots[1]
        for side in [-1.0, 1.0]:
                _variant_mesh(ghost, _variant_cone_mesh(0.075, 0.52, 7), Vector3(side * 0.25, 0.42, -0.14), Vector3(0.72, 1.0, 0.32), cyan, Vector3(0, 0, side * 0.45))
                _variant_box(ghost, Vector3(0.035, 0.25, 0.035), Vector3(side * 0.39, 0.35, 0.0), cyan, Vector3(0, 0, side * 0.25))
        # 2 Oni: twin helmet horns plus angular shoulder blades.
        var oni := _skin_variant_roots[2]
        for side in [-1.0, 1.0]:
                _variant_mesh(oni, _variant_cone_mesh(0.052, 0.31, 8), Vector3(side * 0.092, 0.815, 0.008), Vector3(0.88, 1.0, 0.82), magenta, Vector3(0, 0, side * 0.34))
                _variant_box(oni, Vector3(0.07, 0.26, 0.24), Vector3(side * 0.34, 0.42, -0.04), magenta, Vector3(0, 0, side * 0.38))
        # 3 Phantom: aerodynamic purple fins.
        var phantom := _skin_variant_roots[3]
        for side in [-1.0, 1.0]:
                _variant_box(phantom, Vector3(0.055, 0.34, 0.38), Vector3(side * 0.36, 0.39, -0.12), purple, Vector3(0, side * 0.14, side * -0.44))
                _variant_mesh(phantom, _variant_sphere_mesh(), Vector3(side * 0.22, 0.59, -0.17), Vector3(0.075, 0.075, 0.075), purple)
        # 4 Golden Overlord: halo and shoulder-mounted solar coils.
        var golden := _skin_variant_roots[4]
        _variant_mesh(golden, _variant_torus_mesh(0.16, 0.205), Vector3(0, 0.86, -0.01), Vector3(1.0, 0.72, 1.0), gold, Vector3(0.16, 0, 0))
        for side in [-1.0, 1.0]:
                _variant_mesh(golden, _variant_torus_mesh(0.065, 0.085), Vector3(side * 0.34, 0.44, 0), Vector3.ONE, gold, Vector3(PI / 2.0, 0, 0))
        # 5 Alloy: reinforced shoulder shells and exposed spine rails.
        var alloy := _skin_variant_roots[5]
        for side in [-1.0, 1.0]:
                _variant_box(alloy, Vector3(0.20, 0.15, 0.22), Vector3(side * 0.34, 0.43, 0), alloy_mat, Vector3(0, 0, side * -0.10))
                _variant_box(alloy, Vector3(0.04, 0.22, 0.045), Vector3(side * 0.25, 0.28, -0.215), cyan)

func _make_limb(m_body: Material, m_dark: Material, is_left: bool, leg: bool = false, m_trim: Material = null) -> Node3D:
        var pivot := Node3D.new()
        if leg:
                pivot.position = Vector3(-0.115 if is_left else 0.115, 0.82, 0.0)
                pivot.add_child(_capsule(0.078, 0.39, m_dark, Vector3(0, -0.19, 0), "dark"))
                pivot.add_child(_skin_box(0.15, 0.22, 0.19, m_body, Vector3(0, -0.19, 0.075), "body"))
                pivot.add_child(_skin_box(0.115, 0.14, 0.04, m_dark, Vector3(0, -0.265, 0.18), "dark"))
                pivot.add_child(_skin_box(0.11, 0.10, 0.10, m_body, Vector3(0, -0.33, 0.035), "body"))
                # Raised knee-cap and twin shin ribs form a distinct armored leg profile.
                pivot.add_child(_skin_box(0.145, 0.095, 0.052, m_body, Vector3(0, -0.105, 0.079), "accent"))
                pivot.add_child(_skin_box(0.028, 0.11, 0.018, m_trim, Vector3(-0.043, -0.24, 0.112), "dark"))
                pivot.add_child(_skin_box(0.028, 0.11, 0.018, m_trim, Vector3(0.043, -0.24, 0.112), "dark"))
                pivot.add_child(_sphere(0.077, 0.068, 0.076, m_dark, 0, -0.415, 0.02, "dark"))
                pivot.add_child(_skin_box(0.17, 0.115, 0.27, m_dark, Vector3(0, -0.43, 0.075), "dark"))
                pivot.add_child(_skin_box(0.125, 0.022, 0.20, _mat(Color("00F0FF"), 2.2), Vector3(0, -0.382, 0.115), "glow"))
                pivot.add_child(_skin_box(0.025, 0.13, 0.022, _mat(Color("FF2B88"), 1.8), Vector3(0, -0.22, 0.179), "glow"))
        else:
                pivot.position = Vector3(-0.32 if is_left else 0.32, 0.42, 0.0)
                pivot.add_child(_sphere(0.095, 0.10, 0.09, m_dark, 0, 0, 0, "dark"))
                pivot.add_child(_capsule(0.065, 0.35, m_dark, Vector3(0, -0.17, 0), "dark"))
                pivot.add_child(_skin_box(0.16, 0.19, 0.17, m_body, Vector3(0, -0.16, 0.02), "body"))
                pivot.add_child(_skin_box(0.125, 0.115, 0.055, m_dark, Vector3(0, -0.25, 0.093), "dark"))
                pivot.add_child(_skin_box(0.04, 0.16, 0.03, _mat(Color("00F0FF"), 2.0), Vector3(0, -0.16, 0.115), "glow"))
                pivot.add_child(_sphere(0.068, 0.062, 0.068, m_dark, 0, -0.30, 0, "dark"))
                pivot.add_child(_skin_box(0.115, 0.10, 0.125, m_body, Vector3(0, -0.35, 0.01), "body"))
                pivot.add_child(_skin_box(0.085, 0.055, 0.13, m_dark, Vector3(0, -0.405, 0.035), "dark"))
                # Slim wrist cuff and a second inset make the forearm feel constructed,
                # while merging by role later keeps the added triangles inexpensive.
                pivot.add_child(_skin_box(0.135, 0.045, 0.16, m_trim, Vector3(0, -0.325, 0.045), "dark"))
                pivot.add_child(_skin_box(0.075, 0.022, 0.025, m_body, Vector3(0, -0.325, 0.131), "body"))
        return pivot

# ---------- 皮肤 ----------

func _refresh_skin_glow_cache() -> void:
        _skin_glow_materials.clear()
        _skin_glow_base_energy.clear()
        var seen: Dictionary = {}
        for root in [body, leg_l, leg_r, arm_l, arm_r, board]:
                if is_instance_valid(root):
                        _collect_skin_glow_materials(root, seen)

func _collect_skin_glow_materials(node: Node, seen: Dictionary) -> void:
        if node is MeshInstance3D and node.has_meta("skin_role"):
                var role: String = String(node.get_meta("skin_role"))
                if role == "glow" or role == "eye":
                        var material := (node as MeshInstance3D).material_override as StandardMaterial3D
                        if material != null and material.emission_enabled:
                                var material_id: int = material.get_instance_id()
                                if not seen.has(material_id):
                                        seen[material_id] = true
                                        _skin_glow_materials.append(material)
                                        _skin_glow_base_energy.append(material.emission_energy_multiplier)
        for child in node.get_children():
                _collect_skin_glow_materials(child, seen)

func _update_skin_glow_pulse(dt: float, spd: float) -> void:
        _skin_glow_time += dt * (2.1 + clampf(spd * 0.045, 0.0, 1.6))
        for i in _skin_glow_materials.size():
                var pulse: float = 0.92 + 0.15 * (0.5 + 0.5 * sin(_skin_glow_time + float(i) * 0.71))
                _skin_glow_materials[i].emission_energy_multiplier = _skin_glow_base_energy[i] * pulse

func apply_skin(id: int) -> void:
        var s: Dictionary = SKINS[posmod(id, SKINS.size())]
        var body_color: Color = Config.PALETTE.get(s.body, Color.YELLOW)
        var light_color: Color = Config.PALETTE.get(s.light, Color.CYAN)
        var eye_color: Color = Config.PALETTE.get(s.eye, light_color)
        var body_mat := _mat(body_color)
        var accent_mat := _mat(body_color.lerp(Color.WHITE, 0.24))
        var dark_mat := _mat(Color("111522"))
        var glow_mat := _mat(light_color, 2.7)
        var eye_mat := _mat(eye_color, 3.2)
        # Apply the same skin palette to every animated rig branch. Arms were omitted
        # in an earlier pass, leaving their armor in the starter palette on other skins.
        for node in [body, leg_l, leg_r, arm_l, arm_r, board]:
                if is_instance_valid(node):
                        _apply_skin_tree(node, body_mat, accent_mat, dark_mat, glow_mat, eye_mat)
        for variant_idx in _skin_variant_roots.size():
                _skin_variant_roots[variant_idx].visible = variant_idx == s.id
        _refresh_skin_glow_cache()
        skill_ghost = s.id == 1
        skill_oni = s.id == 2
        skill_phantom = s.id == 3
        skill_gold = s.id == 4
        _jump_scale = 1.0
        _fric_scale = 1.0
        _squash_scale = 0.5 if s.id == 5 else 1.0

func _apply_skin_tree(node: Node, body_mat: StandardMaterial3D, accent_mat: StandardMaterial3D, dark_mat: StandardMaterial3D, glow_mat: StandardMaterial3D, eye_mat: StandardMaterial3D) -> void:
        if node is MeshInstance3D and node.has_meta("skin_role"):
                var mi := node as MeshInstance3D
                match String(mi.get_meta("skin_role")):
                        "body": mi.material_override = body_mat
                        "accent": mi.material_override = accent_mat
                        "dark": mi.material_override = dark_mat
                        "glow": mi.material_override = glow_mat
                        "eye": mi.material_override = eye_mat
        for child in node.get_children():
                _apply_skin_tree(child, body_mat, accent_mat, dark_mat, glow_mat, eye_mat)

# ---------- 输入动作 ----------

func move_lane(dir: int) -> void:
        if dir == 0:
                return
        var direction: int = 1 if dir > 0 else -1
        var target: int = clampi(lane + direction, 0, 2)
        if target == lane:
                # A lane-edge swipe must not keep pushing the runner away from the lane center.
                return
        lane = target
        vx += direction * Config.PHYSICS.laneImpulse * _fric_scale   # 脉冲启动；后续由阻尼转向目标车道

func jump() -> void:
        var jv: float = Config.PHYSICS.jumpVel
        if mech == "lowg":
                jv *= Config.MECH_CFG.lowJumpMult   # 天港低重力跳
        if sliding:
                _want_slide = false
                sliding = false
                slide_t = 0.0
        if on_ground:
                EventBus.jumped.emit()
                vy = jv * _jump_scale
                on_ground = false
                _double_used = false
                land_squash = 0.0
                _stretch = 1.0
        elif on_board and not _double_used:
                # 二段跳（滑板技能）
                EventBus.jumped.emit()
                vy = jv * 0.88 * _jump_scale
                _double_used = true
                _stretch = 1.0
        else:
                _jump_buf = 0.12    # 落地前 120ms 预输入缓冲

func slide() -> void:
        if on_ground:
                if not sliding:
                        EventBus.slid.emit()   # 仅统计一次真实起滑；滑铲期间重输只延长动作
                sliding = true
                slide_t = Config.PHYSICS.slideTime
        else:
                _want_slide = true  # 落地转滑

func set_board(on: bool) -> void:
        on_board = on
        board.visible = on
        if on:
                _double_used = false

# ---------- 帧更新（对齐 Player.update 全逻辑） ----------

func update(dt: float, spd: float, state: String) -> void:
        # —— 横向物理（脉冲-惯性-阻尼目标车道） ——
        # 除惯性和阻尼外，目标车道引导负责确保单次滑动能够完成有效换道。
        # 小于相邻车道的有效碰撞宽度，单次侧滑常常仍会撞回原车道障碍。
        # 保留脉冲和惯性，同时加入受阻尼的车道引导，确保一次手势能完成一次换道。
        var lane_fric: float = Config.PHYSICS.laneFriction * _fric_scale
        if mech == "ice":
                lane_fric *= Config.MECH_CFG.iceFrictionMult   # 极地冰面降低阻尼，允许更明显的横滑
        var lane_error: float = Config.LANES[lane] - x
        var steering_accel: float = clampf(lane_error * 48.0 - vx * (lane_fric + 4.0), -90.0, 90.0)
        vx = clampf(vx + steering_accel * dt, -Config.PHYSICS.laneMaxV, Config.PHYSICS.laneMaxV)
        x += vx * dt
        if absf(lane_error) < 0.015 and absf(vx) < 0.08:
                x = Config.LANES[lane]
                vx = 0.0
        # 边界反弹（撞墙物理反馈）
        var x_min: float = Config.LANES[0] - 1.15
        var x_max: float = Config.LANES[2] + 1.15
        if x < x_min:
                x = x_min
                if vx < 0.0:
                        vx = -vx * Config.PHYSICS.laneWallBounce
                        wall_hit.emit(-1)
        elif x > x_max:
                x = x_max
                if vx > 0.0:
                        vx = -vx * Config.PHYSICS.laneWallBounce
                        wall_hit.emit(1)
        # 倾斜由真实横向速度驱动（惯性外观）
        var lean: float = clampf(-vx * 0.042, -0.55, 0.55)
        rotation.z = U.dampf(rotation.z, lean, 10.0, dt)

        # —— 纵向（跳跃） ——
        if not on_ground:
                var g: float = Config.PHYSICS.gravity
                if mech == "lowg":
                        g *= Config.MECH_CFG.lowGravMult   # 天港低重力滞空
                elif mech == "float":
                        g *= Config.MECH_CFG.floatGravMult   # 深海浮力（轻度滞空）
                vy += g * dt
                y += vy * dt
                air_time += dt
                _jump_buf = maxf(0.0, _jump_buf - dt)
                if y <= 0.0:
                        var fall_speed: float = -vy
                        y = 0.0
                        vy = 0.0
                        on_ground = true
                        # Harder falls compress the torso more; tiny drops still get a readable response.
                        land_squash = clampf(0.42 + fall_speed * 0.042, 0.45, 1.28)
                        landed.emit(fall_speed)
                        if _want_slide:
                                _want_slide = false
                                slide()
                        elif _jump_buf > 0.0:
                                _jump_buf = 0.0
                                jump()
        else:
                _want_slide = false
                _jump_buf = 0.0

        # —— 滑铲计时 ——
        if sliding:
                slide_t -= dt
                if slide_t <= 0.0:
                        sliding = false

        # —— J-2：落地压扁 140ms 恢复 · 起跳拉伸 80ms 恢复 ——
        land_squash = maxf(0.0, land_squash - dt * 7.0)
        _stretch = maxf(0.0, _stretch - dt * 12.5)

        position.x = x
        position.y = y
        # 假阴影贴地跟随：角色滞空时缩小并淡化。
        if _blob_shadow:
                var air_k: float = U.clampf(y / 3.0, 0.0, 1.0)
                _blob_shadow.scale = Vector3.ONE * (1.0 - air_k * 0.4)
                (_blob_shadow.material_override as StandardMaterial3D).albedo_color.a = 0.42 - air_k * 0.24
                _blob_shadow.position = Vector3(0, 0.015, 0)

        _update_skin_glow_pulse(dt, spd)
        if state == "dying":
                _update_dying(dt)
                return
        _update_anim(dt, spd)

# ---------- 程序动画 ----------

func _update_anim(dt: float, spd: float) -> void:
        var run: bool = on_ground and not sliding
        var normalized_speed: float = clampf((spd - Config.SPEED.base) / maxf(1.0, Config.SPEED.max - Config.SPEED.base), 0.0, 1.0)
        run_phase += dt * (4.2 + spd * 0.42)
        var s: float = sin(run_phase)
        var stride: float = lerpf(0.78, 1.12, normalized_speed)

        # 骑板姿态
        if on_board:
                body.rotation.x = U.dampf(body.rotation.x, 0.28, 8.0, dt)
                body.position.y = 0.98 + sin(run_phase * 0.7) * 0.05   # 板上悬浮起伏
                leg_l.rotation.x = -0.5 + s * 0.05
                leg_r.rotation.x = 0.35 + s * 0.05
                arm_l.rotation.x = -0.9
                arm_r.rotation.x = -1.1
                body.rotation.y = U.dampf(body.rotation.y, 0.0, 9.0, dt)
                body.rotation.z = U.dampf(body.rotation.z, 0.0, 9.0, dt)
                head.rotation.z = U.dampf(head.rotation.z, 0.0, 9.0, dt)
                board.position.y = 0.0
        # 滑铲姿态
        elif sliding:
                body.rotation.x = U.dampf(body.rotation.x, 1.15, 14.0, dt)
                body.position.y = U.dampf(body.position.y, 0.52, 14.0, dt)
                leg_l.rotation.x = U.dampf(leg_l.rotation.x, 1.3, 14.0, dt)
                leg_r.rotation.x = U.dampf(leg_r.rotation.x, 0.9, 14.0, dt)
                arm_l.rotation.x = U.dampf(arm_l.rotation.x, -0.8, 14.0, dt)
                arm_r.rotation.x = U.dampf(arm_r.rotation.x, -1.2, 14.0, dt)
                body.rotation.y = U.dampf(body.rotation.y, 0.0, 12.0, dt)
                body.rotation.z = U.dampf(body.rotation.z, 0.0, 12.0, dt)
                head.rotation.z = U.dampf(head.rotation.z, 0.0, 12.0, dt)
        # 跑步
        elif run:
                body.rotation.x = U.dampf(body.rotation.x, 0.13, 10.0, dt)
                body.position.y = 0.98 + absf(s) * 0.06
                leg_l.rotation.x = s * 0.82 * stride
                leg_r.rotation.x = -s * 0.82 * stride
                arm_l.rotation.x = -s * 0.64 * stride
                arm_r.rotation.x = s * 0.64 * stride
                # Secondary motion gives the runner weight without adding bones or per-frame nodes.
                body.rotation.y = U.dampf(body.rotation.y, s * 0.035, 7.5, dt)
                body.rotation.z = U.dampf(body.rotation.z, -vx * 0.018 + s * 0.012, 8.0, dt)
                head.rotation.z = U.dampf(head.rotation.z, -s * 0.025, 9.0, dt)
        # 空中（跳跃收腿）
        else:
                body.rotation.x = U.dampf(body.rotation.x, -0.08, 8.0, dt)
                leg_l.rotation.x = U.dampf(leg_l.rotation.x, -0.5, 10.0, dt)
                leg_r.rotation.x = U.dampf(leg_r.rotation.x, 0.6, 10.0, dt)
                arm_l.rotation.x = U.dampf(arm_l.rotation.x, -1.9, 10.0, dt)
                arm_r.rotation.x = U.dampf(arm_r.rotation.x, 0.4, 10.0, dt)
                body.rotation.y = U.dampf(body.rotation.y, 0.0, 8.0, dt)
                body.rotation.z = U.dampf(body.rotation.z, 0.0, 8.0, dt)
                head.rotation.z = U.dampf(head.rotation.z, 0.0, 8.0, dt)

        # J-2 squash & stretch（落地压扁/起跳拉伸）
        var squash: float = land_squash * 0.16 * _squash_scale + _stretch * -0.12
        body.scale = Vector3(1.0 + squash * 0.5, 1.0 - squash, 1.0 + squash * 0.5)
        # Fine head/helmet motion is deliberately small so it reads as weight, not wobble.
        head.rotation.y = sin(run_phase * 0.5) * 0.07
        # Skin silhouette kits get restrained independent secondary motion.
        if _skin_variant_roots.size() == SKINS.size():
                _skin_variant_roots[1].rotation.z = sin(run_phase * 0.52) * 0.025
                _skin_variant_roots[2].rotation.y = sin(run_phase * 0.38) * 0.022
                _skin_variant_roots[3].rotation.z = sin(run_phase * 0.62 + 0.4) * 0.035
                _skin_variant_roots[4].rotation.y = fmod(run_phase * 0.12, TAU)
                _skin_variant_roots[5].rotation.z = sin(run_phase * 0.44) * 0.012

func _update_dying(dt: float) -> void:
        _dying_pose = minf(1.0, _dying_pose + dt * 3.5)
        rotation.z += dt * 2.2 * (1.0 - _dying_pose)
        body.position.y = U.dampf(body.position.y, 0.35, 6.0, dt)

func reset() -> void:
        # Reset every transient field owned by Player. Do not rely on the previous
        # run (or on the first update tick) to finish restoring a neutral pose.
        lane = 1
        x = Config.LANES[1]
        y = 0.0
        vy = 0.0
        vx = 0.0
        on_ground = true
        sliding = false
        slide_t = 0.0
        air_time = 0.0
        run_phase = 0.0
        _skin_glow_time = 0.0
        land_squash = 0.0
        _stretch = 0.0
        _dying_pose = 0.0
        _want_slide = false
        _jump_buf = 0.0
        _double_used = false
        _fric_scale = 1.0
        _jump_scale = 1.0
        _squash_scale = 1.0
        _blob_shadow.scale = Vector3.ONE
        var shadow_material := _blob_shadow.material_override as StandardMaterial3D
        if shadow_material != null:
                shadow_material.albedo_color.a = 0.42
        mech = ""
        set_board(false)
        rotation = Vector3.ZERO
        position = Vector3(Config.LANES[1], 0.0, 0.0)
        body.rotation = Vector3(0.13, 0.0, 0.0)
        body.position = Vector3(0.0, 0.98, 0.0)
        body.scale = Vector3.ONE
        head.rotation = Vector3.ZERO
        leg_l.rotation = Vector3.ZERO
        leg_r.rotation = Vector3.ZERO
        arm_l.rotation = Vector3.ZERO
        arm_r.rotation = Vector3.ZERO
        board.position = Vector3.ZERO
        for variant_root in _skin_variant_roots:
                variant_root.rotation = Vector3.ZERO
        # Native physics interpolation is enabled globally; resetting after the full
        # pose/position restore prevents a one-frame streak from the previous run.
        reset_physics_interpolation()
