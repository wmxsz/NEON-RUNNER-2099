"""Generate seamless cyber-composite armor PBR maps.

This is a neutral but unmistakably engineered surface: fine hexagonal ceramic cells,
laminated micro-weave, laser-etched signal paths and precision-machined edge relief.
The neutral palette lets each GLB material retain its authored faction/chapter color.
Outputs a 1024x1024 RGBA masked detail-albedo, tangent-space normal and roughness maps; Pillow + NumPy required.
"""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "textures"
OUT.mkdir(parents=True, exist_ok=True)
S = 1024
rng = np.random.default_rng(2099_835)
fy = np.fft.fftfreq(S).astype(np.float32)[:, None]
fx = np.fft.rfftfreq(S).astype(np.float32)[None, :]


def periodic_noise(cutoff_x: float, cutoff_y: float | None = None) -> np.ndarray:
    if cutoff_y is None:
        cutoff_y = cutoff_x
    raw = rng.normal(0.0, 1.0, (S, S)).astype(np.float32)
    spectrum = np.fft.rfft2(raw)
    filt = np.exp(-(fx * fx * cutoff_x + fy * fy * cutoff_y)).astype(np.float32)
    field = np.fft.irfft2(spectrum * filt, s=(S, S)).astype(np.float32)
    field -= field.mean()
    field /= field.std() + 1e-6
    return field


