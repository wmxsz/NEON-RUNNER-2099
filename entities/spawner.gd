class_name Spawner
extends Node3D
## 障碍、芯片、道具、模式目录和碰撞查询。
## 逻辑对象池与 MultiMesh 渲染层分离；所有候选生成点在最终写入前需通过安全检查。

signal chip_collected(x: float, y: float)
signal powerup_collected(kind: String, x: float, y: float)
signal slide_dodged
signal smashed(x: float, y: float, color: Color)
signal laser_warning

const ARMOR_ALBEDO: Texture2D = preload("res://assets/textures/cyber_armor_albedo.png")
const ARMOR_NORMAL: Texture2D = preload("res://assets/textures/cyber_armor_normal.png")
const ARMOR_ROUGHNESS: Texture2D = preload("res://assets/textures/cyber_armor_roughness.png")
const CHAMFERED_BOX_SCENE: PackedScene = preload("res://assets/models/chamfered_unit_box.glb")
const DRONE_CORE_SCENE: PackedScene = preload("res://assets/models/aerial_drone_core.glb")
const POWERUP_KINDS := ["magnet", "shield", "double", "board"]

const OB := {
        "low":   {"w": 1.9, "d": 0.62, "y0": 0.0,  "y1": 0.85, "pool": 12},
        "bar":   {"w": 7.0, "d": 0.34, "y0": 1.18, "y1": 1.64, "pool": 8},
        "block": {"w": 1.9, "d": 0.9,  "y0": 0.0,  "y1": 2.9,  "pool": 12},
        "gate":  {"w": 2.1, "d": 0.9,  "y0": 0.0,  "y1": 2.9,  "pool": 5},
        "laser": {"w": 1.9, "d": 0.8,  "y0": 0.0,  "y1": 0.8,  "pool": 8},
        "mover": {"w": 1.9, "d": 0.9,  "y0": 0.0,  "y1": 2.9,  "pool": 6},
        "drone": {"w": 1.7, "d": 0.9,  "y0": 1.22, "y1": 2.7, "pool": 6},
}

## 26 模式库（min=解锁距离 m；r=随机道 all=三道 m=中道）
const PATTERNS := [
        {"min": 0, "obs": [["r", "low"]], "chips": [["r", 2.3, 0]]},
        {"min": 0, "obs": [["r", "low"], ["r", "low", 7]], "chips": [["r", 2.3, 3.5]]},
        {"min": 0, "obs": [["all", "bar"]], "chips": [["r", 0.55, 0]]},
        {"min": 0, "obs": [], "chips": [["m", 1.0, 0], ["m", 1.0, 3], ["m", 1.0, 6], ["m", 1.0, 9]]},
        {"min": 120, "obs": [["r", "block"]], "chips": []},
        {"min": 120, "obs": [["r", "low"], ["r", "bar"]], "chips": [["r", 2.3, 0]]},
        {"min": 160, "obs": [["r", "laser"]], "chips": [["r", 2.3, 0]]},
        {"min": 260, "obs": [[0, "block"], [2, "block"], [1, "low"]], "chips": [["r", 2.3, 0]]},
        {"min": 260, "obs": [["r", "block"], ["r", "bar"]], "chips": [["r", 0.55, 0]]},
        {"min": 300, "obs": [["m", "mover"]], "chips": []},
        {"min": 400, "obs": [["all", "low"], ["all", "bar", 10]], "chips": [["m", 2.3, 0], ["m", 0.55, 10]]},
        {"min": 400, "obs": [["r", "gate"]], "chips": []},
        {"min": 460, "obs": [["r", "laser"], ["r", "laser", 8]], "chips": [["r", 2.3, 4]]},
        {"min": 560, "obs": [[0, "block"], [2, "block"]], "chips": []},
        {"min": 560, "obs": [["r", "low"], ["r", "low", 7], ["r", "low", 14], ["r", "low", 21]], "chips": [["r", 2.3, 4]]},
        {"min": 620, "obs": [["m", "mover"], ["r", "laser", 10]], "chips": [["m", 2.3, 5]]},
        {"min": 720, "obs": [["r", "block"], ["r", "gate", 9]], "chips": [["m", 1.0, 4]]},
        {"min": 720, "obs": [["all", "bar"], ["r", "block", 9]], "chips": [["m", 0.55, 0]]},
        {"min": 800, "obs": [["r", "mover"], ["r", "mover", 9]], "chips": []},
        {"min": 900, "obs": [[0, "gate"], [2, "gate"], [1, "low", 8]], "chips": []},
        {"min": 1000, "obs": [["all", "laser"], ["all", "bar", 13]], "chips": [["m", 0.55, 5]]},
        # —— 哨戒无人机 ——
        {"min": 150, "obs": [["r", "drone"]], "chips": [["r", 0.55, 0]]},
        {"min": 350, "obs": [["r", "drone"], ["r", "low", 9]], "chips": [["m", 2.3, 4]]},
        {"min": 500, "obs": [["r", "drone"], ["r", "drone", 9]], "chips": [["m", 0.55, 4]]},
        {"min": 700, "obs": [["r", "block"], ["r", "drone", 9]], "chips": [["m", 0.55, 9]]},
        # 先遇到三道无人机（滑铲可过），再遇到三道低障碍（起跳可过）。
        # 注意：障碍按 o.z += speed * dt 向玩家移动，dz 越小越先到；顺序参数不能写反。
        {"min": 950, "obs": [["all", "drone"], ["all", "low", 10]], "chips": [["m", 2.3, 10]]},
]


var pools: Dictionary = {}          # type -> Array[Dictionary]
var chip_pool: Array = []
var powerup_pool: Array = []
var next_spawn_z: float = -86.0
var boss_on: bool = false
# DDA（外部注入；reset 禁触）
var dda_gap: float = 1.0
var dda_unlock: float = 0.0
var _time: float = 0.0
var _last_pattern: Dictionary = {}
var _pu_cooldown: int = 2
var mech: String = ""     # 章节机制（main 每帧同步）
var _rng: Callable = U.mulberry32(2099)
var _run_seed: int = 2099

