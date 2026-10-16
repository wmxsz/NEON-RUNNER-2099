"""Generate procedural glTF assets used by the Godot game.
Requires Python packages trimesh, numpy and Pillow. Generated models are exported as GLB.
"""
from pathlib import Path
import math
import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial
from trimesh.visual.texture import TextureVisuals
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "models"
OUT.mkdir(parents=True, exist_ok=True)


def material(name, color, metallic=0.2, roughness=0.4, emission=None):
    return PBRMaterial(
        name=name,
        baseColorFactor=[int(color[0]), int(color[1]), int(color[2]), 255],
        metallicFactor=float(metallic),
        roughnessFactor=float(roughness),
        emissiveFactor=list(emission or [0.0, 0.0, 0.0]),
    )

M = {
    # Slightly lower metalness and lifted midtones keep surfaces readable without
    # reflection probes; bevel highlights and normal maps now do more of the work.
    "dark": material("Ceramic titanium", [44, 54, 73], 0.52, 0.30),
    "mid": material("Brushed alloy", [98, 118, 144], 0.62, 0.29),
    "light": material("Edge titanium", [185, 205, 225], 0.54, 0.25),
    "glass": material("Ion glass", [26, 134, 172], 0.30, 0.18, [0.015, 0.18, 0.29]),
    "cyan": material("Cyan lightguide", [0, 220, 255], 0.18, 0.24, [0.0, 0.88, 1.0]),
    "pink": material("Magenta lightguide", [255, 35, 138], 0.18, 0.26, [0.95, 0.03, 0.32]),
    "amber": material("Amber signal", [255, 149, 55], 0.16, 0.28, [1.0, 0.25, 0.03]),
    "red": material("Warning optics", [255, 26, 58], 0.12, 0.2, [1.0, 0.02, 0.06]),
    "building": material("Obsidian cladding", [28, 38, 58], 0.54, 0.35),
    "building2": material("Blue titanium facade", [52, 72, 101], 0.56, 0.31),
}


def add_planar_uvs(mesh, source_material):
    """Duplicate triangle vertices and assign stable planar UVs for textured runtime overrides.

    A mesh without TEXCOORD_0 cannot show the armor detail/normal/roughness maps when
    Godot applies its runtime material layer. A tiny white base-color texture forces the
    GLB exporter to retain UVs; runtime verifies this 2x2 placeholder, clears its redundant
    sampler, preserves the imported albedo_color factor, and adds the native detail overlay.
    """
    source = mesh.copy()
    tri_vertices = np.asarray(source.vertices[source.faces], dtype=np.float64).reshape(-1, 3)
    tri_faces = np.arange(len(tri_vertices), dtype=np.int64).reshape(-1, 3)
    face_normals = np.asarray(source.face_normals, dtype=np.float64)
    uv = np.zeros((len(tri_vertices), 2), dtype=np.float64)
    bounds_min = np.asarray(source.bounds[0], dtype=np.float64)
    extent = np.maximum(np.asarray(source.bounds[1] - source.bounds[0], dtype=np.float64), 1e-6)
    normalized_vertices = (tri_vertices - bounds_min) / extent
    for face_index in range(len(tri_faces)):
        sl = slice(face_index * 3, face_index * 3 + 3)
        normal = face_normals[face_index]
        # Project along the two tangent axes; normalized against this mesh's bounds so
        # small vehicles and tall landmarks both receive a valid non-clamped UV range.
        axes = np.argsort(np.abs(normal))[:2]
        uv[sl, :] = np.clip(normalized_vertices[sl][:, axes], 0.0, 1.0)
    source.vertices = tri_vertices
    source.faces = tri_faces
    source.visual = TextureVisuals(uv=uv, material=PBRMaterial(
        name=source_material.name,
        baseColorFactor=source_material.baseColorFactor,
        metallicFactor=source_material.metallicFactor,
        roughnessFactor=source_material.roughnessFactor,
        emissiveFactor=source_material.emissiveFactor,
        baseColorTexture=Image.new("RGBA", (2, 2), (255, 255, 255, 255)),
    ))
    source.fix_normals()
    return source


