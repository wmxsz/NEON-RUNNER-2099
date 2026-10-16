"""Generate the seamless cybernetic race-deck PBR material set.

The surface is a future-tech composite deck, not a real-world road: carbon-ceramic
armor panels, recessed modular joints, machined metallic bevels, etched data traces,
service-port details, and selective polished inlays. All procedural fields and panel
motifs wrap seamlessly. Outputs 1024x1024 RGBA albedo (linear roughness in alpha),
tangent-space normal, and a separate editable grayscale roughness source.
Requires Pillow and NumPy.
"""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "textures"
OUT.mkdir(parents=True, exist_ok=True)
S = 1024
rng = np.random.default_rng(2099_834)
fy = np.fft.fftfreq(S).astype(np.float32)[:, None]
fx = np.fft.rfftfreq(S).astype(np.float32)[None, :]


def periodic_noise(cutoff_x: float, cutoff_y: float | None = None) -> np.ndarray:
    """Zero-mean, unit-variance tileable noise with optional directional flow."""
    if cutoff_y is None:
        cutoff_y = cutoff_x
    raw = rng.normal(0.0, 1.0, (S, S)).astype(np.float32)
    spectrum = np.fft.rfft2(raw)
    low_pass = np.exp(-(fx * fx * cutoff_x + fy * fy * cutoff_y)).astype(np.float32)
    field = np.fft.irfft2(spectrum * low_pass, s=(S, S)).astype(np.float32)
    field -= field.mean()
    field /= field.std() + 1e-6
    return field