# ---- 渲染资产（类型级共享） ----
var _mats: Dictionary = {}
var _glow_base_energy: Dictionary = {}
const GLOW_PHASES := {
        "cyanGlow": 0.0,
        "yellowGlow": 1.3,
        "magentaGlow": 2.5,
        "redGlow": 3.7,
        "whiteGlow": 0.8,
        "chip": 1.9,
        "laserBeam": 4.4,
}
var _obstacle_tints: Array[Color] = [Color("B6C8DF"), Color("D9A6C3"), Color("C7B4F4"), Color("9EDCD8")]
var _laser_warn: bool = false
var _chamfered_box_mesh: Mesh
var _drone_core_mesh: Mesh

func _ready() -> void:
        _chamfered_box_mesh = _extract_first_mesh(CHAMFERED_BOX_SCENE)
        _drone_core_mesh = _extract_first_mesh(DRONE_CORE_SCENE)
        _build_materials()
        _build_pools()
        _sync_instances()

# ---------- 外观 ----------

func _extract_first_mesh(scene: PackedScene) -> Mesh:
        var imported_root: Node = scene.instantiate()
        var found_mesh: Mesh = null
        if imported_root is MeshInstance3D:
                found_mesh = (imported_root as MeshInstance3D).mesh
        else:
                var mesh_nodes: Array[Node] = imported_root.find_children("*", "MeshInstance3D", true, false)
                for candidate in mesh_nodes:
                        if candidate is MeshInstance3D and (candidate as MeshInstance3D).mesh != null:
                                found_mesh = (candidate as MeshInstance3D).mesh
                                break
        imported_root.free()
        return found_mesh

func _build_materials() -> void:
        var p: Dictionary = Config.PALETTE
        var hazard_material := _std(Color(0.13, 0.14, 0.22), true)
        # MultiMesh instance colors tint only the dark armor shell; glow parts keep their authored hue.
        hazard_material.vertex_color_use_as_albedo = true
        _mats = {
                "hazard": hazard_material,
                "hazardStripe": _std(p.magenta, false),
                "cyanGlow": _glow(p.cyan),
                "yellowGlow": _glow(p.yellow),
                "magentaGlow": _glow(p.magenta),
                "redGlow": _glow(Color(1.0, 0.13, 0.2)),
                "whiteGlow": _glow(Color(0.79, 0.96, 1.0)),
                "chip": _glow(p.yellow),
                "laserBeam": _glow(Color(1.0, 0.2, 0.27), 3.0),
        }
        for key in ["cyanGlow", "yellowGlow", "magentaGlow", "redGlow", "whiteGlow", "chip", "laserBeam"]:
                var glow_material: StandardMaterial3D = _mats[key]
                _glow_base_energy[key] = glow_material.emission_energy_multiplier

func _std(color: Color, hazard: bool) -> StandardMaterial3D:
        var m := StandardMaterial3D.new()
        m.albedo_color = color
        m.detail_enabled = true
        m.detail_albedo = ARMOR_ALBEDO
        m.detail_normal = ARMOR_NORMAL
        m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
        m.roughness_texture = ARMOR_ROUGHNESS
        m.uv1_scale = Vector3(0.80, 0.80, 1.0)
        m.metallic = 0.75
        m.roughness = 0.35
        if hazard:
                m.emission_enabled = true
                m.emission = color * 0.3
                m.emission_energy_multiplier = 0.5
        return m

func _glow(color: Color, energy := 2.2) -> StandardMaterial3D:
        var m := StandardMaterial3D.new()
        m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        m.albedo_color = color
        m.emission_enabled = true
        m.emission = color
        m.emission_energy_multiplier = energy
        return m

# The live obstacle renderer is the type-level MultiMesh pipeline below; the old per-instance Node3D prototype path was removed to avoid maintaining two visual implementations.

func _make_arc_mat() -> StandardMaterial3D:
        var m := _glow(Config.PALETTE.cyan, 1.6)
        m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        return m

func _make_cone_mat() -> StandardMaterial3D:
        var m := _glow(Color(1.0, 0.13, 0.2), 0.8)
        m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        m.albedo_color.a = 0.16
        return m

## 渲染架构：逻辑池 + 类型级 MultiMesh；逻辑更新与实例批量写入分开。
## 部件表：type → [{mesh, mat, off, spin}]（spin: beam自转/rotor桨转/chip芯片转/pu道具转）
## 渲染 DC 与活动数解耦：每类型每部件 1 个 MultiMeshInstance3D 封顶。
var _mm: Dictionary = {}          # type → Array[MultiMeshInstance3D]
var _part_tables: Dictionary = {} # type → Array[部件描述]

func _part(w: float, h: float, d: float, mat: Material, ox := 0.0, oy := 0.0, oz := 0.0, spin := "") -> Dictionary:
        if _chamfered_box_mesh != null:
                return _part_mesh(_chamfered_box_mesh, mat, Vector3(ox, oy, oz), spin, Vector3.ZERO, Vector3(w, h, d))
        # Robust fallback for editor/import failures: retain original visible shape.
        return _part_mesh(_box_mesh(w, h, d), mat, Vector3(ox, oy, oz), spin)

func _part_mesh(mesh: Mesh, mat: Material, offset: Vector3, spin := "", rotation := Vector3.ZERO, scale := Vector3.ONE) -> Dictionary:
        # Base orientation is static for each part. Calculate it once during scene setup,
        # instead of rebuilding Euler bases for every active MultiMesh slot every frame.
        return {"mesh": mesh, "mat": mat, "off": offset, "spin": spin, "base_basis": Basis.from_euler(rotation), "scale": scale}

func _cylinder_mesh(radius: float, height: float, segments: int = 12, top_radius: float = -1.0) -> CylinderMesh:
        var mesh := CylinderMesh.new()
        mesh.top_radius = radius if top_radius < 0.0 else top_radius
        mesh.bottom_radius = radius
        mesh.height = height
        mesh.radial_segments = segments
        mesh.rings = 2
        return mesh

