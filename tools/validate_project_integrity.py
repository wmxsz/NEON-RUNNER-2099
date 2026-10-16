#!/usr/bin/env python3
"""Cross-cutting project integrity checks driven by RELEASE_MANIFEST.json.

These checks validate repository consistency and references. They do not parse or
compile GDScript, scenes, or shaders; Godot engine checks remain a separate gate.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_SUFFIXES = {".gd", ".gdshader", ".tscn", ".tres", ".godot", ".cfg", ".import"}
CURRENT_DOCS = (
    "README.md",
    "docs/README.md",
    "docs/RELEASE_STATUS.md",
    "docs/PROJECT_MAP.md",
    "docs/DEVELOPMENT_GUIDE.md",
    "docs/REGRESSION_CHECKLIST.md",
    "docs/RUN_LIFECYCLE.md",
    "docs/ART_PIPELINE.md",
    "docs/build/ENVIRONMENT_SETUP.md",
    "docs/build/ANDROID_RELEASE_CHECKLIST.md",
)


def fail(message: str) -> None:
    raise SystemExit(f"FAIL project integrity: {message}")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read {path.relative_to(ROOT)}: {exc}")
        raise AssertionError("unreachable")


def validate_manifest() -> dict:
    path = ROOT / "RELEASE_MANIFEST.json"
    if not path.is_file():
        fail("RELEASE_MANIFEST.json is missing")
    try:
        manifest = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        fail(f"RELEASE_MANIFEST.json is invalid JSON: {exc}")
    if not isinstance(manifest, dict):
        fail("RELEASE_MANIFEST.json root must be an object")
    required = {
        "product", "display_name", "version", "android_version_code",
        "godot_series", "godot_recommended_version", "physics_ticks_per_second", "replay_schema",
        "replay_ruleset_version", "asset_counts", "delivery", "project_name",
        "main_scene", "renderer", "viewport", "android_package_id", "android_abis",
        "android_backup_enabled", "android_artifact_name", "current_audit_report",
    }
    missing = sorted(required - set(manifest))
    if missing:
        fail(f"release manifest misses keys: {missing}")
    for key in ("product", "display_name", "godot_series", "project_name", "main_scene", "renderer", "android_package_id", "android_artifact_name", "godot_recommended_version", "current_audit_report"):
        if not isinstance(manifest[key], str) or not manifest[key].strip():
            fail(f"release manifest {key} must be a non-empty string")
    if not isinstance(manifest["viewport"], dict) or not all(k in manifest["viewport"] for k in ("width", "height", "orientation")):
        fail("manifest viewport must define width, height and orientation")
    if int(manifest["viewport"]["width"]) <= 0 or int(manifest["viewport"]["height"]) <= 0:
        fail("manifest viewport dimensions must be positive")
    if manifest["viewport"]["orientation"] not in ("portrait", "landscape"):
        fail("manifest viewport orientation must be portrait or landscape")
    if not isinstance(manifest["android_abis"], list) or not manifest["android_abis"] or len(set(manifest["android_abis"])) != len(manifest["android_abis"]):
        fail("android_abis must be a non-empty list of unique ABI names")
    known_abis = {"armeabi-v7a", "arm64-v8a", "x86", "x86_64"}
    if any(not isinstance(abi, str) or abi not in known_abis for abi in manifest["android_abis"]):
        fail("android_abis contains an unsupported ABI name")
    if not isinstance(manifest["android_backup_enabled"], bool):
        fail("android_backup_enabled must be a Boolean")
    if not isinstance(manifest["asset_counts"], dict) or not isinstance(manifest["delivery"], dict):
        fail("asset_counts and delivery must be objects")
    if not isinstance(manifest["delivery"].get("contains_apk"), bool) or not isinstance(manifest["delivery"].get("release_signing_configured"), bool):
        fail("delivery contains_apk and release_signing_configured must be Booleans")
    if not re.fullmatch(r"\d+\.\d+\.\d+-G", str(manifest["version"])):
        fail(f"invalid version format: {manifest['version']!r}")
    if not re.fullmatch(r"\d+\.\d+\.\d+-stable", str(manifest["godot_recommended_version"])):
        fail("godot_recommended_version must be a stable semantic version such as 4.7.2-stable")
    if not str(manifest["godot_recommended_version"]).startswith(str(manifest["godot_series"]) + "."):
        fail("recommended Godot patch must belong to the configured feature series")
    version_number = str(manifest["version"]).split("-", 1)[0].replace(".", "_")
    expected_audit = f"docs/audit/V{version_number}_CLEAN_HANDOFF.md"
    if str(manifest["current_audit_report"]) != expected_audit:
        fail(f"current_audit_report must follow the release identity ({expected_audit})")
    if int(manifest["android_version_code"]) < 1:
        fail("android_version_code must be positive")
    if int(manifest["physics_ticks_per_second"]) != 60:
        fail("manifest physics tick rate must match this project's 60 Hz simulation")
    return manifest


def validate_version(manifest: dict) -> None:
    version = str(manifest["version"])
    code = int(manifest["android_version_code"])
    project = read_text(ROOT / "project.godot")
    export = read_text(ROOT / "export_presets.cfg")
    project_version = re.search(r'^config/version="([^\"]+)"', project, re.M)
    export_version = re.search(r'^version/name="([^\"]+)"', export, re.M)
    export_code = re.search(r"^version/code=(\d+)", export, re.M)
    feature = re.search(r'^config/features=PackedStringArray\("([^\"]+)"\)', project, re.M)
    if not project_version or project_version.group(1) != version:
        fail(f"project.godot version must be {version}")
    if not export_version or export_version.group(1) != version:
        fail(f"Android version/name must be {version}")
    if not export_code or int(export_code.group(1)) != code:
        fail(f"Android version/code must be {code}")
    if not feature or feature.group(1) != str(manifest["godot_series"]):
        fail(f"project engine feature must be Godot {manifest['godot_series']}")
    expected_project_fields = {
        "config/name": str(manifest["project_name"]),
        "run/main_scene": str(manifest["main_scene"]),
        "renderer/rendering_method": str(manifest["renderer"]),
    }
    for key, value in expected_project_fields.items():
        m = re.search(r"^" + re.escape(key) + r'=\"([^\"]+)\"$', project, re.M)
        if not m or m.group(1) != value:
            fail(f"project setting {key} must match RELEASE_MANIFEST.json ({value})")
    viewport_checks = (
        ("window/size/viewport_width", int(manifest["viewport"]["width"])),
        ("window/size/viewport_height", int(manifest["viewport"]["height"])),
    )
    for key, value in viewport_checks:
        m = re.search(r"^" + re.escape(key) + r"=(\d+)$", project, re.M)
        if not m or int(m.group(1)) != value:
            fail(f"project viewport {key} must match release manifest")
    if re.search(r"^export_presets\.cfg\s*$", read_text(ROOT / ".gitignore"), re.M):
        fail("export_presets.cfg must remain tracked")
    for key in ("keystore/release=", "keystore/release_user=", "keystore/release_password="):
        match = re.search(r"^" + re.escape(key) + r"(.*)$", export, re.M)
        if not match or match.group(1).strip().strip('"'):
            fail(f"release signing secret must remain blank in source: {key}")
    for key, expected in (("package/unique_name", str(manifest["android_package_id"])),
                          ("package/name", str(manifest["project_name"])),
                          ("version/name", version),
                          ("version/code", str(code)),
                          ("user_data_backup/allow", "true" if bool(manifest["android_backup_enabled"]) else "false")):
        m = re.search(r"^" + re.escape(key) + r"=(.*)$", export, re.M)
        if not m or m.group(1).strip().strip('"') != expected:
            fail(f"Android export field {key} must match release manifest ({expected})")
    artifact_match = re.search(r'^export_path="([^"\n]+)"', export, re.M)
    if not artifact_match or Path(artifact_match.group(1)).name != str(manifest["android_artifact_name"]):
        fail("Android export artifact filename must match release manifest")
    abis = {
        "arm64-v8a": bool(manifest["android_abis"].count("arm64-v8a")),
        "armeabi-v7a": bool(manifest["android_abis"].count("armeabi-v7a")),
        "x86": bool(manifest["android_abis"].count("x86")),
        "x86_64": bool(manifest["android_abis"].count("x86_64")),
    }
    for abi, enabled in abis.items():
        m = re.search(r"^architectures/" + re.escape(abi) + r"=(true|false)$", export, re.M)
        if not m or (m.group(1) == "true") != enabled:
            fail(f"Android ABI {abi} must match release manifest")
    if not bool(manifest["delivery"].get("contains_apk", False)) and list(ROOT.rglob("*.apk")):
        fail("manifest says this is a source-only package, but an APK is present")
    physics = read_text(ROOT / "project.godot")
    m = re.search(r"^common/physics_ticks_per_second=(\d+)$", physics, re.M)
    if not m or int(m.group(1)) != int(manifest["physics_ticks_per_second"]):
        fail("physics tick rate differs from the release manifest")
    for rel in CURRENT_DOCS:
        doc_path = ROOT / rel
        if not doc_path.is_file():
            fail(f"current documentation entry point is missing: {rel}")
        content = read_text(doc_path)
        opening = "\n".join(content.splitlines()[:12])
        if version not in opening or f"versionCode={code}" not in opening:
            fail(f"current baseline missing in opening section of {rel}")
        advertised_baselines = re.findall(r"当前开发基线：v([^（]+)（Android versionCode=(\d+)）", opening)
        if not advertised_baselines or any(v != version or int(c) != code for v, c in advertised_baselines):
            fail(f"stale or conflicting current baseline remains in opening section of {rel}")
    recommended_engine = str(manifest["godot_recommended_version"])
    for rel in ("README.md", "docs/RELEASE_STATUS.md", "docs/REGRESSION_CHECKLIST.md", "docs/build/ENVIRONMENT_SETUP.md", str(manifest["current_audit_report"]), "docs/CHANGELOG.md"):
        content = read_text(ROOT / rel)
        if recommended_engine not in content:
            fail(f"recommended stable engine target {recommended_engine} is stale/missing in {rel}")


def validate_assets(manifest: dict) -> None:
    counts = manifest["asset_counts"]
    actual = {
        "glb_models": len(list((ROOT / "assets/models").glob("*.glb"))),
        "pbr_textures": len(list((ROOT / "assets/textures").glob("*.png"))),
        "music_tracks": len(list((ROOT / "assets/music").glob("*.ogg"))),
        "sfx_streams": len(list((ROOT / "assets/sfx").glob("*.wav"))),
        "ui_vector_icons": len(list((ROOT / "assets/ui/icons").glob("*.svg"))),
    }
    for key, expected in actual.items():
        if int(counts.get(key, -1)) != expected:
            fail(f"manifest asset count {key}={counts.get(key)} but project contains {expected}")


def validate_resource_paths() -> int:
    refs = 0
    missing: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        content = read_text(path)
        for match in re.finditer(r'''["']res://([^"']+)["']''', content):
            raw = match.group(1)
            # Resource subresources use :: identifiers; interpolation is not a fixed file path.
            resource = raw.split("::", 1)[0]
            if resource.startswith(".godot/") or any(token in resource for token in ("%", "{", "}")):
                # Imported cache destinations are generated by Godot and intentionally
                # do not ship in the source archive.
                continue
            if not (ROOT / resource).is_file() and not (ROOT / resource).is_dir():
                missing.append(f"{path.relative_to(ROOT)} -> res://{resource}")
            refs += 1
    if missing:
        fail("missing literal resource paths: " + "; ".join(missing[:15]))
    return refs


def validate_uids() -> int:
    seen: dict[str, str] = {}
    uid_files = list(ROOT.rglob("*.uid"))
    for path in uid_files:
        raw = read_text(path).strip()
        if not raw.startswith("uid://"):
            fail(f"invalid UID sidecar: {path.relative_to(ROOT)}")
        previous = seen.get(raw)
        if previous:
            fail(f"duplicate UID {raw}: {previous} and {path.relative_to(ROOT)}")
        seen[raw] = str(path.relative_to(ROOT))
        owner = path.with_suffix("")
        if not owner.is_file():
            fail(f"orphan UID sidecar {path.relative_to(ROOT)}")
    missing_sidecars = []
    for suffix in (".gd", ".gdshader"):
        for owner in ROOT.rglob(f"*{suffix}"):
            if not owner.with_suffix(owner.suffix + ".uid").is_file():
                missing_sidecars.append(str(owner.relative_to(ROOT)))
    if missing_sidecars:
        fail("script/shader UID sidecar missing for: " + ", ".join(missing_sidecars[:10]))
    return len(seen)


def validate_release_cleanup() -> None:
    allowed_root_docs = {"README.md"}
    unexpected_root_docs = sorted(path.name for path in ROOT.iterdir()
                                  if path.is_file() and path.suffix.lower() in {".md", ".txt"}
                                  and path.name not in allowed_root_docs)
    if unexpected_root_docs:
        fail("historical documents must not accumulate in the project root: " + ", ".join(unexpected_root_docs))
    stale_versioned_validators = sorted(path.name for path in (ROOT / "tools").glob("validate_v*_contracts.py"))
    if stale_versioned_validators:
        fail("version-hardcoded validator filenames must be migrated to validate_release_contracts.py: " + ", ".join(stale_versioned_validators))
    archive = ROOT / "docs/audit/archive"
    if not archive.is_dir() or not any(archive.glob("*.md")):
        fail("historical audit archive is missing or empty")



def validate_baseline_hygiene() -> None:
    # Current audit directory must not accumulate old release reports beside the active report.
    active_audit_files = sorted(path.name for path in (ROOT / "docs/audit").glob("*.md"))
    expected_audit_name = Path(str(json.loads(read_text(ROOT / "RELEASE_MANIFEST.json"))["current_audit_report"])).name
    if active_audit_files != [expected_audit_name]:
        fail(f"only {expected_audit_name} may remain directly under docs/audit/; move older reports to docs/audit/archive/")
    if not (ROOT / str(json.loads(read_text(ROOT / "RELEASE_MANIFEST.json"))["current_audit_report"])).is_file():
        fail("manifest current_audit_report path does not exist")
    if not (ROOT / "docs/CHANGELOG_HISTORY.md").is_file():
        fail("historical change log must remain separate from the current release log")
    # Legacy project-version tags in live script comments made previous releases look current.
    for suffix in (".gd", ".gdshader"):
        for path in ROOT.rglob(f"*{suffix}"):
            for number, line in enumerate(read_text(path).splitlines(), 1):
                comment = line.split("#", 1)[1] if "#" in line else ""
                if re.search(r"\bv\d+\.\d+(?:\.\d+)?\b", comment) or any(token in comment for token in ("WebView", "移植自", "对齐 JS")):
                    fail(f"legacy iteration/source-port comment remains in live script {path.relative_to(ROOT)}:{number}; current code comments should describe current responsibility")


def main() -> int:
    manifest = validate_manifest()
    validate_version(manifest)
    validate_assets(manifest)
    refs = validate_resource_paths()
    uid_count = validate_uids()
    validate_release_cleanup()
    validate_baseline_hygiene()
    print(f"PASS release manifest: {manifest['version']} / Android code {manifest['android_version_code']} / Godot {manifest['godot_series']}")
    print(f"PASS project integrity: {refs} literal res:// paths, {uid_count} unique script/shader UIDs, version/project/Android identity and ABI settings match manifest, current/history docs separated, no legacy version tags in live script comments")
    print("NOTE: Integrity checks do not replace Godot's semantic parser, scene/shader import or Android device validation.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise SystemExit(f"FAIL project integrity: {exc}")