def smoothstep(edge0: float, edge1: float, value: np.ndarray) -> np.ndarray:
    t = np.clip((value - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


axis = (np.arange(S, dtype=np.float32) + 0.5) / S
U, V = np.meshgrid(axis, axis)
broad = periodic_noise(1800.0)
mid = periodic_noise(190.0)
fine = periodic_noise(20.0)
micro = periodic_noise(1.2)
brush = periodic_noise(3.5, 760.0)

# Use larger, seamless engineered cells. An odd column count is important here:
# the alternating half-row phase of the final column must match column zero at the
# horizontal tile edge. The vertical row count is even so the phase wraps vertically.
# Nine columns by twelve rows avoids dense honeycomb wallpaper on small armor parts.
rows = 12.0
cols = 9.0
column = np.floor(U * cols)
column_shift = np.mod(column, 2.0) * 0.5
cell_x = np.mod(U * cols, 1.0)
cell_y = np.mod(V * rows + column_shift, 1.0)
px = np.abs(cell_x - 0.5)
py = np.abs(cell_y - 0.5) * 0.8660254
# Flat-top regular hex SDF. Adjacent columns alternate vertically by half a row;
# the odd/even lattice counts let the phase wrap without a visible tile seam. A gasket
# and shallow face lift make each cell read as an engineered ceramic armor plate.
hex_metric = np.maximum(px * 0.8660254 + py * 0.5, py)
hex_edge = 1.0 - smoothstep(0.008, 0.026, np.abs(hex_metric - 0.4330127))
hex_face = 1.0 - smoothstep(0.370, 0.425, hex_metric)
# A second inset cut inside each ceramic cell creates a machined double-bevel,
# preventing the armor from reading as a plain honeycomb wallpaper at distance.
hex_inset = (1.0 - smoothstep(0.004, 0.012, np.abs(hex_metric - 0.335))) * hex_face

# Four large carbon-ceramic armor cassettes form the macro structure. Each cassette
# has a narrow gasket, a raised inset frame, corner locking rings and selected etched
# data paths. All coordinates wrap on exact quarter-tile boundaries.
panel_u = np.mod(U * 4.0, 1.0)
panel_v = np.mod(V * 4.0, 1.0)
panel_edge_dist = np.minimum(np.minimum(panel_u, 1.0 - panel_u), np.minimum(panel_v, 1.0 - panel_v))
panel_seam = (1.0 - smoothstep(0.006, 0.018, panel_edge_dist)) * 0.72
panel_frame = 1.0 - smoothstep(0.004, 0.010, np.abs(panel_edge_dist - 0.072))
panel_frame_inner = 1.0 - smoothstep(0.003, 0.008, np.abs(panel_edge_dist - 0.092))
# Alternate a few routed telemetry paths by cassette index so the surface is not a
# uniform honeycomb wallpaper. Even 4x4 IDs preserve exact edge wrapping.
panel_ix = np.floor(U * 4.0)
panel_iy = np.floor(V * 4.0)
# Symmetric edge IDs mean the final cassette and first cassette have matching value
# variation across the wrap; the macro pattern remains a true periodic tile.
edge_panel_ix = np.minimum(panel_ix, 3.0 - panel_ix)
edge_panel_iy = np.minimum(panel_iy, 3.0 - panel_iy)
panel_route_a = (np.mod(panel_ix + panel_iy, 2.0) == 0.0).astype(np.float32)
panel_route_b = (np.mod(panel_ix + 2.0 * panel_iy, 3.0) == 1.0).astype(np.float32)
route_y = 1.0 - smoothstep(0.0022, 0.0065, np.abs(panel_v - 0.30))
route_x = smoothstep(0.10, 0.14, panel_u) * (1.0 - smoothstep(0.36, 0.42, panel_u))
route_elbow = (1.0 - smoothstep(0.0022, 0.0065, np.abs(panel_u - 0.38))) * smoothstep(0.28, 0.34, panel_v) * (1.0 - smoothstep(0.54, 0.60, panel_v))
route_b_y = 1.0 - smoothstep(0.0022, 0.0065, np.abs(panel_v - 0.72))
route_b_x = smoothstep(0.61, 0.66, panel_u) * (1.0 - smoothstep(0.85, 0.90, panel_u))
trace = np.clip(panel_route_a * (route_y * route_x + route_elbow) + panel_route_b * route_b_y * route_b_x, 0.0, 1.0)
trace_x = np.minimum(np.abs(panel_u - 0.23), np.abs(panel_u - 0.77))
trace_y = np.minimum(np.abs(panel_v - 0.19), np.abs(panel_v - 0.81))
secondary_trace = (1.0 - smoothstep(0.0018, 0.0045, trace_x)) * (1.0 - smoothstep(0.04, 0.085, panel_v))
secondary_trace += (1.0 - smoothstep(0.0018, 0.0045, trace_y)) * (1.0 - smoothstep(0.19, 0.24, panel_u))
trace = np.clip(trace + secondary_trace * panel_route_b * 0.75, 0.0, 1.0)
# Four precision lock contacts per large cassette, each made from a metallic ring and
# a dark recessed center. They are geometry-inspired decals, not random pinholes.
lock_rings = np.zeros((S, S), dtype=np.float32)
lock_cores = np.zeros((S, S), dtype=np.float32)
for lx in (0.085, 0.915):
    for ly in (0.085, 0.915):
        radius = np.sqrt((panel_u - lx) ** 2 + (panel_v - ly) ** 2)
        lock_rings = np.maximum(lock_rings, 1.0 - smoothstep(0.0025, 0.006, np.abs(radius - 0.014)))
        lock_cores = np.maximum(lock_cores, 1.0 - smoothstep(0.0045, 0.0085, radius))

# Each larger hex-cell group gets short embedded telemetry branches. The higher-level
# cassette route sits on top, giving both readable macro structure and micro precision.
cell_x_line = 1.0 - smoothstep(0.007, 0.018, np.abs(cell_x - 0.205))
cell_y_line = 1.0 - smoothstep(0.007, 0.018, np.abs(cell_y - 0.63))
cell_branch = cell_x_line * ((cell_y > 0.37) & (cell_y < 0.65)) * hex_face
cell_branch += cell_y_line * ((cell_x > 0.20) & (cell_x < 0.39)) * hex_face
node_radius = np.sqrt((cell_x - 0.205) ** 2 + (cell_y - 0.63) ** 2)
contact_node = (1.0 - smoothstep(0.008, 0.018, node_radius)) * hex_face
cell_branch = np.clip(cell_branch, 0.0, 1.0)

# Near-neutral high-value titanium/ceramic overlay: this is a micro-detail map that
# multiplies the GLB-authored material tint. Keeping the broad face near white prevents
# the old gray texture from crushing the model's own faction/chapter colors. Darker
# values are localized to etched grooves and panel joints; cool highlights mark cut lips.
# The map is consumed as a native StandardMaterial3D detail overlay with MUL blend.
# Alpha is the *detail mask*: large ceramic faces remain completely untouched, and only
# the narrow engineered seams/gaskets/etched telemetry lines multiply into the authored
# authored base-color tint. This avoids globally darkening every faction tint just to show micro-detail.
noise = broad * 0.72 + mid * 0.62 + fine * 0.42 + micro * 0.10 + brush * 0.24
face_lift = hex_face * 0.55 + hex_edge * 1.6 + hex_inset * 0.85 + panel_seam * 0.9 + panel_frame * 0.9 + lock_rings * 0.8
albedo = np.empty((S, S, 3), dtype=np.float32)
albedo[:, :, 0] = 252.0 + noise + face_lift * 0.25
albedo[:, :, 1] = 253.0 + noise * 0.82 + face_lift * 0.34
albedo[:, :, 2] = 255.0 + noise * 0.78 + face_lift * 0.45
albedo -= panel_seam[:, :, None] * np.array([74.0, 82.0, 92.0], dtype=np.float32)
albedo -= panel_frame[:, :, None] * np.array([30.0, 35.0, 39.0], dtype=np.float32)
albedo += panel_frame_inner[:, :, None] * np.array([1.0, 2.0, 4.0], dtype=np.float32)
albedo -= hex_edge[:, :, None] * np.array([46.0, 52.0, 60.0], dtype=np.float32)
albedo += hex_inset[:, :, None] * np.array([0.0, 1.0, 3.0], dtype=np.float32)
albedo -= trace[:, :, None] * np.array([70.0, 57.0, 36.0], dtype=np.float32)
albedo -= secondary_trace[:, :, None] * panel_route_b[:, :, None] * np.array([34.0, 32.0, 25.0], dtype=np.float32)
albedo -= cell_branch[:, :, None] * np.array([66.0, 53.0, 35.0], dtype=np.float32)
albedo += contact_node[:, :, None] * np.array([0.0, 1.0, 3.0], dtype=np.float32)
albedo += lock_rings[:, :, None] * np.array([0.0, 1.0, 3.0], dtype=np.float32)
albedo -= lock_cores[:, :, None] * np.array([80.0, 72.0, 58.0], dtype=np.float32)
albedo = np.clip(albedo, 140.0, 255.0).astype(np.uint8)
# The mask fades with the same authored SDFs used to draw the cuts, so edges remain
# antialiased under mipmapping and only detail-bearing pixels blend with the base tint.
detail_mask = np.maximum.reduce((
    panel_seam * 0.98,
    panel_frame * 0.88,
    lock_rings * 0.92,
    lock_cores * 0.78,
    hex_edge * 0.98,
    trace * 0.96,
    secondary_trace * 0.70,
    cell_branch * 0.94,
)).clip(0.0, 1.0)
detail_mask_u8 = np.clip(detail_mask * 255.0, 0.0, 255.0).astype(np.uint8)
albedo_rgba = np.dstack((albedo, detail_mask_u8))

height = (
    broad * 0.0012 + mid * 0.0017 + fine * 0.0024 + micro * 0.00065
    + brush * 0.0007 + hex_edge * 0.0018 + hex_inset * 0.0008
    + panel_seam * 0.0024 + panel_frame * 0.0015 + panel_frame_inner * 0.0010
    + lock_rings * 0.0015 - lock_cores * 0.0006
    - trace * 0.0006 - secondary_trace * 0.00035 - cell_branch * 0.00045
).astype(np.float32)
dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
# Native detail_normal has no separate strength slider; bake a calibrated micro-relief amplitude
# comparable to the previous 0.18-ish StandardMaterial3D normal_scale on the same height field.
nx, ny, nz = -dx * 20.0, -dy * 20.0, np.ones_like(dx)
normal_len = np.sqrt(nx * nx + ny * ny + nz * nz)
normal = np.stack((nx / normal_len, ny / normal_len, nz / normal_len), axis=2)
normal = np.clip((normal * 0.5 + 0.5) * 255.0, 0.0, 255.0).astype(np.uint8)

roughness = (
    158.0 + broad * 3.0 + mid * 4.2 + fine * 4.2 + micro * 1.3 + brush * 3.2
    + panel_seam * 34.0 + hex_edge * 21.0 + cell_branch * 14.0 + lock_cores * 22.0
    + panel_frame * 10.0 - panel_frame_inner * 13.0
    - hex_face * 12.0 - hex_inset * 14.0 - trace * 38.0 - secondary_trace * 15.0 - contact_node * 8.0 - lock_rings * 15.0
).clip(112.0, 212.0).astype(np.uint8)

Image.fromarray(albedo_rgba, "RGBA").save(OUT / "cyber_armor_albedo.png", optimize=True)
Image.fromarray(normal, "RGB").save(OUT / "cyber_armor_normal.png", optimize=True)
Image.fromarray(roughness, "L").save(OUT / "cyber_armor_roughness.png", optimize=True)
if float(np.mean(hex_edge > 0.5)) < 0.01:
    raise RuntimeError("Armor hex-cell detailing fell below the visual coverage threshold")
if float(np.mean(hex_inset > 0.5)) < 0.008 or float(np.mean(cell_branch > 0.5)) < 0.002:
    raise RuntimeError("Armor double-cut inset or cell telemetry detail fell below the visual contract")
if float(np.mean(panel_frame > 0.5)) < 0.008 or float(np.mean(lock_rings > 0.5)) < 0.0005:
    raise RuntimeError("Armor macro cassette frames or precision lock contacts disappeared")
channel_means = albedo.mean(axis=(0, 1))
mask_coverage = float(np.mean(detail_mask_u8 >= 16))
opaque_face_means = albedo[detail_mask_u8 < 8].mean(axis=0)
if float(opaque_face_means.min()) < 249.0:
    raise RuntimeError(f"Unmasked armor faces must remain near-white to preserve authored model/faction colors: {opaque_face_means.round(1).tolist()}")
if mask_coverage < 0.02 or mask_coverage > 0.30:
    raise RuntimeError(f"Armor detail mask coverage is too low/high for premium surface readability: {mask_coverage:.3%}")
if float(np.mean((albedo[:, :, 0] < 225) & (detail_mask_u8 >= 128))) < 0.003:
    raise RuntimeError("Armor engraved grooves / double-cut seams are too subtle for the native multiply overlay")
if int(roughness.max()) - int(roughness.min()) < 60:
    raise RuntimeError("Armor roughness variation collapsed")
print(
    "Cyber-composite armor PBR regenerated: 1024x1024 native MUL detail albedo with alpha-cut mask, larger tile-periodic hex cells, four-cassette macro frames, lock contacts, routed telemetry, "
    f"albedo mean RGB={channel_means.round(1).tolist()}, unmasked face mean={opaque_face_means.round(1).tolist()}, "
    f"detail mask coverage={mask_coverage:.3%}, "
    f"normal RGB std={normal.std(axis=(0, 1)).round(2).tolist()}, "
    f"roughness min/mean/max={int(roughness.min())}/{roughness.mean():.1f}/{int(roughness.max())}."
)