func _sphere_mesh() -> SphereMesh:
        var mesh := SphereMesh.new()
        mesh.radius = 0.5
        mesh.height = 1.0
        mesh.radial_segments = 16
        mesh.rings = 10
        return mesh

func _torus_mesh(inner_radius: float, outer_radius: float) -> TorusMesh:
        var mesh := TorusMesh.new()
        mesh.inner_radius = inner_radius
        mesh.outer_radius = outer_radius
        mesh.rings = 12
        mesh.ring_segments = 20
        return mesh

func _box_mesh(w: float, h: float, d: float) -> BoxMesh:
        var bm := BoxMesh.new()
        bm.size = Vector3(w, h, d)
        return bm

func _parts_for(type: String) -> Array:
        match type:
                "low":
                        var low_parts: Array = [
                                _part(OB.low.w, 0.78, OB.low.d, _mats.hazard, 0, 0.39, 0),
                                _part(OB.low.w * 0.88, 0.045, OB.low.d + 0.04, _mats.cyanGlow, 0, 0.80, 0),
                                _part_mesh(_cylinder_mesh(0.075, OB.low.w * 0.86, 12), _mats.hazardStripe, Vector3(0, 0.68, 0.0), "", Vector3(0, 0, PI / 2.0)),
                        ]
                        # Front-facing service hatch and vents add scale cues to the broad slab.
                        low_parts.append(_part(OB.low.w * 0.40, 0.22, 0.024, _mats.hazardStripe, 0, 0.43, OB.low.d * 0.5 + 0.016))
                        for vent in range(3):
                                low_parts.append(_part(OB.low.w * 0.23, 0.018, 0.018, _mats.cyanGlow, 0, 0.38 + float(vent) * 0.045, OB.low.d * 0.5 + 0.034))
                        for side in [-1.0, 1.0]:
                                low_parts.append(_part_mesh(_sphere_mesh(), _mats.yellowGlow, Vector3(side * 0.78, 0.44, 0.34), "", Vector3.ZERO, Vector3(0.13, 0.13, 0.13)))
                                low_parts.append(_part_mesh(_cylinder_mesh(0.045, 0.48, 8), _mats.hazardStripe, Vector3(side * 0.89, 0.42, 0.0)))
                        return low_parts
                "bar":
                        var bar_parts: Array = [
                                _part(OB.bar.w, 0.38, OB.bar.d, _mats.hazard, 0, (OB.bar.y0 + OB.bar.y1) / 2.0, 0),
                                _part_mesh(_cylinder_mesh(0.075, OB.bar.w, 14), _mats.magentaGlow, Vector3(0, OB.bar.y1 + 0.01, 0), "", Vector3(0, 0, PI / 2.0)),
                                _part(OB.bar.w, 0.026, OB.bar.d + 0.06, _mats.yellowGlow, 0, OB.bar.y0 + 0.08, 0),
                        ]
                        for idx in range(5):
                                var xpos: float = -2.8 + float(idx) * 1.4
                                bar_parts.append(_part(0.065, 0.43, OB.bar.d + 0.07, _mats.hazardStripe, xpos, (OB.bar.y0 + OB.bar.y1) * 0.5, 0))
                        return bar_parts
                "block":
                        var block_parts: Array = [
                                _part(OB.block.w, OB.block.y1, OB.block.d, _mats.hazard, 0, OB.block.y1 / 2.0, 0),
                                _part(OB.block.w * 0.9, 0.06, OB.block.d + 0.05, _mats.yellowGlow, 0, OB.block.y1 - 0.15, 0),
                                _part(OB.block.w * 0.76, 0.035, OB.block.d + 0.07, _mats.cyanGlow, 0, 0.12, 0),
                        ]
                        # Raised front service panel, vent slats and corner beacons create depth.
                        block_parts.append(_part(OB.block.w * 0.54, OB.block.y1 * 0.48, 0.026, _mats.hazard, 0, OB.block.y1 * 0.56, OB.block.d * 0.5 + 0.015))
                        for vent in range(3):
                                block_parts.append(_part(OB.block.w * 0.30, 0.025, 0.018, _mats.hazardStripe, 0, OB.block.y1 * (0.43 + float(vent) * 0.075), OB.block.d * 0.5 + 0.04))
                        for side in [-1.0, 1.0]:
                                for depth_side in [-1.0, 1.0]:
                                        block_parts.append(_part_mesh(_cylinder_mesh(0.055, OB.block.y1 * 0.92, 10), _mats.hazardStripe, Vector3(side * 0.82, OB.block.y1 * 0.5, depth_side * 0.40)))
                                block_parts.append(_part_mesh(_sphere_mesh(), _mats.yellowGlow, Vector3(side * 0.80, OB.block.y1 - 0.22, OB.block.d * 0.5 + 0.03), "", Vector3.ZERO, Vector3(0.10, 0.10, 0.10)))
                        return block_parts
                "gate":
                        var post_mesh := _cylinder_mesh(0.105, 2.9, 12)
                        var gate_parts: Array = [
                                _part_mesh(post_mesh, _mats.hazard, Vector3(-0.95, 1.45, 0)),
                                _part_mesh(post_mesh, _mats.hazard, Vector3(0.95, 1.45, 0)),
                                _part(2.14, 0.19, 0.22, _mats.hazard, 0, 2.85, 0),
                                _part(1.72, 2.42, 0.025, _make_arc_mat(), 0, 1.45, 0),
                                _part(0.035, 2.58, 0.045, _mats.cyanGlow, -0.77, 1.43, 0.03),
                                _part(0.035, 2.58, 0.045, _mats.magentaGlow, 0.77, 1.43, 0.03),
                        ]
                        for side in [-1.0, 1.0]:
                                gate_parts.append(_part_mesh(_sphere_mesh(), _mats.whiteGlow, Vector3(side * 0.95, 2.88, 0.13), "", Vector3.ZERO, Vector3(0.12, 0.12, 0.12)))
                                gate_parts.append(_part_mesh(_torus_mesh(0.085, 0.12), _mats.cyanGlow, Vector3(side * 0.95, 2.48, 0.0), "rotor", Vector3(PI / 2.0, 0, 0), Vector3.ONE))
                        gate_parts.append(_part(1.42, 0.035, 0.05, _mats.whiteGlow, 0, 0.23, 0.055))
                        gate_parts.append(_part(1.42, 0.035, 0.05, _mats.magentaGlow, 0, 2.61, 0.055))
                        return gate_parts
                "laser":
                        var beam_parts: Array = [
                                _part_mesh(_cylinder_mesh(0.063, 1.82, 12), _mats.laserBeam, Vector3(0, 0.55, 0), "beam", Vector3(0, 0, PI / 2.0)),
                                _part(1.82, 0.12, 0.12, _mats.hazard, 0, 0.55, 0),
                        ]
                        for side in [-1.0, 1.0]:
                                beam_parts.append(_part_mesh(_cylinder_mesh(0.085, 0.56, 10), _mats.hazard, Vector3(side * 0.85, 0.27, 0)))
                                beam_parts.append(_part_mesh(_sphere_mesh(), _mats.redGlow, Vector3(side * 0.85, 0.59, 0.0), "", Vector3.ZERO, Vector3(0.13, 0.13, 0.13)))
                        return beam_parts
                "mover":
                        var hover_ring := _torus_mesh(0.36, 0.44)
                        return [
                                _part(OB.mover.w, OB.mover.y1, OB.mover.d, _mats.hazard, 0, OB.mover.y1 / 2.0, 0),
                                _part(OB.mover.w * 0.86, 0.06, OB.mover.d + 0.05, _mats.cyanGlow, 0, OB.mover.y1 - 0.16, 0),
                                _part_mesh(hover_ring, _mats.cyanGlow, Vector3(0, 0.12, 0), "rotor", Vector3(PI / 2.0, 0, 0), Vector3(2.25, 1.0, 2.25)),
                                _part_mesh(_cylinder_mesh(0.055, OB.mover.y1 * 0.86, 10), _mats.hazardStripe, Vector3(-0.78, OB.mover.y1 * 0.5, 0)),
                                _part_mesh(_cylinder_mesh(0.055, OB.mover.y1 * 0.86, 10), _mats.hazardStripe, Vector3(0.78, OB.mover.y1 * 0.5, 0)),
                        ]
                "drone":
                        var rotor_mesh := _torus_mesh(0.18, 0.24)
                        var cone_mesh := _cylinder_mesh(0.40, 0.78, 12, 0.0)
                        var drone_body_mesh: Mesh = _drone_core_mesh if _drone_core_mesh != null else _sphere_mesh()
                        var drone_body_scale: Vector3 = Vector3(0.94, 0.40, 0.84)
                        var drone_parts: Array = [
                                _part_mesh(drone_body_mesh, _mats.hazard, Vector3(0, 1.95, 0), "", Vector3.ZERO, drone_body_scale),
                                _part(0.56, 0.10, 0.58, _mats.hazardStripe, 0, 1.72, 0),
                                _part(0.98, 0.055, 0.12, _mats.hazard, 0, 2.05, 0),
                                _part_mesh(_sphere_mesh(), _mats.redGlow, Vector3(0, 1.94, 0.43), "", Vector3.ZERO, Vector3(0.22, 0.13, 0.08)),
                                _part_mesh(cone_mesh, _make_cone_mat(), Vector3(0, 1.24, 0.32)),
                        ]
                        for rx in [-0.62, 0.62]:
                                for rz in [-0.62, 0.62]:
                                        drone_parts.append(_part(0.38, 0.05, 0.08, _mats.hazard, rx, 2.10, rz))
                                        drone_parts.append(_part_mesh(rotor_mesh, _mats.cyanGlow, Vector3(rx, 2.15, rz), "rotor", Vector3(PI / 2.0, 0, 0), Vector3(1.3, 1.0, 1.3)))
                        # Dual camera glass and armored side fins make the GLB core read as a patrol unit.
                        drone_parts.append(_part_mesh(_sphere_mesh(), _mats.whiteGlow, Vector3(0, 1.82, 0.46), "", Vector3.ZERO, Vector3(0.14, 0.10, 0.07)))
                        for side in [-1.0, 1.0]:
                                drone_parts.append(_part(0.08, 0.28, 0.24, _mats.hazardStripe, side * 0.47, 1.92, -0.05))
                        return drone_parts
                "chip":
                        var gem := _cylinder_mesh(0.22, 0.26, 6, 0.025)
                        var ring := _torus_mesh(0.16, 0.19)
                        return [
                                _part_mesh(gem, _mats.chip, Vector3(0, 0.08, 0), "chip", Vector3.ZERO, Vector3(1.0, 1.0, 0.6)),
                                _part_mesh(gem, _mats.whiteGlow, Vector3(0, -0.08, 0), "chip", Vector3(PI, 0, 0), Vector3(0.72, 0.72, 0.45)),
                                _part_mesh(ring, _mats.cyanGlow, Vector3.ZERO, "chip", Vector3(PI / 2.0, 0, 0), Vector3(1.08, 1.0, 1.08)),
                        ]
                "powerup":
                        var output: Array = []
                        for kind in ["magnet", "shield", "double", "board"]:
                                var color: Color = Config.POWERUPS[kind].color
                                var core_mat := _glow(color, 2.3)
                                var ring_mesh := _torus_mesh(0.30, 0.38)
                                var core_mesh := _sphere_mesh()
                                var glyph_mat := _glow(Color.WHITE, 1.9)
                                output.append([
                                        _part_mesh(core_mesh, core_mat, Vector3.ZERO, "pu", Vector3.ZERO, Vector3(0.42, 0.42, 0.42)),
                                        _part_mesh(ring_mesh, core_mat, Vector3.ZERO, "pu", Vector3(PI / 2.0, 0, 0), Vector3(1.0, 1.0, 1.0)),
                                        _part(0.58, 0.045, 0.045, glyph_mat, 0, 0.44, 0, "pu"),
                                ])
                        return output
        return []

