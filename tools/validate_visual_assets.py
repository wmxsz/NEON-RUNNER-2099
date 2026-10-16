#!/usr/bin/env python3
"""Offline validation for Neon Runner 2099 generated GLB/PBR assets.

Requires: Python 3, Pillow, NumPy and trimesh.
This is a content sanity check only; it does not compile Godot scenes or shaders.
"""
from __future__ import annotations
from pathlib import Path
import json
import math
import random
import re
import sys
import wave
import xml.etree.ElementTree as ET

import numpy as np
import trimesh
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MODEL_DIR = ROOT / "assets" / "models"
TEXTURE_DIR = ROOT / "assets" / "textures"
EXPECTED_MODELS = {
    "aerial_drone_core.glb", "cargo_skimmer.glb", "chamfered_unit_box.glb",
    "neon_arcology.glb", "neon_landmark.glb", "neon_spire.glb",
    "patrol_interceptor.glb", "sentinel_boss.glb", "sky_courier.glb",
}
EXPECTED_TEXTURES = {
    "cyber_armor_albedo.png": 4,
    "cyber_armor_normal.png": 3,
    "cyber_armor_roughness.png": 2,
    "cyber_deck_albedo.png": 4,
    "cyber_deck_normal.png": 3,
    "cyber_deck_roughness.png": 2,
}

def fail(message: str) -> None:
    raise AssertionError(message)

def validate_models() -> int:
    present = {p.name for p in MODEL_DIR.glob("*.glb")}
    missing = EXPECTED_MODELS - present
    if missing:
        fail(f"Missing GLB model(s): {sorted(missing)}")
    checks = 0
    minimum_triangles = {
        "aerial_drone_core.glb": 300,
        "cargo_skimmer.glb": 3200,
        "chamfered_unit_box.glb": 40,
        "neon_arcology.glb": 2600,
        "neon_landmark.glb": 2250,
        "neon_spire.glb": 2100,
        "patrol_interceptor.glb": 3300,
        "sentinel_boss.glb": 7000,
        "sky_courier.glb": 3300,
    }
    for name in sorted(EXPECTED_MODELS):
        path = MODEL_DIR / name
        scene = trimesh.load(path, force="scene")
        if not scene.geometry:
            fail(f"{name}: empty scene")
        face_count = 0
        material_count = 0
        degenerate_faces = 0
        duplicate_faces = 0
        nonfinite_normals = 0
        for mesh_name, mesh in scene.geometry.items():
            if len(mesh.vertices) < 3 or len(mesh.faces) < 1:
                fail(f"{name}/{mesh_name}: empty mesh")
            if not np.isfinite(mesh.vertices).all():
                fail(f"{name}/{mesh_name}: non-finite vertex")
            if not np.isfinite(mesh.bounds).all() or np.any(np.ptp(mesh.bounds, axis=0) <= 0):
                fail(f"{name}/{mesh_name}: invalid bounds")
            if np.any(mesh.faces < 0) or np.any(mesh.faces >= len(mesh.vertices)):
                fail(f"{name}/{mesh_name}: invalid triangle index")
            face_areas = np.asarray(mesh.area_faces, dtype=np.float64)
            if not np.isfinite(face_areas).all():
                fail(f"{name}/{mesh_name}: non-finite triangle area")
            degenerate_faces += int(np.count_nonzero(face_areas <= 1e-10))
            canonical_faces = np.sort(np.asarray(mesh.faces), axis=1)
            duplicate_faces += len(canonical_faces) - len(np.unique(canonical_faces, axis=0))
            face_normals = np.asarray(mesh.face_normals, dtype=np.float64)
            nonfinite_normals += int(np.count_nonzero(~np.isfinite(face_normals).all(axis=1)))
            uv = getattr(mesh.visual, "uv", None)
            if uv is None or uv.shape != (len(mesh.vertices), 2):
                fail(f"{name}/{mesh_name}: no valid UVs for runtime material textures")
            if not np.isfinite(uv).all() or float(uv.min()) < -1e-4 or float(uv.max()) > 1.0001:
                fail(f"{name}/{mesh_name}: UVs are non-finite or out of 0..1 bounds")
            face_count += len(mesh.faces)
            mat = getattr(mesh.visual, "material", None)
            material_count += int(mat is not None)
        if degenerate_faces:
            fail(f"{name}: {degenerate_faces} degenerate triangle(s) with area <= 1e-10")
        if duplicate_faces:
            fail(f"{name}: {duplicate_faces} duplicate triangle(s) within material meshes")
        if nonfinite_normals:
            fail(f"{name}: {nonfinite_normals} face normal(s) contain non-finite values")
        if face_count < minimum_triangles[name]:
            fail(f"{name}: model detail regression ({face_count} triangles < {minimum_triangles[name]} minimum)")
        if material_count < 1:
            fail(f"{name}: no material data")
        # Generated GLBs use only 2x2 opaque-white albedo placeholders to preserve UVs.
        # Runtime removes these redundant base-color samplers and keeps glTF baseColorFactor.
        # If a future generator adds authored base textures, this explicit contract must be revised.
        placeholder_textures = sorted(MODEL_DIR.glob(f"{path.stem}_*.png"))
        if not placeholder_textures:
            fail(f"{name}: expected a 2x2 white UV-preservation placeholder texture")
        for texture_path in placeholder_textures:
            with Image.open(texture_path) as placeholder_image:
                pixels = np.asarray(placeholder_image.convert("RGBA"), dtype=np.uint8)
                if placeholder_image.size != (2, 2) or not np.all(pixels == 255):
                    fail(f"{name}/{texture_path.name}: expected the exact 2x2 pure-white GLB UV placeholder")
        print(f"PASS model {name}: {len(scene.geometry)} meshes, {face_count} triangles, 0 degenerate/duplicate faces, finite normals, {len(placeholder_textures)} neutral UV placeholder(s)")
        checks += 1
    return checks

def _seam_ratio(a: np.ndarray) -> tuple[float, float]:
    if a.ndim == 2:
        seam_x = float(np.abs(a[:, 0] - a[:, -1]).mean())
        inner_x = float(np.abs(a[:, 1:] - a[:, :-1]).mean())
        seam_y = float(np.abs(a[0, :] - a[-1, :]).mean())
        inner_y = float(np.abs(a[1:, :] - a[:-1, :]).mean())
    else:
        seam_x = float(np.abs(a[:, 0, :] - a[:, -1, :]).mean())
        inner_x = float(np.abs(a[:, 1:, :] - a[:, :-1, :]).mean())
        seam_y = float(np.abs(a[0, :, :] - a[-1, :, :]).mean())
        inner_y = float(np.abs(a[1:, :, :] - a[:-1, :, :]).mean())
    return seam_x / max(inner_x, 1e-5), seam_y / max(inner_y, 1e-5)

def validate_textures() -> int:
    checks = 0
    for name, channels in EXPECTED_TEXTURES.items():
        path = TEXTURE_DIR / name
        if not path.is_file():
            fail(f"Missing texture: {name}")
        with Image.open(path) as img:
            if img.size != (1024, 1024):
                fail(f"{name}: expected 1024x1024, got {img.size}")
            if channels == 2 and img.mode not in ("L", "LA"):
                fail(f"{name}: expected single-channel grayscale map, got {img.mode}")
            if channels == 3 and img.mode not in ("RGB", "RGBA"):
                fail(f"{name}: expected RGB map, got {img.mode}")
            if channels == 4 and img.mode != "RGBA":
                fail(f"{name}: expected RGBA texture, got {img.mode}")
            arr = np.asarray(img).astype(np.float64)
        if not np.isfinite(arr).all():
            fail(f"{name}: non-finite pixel data")
        rx, ry = _seam_ratio(arr)
        # A periodic texture's border jump should be comparable to ordinary adjacent pixels.
        if rx > 2.25 or ry > 2.25:
            fail(f"{name}: visible tiling seam risk (x={rx:.2f}, y={ry:.2f})")
        # These two albedo and normal pairs are directly sampled across large visible
        # surfaces. Keep a tighter edge continuity budget than generic source maps.
        if name in {"cyber_armor_albedo.png", "cyber_armor_normal.png", "cyber_deck_albedo.png", "cyber_deck_normal.png"} and max(rx, ry) > 1.55:
            fail(f"{name}: directly tiled PBR edges must match adjacent texels (x={rx:.2f}, y={ry:.2f})")
        if name == "cyber_armor_normal.png":
            # This map now feeds StandardMaterial3D.detail_normal, which has no separate strength slider.
            # Keep the texture's encoded micro-normal amplitude at the calibrated level instead of
            # relying on normal_scale, which only affects the base normal channel.
            xy_mean = arr[:, :, :2].mean(axis=(0, 1))
            xy_std = arr[:, :, :2].std(axis=(0, 1))
            if np.any(np.abs(xy_mean - 127.0) > 2.0) or np.any(xy_std < 2.0) or np.any(xy_std > 8.0):
                fail(f"cyber_armor_normal.png: detail-normal amplitude must remain subtle and centered; mean={xy_mean.round(2).tolist()} std={xy_std.round(2).tolist()}")
        print(f"PASS texture {name}: 1024x1024, seam ratios x={rx:.2f}, y={ry:.2f}")
        checks += 1
    # Material albedo maps multiply imported model colors after sRGB decoding. Keep
    # the armor micro-detail overlay near neutral/high value so it cannot crush GLB
    # faction colors; the cyber deck itself needs enough RGB range for the machined
    # panels to remain legible beneath neon inlays.
    armor_import = TEXTURE_DIR / "cyber_armor_albedo.png.import"
    if not armor_import.is_file():
        fail("cyber_armor_albedo.png.import is missing; Godot must preserve the armor alpha detail mask")
    armor_import_text = armor_import.read_text(encoding="utf-8")
    for token in ("process/channel_remap/alpha=3", "process/fix_alpha_border=true", "process/premult_alpha=false"):
        if token not in armor_import_text:
            fail(f"Godot texture import settings would not reliably preserve the armor detail mask: missing {token}")
    with Image.open(TEXTURE_DIR / "cyber_armor_albedo.png") as armor_image:
        armor_rgba = np.array(armor_image.convert("RGBA"), dtype=np.uint8, copy=True)
    armor_rgb = armor_rgba[:, :, :3].astype(np.float64)
    armor_alpha = armor_rgba[:, :, 3]
    armor_mean = armor_rgb.mean(axis=(0, 1))
    unmasked = armor_alpha < 8
    unmasked_face_mean = armor_rgb[unmasked].mean(axis=0) if np.any(unmasked) else np.zeros(3)
    mask_coverage = float(np.mean(armor_alpha >= 16))
    engraved_ratio = float(np.mean((armor_rgb[:, :, 0] < 225) & (armor_alpha >= 128)))
    if np.any(unmasked_face_mean < 249.0):
        fail(f"Native MUL armor detail must leave unmasked base-color faces near-white, mean={unmasked_face_mean.round(1).tolist()}")
    if mask_coverage < 0.02 or mask_coverage > 0.30:
        fail(f"Armor alpha detail mask coverage is too subtle/dense, coverage={mask_coverage:.3%}")
    if engraved_ratio < 0.003:
        fail("Armor engraved grooves / double-cut seams have disappeared from the masked detail albedo")
    with Image.open(TEXTURE_DIR / "cyber_deck_albedo.png") as deck_image:
        deck_rgb = np.asarray(deck_image.convert("RGB"), dtype=np.float64)
    deck_mean = deck_rgb.mean(axis=(0, 1))
    deck_p95 = np.percentile(deck_rgb, 95, axis=(0, 1))
    if deck_mean[0] < 55.0 or deck_mean[1] < 75.0 or deck_mean[2] < 100.0:
        fail(f"Cyber-deck material is too dark for panel readability in linear-space PBR, mean={deck_mean.round(1).tolist()}")
    if deck_p95[2] < 140.0:
        fail(f"Cyber-deck machined lips / connector highlights lost required contrast, p95={deck_p95.round(1).tolist()}")
    print(f"PASS color-preserving PBR values: armor detail mean={armor_mean.round(1).tolist()}, unmasked face mean={unmasked_face_mean.round(1).tolist()}, alpha mask coverage={mask_coverage:.3%}, engraved dark-pixel ratio={engraved_ratio:.3%}, deck mean={deck_mean.round(1).tolist()}, deck P95={deck_p95.round(1).tolist()}")
    # The runtime road shader consumes roughness from the albedo alpha channel.
    # Check it byte-for-byte against the authoring grayscale map so generation drift
    # cannot silently change wet-sheen behavior while the extra runtime sample stays removed.
    with Image.open(TEXTURE_DIR / "cyber_deck_albedo.png") as albedo_image:
        packed_roughness = np.asarray(albedo_image.getchannel("A"))
    with Image.open(TEXTURE_DIR / "cyber_deck_roughness.png") as roughness_image:
        source_roughness = np.asarray(roughness_image.convert("L"))
    if packed_roughness.shape != source_roughness.shape or not np.array_equal(packed_roughness, source_roughness):
        fail("Packed deck albedo alpha must exactly match the editable grayscale roughness source")
    print("PASS packed cyber-deck material: albedo RGB + roughness alpha are byte-identical to source roughness")
    return checks

