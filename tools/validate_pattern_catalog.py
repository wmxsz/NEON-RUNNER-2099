#!/usr/bin/env python3
"""Structural safety checks for the authored obstacle pattern catalogue.

This is not a Godot physics solver. It validates pattern syntax, references,
non-negative spawn offsets and obviously fully blocked simultaneous hard rows.
"""
from __future__ import annotations
import itertools
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "entities" / "spawner.gd"
HARD_BLOCKERS = {"block", "gate", "mover"}
KNOWN_TYPES = {"low", "bar", "block", "gate", "laser", "mover", "drone"}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL pattern catalog: {message}")


def extract_patterns(source: str) -> list[dict]:
    marker = "const PATTERNS := ["
    start = source.find(marker)
    if start < 0:
        fail("cannot find const PATTERNS")
    start += len("const PATTERNS := ")
    depth = 0
    quoted = False
    escaped = False
    end = -1
    for i in range(start, len(source)):
        ch = source[i]
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
            continue
        if ch == '"':
            quoted = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        fail("unterminated PATTERNS array")
    body = source[start:end]
    body = re.sub(r"(?m)#.*$", "", body)
    body = re.sub(r",\s*([}\]])", r"\1", body)
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        fail(f"PATTERNS is not a JSON-compatible literal: {exc}")
    if not isinstance(parsed, list) or not parsed:
        fail("pattern library must be a non-empty array")
    return parsed


def validate() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    raw_ob = re.search(r"const OB := \{(.*?)\n\}", source, re.S)
    if not raw_ob:
        fail("cannot find obstacle dimension table")
    ob_types = set(re.findall(r'^\s*"([a-z]+)"\s*:', raw_ob.group(1), re.M))
    if ob_types != KNOWN_TYPES:
        fail(f"obstacle type set differs from validator; source={sorted(ob_types)}")
    patterns = extract_patterns(source)
    checked_obstacles = 0
    checked_chip_lines = 0
    checked_hard_rows = 0
    for idx, pattern in enumerate(patterns):
        if not isinstance(pattern, dict):
            fail(f"pattern #{idx} is not a dictionary")
        minimum = pattern.get("min")
        obs = pattern.get("obs")
        chips = pattern.get("chips")
        if not isinstance(minimum, (int, float)) or minimum < 0:
            fail(f"pattern #{idx} has invalid unlock distance")
        if not isinstance(obs, list) or not isinstance(chips, list):
            fail(f"pattern #{idx} must define obs and chips arrays")
        hard_by_z: dict[float, list[tuple[object, str]]] = {}
        for obstacle_idx, obstacle in enumerate(obs):
            if not isinstance(obstacle, list) or len(obstacle) not in (2, 3):
                fail(f"pattern #{idx} obstacle #{obstacle_idx} must be [lane,type,(offset)]")
            lane, kind = obstacle[0], obstacle[1]
            offset = obstacle[2] if len(obstacle) == 3 else 0
            if lane not in ("r", "m", "all", 0, 1, 2):
                fail(f"pattern #{idx} obstacle #{obstacle_idx} has invalid lane selector {lane!r}")
            if kind not in KNOWN_TYPES:
                fail(f"pattern #{idx} obstacle #{obstacle_idx} references unknown type {kind!r}")
            if not isinstance(offset, (int, float)) or offset < 0:
                fail(f"pattern #{idx} obstacle #{obstacle_idx} has negative/invalid offset")
            checked_obstacles += 1
            if kind in HARD_BLOCKERS:
                hard_by_z.setdefault(float(offset), []).append((lane, kind))
        for chip_idx, chip in enumerate(chips):
            if not isinstance(chip, list) or len(chip) != 3:
                fail(f"pattern #{idx} chip line #{chip_idx} must be [lane,spacing,offset]")
            lane, spacing, offset = chip
            if lane not in ("r", "m", "all", 0, 1, 2):
                fail(f"pattern #{idx} chip line #{chip_idx} has invalid lane selector {lane!r}")
            if not isinstance(spacing, (int, float)) or spacing <= 0:
                fail(f"pattern #{idx} chip line #{chip_idx} has invalid spacing")
            if not isinstance(offset, (int, float)) or offset < 0:
                fail(f"pattern #{idx} chip line #{chip_idx} has invalid offset")
            checked_chip_lines += 1
        # Check each exact same-depth group. Random lane selectors are exhaustively
        # enumerated here; any arrangement hard-blocking all 3 lanes is suspicious.
        for offset, entries in hard_by_z.items():
            checked_hard_rows += 1
            choices = []
            for lane, _kind in entries:
                if lane == "all":
                    choices.append([(0, 1, 2)])
                elif lane == "r":
                    choices.append([(0,), (1,), (2,)])
                elif lane == "m":
                    choices.append([(1,)])
                else:
                    choices.append([(int(lane),)])
            assignments = itertools.product(*choices)
            for assignment in assignments:
                blocked: set[int] = set()
                for row_lanes in assignment:
                    blocked.update(row_lanes)
                if blocked == {0, 1, 2}:
                    fail(f"pattern #{idx} may hard-block all lanes at offset {offset:g}: {entries}")
    print(f"PASS pattern catalog: {len(patterns)} patterns, {checked_obstacles} obstacles, {checked_chip_lines} chip lines, {checked_hard_rows} simultaneous hard-obstacle rows; no structural all-lane hard lock found")
    print("NOTE: this is a structural screen, not a continuous-time collision solver; jump/slide timing, obstacle widths and overlapping depth windows still require Godot gameplay simulation.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(validate())
    except OSError as exc:
        raise SystemExit(f"FAIL pattern catalog: {exc}")