func _build_mm(type: String, count: int) -> void:
        var parts: Array = _parts_for(type)
        _part_tables[type] = parts
        var mms: Array = []
        if type == "powerup":
                # 道具：4 kind × 2 部件，每 kind 独立 MultiMesh（count=1 槽）
                for kind_parts in parts:
                        var kmms: Array = []
                        for part in kind_parts:
                                kmms.append(_mk_mm(part, 1))
                        mms.append(kmms)
        else:
                for part in parts:
                        mms.append(_mk_mm(part, count))
        _mm[type] = mms

func _mk_mm(part: Dictionary, count: int) -> MultiMeshInstance3D:
        var mmi := MultiMeshInstance3D.new()
        var mm := MultiMesh.new()
        mm.transform_format = MultiMesh.TRANSFORM_3D
        mm.use_colors = true
        mm.instance_count = count
        mm.mesh = part.mesh
        mmi.multimesh = mm
        mmi.material_override = part.mat
        mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   #：MultiMesh 阴影关（移动端 DC 优先）
        add_child(mmi)
        return mmi

func _build_pools() -> void:
        for type in OB.keys():
                var arr: Array = []
                for i in OB[type].pool:
                        arr.append({
                                "active": false, "node": null, "type": type,
                                "x": 0.0, "z": 0.0, "y0": OB[type].y0, "y1": OB[type].y1,
                                "w": OB[type].w, "d": OB[type].d, "phase": 0.0, "style": 0, "_mt": 0.0,
                                "_nmDone": false, "_sd": false, "_render_active": true, "_render_style": -1,
                        })
                pools[type] = arr
                _build_mm(type, OB[type].pool)
        # 芯片池（40）
        for i in 40:
                chip_pool.append({"active": false, "x": 0.0, "y": 0.0, "z": 0.0, "phase": randf() * 2.0, "_render_active": true})
        _build_mm("chip", 40)
        # 道具池（4 kind × 1 槽）
        for i in 4:
                powerup_pool.append({"active": false, "kind": POWERUP_KINDS[i], "x": 0.0, "y": 0.0, "z": 0.0, "phase": randf() * 2.0, "_render_active": true})
        _build_mm("powerup", 1)