def transform_mesh(mesh, pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    mesh = mesh.copy()
    s = np.eye(4); s[0, 0], s[1, 1], s[2, 2] = scale
    mesh.apply_transform(s)
    rx, ry, rz = rot
    cx, sx = math.cos(rx), math.sin(rx)
    cy, sy = math.cos(ry), math.sin(ry)
    cz, sz = math.cos(rz), math.sin(rz)
    Rx = np.array([[1,0,0,0],[0,cx,-sx,0],[0,sx,cx,0],[0,0,0,1]])
    Ry = np.array([[cy,0,sy,0],[0,1,0,0],[-sy,0,cy,0],[0,0,0,1]])
    Rz = np.array([[cz,-sz,0,0],[sz,cz,0,0],[0,0,1,0],[0,0,0,1]])
    t = np.eye(4); t[:3, 3] = pos
    mesh.apply_transform(t @ Rz @ Ry @ Rx)
    return mesh


def add(scene, mesh, name, mat, pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    m = transform_mesh(mesh, pos, rot, scale)
    m.visual.material = mat
    scene.add_geometry(m, geom_name=name, node_name=name)


def beveled_box_mesh(extents, bevel_ratio=0.14, max_bevel=0.075):
    """Create a compact hard-surface cuboid with real chamfer faces.

    The bevel is tied to the thinnest dimension so tiny vents and light strips stay
    crisp, while larger armor plates and building masses catch a visible highlight.
    A convex hull keeps the mesh watertight and avoids extra per-part draw calls.
    """
    size = np.maximum(np.asarray(extents, dtype=np.float64), 1e-4)
    half = size * 0.5
    bevel = min(float(size.min()) * bevel_ratio, max_bevel)
    bevel = max(min(bevel, float(size.min()) * 0.45), 1e-5)
    points = []
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            for sz in (-1.0, 1.0):
                # Three points per original corner produce edge and corner chamfers.
                points.extend([
                    (sx * (half[0] - bevel), sy * half[1], sz * half[2]),
                    (sx * half[0], sy * (half[1] - bevel), sz * half[2]),
                    (sx * half[0], sy * half[1], sz * (half[2] - bevel)),
                ])
    mesh = trimesh.convex.convex_hull(np.asarray(points, dtype=np.float64))
    mesh.fix_normals()
    return mesh


def box(extents, name, mat, pos=(0, 0, 0), rot=(0, 0, 0)):
    # Consistent machined edges make aircraft, armor plates and skyline architecture
    # read as manufactured hard-surface objects instead of unprocessed primitives.
    return (beveled_box_mesh(extents), name, mat, pos, rot, (1, 1, 1))


def ellipsoid(radii, name, mat, pos=(0, 0, 0), ico=2):
    # Mobile-visible round parts (cockpits, optics, engine pods and beacons) should not
    # show coarse triangular facets at close range. Keep the smoother parts one tier up;
    # flat hard-surface armor remains deliberately faceted and material batches stay merged.
    smooth_subdivisions = max(int(ico), 3)
    sph = trimesh.creation.icosphere(subdivisions=smooth_subdivisions, radius=1.0)
    return (sph, name, mat, pos, (0, 0, 0), radii)


def cylinder(radius, height, name, mat, pos=(0, 0, 0), rot=(0, 0, 0), sections=16):
    return (trimesh.creation.cylinder(radius=radius, height=height, sections=sections), name, mat, pos, rot, (1, 1, 1))


def cone(radius, height, name, mat, pos=(0, 0, 0), rot=(0, 0, 0), sections=12):
    return (trimesh.creation.cone(radius=radius, height=height, sections=sections), name, mat, pos, rot, (1, 1, 1))


def wedge_hull(length, width, height, name, mat):
    # A faceted aircraft hull with a tapered nose and narrowing rear; forward = -Z.
    stations = [(-length*0.56, width*0.08, height*0.16), (-length*0.38, width*0.35, height*0.44),
                (-length*0.08, width*0.50, height*0.50), (length*0.26, width*0.43, height*0.42),
                (length*0.48, width*0.23, height*0.26)]
    ring = 8
    verts=[]
    for z, rx, ry in stations:
        for j in range(ring):
            a = 2*math.pi*j/ring + math.pi/8
            verts.append([math.cos(a)*rx, math.sin(a)*ry, z])
    faces=[]
    # Fan-cap both ends so every face is triangulated for robust glTF export.
    verts.append([0.0, 0.0, stations[0][0]])
    start_center = len(verts) - 1
    for j in range(ring):
        faces.append([start_center, (j+1)%ring, j])
    for si in range(len(stations)-1):
        for j in range(ring):
            a=si*ring+j; b=si*ring+(j+1)%ring
            c=(si+1)*ring+(j+1)%ring; d=(si+1)*ring+j
            faces.append([a,b,c]); faces.append([a,c,d])
    end_center_pos = [0.0, 0.0, stations[-1][0]]
    verts.append(end_center_pos)
    end_center = len(verts) - 1
    end_start = (len(stations)-1)*ring
    for j in range(ring):
        faces.append([end_center, end_start+j, end_start+(j+1)%ring])
    mesh=trimesh.Trimesh(vertices=np.array(verts), faces=np.array(faces), process=True)
    mesh.fix_normals()
    return (mesh, name, mat, (0,0,0), (0,0,0), (1,1,1))


def combined_boxes(items):
    meshes = []
    for extents, pos, rot in items:
        meshes.append(transform_mesh(trimesh.creation.box(extents=extents), pos, rot, (1,1,1)))
    return trimesh.util.concatenate(meshes) if meshes else trimesh.Trimesh()


def export_scene(name, parts):
    # Merge geometry by material: keeps detailed silhouettes while limiting each asset
    # to a small number of glTF mesh/material draw calls.
    scene=trimesh.Scene()
    groups = {}
    group_mats = {}
    for item in parts:
        mesh, n, mat, pos, rot, scale = item
        built = transform_mesh(mesh, pos, rot, scale)
        key = mat.name
        groups.setdefault(key, []).append(built)
        group_mats[key] = mat
    for key, geometries in groups.items():
        merged = trimesh.util.concatenate(geometries)
        merged.visual.material = group_mats[key]
        # Every imported material group gets UVs so Godot can safely add PBR micro maps
        # with set_surface_override_material; emissive groups remain unchanged at runtime.
        merged = add_planar_uvs(merged, group_mats[key])
        scene.add_geometry(merged, geom_name=key.replace(" ", "_"), node_name=key.replace(" ", "_"))
    path=OUT/(name+".glb")
    scene.export(path, file_type="glb")
    loaded=trimesh.load(path, force="scene")
    print(f"{path.name}: {path.stat().st_size:,} bytes, {len(loaded.geometry)} mesh nodes")


# Sleek sky courier: tapered monocoque, swept wings, side nacelles, canopy and underbody light strips.
parts = [
    wedge_hull(2.75, 1.22, 0.62, "CourierHull", M["dark"]),
    ellipsoid((0.47,0.18,0.42), "CockpitCanopy", M["glass"], (0,0.20,-0.17), 3),
    box((1.50,0.08,0.50), "SweptWing", M["mid"], (0,0.00,0.20), (0,0,0.03)),
    box((0.62,0.045,0.22), "RearStabilizer", M["mid"], (0,0.08,0.78)),
    box((1.20,0.035,0.055), "CyanWingGuide", M["cyan"], (0,0.065,0.18)),
    box((0.62,0.035,0.05), "MagentaNoseGuide", M["pink"], (0,0.21,-0.75)),
]
for side in (-1,1):
    parts += [
        ellipsoid((0.18,0.13,0.38), f"EnginePod_{side}", M["mid"], (side*0.62,-0.02,0.38), 2),
        cylinder(0.09,0.20,f"EngineThroat_{side}",M["cyan"],(side*0.62,-0.02,0.72),(math.pi/2,0,0),16),
        box((0.15,0.045,0.58),f"WingArmor_{side}",M["light"],(side*0.67,0.02,0.13),(0,0,side*0.06)),
        ellipsoid((0.06,0.045,0.07),f"NavLamp_{side}",M["amber" if side>0 else "cyan"],(side*0.98,0.075,0.10),2),
    ]
# Raised dorsal spine, inset intakes and engine service panels give the courier a
# stronger scale read without increasing material count or adding runtime lights.
parts += [
    box((0.115,0.085,0.82), "DorsalArmorSpine", M["light"], (0,0.335,0.035)),
    box((0.42,0.026,0.24), "ForwardIntakeFrame", M["mid"], (0,0.305,-0.38)),
    box((0.30,0.018,0.15), "IntakeDarkRecess", M["dark"], (0,0.323,-0.39)),
    box((0.28,0.014,0.028), "IntakeStatusLight", M["cyan"], (0,0.337,-0.43)),
    box((0.36,0.024,0.055), "RearTransomLight", M["pink"], (0,0.272,0.83)),
]
for side in (-1,1):
    parts += [
        box((0.16,0.025,0.22), f"WingServiceInset_{side}", M["dark"], (side*0.48,0.057,0.20), (0,0,side*0.08)),
        box((0.095,0.018,0.14), f"EngineServicePanel_{side}", M["light"], (side*0.62,0.102,0.36), (0,0,side*0.08)),
        box((0.065,0.015,0.10), f"EngineVent_{side}", M["dark"], (side*0.62,0.116,0.36), (0,0,side*0.08)),
    ]
export_scene("sky_courier", parts)

# Cargo skimmer: broad layered hull, cargo modules, anti-gravity rings and engine bells.
parts = [
    wedge_hull(3.25, 1.72, 0.88, "CargoHull", M["dark"]),
    box((1.18,0.55,1.02),"CargoModuleCenter",M["building2"],(0,0.38,0.18)),
    box((0.48,0.38,0.80),"CargoModuleLeft",M["mid"],(-0.67,0.30,0.32)),
    box((0.48,0.38,0.80),"CargoModuleRight",M["mid"],(0.67,0.30,0.32)),
    ellipsoid((0.40,0.16,0.28),"Cockpit",M["glass"],(0,0.30,-0.60),3),
    box((1.90,0.045,0.06),"FrontCyanLightbar",M["cyan"],(0,0.14,-0.70)),
    box((1.25,0.045,0.06),"RearWarningStrip",M["amber"],(0,0.08,0.75)),
]
for side in (-1,1):
    parts += [
        ellipsoid((0.30,0.21,0.36),f"LiftPod_{side}",M["mid"],(side*1.05,-0.22,0.38),2),
        cylinder(0.21,0.09,f"AntiGravityRing_{side}",M["cyan"],(side*1.05,-0.34,0.38),(0,0,0),24),
        cylinder(0.17,0.34,f"EngineBell_{side}",M["dark"],(side*0.54,-0.14,0.82),(math.pi/2,0,0),16),
        cylinder(0.10,0.07,f"EngineCore_{side}",M["amber"],(side*0.54,-0.14,1.02),(math.pi/2,0,0),16),
    ]
# Cargo pod hard rails and recessed latch seams add manufactured detail to the big
# center container while preserving its original silhouette and center of mass.
parts += [
    box((1.22,0.035,0.05), "CargoTopFrontRail", M["light"], (0,0.675,-0.335)),
    box((1.22,0.035,0.05), "CargoTopRearRail", M["light"], (0,0.675,0.695)),
    box((0.05,0.035,0.98), "CargoTopLeftRail", M["mid"], (-0.595,0.675,0.18)),
    box((0.05,0.035,0.98), "CargoTopRightRail", M["mid"], (0.595,0.675,0.18)),
    box((0.88,0.025,0.025), "CargoHatchSeam", M["dark"], (0,0.665,0.18)),
    box((0.42,0.018,0.03), "CargoHatchStatus", M["cyan"], (0,0.685,0.18)),
    box((0.075,0.28,0.025), "CargoIDPlate", M["light"], (0.0,0.37,-0.703)),
    box((0.24,0.035,0.025), "CargoIDLight", M["amber"], (0.0,0.36,-0.724)),
]
for side in (-1,1):
    for level, yy in enumerate((0.29,0.38,0.47)):
        parts.append(box((0.018,0.035,0.28), f"CargoSideVent_{side}_{level}", M["dark"], (side*0.604,yy,0.16)))
    parts.append(box((0.20,0.025,0.05), f"CargoLiftWarning_{side}", M["amber"], (side*1.05,-0.01,0.38)))
export_scene("cargo_skimmer", parts)

# Patrol interceptor: a compact aggressive airframe, angled wings, optics and two weapon pods.
parts = [
    wedge_hull(3.05, 1.50, 0.82, "InterceptorHull", M["dark"]),
    ellipsoid((0.34,0.13,0.38),"ArmoredCanopy",M["glass"],(0,0.27,-0.24),3),
    box((1.78,0.09,0.46),"DeltaWing",M["mid"],(0,0.03,0.05),(0,0,0.07)),
    box((0.68,0.055,0.23),"TailPlane",M["mid"],(0,0.13,0.78)),
    box((0.06,0.03,1.45),"CenterSpine",M["light"],(0,0.22,0.04)),
    box((0.94,0.035,0.045),"CyanWingStrip",M["cyan"],(0,0.09,0.14)),
    ellipsoid((0.16,0.08,0.10),"ForwardOptic",M["red"],(0,0.02,-0.91),2),
]
for side in (-1,1):
    parts += [
        wedge_hull(0.95,0.34,0.30,f"WeaponPod_{side}",M["mid"]),
        ellipsoid((0.08,0.08,0.18),f"WeaponEmitter_{side}",M["pink"],(side*0.55,-0.06,-0.44),2),
        cylinder(0.10,0.26,f"Engine_{side}",M["dark"],(side*0.56,-0.04,0.77),(math.pi/2,0,0),14),
        cylinder(0.066,0.04,f"EngineGlow_{side}",M["cyan"],(side*0.56,-0.04,0.92),(math.pi/2,0,0),16),
    ]
    # place weapon pods outward and slightly aft without changing their silhouette geometry
    parts[-4] = (parts[-4][0],parts[-4][1],parts[-4][2],(side*0.68,-0.02,0.22),(0,side*-0.14,side*-0.12),(1,1,1))
# Sensor spine and short inset vent stacks reinforce the interceptor's sharp nose
# and engine-intake silhouette. All additions reuse existing material batches.
parts += [
    box((0.10,0.065,0.78), "DorsalSensorSpine", M["light"], (0,0.425,0.0)),
    box((0.34,0.025,0.21), "NoseSensorFrame", M["mid"], (0,0.386,-0.60)),
    box((0.24,0.018,0.12), "NoseSensorGlass", M["glass"], (0,0.403,-0.62)),
    box((0.14,0.020,0.035), "NoseWarningBar", M["amber"], (0,0.422,-0.70)),
    box((0.52,0.028,0.06), "TailArmorLip", M["light"], (0,0.36,0.75)),
]
for side in (-1,1):
    for vent in range(3):
        parts.append(box((0.12,0.016,0.055), f"WingIntake_{side}_{vent}", M["dark"], (side*(0.35+vent*0.16),0.089,0.10+vent*0.11), (0,0,side*0.08)))
    parts.append(box((0.10,0.035,0.24), f"WeaponPodArmor_{side}", M["light"], (side*0.68,0.12,0.33), (0,side*-0.14,side*-0.12)))
export_scene("patrol_interceptor", parts)

# Heavy sentinel boss: wide armored wedge, layered shell, optical core, fins and emitter arrays.
parts = [
    wedge_hull(4.1, 3.9, 1.35, "SentinelCoreHull", M["dark"]),
    ellipsoid((0.62,0.44,0.32),"PrimaryRedOptic",M["red"],(0,-0.04,-1.10),3),
    ellipsoid((0.80,0.48,0.22),"OpticBezel",M["mid"],(0,-0.03,-1.05),3),
    box((2.92,0.10,0.44),"UpperArmorSpine",M["mid"],(0,0.58,0.02)),
    box((2.45,0.07,0.055),"CyanSpineLight",M["cyan"],(0,0.65,-0.08)),
    box((2.75,0.12,0.48),"RearArmorDeck",M["building2"],(0,0.30,0.82)),
]
for side in (-1,1):
    parts += [
        ellipsoid((0.66,0.38,0.78),f"ShoulderPod_{side}",M["mid"],(side*1.62,0.02,0.24),3),
        box((0.82,0.17,1.30),f"WingBlade_{side}",M["dark"],(side*2.02,0.07,0.20),(0,side*0.12,side*0.05)),
        box((0.52,0.04,1.10),f"MagentaBladeLight_{side}",M["pink"],(side*2.05,0.17,0.15),(0,side*0.12,side*0.05)),
        cylinder(0.21,0.50,f"CannonBarrel_{side}",M["dark"],(side*1.55,-0.16,-0.88),(math.pi/2,0,0),18),
        cylinder(0.14,0.08,f"CannonEmitter_{side}",M["amber"],(side*1.55,-0.16,-1.16),(math.pi/2,0,0),18),
        cylinder(0.43,0.08,f"EngineRing_{side}",M["cyan"],(side*0.83,-0.29,1.10),(math.pi/2,0,0),28),
        ellipsoid((0.18,0.18,0.12),f"EngineCore_{side}",M["cyan"],(side*0.83,-0.29,1.18),2),
        box((0.22,0.08,0.90),f"SideArmorInset_{side}",M["light"],(side*1.35,-0.20,0.10),(0,side*-0.18,0)),
        box((0.42,0.055,0.42),f"ShoulderTopArmor_{side}",M["light"],(side*1.58,0.39,0.04),(0,side*0.10,side*0.04)),
        box((0.26,0.035,0.48),f"ShoulderStatusRail_{side}",M["cyan"],(side*1.72,0.43,0.13),(0,side*0.10,side*0.04)),
        box((0.13,0.06,0.30),f"CannonGuideRail_{side}",M["mid"],(side*1.55,0.02,-0.78)),
    ]
# Layered frontal brow, dorsal cooling louvers and segmented armor seams help the
# boss retain a readable silhouette at phone scale instead of reading as one slab.
parts += [
    box((1.52,0.11,0.14), "OpticBrowArmor", M["light"], (0,0.44,-1.24)),
    box((1.12,0.065,0.085), "OpticBrowLight", M["cyan"], (0,0.505,-1.255)),
    box((1.62,0.055,0.32), "DorsalCoolingFrame", M["mid"], (0,0.52,0.58)),
]
for vent in range(5):
    parts.append(box((0.20,0.025,0.21), f"DorsalCoolingLouver_{vent}", M["dark"], (-0.80+vent*0.40,0.565,0.58)))
export_scene("sentinel_boss", parts)

# Tall stepped landmark: repeatable city silhouette model. Details are consolidated into material groups by GLTF import.
parts = [
    box((4.4,18.0,4.1),"TowerBase",M["building"],(0,9.0,0)),
    box((3.5,10.5,3.3),"TowerMiddle",M["building2"],(0,21.5,0.12)),
    box((2.3,8.2,2.2),"TowerUpper",M["building"],(0,30.8,-0.08)),
    (wedge_hull(5.5,2.7,2.7,"CrownSpire",M["mid"])[0], "CrownSpire", M["mid"], (0,35.7,0.15), (0,0,0), (1,1,1)),
    box((0.09,27.0,0.07),"FrontCyanSpine",M["cyan"],(0.94,15.0,2.08)),
    box((0.07,22.0,0.06),"FrontPinkSpine",M["pink"],(-1.05,19.0,1.76)),
    box((2.25,0.11,0.06),"CrownLight",M["amber"],(0,34.6,0.95)),
    cylinder(0.055,5.0,"Antenna",M["light"],(0,38.2,0),(math.pi/2,0,0),10),
    ellipsoid((0.18,0.18,0.18),"Beacon",M["cyan"],(0,41.0,0),2),
]
# narrow transverse floors/canopies create a layered skyline profile.
for i,y in enumerate((4.0,8.0,12.0,17.0,22.5,27.0,31.0)):
    parts.append(box((4.75-i*0.24,0.18,4.4-i*0.20),f"FloorLip_{i}",M["mid"],(0,y,-0.02)))
# Merge fine window modules by material, avoiding dozens of separate draw calls.
cyan_windows=[]; amber_windows=[]
for floor, yy in enumerate((2.6,5.0,7.4,9.8,12.2,14.6,17.8,20.2,22.6,28.5,30.7,32.9)):
    if yy < 16.5:
        half=1.8; front=2.075; side=2.22
    elif yy < 26.0:
        half=1.38; front=1.79; side=1.83
    else:
        half=0.88; front=1.12; side=1.23
    for col, xx in enumerate(np.linspace(-half,half,4 if yy<26 else 3)):
        target = cyan_windows if (floor+col)%3 else amber_windows
        target.append(((0.34,0.55,0.035),(float(xx),yy,front),(0,0,0)))
    for col, zz in enumerate((-0.95,0.0,0.95)):
        target = cyan_windows if (floor+col)%2 else amber_windows
        target.append(((0.035,0.52,0.29),(side,yy,float(zz)),(0,0,0)))
        target.append(((0.035,0.52,0.29),(-side,yy,float(zz)),(0,0,0)))
parts.append((combined_boxes(cyan_windows), "CyanWindowArrays", M["cyan"], (0,0,0), (0,0,0), (1,1,1)))
parts.append((combined_boxes(amber_windows), "AmberWindowArrays", M["amber"], (0,0,0), (0,0,0), (1,1,1)))
export_scene("neon_landmark", parts)


# Alternate landmark: broad multi-tier arcology with separated towers and many small window bands.
parts = [
    box((6.2,15.0,5.6),"ArcologyBase",M["building"],(0,7.5,0)),
    box((5.0,8.0,4.5),"ArcologyMid",M["building2"],(0,19.0,-0.20)),
    box((3.4,9.0,3.0),"ArcologyUpper",M["building"],(0,27.5,-0.35)),
    box((1.9,6.0,1.8),"ArcologyCrown",M["mid"],(0,35.0,-0.45)),
    box((0.12,25.0,0.07),"ArcologyCyanSpine",M["cyan"],(1.74,15.0,2.84)),
    box((0.10,21.0,0.06),"ArcologyPinkSpine",M["pink"],(-2.32,18.0,2.40)),
    box((5.5,0.20,5.0),"ArcologyPodium",M["mid"],(0,3.0,0)),
    cylinder(0.06,5.4,"ArcologyAntenna",M["light"],(0,40.3,-0.45),(math.pi/2,0,0),10),
    ellipsoid((0.2,0.2,0.2),"ArcologyBeacon",M["amber"],(0,43.0,-0.45),2),
]
for side in (-1,1):
    parts += [
        box((1.05,18.0,1.8),f"SideTower_{side}",M["building2"],(side*3.5,9.0,0.40)),
        box((1.2,0.14,1.95),f"SideTowerCrown_{side}",M["mid"],(side*3.5,18.1,0.40)),
        box((0.055,16.0,0.05),f"SideTowerLight_{side}",M["cyan" if side<0 else "pink"],(side*3.5+side*0.54,9.1,1.31)),
    ]
# Combined facade windows on front and both sides: a few material batches rather than many nodes.
arc_cyan=[]; arc_amber=[]
for floor, yy in enumerate((2.2,4.4,6.6,8.8,11.0,13.2,16.7,18.8,20.9,24.0,26.2,28.4,31.0,33.0)):
    front=2.83 if yy<15.0 else (2.05 if yy<23.0 else (1.18 if yy<32.0 else 0.46))
    half=2.5 if yy<15.0 else (2.0 if yy<23.0 else (1.32 if yy<32.0 else 0.7))
    for col,xx in enumerate(np.linspace(-half,half,5)):
        (arc_cyan if (floor+col)%3 else arc_amber).append(((0.30,0.40,0.035),(float(xx),yy,front),(0,0,0)))
    side_x = 3.12 if yy < 15.0 else (2.52 if yy < 23.0 else (1.70 if yy < 32.0 else 0.95))
    side_z = 1.85 if yy < 15.0 else (1.50 if yy < 23.0 else (1.00 if yy < 32.0 else 0.55))
    for zside in (-side_z,0.0,side_z):
        (arc_cyan if floor%2 else arc_amber).append(((0.035,0.40,0.28),(side_x,yy,zside),(0,0,0)))
        (arc_cyan if floor%2 else arc_amber).append(((0.035,0.40,0.28),(-side_x,yy,zside),(0,0,0)))
parts.append((combined_boxes(arc_cyan),"ArcologyWindowCyan",M["cyan"],(0,0,0),(0,0,0),(1,1,1)))
parts.append((combined_boxes(arc_amber),"ArcologyWindowAmber",M["amber"],(0,0,0),(0,0,0),(1,1,1)))
export_scene("neon_arcology", parts)

# Alternate landmark: narrow needle spire with staggered fins, floating ring platforms and light rails.
parts = [
    box((2.6,22.0,2.6),"SpireMainShaft",M["building"],(0,11.0,0)),
    box((1.85,9.0,1.9),"SpireUpperShaft",M["building2"],(0,26.5,0.0)),
    cone(0.85,8.0,"SpireNeedle",M["mid"],(0,35.0,0),(math.pi/2,0,0),12),
    cylinder(2.3,0.22,"SpireRingLower",M["mid"],(0,8.5,0),(0,0,0),32),
    cylinder(1.85,0.18,"SpireRingMiddle",M["light"],(0,20.5,0),(0,0,0),32),
    cylinder(1.42,0.16,"SpireRingUpper",M["mid"],(0,30.5,0),(0,0,0),32),
    box((0.10,31.0,0.07),"SpireFrontCyan",M["cyan"],(0.72,17.0,1.33)),
    box((0.08,24.0,0.06),"SpireFrontPink",M["pink"],(-0.83,20.5,1.05)),
    ellipsoid((0.23,0.23,0.23),"SpireBeacon",M["amber"],(0,38.9,0),2),
]
for side in (-1,1):
    for level, yy in enumerate((5.0,12.0,19.0,26.0)):
        parts.append(box((0.55,5.0,0.55),f"SpireFin_{side}_{level}",M["building2"],(side*(1.25+level*0.18),yy,0.0),(0,0,side*0.12)))
        parts.append(box((0.035,4.6,0.035),f"SpireFinLight_{side}_{level}",M["cyan" if side < 0 else "pink"],(side*(1.54+level*0.18),yy,0.29),(0,0,side*0.12)))
# Narrow glowing windows are grouped into one cyan mesh.
spire_windows=[]
for yy in np.arange(2.2,33.0,1.65):
    for xx in (-0.63,0.0,0.63):
        spire_windows.append(((0.12,0.48,0.03),(float(xx),float(yy),1.315 if yy<22 else 0.97),(0,0,0)))
parts.append((combined_boxes(spire_windows),"SpireWindowArray",M["cyan"],(0,0,0),(0,0,0),(1,1,1)))
export_scene("neon_spire", parts)

# Shared 45-degree chamfered unit box mesh used by the obstacle MultiMesh renderer.
# This creates real sloped edge faces so warning blocks/pylons stop reading as raw cubes.
unit_points=[]
b=0.085
inner=0.5-b
for axis in range(3):
    for sign in (-1.0,1.0):
        for a in (-inner,inner):
            for c in (-inner,inner):
                coords=[a,c]
                point=[0.0,0.0,0.0]
                rem=[i for i in range(3) if i != axis]
                point[axis]=sign*0.5
                point[rem[0]]=a
                point[rem[1]]=c
                unit_points.append(point)
unit_mesh=trimesh.convex.convex_hull(np.array(unit_points,dtype=np.float64))
unit_mesh.fix_normals()
unit_mesh=add_planar_uvs(unit_mesh, M["dark"])
export_scene("chamfered_unit_box", [(unit_mesh,"ChamferedUnitBox",M["dark"],(0,0,0),(0,0,0),(1,1,1))])

# Compact angular obstacle drone core used by the type-level MultiMesh pool.
# Build its panel ridges into one shared mesh because Spawner deliberately extracts
# one material-compatible mesh for the pooled MultiMesh renderer.
drone_core = wedge_hull(1.0, 1.0, 0.76, "AerialDroneCore", M["dark"])
drone_parts = [drone_core[0]]
for side in (-1, 1):
    drone_parts.append(transform_mesh(beveled_box_mesh((0.48, 0.11, 0.27)), (side*0.47, 0.035, 0.02), (0, side*-0.10, side*-0.06)))
drone_parts.extend([
    transform_mesh(beveled_box_mesh((0.20, 0.16, 0.40)), (0, 0.085, -0.03)),
    transform_mesh(beveled_box_mesh((0.25, 0.08, 0.13)), (0, 0.11, -0.30)),
    transform_mesh(beveled_box_mesh((0.12, 0.10, 0.20)), (-0.31, 0.005, 0.22)),
    transform_mesh(beveled_box_mesh((0.12, 0.10, 0.20)), (0.31, 0.005, 0.22)),
])
dr_core_mesh = trimesh.util.concatenate(drone_parts)
dr_core_mesh.fix_normals()
dr_core_mesh = add_planar_uvs(dr_core_mesh, M["dark"])
export_scene("aerial_drone_core", [(dr_core_mesh, drone_core[1], drone_core[2], drone_core[3], drone_core[4], drone_core[5])])
