#!/usr/bin/env sh
# Pinned-engine verification. This complements, not replaces, the offline Python checks.
# Usage: GODOT_BIN=/path/to/Godot_v4.7.2-stable sh tools/run_godot_tests.sh
set -eu
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"
PYTHON=${PYTHON:-python3}
# Every editor import/test scene/main smoke uses a private test save + replay namespace.
export NR2099_TEST_MODE=1

if [ -n "${GODOT_BIN:-}" ]; then
    ENGINE=$GODOT_BIN
elif command -v godot4 >/dev/null 2>&1; then
    ENGINE=$(command -v godot4)
elif command -v godot >/dev/null 2>&1; then
    ENGINE=$(command -v godot)
else
    EXPECTED=$($PYTHON -c 'import json; print(json.load(open("RELEASE_MANIFEST.json", encoding="utf-8"))["godot_recommended_version"])')
    echo "SKIP Godot runtime suite: $EXPECTED executable not found."
    exit 0
fi

if [ ! -x "$ENGINE" ]; then
    echo "FAIL Godot executable is not executable: $ENGINE" >&2
    exit 2
fi
EXPECTED=$($PYTHON -c 'import json; print(json.load(open("RELEASE_MANIFEST.json", encoding="utf-8"))["godot_recommended_version"])')
EXPECTED_BASE=${EXPECTED%-stable}
ACTUAL=$($ENGINE --version 2>/dev/null || true)
case "$ACTUAL" in
    "$EXPECTED_BASE"*) ;;
    *)
        echo "SKIP pinned-engine suite: found '$ACTUAL', but release manifest requires '$EXPECTED'." >&2
        exit 0
        ;;
esac

printf 'RUN Godot editor import/semantic parse: %s (%s)\n' "$ENGINE" "$ACTUAL"
"$ENGINE" --headless --editor --path "$PROJECT_ROOT" --quit

for scene in \
    res://tests/test_headless.tscn \
    res://tests/test_content.tscn \
    res://tests/test_mechanics.tscn \
    res://tests/test_runtime.tscn; do
    printf 'RUN test scene: %s\n' "$scene"
    # Content soak includes a 25-second run, a possible 6-second boss window,
    # revive timeout, and later regressions. 30 seconds was not a safe ceiling.
    FRAME_BUDGET=1800
    if [ "$scene" = "res://tests/test_content.tscn" ]; then
        FRAME_BUDGET=5400
    fi
    "$ENGINE" --headless --fixed-fps 60 --audio-driver Dummy --path "$PROJECT_ROOT" --quit-after "$FRAME_BUDGET" "$scene"
done

printf 'RUN main-scene startup smoke test\n'
"$ENGINE" --headless --fixed-fps 60 --audio-driver Dummy --path "$PROJECT_ROOT" --quit-after 180 res://scenes/main.tscn
printf 'PASS pinned Godot %s editor import, 4 test scenes, and main-scene startup.\n' "$ACTUAL"
