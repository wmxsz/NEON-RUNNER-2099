#!/usr/bin/env sh
# One-command validation for NEON RUNNER 2099. Engine smoke tests only count as release validation on the manifest-pinned stable patch.
# Run from any directory: sh tools/run_offline_checks.sh
set -eu
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"
PYTHON=${PYTHON:-python3}

"$PYTHON" -m py_compile tools/*.py
"$PYTHON" tools/validate_project_integrity.py
"$PYTHON" tools/validate_visual_assets.py
"$PYTHON" tools/validate_pattern_catalog.py
"$PYTHON" tools/validate_release_contracts.py

# Run the pinned-engine semantic/import suite when the recommended engine is available.
# Missing Godot is reported as SKIP, never counted as a passed runtime test.
GODOT_BIN="${GODOT_BIN:-}"
if [ -z "$GODOT_BIN" ]; then
    if command -v godot4 >/dev/null 2>&1; then
        GODOT_BIN=$(command -v godot4)
    elif command -v godot >/dev/null 2>&1; then
        GODOT_BIN=$(command -v godot)
    fi
fi
GODOT_BIN="$GODOT_BIN" sh "$SCRIPT_DIR/run_godot_tests.sh"