## 每帧把活动实例 world transform 写入 MultiMesh 槽位（零缩放收口非活动）
func _sync_instances() -> void:
        var xf := Transform3D()
        for type in pools:
                var parts: Array = _part_tables[type]
                var mms: Array = _mm[type]
                for i in pools[type].size():
                        var o: Dictionary = pools[type][i]
                        var active: bool = o.active
                        if not active:
                                # Hidden pool slots already have zero transforms. Write them
                                # only on the active→inactive edge instead of every 60Hz tick.
                                if bool(o.get("_render_active", false)):
                                        for p_idx in parts.size():
                                                var hidden_mm: MultiMesh = mms[p_idx].multimesh
                                                hidden_mm.set_instance_transform(i, xf.scaled_local(Vector3.ZERO))
                                                hidden_mm.reset_instance_physics_interpolation(i)
                                        o["_render_active"] = false
                                continue
                        var just_activated: bool = not bool(o.get("_render_active", false))
                        if just_activated:
                                o["_render_active"] = true
                        var pos := Vector3(o.x, 0.0, o.z)
                        if type == "drone":
                                pos.y = sin(_time * 2.2 + o.z) * 0.12
                        var style_idx: int = posmod(int(o.get("style", 0)), _obstacle_tints.size())
                        var style_changed: bool = int(o.get("_render_style", -1)) != style_idx
                        for p_idx in parts.size():
                                var part: Dictionary = parts[p_idx]
                                var mm: MultiMesh = mms[p_idx].multimesh
                                var basis: Basis = part.base_basis
                                if part.spin == "beam":
                                        basis = Basis(Vector3.UP, _time * 3.2) * basis
                                elif part.spin == "rotor":
                                        basis = Basis(Vector3.UP, _time * 7.0 + float(i)) * basis
                                basis = basis.scaled(part.scale)
                                mm.set_instance_transform(i, Transform3D(basis, pos + part.off))
                                if just_activated:
                                        mm.reset_instance_physics_interpolation(i)
                                # Per-instance tint changes only when this pooled obstacle gets a new style.
                                if style_changed and part.mat == _mats.hazard:
                                        mm.set_instance_color(i, _obstacle_tints[style_idx])
                        if style_changed:
                                o["_render_style"] = style_idx
        # 芯片
        var chip_parts: Array = _part_tables.chip
        var chip_mms: Array = _mm.chip
        for i in chip_pool.size():
                var c: Dictionary = chip_pool[i]
                if not c.active:
                        if bool(c.get("_render_active", false)):
                                for part_idx in chip_mms.size():
                                        var hidden_chip_mm: MultiMesh = chip_mms[part_idx].multimesh as MultiMesh
                                        hidden_chip_mm.set_instance_transform(i, xf.scaled_local(Vector3.ZERO))
                                        hidden_chip_mm.reset_instance_physics_interpolation(i)
                                c["_render_active"] = false
                        continue
                var chip_just_activated: bool = not bool(c.get("_render_active", false))
                if chip_just_activated:
                        c["_render_active"] = true
                var pos := Vector3(c.x, c.y + sin(_time * 3.0 + c.phase) * 0.1, c.z)
                for part_idx in chip_mms.size():
                        var part: Dictionary = chip_parts[part_idx]
                        var basis: Basis = Basis(Vector3.UP, c.phase + _time * 3.2) * part.base_basis
                        basis = basis.scaled(part.scale)
                        var chip_mm: MultiMesh = chip_mms[part_idx].multimesh
                        chip_mm.set_instance_transform(i, Transform3D(basis, pos + part.off))
                        if chip_just_activated:
                                chip_mm.reset_instance_physics_interpolation(i)
        # 道具（每 kind 独立组，kind 索引即槽）。State transitions are handled
        # outside the part loop so every component is hidden/reset together.
        for k_idx in POWERUP_KINDS.size():
                if k_idx >= powerup_pool.size():
                        break
                var p: Dictionary = powerup_pool[k_idx]
                if str(p.get("kind", "")) != POWERUP_KINDS[k_idx]:
                        continue
                var kind_mms: Array = _mm.powerup[k_idx]
                var parts_for_kind: Array = _part_tables.powerup[k_idx]
                if not p.active:
                        if bool(p.get("_render_active", false)):
                                for p_idx in kind_mms.size():
                                        var hidden_powerup_mm: MultiMesh = kind_mms[p_idx].multimesh
                                        hidden_powerup_mm.set_instance_transform(0, xf.scaled_local(Vector3.ZERO))
                                        hidden_powerup_mm.reset_instance_physics_interpolation(0)
                                p["_render_active"] = false
                        continue
                var powerup_just_activated: bool = not bool(p.get("_render_active", false))
                if powerup_just_activated:
                        p["_render_active"] = true
                for p_idx in kind_mms.size():
                        var part: Dictionary = parts_for_kind[p_idx]
                        var mm: MultiMesh = kind_mms[p_idx].multimesh
                        var bas: Basis = Basis(Vector3.UP, p.phase + _time * 1.2) * part.base_basis
                        bas = bas.scaled(part.scale)
                        var ppos: Vector3 = Vector3(p.x, p.y + sin(_time * 2.6 + p.phase) * 0.14, p.z) + part.off
                        mm.set_instance_transform(0, Transform3D(bas, ppos))
                        if powerup_just_activated:
                                mm.reset_instance_physics_interpolation(0)

