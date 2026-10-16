#!/usr/bin/env python3
"""Generate short, deterministic PCM sound effects for NEON RUNNER 2099.

Uses only the Python standard library. Re-run from any directory; assets are
written relative to this script's project root. These are game SFX, not music.
"""
from __future__ import annotations

import math
import random
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "sfx"
RATE = 44_100

# Name -> duration in seconds. Durations are intentionally short to keep Android
# memory use low while allowing several sounds to overlap through an audio pool.
DURATIONS = {
    "chip": 0.105,
    "jump": 0.145,
    "land": 0.125,
    "slide": 0.205,
    "die": 0.48,
    "powerup": 0.31,
    "overclock": 0.43,
    "ui": 0.060,
    "achv": 0.31,
    "ready": 0.13,
    "boss": 0.56,
    "revive": 0.34,
}


def env(t: float, duration: float, attack: float = 0.004, release: float = 0.05) -> float:
    a = min(1.0, t / max(attack, 1e-5))
    r = min(1.0, max(0.0, duration - t) / max(release, 1e-5))
    return min(a, r)


def sine_sweep(t: float, f0: float, f1: float, duration: float) -> float:
    # Integrate linearly-changing frequency rather than changing phase abruptly.
    k = (f1 - f0) / max(duration, 1e-5)
    phase = 2.0 * math.pi * (f0 * t + 0.5 * k * t * t)
    return math.sin(phase)


def synth(name: str, t: float, d: float, rng: random.Random, noise: float) -> float:
    e = env(t, d, attack=0.003 if name in {"chip", "ui", "ready"} else 0.012,
            release={"die": 0.20, "boss": 0.24, "revive": 0.13}.get(name, 0.065))
    u = t / d
    n = noise
    if name == "chip":
        return e * (0.25 * sine_sweep(t, 1420, 1880, d) + 0.11 * sine_sweep(t, 2140, 2750, d))
    if name == "jump":
        return e * (0.26 * sine_sweep(t, 280, 690, d) + 0.035 * sine_sweep(t, 560, 1380, d))
    if name == "land":
        thud = sine_sweep(t, 112, 53, d) * math.exp(-t * 22.0)
        grit = (rng.random() * 2.0 - 1.0) * math.exp(-t * 32.0)
        return e * (0.44 * thud + 0.10 * grit)
    if name == "slide":
        squeak = sine_sweep(t, 780, 260, d) * (0.12 * (1.0 - u))
        return e * (0.19 * n + squeak)
    if name == "die":
        low = sine_sweep(t, 250, 54, d)
        overtone = sine_sweep(t, 510, 105, d)
        grit = (rng.random() * 2.0 - 1.0) * math.exp(-t * 5.5)
        return e * (0.24 * low + 0.07 * overtone + 0.045 * grit)
    if name == "powerup":
        first = sine_sweep(t, 570, 1060, d)
        second = sine_sweep(max(0.0, t - 0.10), 980, 1540, max(0.07, d - 0.10)) if t >= 0.10 else 0.0
        return e * (0.18 * first + 0.16 * second)
    if name == "overclock":
        rise = sine_sweep(t, 90, 330, d)
        shine = sine_sweep(t, 440, 1480, d)
        air = n * (0.8 - 0.35 * u)
        return e * (0.20 * rise + 0.11 * shine + 0.055 * air)
    if name == "ui":
        return e * (0.18 * sine_sweep(t, 820, 1120, d))
    if name == "achv":
        notes = ((0.0, 660.0), (0.085, 880.0), (0.17, 1320.0))
        value = 0.0
        for start, freq in notes:
            if t >= start:
                q = t - start
                value += 0.14 * math.sin(2.0 * math.pi * freq * q) * math.exp(-q * 10.0)
        return e * value
    if name == "ready":
        tone = sine_sweep(t, 880, 1060, d)
        pulse = 1.0 if math.sin(2.0 * math.pi * 34.0 * t) >= 0.0 else -1.0
        return e * (0.16 * tone + 0.025 * pulse)
    if name == "boss":
        rumble = sine_sweep(t, 68, 39, d)
        sub = sine_sweep(t, 52, 33, d)
        texture = n * math.exp(-t * 3.0)
        return e * (0.30 * rumble + 0.12 * sub + 0.03 * texture)
    if name == "revive":
        lift = sine_sweep(t, 320, 820, d)
        shimmer = sine_sweep(t, 640, 1640, d)
        return e * (0.22 * lift + 0.07 * shimmer)
    raise KeyError(name)


def write_effect(name: str, duration: float) -> None:
    rng = random.Random(2099 + sum(ord(c) for c in name))
    frames = int(RATE * duration)
    pcm = bytearray()
    previous_noise = 0.0
    for i in range(frames):
        t = i / RATE
        raw_noise = rng.random() * 2.0 - 1.0
        # A simple low-pass/noise-difference mix avoids harsh full-band noise.
        noise = 0.72 * raw_noise + 0.28 * (raw_noise - previous_noise)
        previous_noise = raw_noise
        value = synth(name, t, duration, rng, noise)
        value = max(-0.92, min(0.92, value))
        sample = int(value * 32767.0)
        pcm.extend(sample.to_bytes(2, byteorder="little", signed=True))
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(pcm)
    peak = max(abs(int.from_bytes(pcm[i:i+2], "little", signed=True)) for i in range(0, len(pcm), 2))
    print(f"WROTE {path.relative_to(ROOT)}: {frames} frames, {duration:.3f}s, peak={peak / 32767.0:.3f}")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, duration in DURATIONS.items():
        write_effect(name, duration)


if __name__ == "__main__":
    main()