def validate_source_references() -> int:
    checks = 0
    missing: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in {".gd", ".tscn", ".tres", ".gdshader", ".godot", ".cfg"}:
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for match in re.finditer(r'''["\']res://([^"\']+)["\']''', content):
            resource = match.group(1)
            # Dynamic resource construction is checked by source review rather than this literal-path pass.
            if "%" in resource or "{" in resource or "}" in resource:
                continue
            if not (ROOT / resource).is_file() and not (ROOT / resource).is_dir():
                missing.append(f"{path.relative_to(ROOT)} -> res://{resource}")
            checks += 1
    if missing:
        fail("Missing literal res:// resource(s): " + "; ".join(missing[:12]))
    manifest = json.loads((ROOT / "RELEASE_MANIFEST.json").read_text(encoding="utf-8"))
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    export = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
    project_version = re.search(r'^config/version="([^"]+)"', project, re.M)
    export_name = re.search(r'^version/name="([^"]+)"', export, re.M)
    export_code = re.search(r'^version/code=(\d+)', export, re.M)
    if not project_version or not export_name or not export_code:
        fail("Project/Android version fields are missing")
    if project_version.group(1) != export_name.group(1):
        fail(f"Project version {project_version.group(1)} != Android export {export_name.group(1)}")
    if project_version.group(1) != str(manifest["version"]) or int(export_code.group(1)) != int(manifest["android_version_code"]):
        fail("Project version/Android versionCode must match RELEASE_MANIFEST.json")
    gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    if re.search(r"^export_presets\.cfg\s*$", gitignore, re.M):
        fail("export_presets.cfg must remain versioned so Android export configuration is not silently omitted")
    for secret_key in ("keystore/release=", "keystore/release_user=", "keystore/release_password="):
        secret_line = re.search(r"^" + re.escape(secret_key) + r"(.*)$", export, re.M)
        if not secret_line or secret_line.group(1).strip().strip('"'):
            fail("Release signing credentials must stay blank in the source package")
    if not (ROOT / "docs" / "audit" / "archive").is_dir() or (ROOT / "FIX_NOTES.md").exists():
        fail("Historical audit notes must live in docs/audit/archive/, not alongside current baseline files")
    if not (ROOT / "docs" / "build" / "ENVIRONMENT_SETUP.md").is_file() or (ROOT / "ENVIRONMENT_SETUP.md").exists():
        fail("Build environment documentation must live only in docs/build/")
    if (ROOT / "UPGRADE_OPPORTUNITY_AUDIT.md").exists() or (ROOT / "AUDIT_EXECUTION_SUMMARY.txt").exists():
        fail("Historical audit summaries must live under docs/audit/, not the project root")
    if not any((ROOT / "docs" / "audit" / "archive").glob("*.md")):
        fail("Historical audit archive must retain at least one versioned report")
    audio_source = (ROOT / "systems" / "audio.gd").read_text(encoding="utf-8")
    expected_tracks = {
        "theme_0_downtown.ogg", "theme_1_industrial.ogg", "theme_2_skyport.ogg",
        "theme_3_electric.ogg", "theme_4_golden.ogg", "theme_5_deepsea.ogg",
        "theme_6_polar.ogg", "theme_7_sunset.ogg", "boss_theme.ogg",
    }
    missing_tracks = sorted(name for name in expected_tracks if not (ROOT / "assets" / "music" / name).is_file())
    if missing_tracks:
        fail("Missing referenced music track(s): " + ", ".join(missing_tracks))
    preload_tracks = re.findall(r'preload\("res://assets/music/([a-z0-9_]+)\.ogg"\)', audio_source)
    if len(preload_tracks) != len(expected_tracks) or set(f"{name}.ogg" for name in preload_tracks) != expected_tracks:
        fail("Music resource preloads must contain all nine unique chapter/BOSS tracks")
    track_block = re.search(r'const MUSIC_TRACKS := \[(.*?)\]', audio_source, re.S)
    if not track_block:
        fail("Music track order table is missing")
    track_names = re.findall(r'"([a-z0-9_]+)"', track_block.group(1))
    if track_names != preload_tracks:
        fail("MUSIC_TRACKS order must exactly match MUSIC_STREAMS preload order")
    if 'load(stream_path)' in audio_source or 'var stream_path :=' in audio_source:
        fail("Music transitions must use preloaded OGG streams, not runtime path-based loading")
    if 'var stream: AudioStreamOggVorbis = MUSIC_STREAMS[idx] as AudioStreamOggVorbis' not in audio_source:
        fail("Music playback does not resolve from the stable preloaded track array")
    expected_sfx = {"chip", "jump", "land", "slide", "die", "powerup", "overclock", "ui", "achv", "ready", "boss", "revive"}
    sfx_entries = re.findall(r'"([a-z_]+)"\s*:\s*preload\("res://assets/sfx/([a-z_]+)\.wav"\)', audio_source)
    sfx_mapping = {kind: filename for kind, filename in sfx_entries}
    if len(sfx_entries) != len(expected_sfx) or set(sfx_mapping) != expected_sfx or set(sfx_mapping.values()) != expected_sfx:
        fail("The SFX preload map must contain exactly one pre-rendered WAV for each supported effect")
    literal_sfx_calls: set[str] = set()
    for script_path in ROOT.rglob("*.gd"):
        script_text = script_path.read_text(encoding="utf-8")
        literal_sfx_calls.update(re.findall(r'\.play_sfx\(\s*["\']([^"\']+)["\']\s*\)', script_text))
    unknown_sfx_calls = sorted(literal_sfx_calls - expected_sfx)
    if unknown_sfx_calls:
        fail("Scripts call unsupported sound effect(s): " + ", ".join(unknown_sfx_calls))
    sfx_checks = 0
    for sfx_name in sorted(expected_sfx):
        wav_path = ROOT / "assets" / "sfx" / f"{sfx_name}.wav"
        if not wav_path.is_file():
            fail(f"Missing sound effect WAV: {wav_path.relative_to(ROOT)}")
        with wave.open(str(wav_path), "rb") as wav:
            if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 44100:
                fail(f"{sfx_name}.wav must be mono 16-bit PCM at 44100 Hz")
            frame_count = wav.getnframes()
            duration = frame_count / wav.getframerate()
            if not 0.04 <= duration <= 0.70:
                fail(f"{sfx_name}.wav duration is outside the expected short-SFX range: {duration:.3f}s")
            samples = np.frombuffer(wav.readframes(frame_count), dtype="<i2")
            if samples.size != frame_count or samples.size == 0:
                fail(f"{sfx_name}.wav has an invalid sample payload")
            peak = float(np.max(np.abs(samples.astype(np.int32)))) / 32768.0
            if peak < 0.08 or peak >= 0.95:
                fail(f"{sfx_name}.wav peak level is outside the safe authored range: {peak:.3f}")
        sfx_checks += 1
    if "AudioStreamGenerator" in audio_source or re.search(r"(?m)^var _bgm_playing\b", audio_source) or "func _sfx_tone(" in audio_source:
        fail("Legacy unused real-time audio synthesis remains; use the OGG music player and pooled WAV SFX")
    if "const MAX_SFX_VOICES := 8" not in audio_source or "_sfx_voice_stamps" not in audio_source:
        fail("Sound effects must use a bounded multi-voice pool with oldest-voice recycling")
    if "const MIX_MAKEUP_GAIN_DB := 3.0" not in audio_source or "comp.gain = MIX_MAKEUP_GAIN_DB" not in audio_source:
        fail("Audio mix must include the reviewed +3 dB compressor makeup gain")
    if "AudioEffectHardLimiter.new()" not in audio_source or "limiter.ceiling_db = MIX_LIMITER_CEILING_DB" not in audio_source:
        fail("Audio mix must include a hard limiter to protect against summed peaks")
    if "const SFX_GAIN_DB := {" not in audio_source or "func _sfx_voice_volume_db(kind: String) -> float:" not in audio_source:
        fail("SFX must use documented per-kind loudness trims while respecting the user volume slider")
    gain_block_match = re.search(r"const SFX_GAIN_DB := \{(.*?)\n\}", audio_source, re.S)
    if not gain_block_match:
        fail("SFX_GAIN_DB dictionary is malformed or missing its closing brace")
    gain_entries = re.findall(r'"([a-z_]+)"\s*:\s*([0-9.]+)', gain_block_match.group(1))
    gain_map = {kind: float(value) for kind, value in gain_entries}
    if len(gain_entries) != len(expected_sfx) or set(gain_map) != expected_sfx:
        fail("SFX_GAIN_DB must define exactly one gain trim for each supported SFX")
    for quiet_effect in ("ui", "achv", "ready"):
        if gain_map.get(quiet_effect, -999.0) < 3.0:
            fail(f"Quiet short SFX {quiet_effect} must retain at least +3 dB compensation")
    if "if sfx_vol <= 0.0001:" not in audio_source or "return -80.0" not in audio_source:
        fail("An SFX slider value of zero must still mute the effect after per-SFX gain compensation")
    if "_sfx_voice_kinds[i]" not in audio_source:
        fail("Changing SFX volume must preserve per-voice gain trim for already-playing sounds")
    if "const MIX_LIMITER_CEILING_DB := -1.0" not in audio_source:
        fail("Final audio limiter ceiling must remain at -1 dBFS")
    print(f"PASS audio: {len(expected_tracks)} OGG tracks + {sfx_checks} pre-rendered SFX WAVs; loudness makeup, per-effect trims, hard limiter, waveform checks, and bounded voice pool")
    # Guard against common accidental breakage while refactoring import helpers/material paths.
    player = (ROOT / "entities" / "player.gd").read_text(encoding="utf-8")
    spawner = (ROOT / "entities" / "spawner.gd").read_text(encoding="utf-8")
    for detail_token in ("Shoulder pauldrons", "Three-piece abdominal plating", "Rear battery cooling louvers", "Raised knee-cap", "Slim wrist cuff"):
        if detail_token not in player:
            fail(f"RUNNER-9 visual detail regression: missing {detail_token}")
    world = (ROOT / "world" / "world.gd").read_text(encoding="utf-8")
    for filename, source in (("entities/player.gd", player), ("entities/spawner.gd", spawner), ("world/world.gd", world)):
        if "cyber_armor_roughness.png" not in source:
            fail(f"{filename}: roughness PBR map is not preloaded")
        if "roughness_texture = ARMOR_ROUGHNESS" not in source:
            fail(f"{filename}: roughness PBR map is not assigned to the material")
    if player.count("const CHAMFERED_BOX_SCENE") != 1 or "_chamfered_box_mesh" not in player:
        fail("Player bevel mesh integration is incomplete")
    if '"neon_color", neon' not in world or '"material": themed' not in world or "_register_themeable_materials(model)" not in world:
        fail("Chapter palette is not propagated to imported city/traffic materials")
    if '"bg_color", Color(0.025, 0.035, 0.075).lerp(backdrop_col, 0.22)' not in world or "func _landmark_profile" not in world:
        fail("Chapter cyber-deck backdrop tint or theme-specific landmark profile is missing")
    if '"backdrop": Color(' not in (ROOT / "core" / "config.gd").read_text(encoding="utf-8"):
        fail("Theme palette must define a chapter backdrop for the cyber-deck scene")
    if '_grid_mat.set_shader_parameter("grid_strength", 0.84 + 0.10 * mix)' not in world:
        fail("Chapter blending must preserve the strengthened cyber-energy road-light level")
    for token in (
        "detailed.detail_enabled = true", "detailed.detail_albedo = ARMOR_ALBEDO",
        "detailed.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL",
        "detailed.detail_normal = ARMOR_NORMAL", "detailed.roughness_texture = ARMOR_ROUGHNESS",
        "Vector3(0.85, 0.85, 1.0)",
        "base_texture.get_width() == 2", 'base_texture.resource_path.begins_with("res://assets/models/")', "detailed.albedo_texture = null",
    ):
        if token not in world:
            fail(f"Imported model PBR must use a native color-preserving detail overlay and clear only the verified 2x2 GLB placeholder: {token}")
    for label, source in (("player", player), ("spawner", spawner), ("city", world)):
        if "detail_enabled = true" not in source or "detail_albedo = ARMOR_ALBEDO" not in source or "detail_normal = ARMOR_NORMAL" not in source or "detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL" not in source:
            fail(f"{label}: opaque cyber armor must use Godot's native masked detail albedo + detail-normal layer")
        if "albedo_texture = ARMOR_ALBEDO" in source:
            fail(f"{label}: cyber armor detail map must not replace the authored base-color tint")
        if "normal_texture = ARMOR_NORMAL" in source:
            fail(f"{label}: micro-normal must not replace a model's base normal map")
    for label, source in (("player", player), ("spawner", spawner), ("world", world)):
        if "detail_normal = ARMOR_NORMAL" not in source:
            fail(f"{label}: calibrated armor normal must use StandardMaterial3D.detail_normal")
        if "normal_texture = ARMOR_NORMAL" in source or "normal_enabled = true" in source:
            fail(f"{label}: armor micro-normal must not replace/enable the base normal channel globally")
    if "Vector3(0.85, 0.85, 1.0)" not in player:
        fail("RUNNER-9 armor must retain the reviewed hex-cell UV scale")
    model_generator = (ROOT / "tools" / "generate_visual_models.py").read_text(encoding="utf-8")
    if "def beveled_box_mesh(" not in model_generator or "return (beveled_box_mesh(extents), name, mat" not in model_generator:
        fail("Hard-surface model generator must retain real chamfered geometry")
    if "smooth_subdivisions = max(int(ico), 3)" not in model_generator:
        fail("Smooth model parts must retain the revised close-up tessellation floor")
    for detail_token in ("DorsalArmorSpine", "CargoTopFrontRail", "WingIntake_", "DorsalCoolingLouver_", "drone_parts.extend"):
        if detail_token not in model_generator:
            fail(f"Procedural model detail regression: missing {detail_token}")
    effects = (ROOT / "fx" / "effects.gd").read_text(encoding="utf-8")
    if "PrismMesh.new()" not in effects or "crystal.radial_segments = 5" not in effects or "shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF" not in effects:
        fail("VFX fragment silhouettes/low-cost pooled setup are incomplete")
    if '"Front service hatch"' in spawner or "OB.block.y1 * 0.56" not in spawner or "Dual camera glass" not in spawner:
        fail("Obstacle surface details are incomplete")
    if "func _build_proto(" in spawner or "func _box_mi(" in spawner or "func _find_children(" in spawner:
        fail("The obsolete per-node obstacle renderer must not coexist with the live MultiMesh renderer")
    high_speed_pattern = re.search(
        r'\{"min":\s*950,\s*"obs":\s*\[\["all",\s*"drone"(?:,\s*([0-9]+(?:\.[0-9]+)?))?\],\s*\["all",\s*"low"(?:,\s*([0-9]+(?:\.[0-9]+)?))?\]\]',
        spawner,
    )
    if not high_speed_pattern:
        fail("The 950m pattern must place a three-lane drone wave followed by a three-lane low obstacle wave")
    drone_dz = float(high_speed_pattern.group(1) or 0.0)
    low_dz = float(high_speed_pattern.group(2) or 0.0)
    if not (drone_dz < low_dz):
        fail("The 950m pattern is ordered by arrival time incorrectly: smaller dz reaches the player first; drone must precede low obstacles")
    if "o.z = next_spawn_z - dz" not in spawner or "o.z += spd * dt" not in spawner:
        fail("Obstacle z placement/movement changed; update the high-speed arrival-order contract")
    if re.search(r'\[\s*"all"\s*,\s*"(?:block|gate|mover)"', spawner):
        fail("An all-lane non-passable obstacle pattern can create an unavoidable collision")
    if 'top_plate.name = "HUDGlassPlate"' not in (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8"):
        fail("HUD glass contrast panel is missing")
    if "for node in [body, leg_l, leg_r, arm_l, arm_r, board]" not in player:
        fail("Skin palettes are not applied to all animated rig branches")
    if "_far_skylines: Array[MultiMeshInstance3D]" not in world or "FarCylindricalTowers" not in world or "FarSpireTowers" not in world:
        fail("Distant skyline silhouette variety is incomplete")
    if "mm.use_custom_data = true" not in world or "set_instance_custom_data(i, Color(_building_rng.randf()" not in world or "set_instance_custom_data(slot, Color(_building_rng.randf()" not in world:
        fail("Near buildings are missing per-instance facade variation data or do not randomize on recycle")
    if "INSTANCE_CUSTOM" not in (ROOT / "world" / "building_windows.gdshader").read_text(encoding="utf-8"):
        fail("Building shader does not consume per-instance facade variation data")
    if "BuildingFacadeShelves" not in world or "shelf_mask" not in world:
        fail("Building facade ledges are missing from the pooled visual system")
    if "_building_tops = _make_detail_multimesh(top_mesh, _make_city_material" not in world:
        fail("Rooftop equipment should use solid metal instead of the repeated window shader")
    if "_current_fog_density" not in world or "else _current_fog_density" not in world:
        fail("Overclock fog does not restore the active blended chapter density")
    if "if not _overclocking:\n                        _env.fog_density = _current_fog_density" not in world:
        fail("Continuous chapter transitions can overwrite the overclock fog effect")
    if "_road_distance_step = maxf(spd, 0.0) * maxf(dt, 0.0)" not in world or "_road_distance = fposmod(_road_distance_previous + _road_distance_step, _road_cycle_length)" not in world:
        fail("Road texture scroll must integrate travelled distance with wrap-safe interpolation to avoid acceleration jumps")
    road_shader = (ROOT / "world" / "road_grid.gdshader").read_text(encoding="utf-8")
    if "vec2(3.0, 40.0)" not in road_shader or "scroll / (road_cycle_length / 4.0)" not in road_shader or "scroll / road_cycle_length * 10.0" not in road_shader:
        fail("Road PBR map frequency is too stretched for sharp close-up detail")
    if "FarSpireTowers" in world and "mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF" not in world:
        fail("Instanced city shadow cost guard is missing")
    # Runtime GDScript test scenes are delivered under tests/*.tscn and executed by
    # the portable engine test runner when the pinned Godot version is available.
    # This Python validator remains strictly static and never claims runtime success.
    hud = (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8")
    menus = (ROOT / "ui" / "menus.gd").read_text(encoding="utf-8")
    if '_skin_action_callback(int(s.id), "equip")' not in menus or '_skin_action_callback(int(s.id), "buy")' not in menus:
        fail("Shop callbacks must explicitly bind the selected skin ID")
    if "_mission_claim_callback(String(m.id))" not in menus or "func _mission_claim_callback(mission_id: String) -> Callable" not in menus:
        fail("Mission-claim callbacks must explicitly bind the selected mission ID")
    print(f"PASS high-speed obstacle chronology: drone wave dz={drone_dz:g} arrives before low wave dz={low_dz:g}")
    progress = (ROOT / "systems" / "progress.gd").read_text(encoding="utf-8")
    config_source = (ROOT / "core" / "config.gd").read_text(encoding="utf-8")
    input_source = (ROOT / "systems" / "input.gd").read_text(encoding="utf-8")
    if 'previous_action == "lane" and dir == previous_lane_dir' not in input_source:
        fail("Input queue must merge any run of adjacent same-direction lane pulses, including triples")
    if "if not sliding:\n                        EventBus.slid.emit()" not in player:
        fail("Repeated slide requests must not inflate real slide-action counts")
    if "same_lane_path" not in spawner or "player.sliding and same_lane_path" not in spawner:
        fail("Slide-dodge tracking must confirm horizontal overlap with the player's path")
    if "Config.LANES[lane] - x" not in player or "lane_error * 48.0" not in player or "vx * (lane_fric + 4.0)" not in player:
        fail("Lane steering must include damped target-lane guidance so one swipe can clear the old lane")
    if "if target == lane:" not in player:
        fail("Same-direction swipes at a lane boundary must not accumulate outward momentum")
    main_loop = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    game_loop = (ROOT / "core" / "game.gd").read_text(encoding="utf-8")
    if "var res: Spawner.HitResult = Spawner.HitResult.new()" in main_loop or "var res: Spawner.HitResult = spawner.check(" not in main_loop:
        fail("Main loop must not allocate and discard a redundant HitResult before each collision check")
    if "var _effect_player_info: Dictionary" not in main_loop or "effects.update(dt, spd, _effect_player_info" not in main_loop:
        fail("Main loop must reuse the small effects payload instead of allocating one every physics tick")
    if 'const POWERUP_TIMER_KEYS := ["magnet", "double", "board"]' not in game_loop or "for kind in POWERUP_TIMER_KEYS:" not in game_loop:
        fail("Powerup timer key array must be reused in the fixed-step game loop")
    if "_refresh_skin_glow_cache()" not in player or "_update_skin_glow_pulse(dt, spd)" not in player:
        fail("Player emissive pulse cache/update integration is missing")
    if "land_squash = clampf(0.42 + fall_speed * 0.042" not in player:
        fail("Landing animation no longer uses impact velocity")
    if "mm.use_colors = true" not in spawner or "mm.set_instance_color(i" not in spawner or "hazard_material.vertex_color_use_as_albedo = true" not in spawner:
        fail("Obstacle instance tint pipeline is not fully connected")
    if "const GLOW_PHASES" not in spawner or "_update_warning_pulses()" not in spawner:
        fail("Cached shared warning-light pulse update is missing")
    if "_shock_ring_inner" not in effects or "_update_trail(dt, spd)\n                return" not in effects:
        fail("Layered shockwave or empty-player trail decay fix is missing")
    effects_update = effects.split("func update(dt: float, spd: float, player_info: Dictionary, overclock_active: bool)", 1)[1].split("func _emit_trail", 1)[0]
    trail_update = effects.split("func _update_trail(dt: float, spd: float)", 1)[1].split("func ", 1)[0]
    if "_active_shard_slots" not in effects or "while shard_cursor < _active_shard_slots.size():" not in effects_update:
        fail("Shards must use an active-slot list rather than scanning the whole inactive pool per frame")
    if "if _rain.emitting:" not in effects_update or "_rain_ratio_cache" not in effects_update or "absf(desired_rain_ratio - _rain_ratio_cache) >= 0.015" not in effects_update:
        fail("Rain-density updates must be skipped while the emitter is off and quantized while active")
    if "_active_trail_slots" not in effects or "while active_cursor < _active_trail_slots.size():" not in trail_update:
        fail("Trails must update active slots only instead of scanning the full ring every frame")
    if "_active_shard_slots[shard_cursor] = _active_shard_slots.back()" not in effects_update or "_active_trail_slots[active_cursor] = _active_trail_slots.back()" not in trail_update:
        fail("Expired pooled visual effects must use bounded swap-pop removal")
    if "if float(d.life) <= 0.0:\n                _active_trail_slots.append(_trail_idx)" not in effects:
        fail("Trail ring reuse must not duplicate an already-active slot")
    if "_city_sign_rails" not in world or "_city_sign_last_colors" not in world or "if not sign_color.is_equal_approx(_city_sign_last_colors[i])" not in world or "_make_city_material(colors[i], 0.0, 0.32, 1.72)" not in world:
        fail("City sign rails must retain an emissive base and update tint only when chapter color changes")
    if 'b.add_theme_stylebox_override("hover", hover)' not in menus or 'b.add_theme_stylebox_override("pressed", pressed)' not in menus or 'b.add_theme_stylebox_override("disabled", disabled)' not in menus:
        fail("Menu buttons must define interaction-state styles")
    if "ToastGlassPlate" not in hud or "_toast_plate.visible = false" not in hud or "_toast_plate.visible = true" not in hud:
        fail("HUD toast contrast plate does not follow toast visibility")
    helper = spawner.split("func _extract_first_mesh", 1)[1].split("func _build_materials", 1)[0]
    if helper.count("imported_root.free()") != 1:
        fail("Spawner mesh-import helper must release its temporary root exactly once")
    uids: dict[str, str] = {}
    for sidecar in ROOT.rglob("*.import"):
        sidecar_text = sidecar.read_text(encoding="utf-8")
        uid_match = re.search(r'^uid="([^"]+)"', sidecar_text, re.M)
        if uid_match:
            uid = uid_match.group(1)
            if uid in uids:
                fail(f"Duplicate import UID {uid}: {uids[uid]} and {sidecar.relative_to(ROOT)}")
            uids[uid] = str(sidecar.relative_to(ROOT))
        src_match = re.search(r'^source_file="res://([^"]+)"', sidecar_text, re.M)
        if src_match and not (ROOT / src_match.group(1)).is_file():
            fail(f"Import sidecar {sidecar.relative_to(ROOT)} references missing source {src_match.group(1)}")
    func_dupes: list[str] = []
    for script in ROOT.rglob("*.gd"):
        names = re.findall(r'^func\s+([A-Za-z0-9_]+)\s*\(', script.read_text(encoding="utf-8"), re.M)
        duplicated = sorted({name for name in names if names.count(name) > 1})
        if duplicated:
            func_dupes.append(f"{script.relative_to(ROOT)}: {', '.join(duplicated)}")
    if func_dupes:
        fail("Duplicate GDScript function names: " + "; ".join(func_dupes))
    print(f"PASS literal resource references: {checks}; import UIDs: {len(uids)} unique; project/export version {project_version.group(1)}, Android versionCode {export_code.group(1)}")
    print("PASS source integration: roughness map connected; RUNNER-9 armor detail guard; player bevel mesh wired; temporary GLB roots released once; no duplicate GDScript function names")
    input_source = (ROOT / "systems" / "input.gd").read_text(encoding="utf-8")
    telemetry_source = (ROOT / "core" / "telemetry.gd").read_text(encoding="utf-8")
    main_source = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    spawner_source = (ROOT / "entities" / "spawner.gd").read_text(encoding="utf-8")
    window_shader = (ROOT / "world" / "building_windows.gdshader").read_text(encoding="utf-8")
    game_source = (ROOT / "core" / "game.gd").read_text(encoding="utf-8")
    if "var _active_touch_index: int = -1" not in input_source or "_touch_started_enabled" not in input_source or "func set_enabled(on: bool)" not in input_source:
        fail("Touch input must track one finger and cancel gestures across run-state transitions")
    if "Telemetry.set_enabled(show_perf)" not in main_source or "func set_enabled(on: bool)" not in telemetry_source:
        fail("Telemetry polling must follow the show-FPS preference")
    if "var _cached_hit_result: HitResult = HitResult.new()" not in spawner_source or "R.reset()" not in spawner_source:
        fail("Spawner collision result should be reused on the 60Hz hot path")
    if "score_updated.emit" in game_source:
        fail("Unused 60Hz score_updated signal emission should not remain in the simulation path")
    if "return fract(sin(dot(p" in window_shader:
        fail("Building window shader still uses the expensive sine-based hash")
    if '"quality": "auto"' in config_source or '                "quality":' in progress:
        fail("Unused quality setting should not be persisted as a no-op preference")
    if "pu_kinds" in spawner_source:
        fail("Spawner references an undefined power-up kind list; use POWERUP_KINDS")
    if "for k_idx in POWERUP_KINDS.size()" not in spawner_source or 'str(p.get("kind", "")) != POWERUP_KINDS[k_idx]' not in spawner_source:
        fail("Power-up render pool must map stable kind indices to the matching MultiMesh group")
    if '"_render_style": -1' not in spawner_source or "var style_changed: bool" not in spawner_source or "if style_changed and part.mat == _mats.hazard" not in spawner_source:
        fail("Obstacle instance colors should be updated only when a pooled obstacle's style changes")
    if 'var just_activated: bool = not bool(o.get("_render_active", false))' not in spawner_source or 'var chip_just_activated: bool = not bool(c.get("_render_active", false))' not in spawner_source or 'var powerup_just_activated: bool = not bool(p.get("_render_active", false))' not in spawner_source:
        fail("MultiMesh pool active-state flags should be written only on state edges")
    if '"base_basis": Basis.from_euler(rotation)' not in spawner_source or "var basis: Basis = part.base_basis" not in spawner_source:
        fail("Static MultiMesh part rotation should be precomputed during setup")
    if "var laser_visual_synced := false" not in spawner_source or spawner_source.count("_mats.laserBeam.albedo_color = Color(") != 1:
        fail("Shared laser material pulse should update at most once per frame, not once per beam")
    fx_source = (ROOT / "fx" / "effects.gd").read_text(encoding="utf-8")
    if "var _speed_lines_cache_valid: bool = false" not in fx_source or "if not _speed_lines_cache_valid or should_emit_speed_lines != _speed_lines_active_cache" not in fx_source:
        fail("Speed-line particle/material properties should update on mode changes, not every frame")
    world_source = (ROOT / "world" / "world.gd").read_text(encoding="utf-8")
    for token in (
        "var _building_root: Node3D",
        "func _rebase_multimesh_root(",
        "var root_z: float = _building_root.position.z + maxf(spd, 0.0) * dt * 0.92",
        "root_z > float(_building_recycle_events[event_cursor].threshold)",
        "_building_local_z[slot] = local_z",
        "_rebase_multimesh_root(_building_root, 220.0)",
        "skyline.position.z += dz",
        "var local_zs: Array = _far_skyline_local_z[skyline_idx]",
        "_far_skyline_recycle_events.append(recycle_events)",
        "skyline.position.z > float(recycle_events[event_cursor].threshold)",
    ):
        if token not in world_source:
            fail(f"Shared-root city scrolling / bounded instance-buffer contract is missing: {token}")
    if "_translate_building_detail_z" in world_source:
        fail("Per-frame per-instance decoration translation should not return; city details must share the parent scroll transform")
    hud_source = (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8")
    if 'var _powerup_labels: Dictionary = {}' not in hud_source or "_pu_sig" in hud_source:
        fail("HUD timed power-up labels should be cached and reused rather than recreated on timer updates")
    if "if score_value != _last_score_value:" not in hud_source or "if chips != _last_chips_value:" not in hud_source or "if combo != _last_combo_value:" not in hud_source:
        fail("HUD should skip score/chip/combo label mutations when the displayed value has not changed")
    if "Telemetry.report_updated.connect(_on_telemetry_report_updated)" not in hud_source or "func _on_telemetry_report_updated(" not in hud_source:
        fail("Performance HUD must consume telemetry reports through the 0.5s event signal")
    if "Telemetry.hud_line()" in re.search(r'func _process\(dt: float\) -> void:(.*?)(?=\nfunc |\Z)', hud_source, re.S).group(1):
        fail("Performance HUD must not format and assign telemetry text every render frame")
    if "func _update_perf_label()" not in hud_source or "if next_text != _last_perf_text:" not in hud_source:
        fail("Performance HUD must cache the last displayed telemetry string")
    print("PASS retained optimization contracts: preloaded OGG playlist; event-driven/cached telemetry HUD; touch lifecycle; opt-in telemetry; cached collision result; indexed power-up rendering; state-edge MultiMesh visibility/tint; cached part bases; pooled HUD labels; laser material deduplication; speed-line state-edge updates; cached root-local city positions with recycle-only instance-buffer writes; mobile hash; clean settings schema")
    for token in ("func _safe_number(", "func _safe_setting(", "func _load_missions(", "func _is_valid_guard_number(", "var valid_skin_ids", "recent_runs.size() > 8"):
        if token not in progress:
            fail(f"Save-data validation is missing required guard: {token}")
    if '"hdr"' in config_source or '"hdr"' in progress or "window_request_hdr_output" in main_source:
        fail("Android-target HDR output must not be exposed as a misleading in-game setting")
    if 'has_base_missions' not in progress or 'daily_count == 3' not in progress or 'missions.sel.size() == 6' not in progress:
        fail("Daily mission rollover must verify exactly three base and three daily missions")
    if 'mission_id in loaded.sel' not in progress or 'not (id in missions.sel)' not in progress:
        fail("Mission progress must be confined to selected IDs and claims must re-check selection")
    print("PASS save hardening: numeric/type validation, known skin/achievement/mission IDs, settings clamping and daily mission schema")
    return checks


def validate_gameplay_contracts() -> int:
    """Source-anchored numerical checks for fragile input/steering contracts.

    This deliberately does not execute GDScript or Godot physics. It parses live
    project constants and simulates the exact lane-controller update ordering at
    60 Hz for single swipes, quick reversals, and lane-boundary inputs.
    """
    config = (ROOT / "core" / "config.gd").read_text(encoding="utf-8")
    player = (ROOT / "entities" / "player.gd").read_text(encoding="utf-8")
    lanes_match = re.search(r'const LANES: PackedFloat32Array = \[([^]]+)\]', config)
    if not lanes_match:
        fail("Cannot read lane coordinates for controller contract validation")
    lanes = [float(x.strip()) for x in lanes_match.group(1).split(",")]
    if len(lanes) != 3 or not (lanes[0] < lanes[1] < lanes[2]):
        fail("Expected three strictly ordered lanes")

    def config_number(key: str) -> float:
        match = re.search(rf'"{re.escape(key)}"\s*:\s*([0-9]+(?:\.[0-9]+)?)', config)
        if not match:
            fail(f"Cannot read PHYSICS.{key}")
        return float(match.group(1))

    impulse = config_number("laneImpulse")
    friction = config_number("laneFriction")
    max_v = config_number("laneMaxV")
    ice_friction = config_number("iceFrictionMult")
    if "Config.LANES[lane] - x" not in player or "lane_error * 48.0" not in player or "vx * (lane_fric + 4.0)" not in player:
        fail("Lane controller source no longer matches the audited damped-steering equation")
    if "if mech == \"ice\":\n                lane_fric *= Config.MECH_CFG.iceFrictionMult" not in player:
        fail("Ice biome must retain its configured reduced lateral damping")
    if "vx += direction * Config.PHYSICS.laneImpulse * _fric_scale" not in player:
        fail("Lane change impulse is no longer connected to the configured physics value")
    if "if target == lane:" not in player:
        fail("Boundary lane input must not apply another outward impulse")

    dt = 1.0 / 60.0
    def simulate(events: dict[int, int], start_lane: int = 1, frames: int = 120, friction_multiplier: float = 1.0) -> tuple[list[float], list[float], list[int]]:
        lane = start_lane
        x = lanes[lane]
        vx = 0.0
        xs: list[float] = []
        vxs: list[float] = []
        targets: list[int] = []
        for step in range(frames):
            if step in events:
                direction = 1 if events[step] > 0 else -1
                target_lane = max(0, min(2, lane + direction))
                if target_lane != lane:
                    lane = target_lane
                    vx += direction * impulse
            lane_error = lanes[lane] - x
            accel = max(-90.0, min(90.0, lane_error * 48.0 - vx * (friction * friction_multiplier + 4.0)))
            vx = max(-max_v, min(max_v, vx + accel * dt))
            x += vx * dt
            if abs(lane_error) < 0.015 and abs(vx) < 0.08:
                x, vx = lanes[lane], 0.0
            xs.append(x)
            vxs.append(vx)
            targets.append(lane)
        return xs, vxs, targets

    # Derive clearance from the live low-obstacle and player collision definitions.
    spawner = (ROOT / "entities" / "spawner.gd").read_text(encoding="utf-8")
    low_width_match = re.search(r'"low"\s*:\s*\{"w"\s*:\s*([0-9]+(?:\.[0-9]+)?)', spawner)
    player_half_width_match = re.search(r'var hx: float = ([0-9]+(?:\.[0-9]+)?)', spawner)
    if not low_width_match or not player_half_width_match:
        fail("Cannot derive the lane-clearance threshold from live collision definitions")
    low_obstacle_width = float(low_width_match.group(1))
    player_half_width = float(player_half_width_match.group(1))
    half_lane_obstacle_clearance = low_obstacle_width / 2.0 + player_half_width

    # One lane swipe must clear the original collision lane within 300 ms.
    xs, vxs, targets = simulate({0: 1})
    at_300ms = xs[17]
    if at_300ms - lanes[1] <= half_lane_obstacle_clearance:
        fail(f"One lane swipe does not clear the old lane after 300 ms (delta={at_300ms - lanes[1]:.3f}m)")
    if abs(xs[-1] - lanes[2]) > 0.05 or abs(vxs[-1]) >= 0.08:
        fail("Lane controller does not settle near the target lane with near-zero lateral velocity")
    left_x, left_v, left_targets = simulate({0: -1})
    if lanes[1] - left_x[17] <= half_lane_obstacle_clearance or abs(left_x[-1] - lanes[0]) > 0.05 or abs(left_v[-1]) >= 0.08:
        fail("Leftward lane steering does not symmetrically clear and settle at the target lane")
    ice_x, ice_v, ice_targets = simulate({0: 1}, friction_multiplier=ice_friction)
    if ice_x[17] - lanes[1] <= half_lane_obstacle_clearance or abs(ice_x[-1] - lanes[2]) > 0.05 or abs(ice_v[-1]) >= 0.08:
        fail("Reduced-damping ice-biome lane steering no longer clears and settles reliably")

    # A reversal after 100 ms should return to the middle lane without drift.
    reverse_x, reverse_v, reverse_targets = simulate({0: 1, 6: -1}, frames=120)
    if reverse_targets[-1] != 1 or abs(reverse_x[-1] - lanes[1]) > 0.05 or abs(reverse_v[-1]) >= 0.08:
        fail("Quick reverse-lane input does not settle at the new target")
    reverse_lane_midpoint = (lanes[1] + lanes[2]) * 0.5
    if max(reverse_x) > reverse_lane_midpoint + 0.1:
        fail("Quick reverse-lane input carries the runner into the next lane's collision range")

    # Swiping outward at the left lane edge does not change target or add velocity.
    edge_x, edge_v, edge_targets = simulate({0: -1, 1: -1, 2: -1}, start_lane=0, frames=30)
    if any(target != 0 for target in edge_targets) or max(abs(v) for v in edge_v) > 1e-6:
        fail("Repeated outward swipes at a lane boundary should not add outward momentum")

    print(f"PASS lane steering: one swipe clears old lane by 300ms ({at_300ms-lanes[1]:.2f}m; required {half_lane_obstacle_clearance:.2f}m), settles, and quick reversal settles")
    ice_reverse_x, ice_reverse_v, ice_reverse_targets = simulate({0: 1, 6: -1}, frames=120, friction_multiplier=ice_friction)
    if ice_reverse_targets[-1] != 1 or abs(ice_reverse_x[-1] - lanes[1]) > 0.05 or abs(ice_reverse_v[-1]) >= 0.08:
        fail("Quick reverse-lane input does not settle under reduced ice-biome damping")
    if max(ice_reverse_x) > reverse_lane_midpoint + 0.1:
        fail("Quick reversal under reduced ice-biome damping carries the runner into the next lane's collision range")
    print("PASS lane boundary: repeated outward swipes add no momentum")
    print("PASS ice physics: reduced lateral damping still clears a lane and settles after quick reversal")
    print("PASS gameplay guards: adjacent duplicate lane pulses collapse; slide stats count starts; slide dodges require lane overlap")
    print("PASS main-loop churn guards: no throwaway HitResult; reusable effect payload and powerup timer keys")
    return 1

def validate_replay_seed_contracts() -> int:
    """Ensure a run seed controls gameplay randomness and is retained in results.

    This is a source-level contract only. Actual replay equivalence still requires
    execution under the same Godot build, physics settings, and input sequence.
    """
    spawner = (ROOT / "entities" / "spawner.gd").read_text(encoding="utf-8")
    main_source = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    game = (ROOT / "core" / "game.gd").read_text(encoding="utf-8")
    utils = (ROOT / "core" / "utils.gd").read_text(encoding="utf-8")
    required = (
        "_rng: Callable = U.mulberry32(2099)",
        "_rng = U.mulberry32(_run_seed)",
        "_last_pattern = {}",
        "func _shuffle_deterministic(items: Array)",
        "static func _imul32(a: int, b: int) -> int:",
        "static func mulberry32(seed_i: int) -> Callable:",
        "var state: Array[int] = [seed_i & 0xFFFFFFFF]",
        "state[0] = (state[0] + 0x6D2B79F5) & 0xFFFFFFFF",
        "U._imul32((t ^ (t >> 15)) & 0xFFFFFFFF, t | 1)",
        "U._imul32(mixed, t | 61)",
        "t = (t ^ ((t + product) & 0xFFFFFFFF)) & 0xFFFFFFFF",
        "t = (t ^ (t >> 14)) & 0xFFFFFFFF",
        "spawner.reset(run_seed)",
        'game.start_run(dda_mode, run_seed)',
        '"seed": game.run_seed',
    )
    sources = (spawner, utils, main_source, game)
    for token in required:
        if not any(token in source for source in sources):
            fail(f"Reproducible run seed contract is missing: {token}")
    if "var s: int = seed_i" in utils or "s = (s + 0x6D2B79F5)" in utils:
        fail("Mulberry32 must mutate shared reference-type state; captured scalar state is not safe in GDScript lambdas")
    rng_section = spawner.split("# ---------- Seeded randomness (gameplay-only) ----------", 1)
    if len(rng_section) != 2:
        fail("Spawner gameplay RNG section marker is missing")
    gameplay_rng_source = rng_section[1].split("# ---------- 帧更新 ----------", 1)[0]
    if re.search(r"\brandf\s*\(|\brandi\s*\(|\brandi_range\s*\(|U\.(?:choice|randf_range|randi_range)\s*\(|\.shuffle\s*\(\s*\)", gameplay_rng_source):
        fail("Unseeded/global random calls remain in the gameplay spawn sequence")
    # A tiny independent reference-vector check catches accidental formula
    # drift. It validates the algorithm design, not the unexecuted GDScript VM.
    state = 2099 & 0xFFFFFFFF
    observed: list[float] = []
    def imul32(a: int, b: int) -> int:
        a_low, a_high = a & 0xFFFF, (a >> 16) & 0xFFFF
        b_low, b_high = b & 0xFFFF, (b >> 16) & 0xFFFF
        low_product = a_low * b_low
        cross_low = (a_high * b_low + a_low * b_high) & 0xFFFF
        return (low_product + (cross_low << 16)) & 0xFFFFFFFF

    for _ in range(5):
        state = (state + 0x6D2B79F5) & 0xFFFFFFFF
        t = state
        t = imul32((t ^ (t >> 15)) & 0xFFFFFFFF, t | 1)
        mixed = (t ^ (t >> 7)) & 0xFFFFFFFF
        product = imul32(mixed, t | 61)
        t = (t ^ ((t + product) & 0xFFFFFFFF)) & 0xFFFFFFFF
        t = (t ^ (t >> 14)) & 0xFFFFFFFF
        observed.append(t / 4294967296.0)
    expected = [0.626209837384522, 0.19005535286851227, 0.2819462378975004, 0.34540687408298254, 0.041607619961723685]
    if any(abs(a - b) > 1e-15 for a, b in zip(observed, expected)) or len({round(value, 12) for value in observed}) != len(observed):
        fail("Canonical Mulberry32 reference vector changed or produces repeated initial samples")
    input_source = (ROOT / "systems" / "input.gd").read_text(encoding="utf-8")
    for token in (
        "func begin_run_recording(seed_value: int, dda_enabled: bool = true, dda_mode: String = \"\")",
        "func validate_replay_trace(trace: Dictionary) -> bool:",
        "func begin_replay(trace: Dictionary) -> bool:",
        '"replayable": _recording_replayable and not _run_input_trace_truncated',
        "MAX_RUN_INPUT_EVENTS := 8000",
    ):
        if token not in input_source:
            fail(f"Bounded input-trace/replay contract is missing: {token}")
    if "user://nr2099_last_run_input_trace.json" not in main_source or "progress.on_run_end" not in main_source:
        fail("Run trace must be saved at game over and replay diagnostics must retain the normal result flow")
    for token in ("if not _is_replay_run:", "progress.on_run_start()", "progress.on_run_end(", 'progress.unlock_achievement("shield_save")'):
        if token not in main_source:
            fail(f"Replay progression isolation marker is missing: {token}")
    print("PASS reproducibility: seeded RNG/reference vector; bounded action trace; validated frame replay; non-replayable pause/truncated trace rejection; replay progression isolation")
    print("PASS canonical Mulberry32 reference vector: seed 2099 yields 5 expected, distinct initial samples")
    return 1


def validate_run_lifecycle_contracts() -> int:
    """Protect new-run ordering, full resets and signal-driven state transitions.

    This verifies source ordering only; it does not execute the Godot runtime.
    """
    main = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    game = (ROOT / "core" / "game.gd").read_text(encoding="utf-8")
    player = (ROOT / "entities" / "player.gd").read_text(encoding="utf-8")

    if "var _starting_run: bool = false" not in main:
        fail("New-run reentrancy guard is missing")
    start_match = re.search(r"^func _start_run\([^\n]*\) -> void:(.*?)(?=^func \w+\()", main, re.M | re.S)
    if not start_match:
        fail("Cannot locate _start_run lifecycle function")
    start = start_match.group(1)
    start_guard = start.find('if _starting_run or (game.state != "menu" and game.state != "gameover")')
    ordered_tokens = [
        "input.clear_queue()",
        "spawner.reset(run_seed)",
        "player.reset()",
        "effects.reset_fx()",
        "effects.set_rain_active(false)",
        "world.boss_show(false)",
        "world.overclock_on(false)",
        "world.apply_theme(0.0, 0.0, true)",
        "audio.reset_run_state()",
        "hud.reset_run_ui()",
        "progress.on_run_start()",
        'input.call("begin_run_recording", run_seed, dda_enabled, dda_mode)',
        'input.call("begin_replay", input_trace)',
        "game.start_run(dda_mode, run_seed)",
        "menus.show_running()",
    ]
    # Recording/replay initialization must happen after all subsystem resets and
    # before publishing RUNNING. This is a lexical-order contract, not runtime execution.
    positions = [start.find(token) for token in ordered_tokens]
    required_indices = list(range(10)) + [11, 12, 13, 14]
    required_positions = [positions[index] for index in required_indices]
    if start_guard < 0 or any(position < 0 for position in required_positions):
        fail("New-run lifecycle order/guard changed: reset and trace setup must precede Game.start_run()")
    # The progress start hook is conditional in a diagnostic replay; its lexical
    # position must still precede trace init and RUNNING publication.
    if positions[10] < 0 or positions[10] > positions[11] or positions[10] > positions[12]:
        fail("Normal run progression must be prepared before input trace setup")
    if required_positions != sorted(required_positions):
        fail("New-run lifecycle order changed: subsystem reset and trace setup must precede RUNNING")
    if "run_dda" in start:
        fail("Legacy bool/string DDA variable remains in _start_run")
    if start.find("menus.show_running()") < start.find("game.start_run(dda_mode, run_seed)"):
        fail("Running menu must appear after Game.start_run()")
    if "if not _is_replay_run:\n                progress.on_run_start()" not in start:
        fail("Diagnostic replay must not increment normal progression at run start")
    if "effects.set_rain_active(false)" not in start:
        fail("New-run cleanup must explicitly disable rain")
    audio = (ROOT / "systems" / "audio.gd").read_text(encoding="utf-8")
    hud = (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8")
    if "func reset_run_state() -> void:" not in audio or "_wanted_theme = 0" not in audio or "_boss_lock = false" not in audio or "_overclock_lock = false" not in audio:
        fail("AudioEngine needs a complete new-run reset contract including chapter and music locks")
    if "func reset_run_ui() -> void:" not in hud or "_toast_ms = 0.0" not in hud or "update_oc(0.0, Config.OVERCLOCK.chipsNeeded, false)" not in hud:
        fail("HUD needs an explicit new-run reset contract for toast, overclock and counters")
    if "Game.dda_gap_for(dda_mode)" not in start or "Game.dda_unlock_for(dda_mode)" not in start:
        fail("Spawner DDA configuration must be derived before Game publishes RUNNING")

    if "func pause_run() -> bool:" not in game or "func resume_run() -> bool:" not in game:
        fail("Game must own pause/resume state transitions")
    for name in ("pause_run", "resume_run"):
        fn_match = re.search(rf"^func {name}\(\) -> bool:(.*?)(?=^func\s|\Z)", game, re.M | re.S)
        if not fn_match or "state_changed.emit(state)" not in fn_match.group(1):
            fail(f"Game.{name}() must emit state_changed")
    if re.search(r"game\.state\s*=(?!=)", main):
        fail("Main must not mutate Game.state directly; use state-transition methods")

    reset_match = re.search(r"^func reset\(\) -> void:(.*)$", player, re.M | re.S)
    if not reset_match:
        fail("Cannot locate Player.reset()")
    player_reset = reset_match.group(1)
    for token in (
        "run_phase = 0.0", "_skin_glow_time = 0.0", "_fric_scale = 1.0", "_jump_scale = 1.0",
        "_squash_scale = 1.0", 'mech = ""', "_jump_buf = 0.0",
        "_want_slide = false", "body.position = Vector3(0.0, 0.98, 0.0)",
        "leg_l.rotation = Vector3.ZERO", "arm_r.rotation = Vector3.ZERO",
    ):
        if token not in player_reset:
            fail(f"Player.reset() is missing transient-state cleanup: {token}")

    print("PASS run lifecycle: duplicate-start guard; clear-before-publish ordering; explicit world/audio reset; pause/resume state signals; complete Player reset contract")
    return 1


def validate_unified_repair_contracts() -> int:
    """Protect unified persistence, lifecycle, platform, and replay repairs.

    These are source contracts, not substitutes for Godot semantic compilation or device tests.
    """
    progress = (ROOT / "systems" / "progress.gd").read_text(encoding="utf-8")
    main = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    menus = (ROOT / "ui" / "menus.gd").read_text(encoding="utf-8")
    telemetry = (ROOT / "core" / "telemetry.gd").read_text(encoding="utf-8")
    postfx = (ROOT / "fx" / "post_fx.gd").read_text(encoding="utf-8")
    hud = (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8")
    config = (ROOT / "core" / "config.gd").read_text(encoding="utf-8")
    world = (ROOT / "world" / "world.gd").read_text(encoding="utf-8")
    game = (ROOT / "core" / "game.gd").read_text(encoding="utf-8")
    input_source = (ROOT / "systems" / "input.gd").read_text(encoding="utf-8")
    export = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")

    for token in (
        '"guard", "sig"',
        '_canonical_config_payload(f).md5_text()',
        'func _verify_config(f: ConfigFile) -> bool:',
        'func _cleanup_tmp_save(absolute_path: String) -> void:',
        'signal save_failed(message: String)',
        'Time.get_datetime_dict_from_system(false)',
        '_pending_achievement_events',
    ):
        if token not in progress:
            fail(f"Unified persistence contract missing in systems/progress.gd: {token}")
    for method_name in ("claim", "buy_skin", "equip_skin"):
        match = re.search(rf"^func {method_name}\([^\n]*\).*?:\n(.*?)(?=^func \w+\(|\Z)", progress, re.M | re.S)
        if not match or "if not _save():" not in match.group(1):
            fail(f"Progress.{method_name} must roll back the transaction if persistence fails")
    if "Time.get_datetime_dict_from_system(false)" not in progress or 'missions.sel = ["m_dist", "m_chips", "m_smash"]' not in progress:
        fail("Daily mission rollover must use local calendar date and the canonical base mission set")

    if "settings_previewed.emit(key, v / 100.0)" not in menus or "sl.drag_ended.connect" not in menus or "sl.focus_exited.connect" not in menus:
        fail("Volume sliders must preview continuously and commit on drag end/focus exit")
    slider_function = menus.split("func _mk_setting_slider", 1)[1].split("func _mk_setting_check", 1)[0]
    if "commit_timer.timeout.connect" in slider_function:
        fail("Volume slider must not write the save while a user pauses mid-drag; commit only at interaction end")
    for token in ("settings_previewed.connect(_on_setting_previewed)", "func _on_setting_committed", "if not progress.save():", "menus.render_settings(progress.settings)"):
        if token not in main:
            fail(f"Settings persistence/rollback contract missing: {token}")

    if not ('layer = 5' in postfx and 'layer = 10' in hud and 'layer = 20' in menus):
        fail("CanvasLayer order must render PostFX before HUD and menus")
    if 'post_fx.set_active(false)' not in main or 'post_fx.update(raw_dt, game.speed_norm(), game.overclock.active)' not in main:
        fail("PostFX must be disabled on state changes and driven conditionally from the render loop")
    if 'if game.state == "running" or game.state == "dying":' not in main:
        fail("PostFX controller should only evaluate speed accents during active gameplay states")
    if '"hdr"' in config or "window_request_hdr_output" in main or "window_request_hdr_output" in (ROOT / "project.godot").read_text(encoding="utf-8"):
        fail("Android-facing settings must not expose an unsupported HDR output toggle")

    revive = re.search(r"^func _accept_revive\(\) -> void:(.*?)(?=^func \w+\(|\Z)", main, re.M | re.S)
    if not revive:
        fail("Cannot locate revive transaction")
    revive_source = revive.group(1)
    revive_positions = [revive_source.find(token) for token in ("game.prepare_revive()", "player.reset()", "game.finish_revive()", "progress.on_revive()")]
    if any(position < 0 for position in revive_positions) or revive_positions != sorted(revive_positions):
        fail("Revive must prepare state, reset player, publish RUNNING, and persist progression in that order")

    for reason in ("game_pause_or_resume", "application_paused", "overclock_activation_not_recorded", "revive_choice_not_recorded"):
        if reason not in main:
            fail(f"Input trace must reject exact replay when omitted external event occurs: {reason}")
    if 'if _is_replay_run:\n                return # Replay consumes only its recorded action timeline.' not in main:
        fail("Diagnostic replay must ignore live overclock activations")
    if 'if not _is_replay_run:\n                                progress.on_run_end' not in main:
        fail("Diagnostic replay must never write normal run rewards/statistics")
    if "func validate_replay_trace(trace: Dictionary) -> bool:" not in input_source or "MAX_RUN_INPUT_EVENTS := 8000" not in input_source:
        fail("Replay trace needs validation and bounded event storage")

    if 'func _apply_safe_area() -> void:' not in menus or 'DisplayServer.get_display_safe_area()' not in menus or 'get_viewport().size_changed.connect(_apply_safe_area)' not in menus:
        fail("Menus must adapt to Android safe area and viewport changes")
    if 'func set_enabled(on: bool) -> void:' not in telemetry or '_sample_frame_dts.clear()' not in telemetry or '"frameP95Ms"' not in telemetry or '_quality_bad_windows = 0' not in telemetry:
        fail("Telemetry toggle must reset old samples and frame-budget hysteresis, and report frame-time percentile")
    state_handler = re.search(r'(?m)^func _on_state\(s: String\) -> void:\n(.*?)(?=^func \w+\(|\Z)', main, re.S)
    revive_state = re.search(r'(?m)^                "revive":(.*?)(?=^                "[a-z]+":|\Z)', state_handler.group(1), re.S) if state_handler else None
    if not revive_state or "if _is_replay_run:" not in revive_state.group(1) or "game.decline_revive()" not in revive_state.group(1):
        fail("A diagnostic replay that diverges into a revive prompt must terminate rather than accept an unrecorded user choice")

    for key in ("viewDistance", "bloomStrength", "glowSpread", "glowThreshold"):
        if key not in config or key not in world and key != "viewDistance":
            fail(f"Runtime visual setting is not wired in config/world: {key}")
    for key in ("roadCycleLength", "buildingMinH", "buildingMaxH"):
        if key not in config or key not in world:
            fail(f"World visual setting is not wired: {key}")
    effects = (ROOT / "fx" / "effects.gd").read_text(encoding="utf-8")
    if "rainCount" not in config or "Config.WORLD.rainCount" not in effects or "func apply_perf_profile(grade: String) -> void:" not in effects:
        fail("Rain particle budget must be connected through Effects.apply_perf_profile()")
    for key in ("fovPortrait", "fovLandscape", "fovOverclockBoost", "followX", "followY"):
        if key not in config or key not in main:
            fail(f"Camera setting is not wired: {key}")
    if 'user_data_backup/allow=true' not in export:
        fail("Android auto-backup setting must remain explicit in export preset")
    if "keystore/release=""" not in export and "keystore/release=" not in export:
        fail("Release signing needs an explicit configuration slot; never embed credentials")

    print("PASS unified repairs: full-save integrity/migration, transactional persistence, slider commit semantics, Android-safe UI, postfx layer order, replay exclusions, revive order, config wiring and export safeguards")
    return 1


def validate_documentation_and_style() -> int:
    """Check local Markdown links and the repository's GDScript whitespace policy."""
    markdown_files = sorted(ROOT.rglob("*.md"))
    missing_links: list[tuple[str, str]] = []
    link_pattern = re.compile(r"\]\(([^)]+)\)")
    for markdown_path in markdown_files:
        content = markdown_path.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(content):
            target = raw_target.strip().split()[0] if raw_target.strip() else ""
            if not target or target.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            target_path = (markdown_path.parent / target).resolve()
            if not target_path.exists():
                missing_links.append((str(markdown_path.relative_to(ROOT)), raw_target))
    if missing_links:
        details = "; ".join(f"{source} -> {target}" for source, target in missing_links[:10])
        fail(f"broken local Markdown links ({len(missing_links)}): {details}")

    gdscript_files = sorted(ROOT.rglob("*.gd"))
    style_violations: list[str] = []
    for script_path in gdscript_files:
        for line_no, line in enumerate(script_path.read_text(encoding="utf-8").splitlines(), 1):
            if line.startswith("\t"):
                style_violations.append(f"{script_path.relative_to(ROOT)}:{line_no}: leading tab")
            if line.rstrip(" \t") != line:
                style_violations.append(f"{script_path.relative_to(ROOT)}:{line_no}: trailing whitespace")
    if style_violations:
        details = "; ".join(style_violations[:10])
        fail(f"GDScript whitespace policy violations ({len(style_violations)}): {details}")

    print(f"PASS documentation/style: {len(markdown_files)} Markdown files have valid local links; {len(gdscript_files)} GDScript files follow whitespace policy")
    return 1


def validate_gdscript_structure() -> int:
    """Detect unbalanced delimiters and unterminated strings in GDScript files.

    This is intentionally a lightweight lexical sanity check, not a GDScript
    parser and not a replacement for Godot's own importer/compiler.
    """
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {value: key for key, value in pairs.items()}
    scripts = sorted(ROOT.rglob("*.gd"))
    for script_path in scripts:
        source = script_path.read_text(encoding="utf-8")
        stack: list[tuple[str, int]] = []
        quote: str | None = None
        escaped = False
        in_comment = False
        line = 1
        for char in source:
            if char == "\n":
                line += 1
                in_comment = False
                if quote is not None and not escaped:
                    fail(f"{script_path.relative_to(ROOT)}:{line - 1}: string crosses a line without a closing quote")
                if escaped:
                    escaped = False
                continue
            if in_comment:
                continue
            if quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue
            if char == "#":
                in_comment = True
            elif char in ("\"", "'"):
                quote = char
            elif char in pairs:
                stack.append((char, line))
            elif char in closers:
                if not stack or stack[-1][0] != closers[char]:
                    fail(f"{script_path.relative_to(ROOT)}:{line}: unexpected closing delimiter {char!r}")
                stack.pop()
        if quote is not None:
            fail(f"{script_path.relative_to(ROOT)}: unterminated string literal")
        if stack:
            opener, open_line = stack[-1]
            fail(f"{script_path.relative_to(ROOT)}:{open_line}: unclosed delimiter {opener!r}")
    print(f"PASS GDScript lexical structure: balanced quotes/delimiters in {len(scripts)} scripts")
    return len(scripts)



def _validate_shared_root_scroll_equivalence(count: int, threshold: float, cycle: float, factor: float, low_z: float, high_z: float) -> int:
    """Compare the optimized shared-root scheme with the old per-instance reference."""
    rng = random.Random(2099 + count)
    reference = [rng.uniform(low_z, high_z) for _ in range(count)]
    local = reference[:]
    root_z = 0.0
    max_drift = 0.0
    for frame in range(12000):
        speed = float((frame * 37) % 3500) / 100.0
        dt = 1.0 / (45.0 if frame % 7 == 0 else 60.0)
        dz = speed * dt * factor
        for i in range(count):
            reference[i] += dz
            if reference[i] > threshold:
                reference[i] -= cycle
        root_z += dz
        for i in range(count):
            if local[i] + root_z > threshold:
                local[i] -= cycle
        if root_z >= cycle:
            root_z -= cycle
            local = [z + cycle for z in local]
        for i in range(count):
            max_drift = max(max_drift, abs((local[i] + root_z) - reference[i]))
    if max_drift > 1e-6:
        fail(f"Shared-root scroll no longer matches reference transforms (max drift {max_drift:.9f})")
    return 1


def _validate_near_building_event_queue_equivalence(count: int = 96) -> int:
    """Compare the near-city sorted event queue with the original per-slot solver."""
    rng = random.Random(2099)
    # Match world.gd's depth formula/range: -fmod(i*12.5, 200)-randf(0, 8); RNG implementation is intentionally independent.
    reference = [-(i * 12.5 % 200.0) - rng.uniform(0.0, 8.0) for i in range(count)]
    local_zs = reference[:]
    events = sorted(((18.0 - z, slot) for slot, z in enumerate(local_zs)), key=lambda event: event[0])
    if events[-1][0] >= 220.0:
        fail("Near-building recycle thresholds must all occur before the 220 m root rebase")
    cursor = 0
    root_z = 0.0
    max_drift = 0.0
    checks = 0
    for frame in range(12000):
        speed = float((frame * 37) % 3500) / 100.0
        dt = 1.0 / (45.0 if frame % 7 == 0 else 60.0)
        dz = speed * dt * 0.92
        for slot in range(count):
            reference[slot] += dz
            if reference[slot] > 18.0:
                reference[slot] -= 220.0
        root_z += dz
        while True:
            while cursor < len(events) and root_z > events[cursor][0]:
                slot = events[cursor][1]
                local_zs[slot] -= 220.0
                cursor += 1
                checks += 1
            if root_z < 220.0:
                break
            root_z -= 220.0
            local_zs = [z + 220.0 for z in local_zs]
            cursor = 0
        for slot in range(count):
            max_drift = max(max_drift, abs(local_zs[slot] + root_z - reference[slot]))
    if max_drift > 1e-6:
        fail(f"Near-building event queue diverged from per-instance reference (max drift {max_drift:.9f})")
    if checks <= count:
        fail("Near-building event simulation did not exercise repeated recycle cycles")
    print(f"PASS near-building event queue: {count} towers, 12,000 frames, max drift {max_drift:.3e}, {checks} recycle events")
    return 1


def _validate_far_skyline_event_queue_equivalence(count: int = 80) -> int:
    """Compare sorted threshold events with the original per-instance wrap solver."""
    rng = random.Random(2099 + count)
    reference = [rng.uniform(-330.0, -120.0) for _ in range(count)]
    local_zs = reference[:]
    events = sorted(((-105.0 - z, slot) for slot, z in enumerate(local_zs)), key=lambda event: event[0])
    if events[-1][0] >= 230.0:
        fail("Far-skyline recycle thresholds must all occur before the 230 m root rebase")
    cursor = 0
    root_z = 0.0
    max_drift = 0.0
    checks = 0
    for frame in range(12000):
        speed = float((frame * 37) % 3500) / 100.0
        dt = 1.0 / (45.0 if frame % 7 == 0 else 60.0)
        dz = speed * dt * 0.22
        for slot in range(count):
            reference[slot] += dz
            if reference[slot] > -105.0:
                reference[slot] -= 230.0
        root_z += dz
        while True:
            while cursor < len(events) and root_z > events[cursor][0]:
                slot = events[cursor][1]
                local_zs[slot] -= 230.0
                cursor += 1
                checks += 1
            if root_z < 230.0:
                break
            root_z -= 230.0
            local_zs = [z + 230.0 for z in local_zs]
            cursor = 0
        for slot in range(count):
            max_drift = max(max_drift, abs(local_zs[slot] + root_z - reference[slot]))
    if max_drift > 1e-6:
        fail(f"Far-skyline event queue diverged from per-instance reference (max drift {max_drift:.9f})")
    if checks <= count:
        fail("Far-skyline event simulation did not exercise repeated recycle cycles")
    print(f"PASS far-skyline event queue: {count} towers, 12,000 frames, max drift {max_drift:.3e}, {checks} recycle events")
    return 1


def validate_visual_quality_contracts() -> int:
    """Guard the current visual upgrade against silent quality regressions."""
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    telemetry = (ROOT / "core/telemetry.gd").read_text(encoding="utf-8")
    post_shader = (ROOT / "fx/post_fx.gdshader").read_text(encoding="utf-8")
    post_controller = (ROOT / "fx/post_fx.gd").read_text(encoding="utf-8")
    road_shader = (ROOT / "world/road_grid.gdshader").read_text(encoding="utf-8")
    window_shader = (ROOT / "world/building_windows.gdshader").read_text(encoding="utf-8")
    world = (ROOT / "world/world.gd").read_text(encoding="utf-8")
    player = (ROOT / "entities/player.gd").read_text(encoding="utf-8")
    armor_generator = (ROOT / "tools/generate_armor_textures.py").read_text(encoding="utf-8")
    road_generator = (ROOT / "tools/generate_road_textures.py").read_text(encoding="utf-8")
    model_generator = (ROOT / "tools/generate_visual_models.py").read_text(encoding="utf-8")
    if not re.search(r"nx\s*,\s*ny\s*,\s*nz\s*=\s*-dx\s*\*\s*20\.0", armor_generator) or "detail_normal has no separate strength slider" not in armor_generator:
        fail("Armor micro-normal amplitude must remain calibrated for native StandardMaterial3D.detail_normal")

    for setting in (
        "anti_aliasing/quality/msaa_3d=4",
        "textures/default_filters/anisotropic_filtering_level=16",
        "scaling_3d/scale=1.0",
        'renderer/rendering_method="mobile"',
    ):
        if setting not in project:
            fail(f"Visual quality baseline is missing project setting: {setting}")
    if "get_viewport().msaa_3d = Viewport.MSAA_4X" not in telemetry or "Viewport.MSAA_DISABLED" in telemetry or "Viewport.MSAA_2X" in telemetry:
        fail("Adaptive performance grades must preserve 4x MSAA and must not blur edges when FPS pressure appears")
    glow_fn = world.split("func _apply_glow_profile()", 1)[1].split("func set_perf_profile(grade: String)", 1)[0] if "func _apply_glow_profile()" in world else ""
    if "_env.set_glow_level(index, levels[index])" not in glow_fn or "levels = [0.36, 0.56, 0.34, 0.18, 0.07, 0.0, 0.0]" not in glow_fn or "levels = [0.42, 0.60, 0.24, 0.0, 0.0, 0.0, 0.0]" not in glow_fn:
        fail("Native glow must budget actual levels per device tier, not just brightness")
    if "_env.glow_enabled = _overclocking or _perf_profile != \"low\"" not in glow_fn or "_env.glow_intensity = 1.1 if _overclocking else _base_glow" not in glow_fn:
        fail("Low-tier glow should stay disabled except the bounded overclock burst")
    profile_block = world.split("func set_perf_profile(grade: String)", 1)[1].split("func get_render_budget_snapshot()", 1)[0]
    for token in ("DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS", "DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS", "DirectionalLight3D.SHADOW_ORTHOGONAL", "directional_shadow_max_distance = 60.0", "directional_shadow_max_distance = 42.0", "directional_shadow_max_distance = 24.0", "directional_shadow_blend_splits = true", "_apply_glow_profile()"):
        if token not in profile_block:
            fail(f"Native per-tier shadow profile is incomplete: {token}")
    if "func get_render_budget_snapshot() -> Dictionary:" not in world or '\"renderBudget\": world.get_render_budget_snapshot()' not in telemetry:
        fail("Runtime telemetry must expose the active native render budget for profiling")
    if "_apply_glow_profile()" not in world.split("func overclock_on(on: bool)", 1)[1]:
        fail("Overclock must restore its glow pulse then return to tier policy when it ends")
    for token in ("uniform float ca_amount", "uniform float boost_vignette", "hint_screen_texture", "if (ca_amount > 0.005)"):
        if token not in post_shader:
            fail(f"Native-first boost accent contract is missing: {token}")
    for token in ('"ca_amount", 0.0', '"boost_vignette", 0.025', 'var should_draw: bool = ca > 0.005', 'set_active(false)'):
        if token not in post_controller:
            fail(f"Post-processing activation defaults/threshold are missing: {token}")
    for forbidden in ("uniform float sharpness", "uniform float contrast", "uniform float saturation", "neighbor_avg", "hash12", "scanline"):
        if forbidden in post_shader:
            fail(f"Screen shader duplicates native Environment grading or adds unused full-screen work: {forbidden}")
    for token in ("polished_sheen", "panel_joint", "circuit_trace", "deck_sample.a", "road_normal_tex", "center_rail", "METALLIC = mix(0.48, 0.82, polished_inlay)", "float cyber_line_coverage(float distance_to_line, float half_width)", "fwidth(distance_to_line)", "subpixel_coverage = clamp(half_width / max(aa_width, half_width)", "cyber_line_coverage(bus_distance", "cyber_line_coverage(left_lane_distance"):
        if token not in road_shader:
            fail(f"Cyber-deck material-detail contract is missing: {token}")
    if "road_roughness_tex" in road_shader or 'set_shader_parameter("road_roughness_tex"' in world:
        fail("Road shader must use packed roughness alpha to avoid the redundant third texture lookup")
    if 'rough_image = Image.fromarray(roughness, "L")' not in road_generator or "packed_albedo.putalpha(rough_image)" not in road_generator:
        fail("Cyber-deck texture generator must reproducibly pack the source roughness into albedo alpha")
    for token in ("carbon-ceramic", "service-port", "circuit_trace", "cyber_deck_albedo.png", "inset_frame", "socket_ring", "data-lock sockets"):
        if token not in road_generator:
            fail(f"Cyber-deck texture design/generation contract is missing: {token}")
    for token in (
        "hex_inset", "cell_branch", "albedo[:, :, 0] = 252.0", "authored base-color tint",
        "native StandardMaterial3D detail overlay with MUL blend", "authored base-color tint", "detail_mask_u8", 'Image.fromarray(albedo_rgba, "RGBA")',
    ):
        if token not in armor_generator:
            fail(f"Color-preserving cyber armor texture contract is missing: {token}")
    for token in ("window_frame", "glass_glint", "cell_variation", "glitch_seed"):
        if token not in window_shader:
            fail(f"Building facade detail contract is missing: {token}")
    # One helper definition plus three call sites: pane randomness is reused and
    # side/distance guards bypass expensive stochastic facade work on unseen detail.
    if len(re.findall(r"\bhash\(", window_shader)) > 4:
        fail("Building facade shader exceeded the three-call hash budget")
    if window_shader.count("if (side > 0.5") < 2 or "detail > 0.025" not in window_shader or "detail > 0.05" not in window_shader:
        fail("Building facade shader must gate pane animation and signage on visible screen-space detail")
    for token in ("const BUILDING_COUNT := 96", "for i in 80:", "Vector3(0.85, 0.85, 1.0)", '"normal_strength", 0.62'):
        if token not in world:
            fail(f"World visual-density/PBR contract is missing: {token}")
    for token in (
        "tm.inner_radius = 2.56", "tm.outer_radius = 2.82",
        "inner_torus.inner_radius = 2.40", "outer_torus.outer_radius = 3.01",
        "marker_multi.instance_count = 8", "GateCyanConduit", "GateMagentaConduit",
        "inner_ring.position.y = 0.045", "outer_ring.position.y = -0.045",
        "Vector3(cos(angle) * 2.70, 0.075, sin(angle) * 2.70)",
        "Basis(Vector3(0.0, 1.0, 0.0), angle + PI / 2.0)",
        "inner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA",
        "outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA",
    ):
        if token not in world:
            fail(f"Cyber energy-gate detail contract is missing: {token}")
    if "tm.inner_radius = 0.10" in world:
        fail("Cyber energy gate regressed to an oversized solid torus instead of a thin arch")
    for token in ("mesh.radial_segments = 28", "mesh.rings = 16", "mesh.radial_segments = 18"):
        if token not in player:
            fail(f"Player model tessellation contract is missing: {token}")
    for token, source in (
        ("smooth_subdivisions = max(int(ico), 3)", model_generator),
        ("hex_edge", armor_generator),
        ("panel_joint", road_shader),
    ):
        if token not in source:
            fail(f"Regenerable art-detail contract is missing: {token}")
    for shader_path, source in (("fx/post_fx.gdshader", post_shader), ("world/road_grid.gdshader", road_shader), ("world/building_windows.gdshader", window_shader)):
        if source.count("{") != source.count("}") or source.count("(") != source.count(")"):
            fail(f"Unbalanced shader delimiters in {shader_path}")
    building_update = world.split("func _update_building_recycling(spd: float, dt: float)", 1)[1].split("func _update_air_traffic", 1)[0]
    building_guard = building_update.find("root_z > float(_building_recycle_events[event_cursor].threshold)")
    building_transform_write = building_update.find("mm.set_instance_transform(slot, xf)")
    if building_guard < 0 or building_transform_write < building_guard:
        fail("Near-building instance transforms must only be written for crossed recycle-queue events")
    if "_building_recycle_events.sort_custom" not in world or "_building_recycle_pointer = 0" not in world.split("func _build_buildings", 1)[1].split("func _build_far_skyline", 1)[0]:
        fail("Near-building depth-ordered recycle events are not initialized")
    if "for i in mm.instance_count:" in building_update:
        fail("Near-building normal update still scans every tower instead of advancing the recycle event cursor")
    if "mm.get_instance_transform(slot)" in building_update:
        fail("Near-building recycling rebuilds full transforms and must not read back the obsolete instance transform")
    far_update = world.split("func _update_far_skyline(spd: float, dt: float)", 1)[1].split("func _new_building_detail_flags", 1)[0]
    far_guard = far_update.find("skyline.position.z > float(recycle_events[event_cursor].threshold)")
    far_transform_read = far_update.find("mm.get_instance_transform(slot)")
    if far_guard < 0 or far_transform_read < far_guard:
        fail("Far-skyline instance transform reads must occur only for crossed recycle events or during cycle rebase")
    if "_far_skyline_recycle_events.append(recycle_events)" not in world or "_far_skyline_recycle_pointer.append(0)" not in world:
        fail("Far-skyline depth-ordered recycle event queues are not initialized")
    if "for i in local_zs.size():" in far_update:
        fail("Far-skyline normal update still scans every tower instead of advancing the recycle event cursor")
    if "var _building_local_z: Array[float] = []" not in world or "_building_local_z.append(pos.z)" not in world or "_far_skyline_local_z.append(skyline_local_zs)" not in world:
        fail("Root-scrolling position caches must be initialized from each instance's actual local transform")
    profile_policy = {"high": True, "mid": True, "low": False}
    for grade, expected_enabled in profile_policy.items():
        for overclocking in (False, True):
            actual_enabled = overclocking or grade != "low"
            if actual_enabled != (overclocking or expected_enabled):
                fail(f"Bloom profile truth-table mismatch for grade={grade}, overclock={overclocking}")
    if 'var _perf_profile: String = "high"' not in world or '"bloomStrength": 0.48' not in (ROOT / "core" / "config.gd").read_text(encoding="utf-8"):
        fail("Bloom policy must preserve the authored 0.48 intensity for high tier rather than treating it as a low-tier cutoff")
    _validate_shared_root_scroll_equivalence(96, 18.0, 220.0, 0.92, -208.0, 0.0)
    _validate_shared_root_scroll_equivalence(80, -105.0, 230.0, 0.22, -330.0, -120.0)
    _validate_near_building_event_queue_equivalence(96)
    _validate_far_skyline_event_queue_equivalence(80)
    # The road uses two material samples (packed albedo+roughness and the normal map).
    road_sample_calls = len(re.findall(r"\btexture\s*\(", road_shader))
    if road_sample_calls != 2:
        fail(f"Road shader should use exactly two texture samples after roughness packing, got {road_sample_calls}")
    if '"qualityBudgetMultiplier": 1.25' not in (ROOT / "core" / "config.gd").read_text(encoding="utf-8"):
        fail("Frame budget downshift must react to sustained under-target refresh before frame pacing degrades excessively")
    sign_update = world.split("func _update_city_signage(spd: float, dt: float)", 1)[1].split("func _rebase_multimesh_root", 1)[0]
    if "if not sign_color.is_equal_approx(_city_sign_last_colors[i])" not in sign_update or "emission_energy_multiplier" in sign_update:
        fail("City-sign rail material updates must be transition-driven rather than rewriting stable values each frame")
    if "_city_sign_data[i] = data" in sign_update:
        fail("City-sign update must mutate its referenced dictionary without writing the same slot back each frame")
    landmark_update = world.split("func _update_landmarks(spd: float, dt: float)", 1)[1].split("func _build_air_traffic", 1)[0]
    if "if not is_equal_approx(landmark.scale.x, target_scale)" not in landmark_update or "_landmark_data[i] = data" in landmark_update:
        fail("Landmark theme scale must only dirty transforms on actual scale changes")
    traffic_update = world.split("func _update_air_traffic(spd: float, dt: float)", 1)[1].split("func _build_gates", 1)[0]
    if "_air_traffic_data[i] = data" in traffic_update:
        fail("Air-traffic dictionaries must not be redundantly written back every render frame")
    if "spine_mask" not in window_shader or "spine_color" not in window_shader:
        fail("Cyber-facade segmented power conduits are missing")
    if '"road_albedo_tex", preload("res://assets/textures/cyber_deck_albedo.png")' not in world or '"road_normal_tex", preload("res://assets/textures/cyber_deck_normal.png")' not in world:
        fail("Runtime road material does not use the authored cyber-deck PBR set")
    if 'uniform float grid_strength : hint_range(0.0, 1.2) = 0.90' not in road_shader or 'float right_lane_line' not in road_shader or 'float left_edge_line' not in road_shader:
        fail("Cyber road must retain readable high-energy and split-spectrum lane/edge inlays")
    print("PASS visual quality contracts: native-scale mobile render, 4x MSAA, 16x anisotropy, cyber-deck two-sample PBR, derivative-aware subpixel anti-aliased energy lines, tiered native shadow/glow budgets, cyber-facade power conduits and equivalent city recycling")
    return 1




def validate_cyber_ui_contracts() -> int:
    """Check platform-stable vector UI icons and their use in core screens."""
    icon_dir = ROOT / "assets" / "ui" / "icons"
    expected_icons = {
        "achievement.svg", "chip.svg", "home.svg", "mission.svg", "overclock.svg",
        "pause.svg", "play.svg", "settings.svg", "shop.svg", "slider_grabber.svg",
        "toggle_off.svg", "toggle_on.svg",
    }
    present = {path.name for path in icon_dir.glob("*.svg")}
    missing = expected_icons - present
    unexpected = present - expected_icons
    if missing or unexpected:
        fail(f"Cyber UI vector icon inventory mismatch; missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    for name in sorted(expected_icons):
        path = icon_dir / name
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            fail(f"{name}: invalid SVG XML: {exc}")
        if not root.tag.endswith("svg") or root.attrib.get("viewBox") != "0 0 64 64":
            fail(f"{name}: expected a self-contained 64x64 vector viewBox")
        if not list(root.iter()):
            fail(f"{name}: SVG has no vector drawing elements")
        if "filter=" in path.read_text(encoding="utf-8") or "<image" in path.read_text(encoding="utf-8"):
            fail(f"{name}: SVG must remain lightweight vector geometry without embedded raster/filter effects")
    hud = (ROOT / "ui" / "hud.gd").read_text(encoding="utf-8")
    menus = (ROOT / "ui" / "menus.gd").read_text(encoding="utf-8")
    for source, label in ((hud, "HUD"), (menus, "menus")):
        if re.search(r"[◈⚡⏸▣⚑★▶⌂↻✕⚙]", source):
            fail(f"{label} still relies on platform-font decorative glyphs instead of vector UI assets")
    for token in ("ICON_CHIP", "ICON_PAUSE", "ICON_OVERCLOCK", "_apply_icon_button_style", "_add_vector_icon"):
        if token not in hud:
            fail(f"HUD lost vector-icon / cyber-button contract: {token}")
    for token in (
        "ICON_SHOP", "ICON_MISSION", "ICON_ACHIEVEMENT", "ICON_SETTINGS", "ICON_HOME", "CyberButtonContent",
        "ICON_SLIDER_GRABBER", "ICON_TOGGLE_ON", "ICON_TOGGLE_OFF", "_apply_cyber_slider_style",
        "_apply_cyber_check_style", "_apply_cyber_scrollbar_style", "_on_check_label_input",
    ):
        if token not in menus:
            fail(f"Menu screens lost vector icon/native cyber-control composition: {token}")
    for token in (
        'sl.add_theme_stylebox_override("slider", track)',
        'sl.add_theme_stylebox_override("grabber_area", fill)',
        'sl.add_theme_icon_override("grabber", ICON_SLIDER_GRABBER)',
        'cb.add_theme_icon_override("checked", ICON_TOGGLE_ON)',
        'cb.add_theme_icon_override("unchecked", ICON_TOGGLE_OFF)',
        'bar.add_theme_stylebox_override("grabber", thumb)',
        'row.custom_minimum_size.y = 48',
        'l.gui_input.connect(_on_check_label_input.bind(cb))',
        'cb.button_pressed = not cb.button_pressed',
        'scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED',
    ):
        if token not in menus:
            fail(f"Native cyber settings control styling/touch affordance is missing: {token}")
    for token in (
        "dim.mouse_filter = Control.MOUSE_FILTER_PASS", "event is InputEventScreenTouch",
        "event is InputEventMouseButton", "b.custom_minimum_size = Vector2(0, 48)",
        "r.gui_input.connect(_on_panel_input.bind(r))", "r.get_global_transform() * local_position",
        "panel.get_global_rect().has_point(click_global)",
    ):
        if token not in menus:
            fail(f"Touch-first modal/close contract missing: {token}")
    if not re.search(r'_mk_btn\(box, "回主菜单"[^\n]*ICON_HOME\)', menus):
        fail("Return-to-menu actions must use the semantically correct Home vector icon")
    if "pause_btn.offset_left = -60" not in hud or "pause_btn.offset_right = -12" not in hud or "pause_btn.offset_bottom = 56" not in hud:
        fail("HUD pause hit target must remain at least 48x48 logical pixels")
    if "func close_topmost_secondary() -> bool" not in menus or "for panel_root in [achv_root, missions_root, shop_root, settings_root]" not in menus:
        fail("Modal-first back navigation must close only the highest secondary panel")
    main = (ROOT / "scenes" / "main.gd").read_text(encoding="utf-8")
    for token in ("NOTIFICATION_WM_GO_BACK_REQUEST", "func _handle_back_navigation()", "menus.close_topmost_secondary()", '"running", "paused"', '"gameover"', '"revive"'):
        if token not in main:
            fail(f"Native Android Back/Escape navigation contract missing: {token}")
    back_fn = re.search(r"(?m)^func _handle_back_navigation\(\) -> void:\n(.*?)(?=^func \w+\(|\Z)", main, re.S)
    pause_fn = re.search(r"(?m)^func _on_pause\(\) -> void:\n(.*?)(?=^func \w+\(|\Z)", main, re.S)
    if not back_fn or not pause_fn:
        fail("Cannot locate modal-first back/pause handlers")
    back_body = back_fn.group(1)
    pause_body = pause_fn.group(1)
    back_close_pos = back_body.find("menus.close_topmost_secondary()")
    back_state_pos = back_body.find("match game.state:")
    pause_close_pos = pause_body.find("menus.close_topmost_secondary()")
    pause_transition_pos = pause_body.find("if game.pause_run():")
    if back_close_pos < 0 or back_state_pos < 0 or back_close_pos > back_state_pos:
        fail("Back handler must close a visible secondary panel before changing run state")
    if pause_close_pos < 0 or pause_transition_pos < 0 or pause_close_pos > pause_transition_pos:
        fail("Pause/Escape must close a visible secondary panel before pausing/resuming")
    for token in ('"revive":', '"gameover":', '"menu":', "progress.save()", "get_tree().quit()", "_decline_revive()", "_go_home()"):
        if token not in back_body:
            fail(f"Platform Back state mapping missing: {token}")
    runner = ROOT / "tools" / "run_godot_tests.sh"
    runner_text = runner.read_text(encoding="utf-8") if runner.is_file() else ""
    for token in ("godot_recommended_version", "--headless --editor", "test_headless.tscn", "test_content.tscn", "test_mechanics.tscn", "test_runtime.tscn", "scenes/main.tscn"):
        if token not in runner_text:
            fail(f"Pinned-engine Godot test runner is missing: {token}")
    print(f"PASS cyber UI contracts: {len(expected_icons)} vector icons; native themed settings, 48px touch targets, mouse + screen-touch modal dismissal, modal-first Esc/P/Android Back, and portable pinned-engine runner")
    return 1


def validate_native_godot_first_contracts() -> int:
    """Protect idiomatic native Godot rendering/physics and their reset contracts."""
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    main = (ROOT / "scenes/main.gd").read_text(encoding="utf-8")
    player = (ROOT / "entities/player.gd").read_text(encoding="utf-8")
    spawner = (ROOT / "entities/spawner.gd").read_text(encoding="utf-8")
    world = (ROOT / "world/world.gd").read_text(encoding="utf-8")
    effects = (ROOT / "fx/effects.gd").read_text(encoding="utf-8")
    postfx = (ROOT / "fx/post_fx.gd").read_text(encoding="utf-8")
    shader = (ROOT / "fx/post_fx.gdshader").read_text(encoding="utf-8")

    if "common/physics_interpolation=true" not in project:
        fail("Godot-native physics interpolation must be enabled for physics-updated 3D transforms")
    if "cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF" not in main:
        fail("Render-loop-smoothed camera must opt out of built-in interpolation to avoid double smoothing")
    for source, tokens, label in (
        (player, ("reset_physics_interpolation()",), "Player spawn/reset"),
        (spawner, ("reset_instance_physics_interpolation(i)", "reset_instance_physics_interpolation(0)"), "pooled MultiMesh teleport"),
        (world, (
            "reset_physics_interpolation()", "reset_instance_physics_interpolation(slot)",
            "reset_instances_physics_interpolation()", "_building_tops.multimesh.reset_instance_physics_interpolation(index)",
            "_building_masts.multimesh.reset_instance_physics_interpolation(index)",
            "_building_roofs.multimesh.reset_instance_physics_interpolation(index)",
            "landmark.reset_physics_interpolation()", "craft.reset_physics_interpolation()",
            "sign_root.reset_physics_interpolation()", "g.reset_physics_interpolation()"
        ), "city/initial pose/decoration recycle"),
        (effects, ("reset_physics_interpolation()",), "pooled visual FX spawn"),
        (postfx, ("physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF",), "screen-space FX")
    ):
        for token in tokens:
            if token not in source:
                fail(f"Native interpolation reset contract missing for {label}: {token}")
    for token in (
        "Environment.TONE_MAPPER_FILMIC", "env_res.fog_enabled = true", "env_res.glow_enabled = true",
        "WorldEnvironment.new()", "DirectionalLight3D.new()", "StandardMaterial3D.new()", "GPUParticles3D.new()"
    ):
        if token not in world + effects:
            fail(f"Native rendering feature unexpectedly removed: {token}")
    if "post_fx.update(raw_dt, game.speed_norm(), game.overclock.active)" not in main:
        fail("Native-first PostFX should be evaluated from Main without running a full-screen pass continuously")
    if "world.update_render_interpolation(world_advancing)" not in main:
        fail("Shader-only world motion must be interpolated in the render loop for high-refresh displays")
    if "Engine.get_physics_interpolation_fraction()" not in world or "_road_distance_previous + _road_distance_step * fraction" not in world or "_time_previous + _time_step * fraction" not in world:
        fail("Cyber-deck scroll and city window shader time must use Godot's interpolation fraction")
    # Numerically check wrap-safe interpolation across a cycle boundary. Forward circular
    # distance must remain equal to the interpolated step rather than jumping backwards.
    cycle = 42.0
    previous_distance = 41.75
    distance_step = 1.0
    fractions = (0.0, 0.25, 0.50, 0.75, 1.0)
    interpolated_scroll = tuple((previous_distance + distance_step * fraction) % cycle for fraction in fractions)
    for index in range(len(interpolated_scroll) - 1):
        forward_delta = (interpolated_scroll[index + 1] - interpolated_scroll[index]) % cycle
        if abs(forward_delta - distance_step * (fractions[index + 1] - fractions[index])) > 1e-8:
            fail("Cyber-deck render interpolation jumps at the shader scroll cycle seam")
    # Native detail layers are explicitly required instead of replacing glTF/player faction albedo.
    for label, source in (("player", player), ("spawner", spawner), ("world", world)):
        if "detail_enabled = true" not in source or "detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL" not in source or "detail_normal = ARMOR_NORMAL" not in source:
            fail(f"{label} lost the native StandardMaterial3D color-preserving albedo + detail-normal layer")
        if "normal_texture = ARMOR_NORMAL" in source:
            fail(f"{label} must preserve the base normal channel instead of replacing it with micro-detail")
    if "detailed.albedo_texture = null" not in world or "base_texture.get_width() == 2" not in world or 'base_texture.resource_path.begins_with("res://assets/models/")' not in world:
        fail("Imported model placeholder sampler removal must remain size-guarded")
    print("PASS native Godot contracts: native Filmic/Environment/Glow/fog/PBR/particles and StandardMaterial3D detail overlay retained; physics and shader-only motion interpolate at render rate with teleport resets; shader wrap math is continuous; screen-reading shader reserved for speed accents; runtime test runner is portable")
    return 1


def main() -> int:
    models = validate_models()
    textures = validate_textures()
    visual_quality = validate_visual_quality_contracts()
    native_godot = validate_native_godot_first_contracts()
    cyber_ui = validate_cyber_ui_contracts()
    refs = validate_source_references()
    gameplay = validate_gameplay_contracts()
    reproducibility = validate_replay_seed_contracts()
    lifecycle = validate_run_lifecycle_contracts()
    unified = validate_unified_repair_contracts()
    docs_style = validate_documentation_and_style()
    gdscript_files = validate_gdscript_structure()
    print(f"PASS: {models} GLB models, {textures} PBR textures, {visual_quality} visual-quality groups, {native_godot} native-Godot groups, {cyber_ui} cyber-UI groups, {refs} literal resource references, {gameplay + reproducibility + lifecycle + unified + docs_style} gameplay/reproducibility/lifecycle/unified-repair/docs contract groups, and {gdscript_files} GDScript lexical scans validated.")
    print("NOTE: GDScript lexical scans are not Godot syntax/semantic compilation; scene/script/shader compilation and device performance are not covered.")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