# ---------- 池操作 ----------

func _take(type: String) -> Dictionary:
        for o in pools[type]:
                if not o.active:
                        return o
        return {}

func _take_chip() -> Dictionary:
        for c in chip_pool:
                if not c.active:
                        return c
        return {}

func _take_powerup() -> Dictionary:
        for p in powerup_pool:
                if not p.active:
                        return p
        return {}


func reset(seed_value: int = 0) -> void:
        _run_seed = seed_value if seed_value != 0 else max(1, int(Time.get_ticks_usec() & 0x7FFFFFFF))
        _rng = U.mulberry32(_run_seed)
        _last_pattern = {}
        _time = 0.0
        boss_on = false
        mech = ""
        print("[spawner] deterministic run seed=%d" % _run_seed)
        for type in pools:
                for o in pools[type]:
                        o.active = false
        for c in chip_pool:
                c.active = false
        for p in powerup_pool:
                p.active = false
        next_spawn_z = -86.0
        _pu_cooldown = 2     # 开局暖机：第三模式起才可能出道具
        #：DDA 乘子/解锁偏移禁在此重置（main.startRun 先赋值后调 reset）
        _laser_warn = false
        _sync_instances()

# ---------- Seeded randomness (gameplay-only) ----------

func _random_range(min_value: float, max_value: float) -> float:
        return lerpf(min_value, max_value, float(_rng.call()))

func _random_int(min_value: int, max_value: int) -> int:
        if max_value <= min_value:
                return min_value
        return min_value + floori(float(_rng.call()) * float(max_value - min_value + 1))

func _random_choice(items: Array) -> Variant:
        if items.is_empty():
                return null
        return items[_random_int(0, items.size() - 1)]

func _shuffle_deterministic(items: Array) -> void:
        for i in range(items.size() - 1, 0, -1):
                var j := _random_int(0, i)
                var tmp: Variant = items[i]
                items[i] = items[j]
                items[j] = tmp

# ---------- 模式放置 ----------

func _candidate_pattern_pool(difficulty: float, laser_boost: bool) -> Array:
        # Deterministic candidate construction is separate from RNG selection so
        # difficulty/weight rules can be tested without flaky Monte Carlo samples.
        var avail: Array = []
        var effective_difficulty: float = maxf(0.0, difficulty)
        for pattern in PATTERNS:
                if pattern.min <= effective_difficulty:
                        avail.append(pattern)
                        if laser_boost and "laser" in JSON.stringify(pattern.obs):
                                for _copy_index in range(maxi(0, int(Config.MECH_CFG.laserWeightMult) - 1)):
                                        avail.append(pattern)
        # New-player protection can pass a negative difficulty; always fall back
        # to base patterns rather than selecting from an empty array.
        if avail.is_empty():
                for candidate in PATTERNS:
                        if candidate.min == 0:
                                avail.append(candidate)
        return avail

func _pick_pattern(difficulty: float) -> Dictionary:
        var avail: Array = _candidate_pattern_pool(difficulty, mech == "laser")
        if avail.is_empty():
                return {"min": 0, "obs": [], "chips": []}
        var p: Dictionary = _random_choice(avail)
        if p == _last_pattern and _rng.call() < 0.7:
                p = _random_choice(avail)
        _last_pattern = p
        return p

func _resolve_lane(spec) -> int:
        # 修复：spec 可能是 String（r/all/m）或 int（固定道 0/1/2）——
        # GDScript 类型严格；比较外部模式数据前先确认字段类型。
        if spec is String:
                if spec == "all":
                        return -1
                if spec == "m":
                        return 1
                if spec == "r":
                        return _random_int(0, 2)
        return int(spec)

