#!/usr/bin/env bash
# NEON RUNNER 2099 — Godot runtime test entrypoint.
# Usage: ./run_tests.sh [path/to/godot] ; alternatively set GODOT_BIN or add godot4/godot to PATH.
# Offline/source/resource gates live in tools/run_offline_checks.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# Tests must never load, delete, or rewrite a player's real profile/replay trace.
export NR2099_TEST_MODE=1

GODOT="${1:-${GODOT_BIN:-}}"
if [[ -z "$GODOT" ]]; then
  if command -v godot4 >/dev/null 2>&1; then
    GODOT="$(command -v godot4)"
  elif command -v godot >/dev/null 2>&1; then
    GODOT="$(command -v godot)"
  fi
fi

if [[ -z "$GODOT" ]]; then
  echo "SKIP engine runtime tests: Godot executable not found."
  echo "Set GODOT_BIN, pass the Godot binary path, or run 'sh tools/run_offline_checks.sh' for offline/source checks."
  exit 2
fi
if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot executable is not executable: $GODOT" >&2
  exit 2
fi

ACTUAL_VERSION="$("$GODOT" --version 2>/dev/null || true)"
RECOMMENDED_VERSION="$(python3 -c 'import json; print(json.load(open("RELEASE_MANIFEST.json", encoding="utf-8"))["godot_recommended_version"].removesuffix("-stable"))')"
if [[ "$ACTUAL_VERSION" != "$RECOMMENDED_VERSION"* ]]; then
  echo "ERROR: runtime tests require Godot ${RECOMMENDED_VERSION}-stable; found '${ACTUAL_VERSION:-unknown}'." >&2
  exit 2
fi

echo "=== Godot runtime tests: $GODOT ($ACTUAL_VERSION) ==="
for test in test_headless test_runtime test_content test_mechanics; do
  log="$(mktemp "/tmp/neon-runner-${test}.XXXXXX.log")"
  if timeout 240 "$GODOT" --headless --fixed-fps 60 --audio-driver Dummy --path . "res://tests/${test}.tscn" >"$log" 2>&1; then
    summary="$(grep '汇总' "$log" | tail -1 || true)"
    echo "PASS $test ${summary}"
  else
    echo "FAIL $test"
    grep -m8 -E '✗|SCRIPT ERROR|ERROR:' "$log" || tail -40 "$log" || true
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
done