def smoothstep(edge0: float, edge1: float, value: np.ndarray) -> np.ndarray:
    t = np.clip((value - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# Periodic coordinate field. One texture tile represents one wide structural deck
# module; the shader repeats it across the three-lane track and along the run.
axis = (np.arange(S, dtype=np.float32) + 0.5) / S
U, V = np.meshgrid(axis, axis)
segment_v = np.mod(V * 4.0, 1.0)  # four independently framed plates per module

broad = periodic_noise(1800.0)
mid = periodic_noise(280.0)
slab = periodic_noise(78.0)
ceramic_grain = periodic_noise(18.0)
micro = periodic_noise(1.5)
flow_brush = periodic_noise(4.5, 920.0)

# Carbon-ceramic panels: recessed joints, machined edge chamfers and a second
# inset frame inside each of the two plate halves. Panel detail is deliberately
# geometric/engineered rather than random scratches painted into the base color.
edge_dist = np.minimum(np.minimum(U, 1.0 - U), np.minimum(segment_v, 1.0 - segment_v))
joint = 1.0 - smoothstep(0.0025, 0.012, edge_dist)
bevel = smoothstep(0.009, 0.014, edge_dist) * (1.0 - smoothstep(0.030, 0.050, edge_dist))
inner_face = smoothstep(0.012, 0.028, edge_dist)
# A secondary stepped seam splits the plate into an engineered pair of sub-panels.
secondary_dist = np.abs(U - 0.5)
secondary_joint = 1.0 - smoothstep(0.0020, 0.0085, secondary_dist)
secondary_bevel = smoothstep(0.007, 0.011, secondary_dist) * (1.0 - smoothstep(0.020, 0.034, secondary_dist))

# Precision inset armor frame and embedded interface details on each half-plate.
# These landmarks survive mipmapping better than simply increasing surface noise.
panel_u = np.mod(U * 2.0, 1.0)
local_x_edge = np.minimum(panel_u, 1.0 - panel_u)
local_y_edge = np.minimum(segment_v, 1.0 - segment_v)
frame_vertical_zone = smoothstep(0.12, 0.16, segment_v) * (1.0 - smoothstep(0.84, 0.88, segment_v))
frame_side = (1.0 - smoothstep(0.0025, 0.0065, np.minimum(np.abs(panel_u - 0.065), np.abs(panel_u - 0.935)))) * frame_vertical_zone
frame_horizontal_zone = ((panel_u > 0.075) & (panel_u < 0.27)) | ((panel_u > 0.73) & (panel_u < 0.925))
frame_end = (1.0 - smoothstep(0.0025, 0.0065, np.minimum(np.abs(segment_v - 0.12), np.abs(segment_v - 0.88)))) * frame_horizontal_zone
inset_frame = np.maximum(frame_side, frame_end).astype(np.float32)

# Four recessed data-lock sockets and their machined annular lips per panel.
socket_xs = (0.145, 0.855)
socket_ys = (0.22, 0.78)
socket_ring = np.zeros((S, S), dtype=np.float32)
socket_core = np.zeros((S, S), dtype=np.float32)
for sx in socket_xs:
    for sy in socket_ys:
        radius = np.sqrt(((panel_u - sx) * 0.86) ** 2 + (segment_v - sy) ** 2)
        socket_ring = np.maximum(socket_ring, 1.0 - smoothstep(0.0025, 0.006, np.abs(radius - 0.018)))
        socket_core = np.maximum(socket_core, 1.0 - smoothstep(0.006, 0.010, radius))

# Fine telemetric slot bars and tiny engraved signal paths in the inner plate area.
slot_phase = np.mod(panel_u * 34.0, 1.0)
slot_bars = (1.0 - smoothstep(0.025, 0.07, np.abs(slot_phase - 0.5))) * (
    (segment_v > 0.38) & (segment_v < 0.62) &
    (((panel_u > 0.31) & (panel_u < 0.445)) | ((panel_u > 0.555) & (panel_u < 0.69)))
)
inner_bus_y = np.minimum(np.abs(segment_v - 0.32), np.abs(segment_v - 0.68))
inner_bus = (1.0 - smoothstep(0.002, 0.005, inner_bus_y)) * (
    ((panel_u > 0.26) & (panel_u < 0.43)) | ((panel_u > 0.57) & (panel_u < 0.74))
)

# Etched circuit paths run to recessed service ports, with deliberate gaps and pads.
left_bus = 1.0 - smoothstep(0.0022, 0.0052, np.abs(U - 0.135))
right_bus = 1.0 - smoothstep(0.0022, 0.0052, np.abs(U - 0.865))
local_y = segment_v
bus_segment = smoothstep(0.095, 0.13, local_y) * (1.0 - smoothstep(0.80, 0.84, local_y))
branch_y = np.minimum(np.abs(local_y - 0.20), np.minimum(np.abs(local_y - 0.52), np.abs(local_y - 0.75)))
branch_mask = 1.0 - smoothstep(0.0028, 0.0065, branch_y)
branch_x = smoothstep(0.12, 0.17, U) * (1.0 - smoothstep(0.20, 0.25, U))
branch_x += smoothstep(0.75, 0.80, U) * (1.0 - smoothstep(0.83, 0.88, U))
circuit_trace = np.clip((left_bus + right_bus) * bus_segment + branch_mask * branch_x, 0.0, 1.0)

# Small machined port rings: repeated at each quarter-panel, not random painted dots.
port_x = np.minimum(np.abs(U - 0.065), np.abs(U - 0.935))
port_y = np.minimum(np.abs(segment_v - 0.075), np.abs(segment_v - 0.925))
port_r = np.sqrt((port_x * 0.82) ** 2 + port_y ** 2)
port_ring = (1.0 - smoothstep(0.004, 0.007, np.abs(port_r - 0.012)))
port_core = 1.0 - smoothstep(0.004, 0.008, port_r)

# Low-contrast optical alignment marks and short hash-bar data labels.
label_x = np.minimum(np.abs(U - 0.31), np.abs(U - 0.69))
label_line = 1.0 - smoothstep(0.0015, 0.0042, label_x)
label_zone = smoothstep(0.34, 0.38, local_y) * (1.0 - smoothstep(0.62, 0.66, local_y))
barcode_phase = np.mod(U * 94.0 + np.floor(V * 4.0) * 0.37, 1.0)
barcode = (1.0 - smoothstep(0.006, 0.015, np.abs(barcode_phase - 0.5))) * label_zone

# Premium dark cobalt carbon-ceramic. Noise is intentionally subordinate to designed
# geometry: the previous macro cloud was too visually dominant and made the surface
# feel dirty instead of precision manufactured. Distinct cassette values and machined
# borders now create the depth; grain only breaks up perfectly flat shading.
noise = broad * 0.65 + mid * 0.85 + slab * 1.15 + ceramic_grain * 0.95 + micro * 0.30 + flow_brush * 0.42
# The face variation must be periodic in both axes; a fractional V cycle caused
# a visible tonal discontinuity when the material tile wrapped vertically.
panel_variation = (0.5 + 0.5 * np.sin(U * 2.0 * np.pi + V * 2.0 * np.pi))
panel_x_id = np.floor(U * 2.0)
panel_y_id = np.floor(V * 4.0)
# Mirror the edge plate IDs so a wrapped neighboring tile does not create a tonal seam.
edge_panel_x = np.minimum(panel_x_id, 1.0 - panel_x_id)
edge_panel_y = np.minimum(panel_y_id, 3.0 - panel_y_id)
panel_variant_id = np.mod(edge_panel_x * 3.0 + edge_panel_y * 5.0, 4.0)
panel_variant = (panel_variant_id - 1.5) * 3.0
face_value = 1.0 + 0.14 * panel_variation + 0.012 * broad
albedo = np.empty((S, S, 3), dtype=np.float32)
# Godot samples source_color textures in linear space. The previous RGB mean (about
# 35/51/78 sRGB) became nearly black in PBR; raise the deck's material response while
# retaining a deep blue-carbon base so seams and emission remain clearly separated.
base = 68.0 + noise
albedo[:, :, 0] = base * 0.72 + 10.0
albedo[:, :, 1] = base * 0.92 + 16.0
albedo[:, :, 2] = base * 1.16 + 27.0
albedo *= face_value[:, :, None]
# Very restrained cobalt/teal cassette-to-cassette variation gives the repeating deck
# a designed industrial rhythm without turning it into a noisy camo texture.
albedo[:, :, 0] += panel_variant * 0.30
albedo[:, :, 1] += panel_variant * 0.48
albedo[:, :, 2] += panel_variant * 0.72
# Machined chamfers and recessed seams are deliberately high enough in contrast to
# survive phone-size mipmapping; blue/cyan paths are precise printed/inlaid circuitry.
albedo += bevel[:, :, None] * np.array([36.0, 54.0, 86.0], dtype=np.float32)
albedo += secondary_bevel[:, :, None] * np.array([22.0, 36.0, 59.0], dtype=np.float32)
albedo += inset_frame[:, :, None] * np.array([9.0, 20.0, 36.0], dtype=np.float32)
albedo -= joint[:, :, None] * np.array([24.0, 28.0, 36.0], dtype=np.float32)
albedo -= secondary_joint[:, :, None] * np.array([14.0, 20.0, 28.0], dtype=np.float32)
# Printed cyan/cobalt circuit ink has chromatic separation but remains albedo, leaving
# true emission and per-chapter color control to the runtime shader.
albedo += circuit_trace[:, :, None] * np.array([6.0, 26.0, 48.0], dtype=np.float32)
albedo += (label_line * label_zone)[:, :, None] * np.array([4.0, 15.0, 26.0], dtype=np.float32)
albedo += barcode[:, :, None] * np.array([5.0, 17.0, 29.0], dtype=np.float32)
albedo += inner_bus[:, :, None] * np.array([4.0, 18.0, 32.0], dtype=np.float32)
albedo += slot_bars[:, :, None] * np.array([9.0, 20.0, 31.0], dtype=np.float32)
albedo += socket_ring[:, :, None] * np.array([24.0, 40.0, 62.0], dtype=np.float32)
albedo -= socket_core[:, :, None] * np.array([15.0, 17.0, 21.0], dtype=np.float32)
albedo = np.clip(albedo, 8.0, 158.0).astype(np.uint8)

# Derive normal relief from both material microstructure and macro plate machining.
height = (
    broad * 0.00045
    + mid * 0.00088
    + slab * 0.0013
    + ceramic_grain * 0.0018
    + micro * 0.00055
    + flow_brush * 0.00078
    + bevel * 0.0032
    + secondary_bevel * 0.0020
    + inset_frame * 0.00055
    - joint * 0.0017
    - secondary_joint * 0.0011
    - socket_core * 0.0007
    + circuit_trace * 0.00045
    + inner_bus * 0.00035
    + socket_ring * 0.0006
).astype(np.float32)
dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
nx, ny, nz = -dx * 128.0, -dy * 128.0, np.ones_like(dx)
normal_len = np.sqrt(nx * nx + ny * ny + nz * nz)
normal = np.stack((nx / normal_len, ny / normal_len, nz / normal_len), axis=2)
normal = np.clip((normal * 0.5 + 0.5) * 255.0, 0.0, 255.0).astype(np.uint8)

# Ceramic faces stay satin; inlays and edge rails are polished, while joints/ports are rough.
roughness = (
    151.0
    + broad * 5.0
    + mid * 6.0
    + slab * 6.8
    + ceramic_grain * 5.3
    + micro * 1.4
    + flow_brush * 3.0
    + joint * 56.0
    + secondary_joint * 34.0
    + port_core * 23.0
    + socket_core * 21.0
    - bevel * 24.0
    - circuit_trace * 72.0
    - inset_frame * 18.0
    - inner_bus * 28.0
    - slot_bars * 30.0
    - (label_line * label_zone) * 38.0
).clip(56.0, 232.0).astype(np.uint8)
rough_image = Image.fromarray(roughness, "L")
packed_albedo = Image.fromarray(albedo, "RGB").convert("RGBA")
packed_albedo.putalpha(rough_image)
packed_albedo.save(OUT / "cyber_deck_albedo.png", optimize=True)
Image.fromarray(normal, "RGB").save(OUT / "cyber_deck_normal.png", optimize=True)
rough_image.save(OUT / "cyber_deck_roughness.png", optimize=True)

# Invariants make accidental loss of the cyber construction language visible to CI.
if float(np.mean(circuit_trace > 0.5)) < 0.003:
    raise RuntimeError("Cyber-deck circuit traces disappeared from the albedo source")
if float(np.mean(inset_frame > 0.5)) < 0.004 or float(np.mean(socket_ring > 0.5)) < 0.0005:
    raise RuntimeError("Cyber-deck precision frame / data-lock geometry fell below the detail contract")
if int(roughness.max()) - int(roughness.min()) < 90:
    raise RuntimeError("Cyber-deck roughness range collapsed; polished inlays would read flat")
print(
    "Cybernetic race-deck PBR regenerated: 1024x1024 carbon-ceramic armor panels, "
    "inset precision frames, four-point data-lock sockets, engraved circuits, machined chamfers; "
    f"normal RGB std={normal.std(axis=(0, 1)).round(2).tolist()}, "
    f"roughness min/mean/max={int(roughness.min())}/{roughness.mean():.1f}/{int(roughness.max())}."
)