func _place_pattern(pattern: Dictionary) -> float:
        var pattern_len := 12.0
        for obs in pattern.obs:
                var lane: int = _resolve_lane(obs[0])
                var type: String = obs[1]
                var dz: float = obs[2] if obs.size() > 2 else 0.0
                var xs: PackedFloat32Array = Config.LANES if lane == -1 else PackedFloat32Array([Config.LANES[lane]])
                for x in xs:
                        var o: Dictionary = _take(type)
                        if o.is_empty():
                                continue
                        o.active = true
                        o.x = x
                        o.z = next_spawn_z - dz
                        o.phase = _random_range(0.0, 2.0)
                        o.style = _random_int(0, _obstacle_tints.size() - 1)
                        o._nmDone = false
                        o._sd = false
                        o._laserWarned = false
                        o.type = type
                pattern_len = maxf(pattern_len, dz + 12.0)
        for ch in pattern.chips:
                var lane: int = _resolve_lane(ch[0])
                var x: float = Config.LANES[lane]
                var y: float = ch[1]
                var dz: float = ch[2]
                var n: int = 4 if dz > 4 else 2
                for i in n:
                        var c: Dictionary = _take_chip()
                        if c.is_empty():
                                break
                        c.active = true
                        c.x = x
                        c.y = y
                        c.z = next_spawn_z - dz - i * 3.0
        # —— 道具投放（冷却约束；避开障碍正上方） ——
        if _pu_cooldown > 0:
                _pu_cooldown -= 1
        elif _rng.call() < Config.POWERUP_CFG.spawnChance:
                var pu: Dictionary = _take_powerup()
                if not pu.is_empty():
                        var first_lane: int = _random_int(0, 2)
                        var first_dz: float = float(_random_int(2, 7))
                        var chosen_lane: int = -1
                        var chosen_dz: float = 0.0
                        # Search bounded candidate positions across all three lanes.
                        # A failed search must skip the drop rather than forcing a
                        # pickup into an obstacle's collision envelope.
                        for lane_offset in 3:
                                var candidate_lane: int = (first_lane + lane_offset) % 3
                                for depth_offset in 6:
                                        var candidate_dz: float = first_dz + float(depth_offset * 2)
                                        if not _lane_blocked(candidate_lane, next_spawn_z - candidate_dz):
                                                chosen_lane = candidate_lane
                                                chosen_dz = candidate_dz
                                                break
                                if chosen_lane >= 0:
                                        break
                        if chosen_lane >= 0 and not _lane_blocked(chosen_lane, next_spawn_z - chosen_dz):
                                pu.active = true
                                pu.x = Config.LANES[chosen_lane]
                                pu.y = 1.15
                                pu.z = next_spawn_z - chosen_dz
                        else:
                                pu.active = false
                        # Avoid repeatedly re-rolling an impossible cluster of drops.
                        _pu_cooldown = int(Config.POWERUP_CFG.minInterval)
        return pattern_len

func _lane_blocked(lane: int, z: float) -> bool:
        for type in pools:
                for o in pools[type]:
                        if not o.active:
                                continue
                        if absf(o.z - z) < o.d / 2.0 + 1.4 and absf(o.x - Config.LANES[lane]) < o.w / 2.0 + 1.0:
                                return true
        return false

## BOSS 围剿波：2 台无人机编队突入（随机留一条活路）
func boss_burst() -> void:
        var lanes := [0, 1, 2]
        _shuffle_deterministic(lanes)
        for i in 2:
                var o: Dictionary = _take("drone")
                if o.is_empty():
                        break
                o.active = true
                o.x = Config.LANES[lanes[i]]
                o.z = -84.0 - _random_range(0.0, 6.0)
                o._nmDone = true      # BOSS 波不算贴身闪避（防刷分）

# ---------- 帧更新 ----------

func update(dt: float, spd: float, difficulty: float, state: String) -> void:
        _time += dt
        _update_warning_pulses()
        # 移动 & 回收障碍（：纯逻辑，渲染由 _sync_instances 统一收口）
        var laser_visual_synced := false
        for type in pools:
                for o in pools[type]:
                        if not o.active:
                                continue
                        o.z += spd * dt
                        if type == "laser":
                                # All beams share one material; update its pulse once per frame,
                                # not once per active beam instance.
                                if not laser_visual_synced:
                                        _mats.laserBeam.albedo_color = Color(1.0, 0.2 + 0.13 * sin(_time * 8.0), 0.27)
                                        laser_visual_synced = true
                                if mech == "laser" and o.z > -30.0 and o.z < 4.0 and not o.get("_laserWarned", false):
                                        o._laserWarned = true
                                        if not _laser_warn:
                                                _laser_warn = true
                                                laser_warning.emit()
                                elif o.z >= 4.0 or o.z <= -30.0:
                                        if not _has_laser_warning_zone():
                                                _laser_warn = false
                        if type == "mover":
                                # 横移节奏随游戏速度缩放
                                o._mt += dt * (0.55 + spd * 0.028)
                                var phase: float = fmod(o._mt + o.phase, 2.0)
                                var k: float = phase if phase < 1.0 else 2.0 - phase
                                o.x = -2.3 + k * 4.6
                        if o.z > 10.0:
                                o.active = false
        # 道具（浮动/自转由 sync 处理）
        for p in powerup_pool:
                if not p.active:
                        continue
                p.z += spd * dt
                if p.z > 10.0:
                        p.active = false
        # 芯片（浮动/自转由 sync 处理）
        for c in chip_pool:
                if not c.active:
                        continue
                c.z += spd * dt
                if c.z > 10.0:
                        c.active = false
        # 生成
        if state == "running":
                next_spawn_z += spd * dt
                if next_spawn_z > -80.0:
                        var pattern := _pick_pattern(difficulty + dda_unlock)
                        var len := _place_pattern(pattern)
                        var gap: float = U.clampf(spd * 0.72, 10.0, 26.0) * (0.7 if boss_on else 1.0) * dda_gap
                        next_spawn_z -= (len + gap)
        # 所有逻辑池移动完成后统一同步 MultiMesh，避免模型停留在原点或首帧不显示。
        _sync_instances()

func _update_warning_pulses() -> void:
        # Cached phase table: animate shared materials without allocating dictionaries per frame.
        for key in GLOW_PHASES:
                var material: StandardMaterial3D = _mats[key]
                var pulse: float = 0.88 + 0.18 * (0.5 + 0.5 * sin(_time * 3.1 + float(GLOW_PHASES[key])))
                material.emission_energy_multiplier = float(_glow_base_energy[key]) * pulse

func _has_laser_warning_zone() -> bool:
        for o in pools.get("laser", []):
                if o.active and o.z > -30.0 and o.z < 4.0:
                        return true
        return false

# ---------- 碰撞检测 ----------

class HitResult:
        var hit: Dictionary = {}
        var chip: bool = false
        var chips: int = 0
        var smashed: int = 0
        var overclock_smashed: int = 0
        var near_miss: bool = false
        var powerup: String = ""

        func reset() -> void:
                # Replace the dictionary reference instead of clearing it: `hit` may
                # refer to a pooled obstacle dictionary owned by Spawner.
                hit = {}
                chip = false
                chips = 0
                smashed = 0
                overclock_smashed = 0
                near_miss = false
                powerup = ""

# `check` returns this borrowed result object. Main must consume it synchronously
# before the next check call; no per-physics-frame result allocation is needed.
var _cached_hit_result: HitResult = HitResult.new()
var _cached_hit_obstacles: Array[Dictionary] = []
var _player_bounds_cache: Dictionary = {"x0": 0.0, "x1": 0.0, "z0": -0.45, "z1": 0.45, "y0": 0.05, "y1": 1.68}

func check(player: Player, overclocking: bool, magnet: bool, board: bool, dt: float) -> HitResult:
        var R: HitResult = _cached_hit_result
        R.reset()
        var b: Dictionary = player_bounds(player)
        var hit_obs: Array[Dictionary] = _cached_hit_obstacles
        hit_obs.clear()
        var chip_taken := 0
        var board_smashed := 0

        for type in pools:
                for o in pools[type]:
                        if not o.active:
                                continue
                        var oz0: float = o.z - o.d / 2.0
                        var oz1: float = o.z + o.d / 2.0
                        if oz1 < b.z0 or oz0 > b.z1:
                                continue
                        if b.x1 < o.x - o.w / 2.0 or b.x0 > o.x + o.w / 2.0:
                                continue
                        if b.y1 < o.y0 or b.y0 > o.y1:
                                continue
                        # 悬浮板：贴地障碍直接碾压
                        if board and (type == "low" or type == "laser"):
                                smash_obstacle(o)
                                board_smashed += 1
                                continue
                        hit_obs.append(o)

        # 芯片收集 + J-4 磁吸
        var py_mid: float = player.y + (0.45 if player.sliding else 0.85)
        var near_x: float = 2.6 if magnet else 1.05
        var near_y: float = 1.8 if magnet else 1.25
        var mag_r: float = (3.2 if magnet else 1.6) * (1.5 if player.skill_phantom else 1.0)
        for c in chip_pool:
                if not c.active:
                        continue
                var dx: float = player.x - c.x
                var dy: float = py_mid - c.y
                var dz: float = -c.z
                var d2: float = dx * dx + dy * dy + dz * dz
                if d2 < mag_r * mag_r:
                        var d: float = maxf(sqrt(d2), 0.0001)
                        var k: float = 1.0 - d / mag_r
                        var v: float = (2.0 + 30.0 * k * k) * dt
                        c.x += (dx / d) * v
                        c.y += (dy / d) * v
                        c.z += (dz / d) * v
                if absf(c.z) > (1.3 if magnet else 0.85):
                        continue
                if absf(c.x - player.x) > near_x:
                        continue
                if absf(c.y - py_mid) > near_y:
                        continue
                c.active = false
                chip_taken += 1
                chip_collected.emit(c.x, c.y)

        # 道具拾取
        for p in powerup_pool:
                if not p.active:
                        continue
                if absf(p.z) > 0.95:
                        continue
                if absf(p.x - player.x) > 1.05:
                        continue
                if absf((p.y + sin(_time * 2.6 + p.phase) * 0.14) - py_mid) > 1.5:
                        continue
                p.active = false
                powerup_collected.emit(p.kind, p.x, p.y)

        R.chip = chip_taken > 0
        R.chips = chip_taken
        R.smashed = board_smashed
        if hit_obs.size() > 0:
                if overclocking:
                        for o in hit_obs:
                                smash_obstacle(o)
                        R.smashed += hit_obs.size()
                        R.overclock_smashed = hit_obs.size()
                        return R
                R.hit = hit_obs[0]
                return R
        # 贴身闪避（bar 排除）
        if not overclocking:
                for type in pools:
                        if type == "bar":
                                continue
                        for o in pools[type]:
                                if not o.active or o._nmDone:
                                        continue
                                if o.z > 0.45 and o.z < 1.6:
                                        o._nmDone = true
                                        if absf(o.x - player.x) < o.w / 2.0 + 0.55:
                                                R.near_miss = true
        # v11 滑铲闪避（含 bar）：只有障碍实际经过玩家横向碰撞范围时才计数。
        # 闪避统计还必须核对障碍与玩家车道重叠，避免跨车道误计。
        var emitted_slide_dodge: bool = false
        var player_half_width: float = (b.x1 - b.x0) * 0.5
        for type in pools:
                for o in pools[type]:
                        if not o.active or o._sd:
                                continue
                        if o.z > 0.6:
                                o._sd = true
                                var same_lane_path: bool = absf(o.x - player.x) < o.w * 0.5 + player_half_width
                                if player.sliding and same_lane_path and not emitted_slide_dodge:
                                        emitted_slide_dodge = true
                                        slide_dodged.emit()
        return R

func player_bounds(player: Player) -> Dictionary:
        # This private query is used only inside check; update the same dictionary
        # in place instead of allocating a fresh bounds object every physics tick.
        var hx: float = 0.42 * (0.85 if player.skill_ghost else 1.0)
        var y_top: float = 0.82 if player.sliding else 1.68
        _player_bounds_cache["x0"] = player.x - hx
        _player_bounds_cache["x1"] = player.x + hx
        _player_bounds_cache["z0"] = -0.45
        _player_bounds_cache["z1"] = 0.45
        _player_bounds_cache["y0"] = player.y + 0.05
        _player_bounds_cache["y1"] = player.y + y_top
        return _player_bounds_cache

func smash_obstacle(o: Dictionary) -> void:
        var col: Color = Config.PALETTE.yellow if o.type == "block" else (Config.PALETTE.cyan if o.type == "bar" else Config.PALETTE.magenta)
        smashed.emit(o.x, (o.y0 + o.y1) / 2.0, col)
        o.active = false

## 复活清场：清空玩家前方 radius 深度内障碍（保留芯片与道具）
func clear_zone(radius: float) -> void:
        for type in pools:
                if type == "chip" or type == "powerup":
                        continue
                for o in pools[type]:
                        if o.active and o.z > -radius:
                                o.active = false
