#!/usr/bin/env python3
"""NEON RUNNER 2099 — 离线音乐渲染器
把 WebAudio 合成逻辑（Am-F-C-G 双段落 Synthwave）升级为高质量预渲染 OGG。
5 曲：4 章节变奏 + 1 BOSS 战歌。140BPM（BOSS 150）。
"""
import numpy as np
from scipy import signal as sg
import wave, subprocess, os
from pathlib import Path

SR = 44100

def note(f): return f

def adsr(n, a=0.01, d=0.05, s=0.7, r=0.08):
    t = np.linspace(0, 1, n)
    env = np.ones(n) * s
    na, nd, nr = int(a*n), int(d*n), int(r*n)
    if na: env[:na] = np.linspace(0, 1, na)
    if nd: env[na:na+nd] = np.linspace(1, s, nd)[:nd]
    if nr: env[-nr:] = env[-nr:] * np.linspace(1, 0, nr)
    return env

def saw(freq, dur, sr=SR, detune=0.0):
    t = np.arange(int(dur*sr)) / sr
    f = freq * (1 + detune)
    return 2*((t*f) % 1.0) - 1

def square(freq, dur, sr=SR):
    t = np.arange(int(dur*sr)) / sr
    return np.sign(np.sin(2*np.pi*freq*t)) * 0.8

def sine(freq, dur, sr=SR):
    t = np.arange(int(dur*sr)) / sr
    return np.sin(2*np.pi*freq*t)

def reverb(x, sr=SR, decay=0.35, delays=(0.031, 0.037, 0.041, 0.047)):
    y = np.copy(x)
    for d in delays:
        nd = int(d*sr)
        y[nd:] += decay * x[:-nd]
    return y

def sidechain(mix, beat_n, sr=SR):
    """kick 侧链：每拍前 80ms 压低"""
    duck = np.ones(len(mix))
    n80 = int(0.08*sr)
    ramp = np.linspace(0.25, 1.0, n80)
    for b in range(0, len(mix), beat_n):
        duck[b:b+n80] = ramp[:max(0, min(n80, len(mix)-b))]
    return mix * duck

CHORDS = [
    ('A1',  [220.0, 261.63, 329.63], 55.0),    # Am
    ('F1',  [174.61, 220.0, 261.63], 43.65),   # F
    ('C2',  [261.63, 329.63, 392.0], 65.41),    # C
    ('G1',  [196.0, 246.94, 293.66], 49.0),     # G
    ('C2',  [261.63, 329.63, 392.0], 65.41),    # 副歌
    ('G1',  [196.0, 246.94, 293.66], 49.0),
    ('A1',  [220.0, 261.63, 329.63], 55.0),
    ('F1',  [174.61, 220.0, 261.63], 43.65),
]
ARP = [440.0, 523.25, 587.33, 659.25, 783.99, 880.0, 1046.5]

ARPS = [
    [0,2,4,2,5,2,4,2,0,2,4,6,5,4,2,1],
    [0,4,2,5,4,6,5,2,0,4,2,5,6,4,2,0],
    [2,2,4,4,5,5,4,2,1,2,4,5,6,5,4,2],
    [0,4,2,4,5,2,6,2,0,4,2,5,4,6,5,1],
]

def render_track(bpm, bars, arp_pat, lead_wave='saw', bass_oct=1, chorus_from=4, tag=''):
    spb = 60.0/bpm               # 每拍秒
    s16 = spb/4                  # 16分
    beat_n = int(spb*SR)
    total = int(bars*4*spb*SR)
    mix = np.zeros(total + SR*2)  # 余量给混响尾
    for bar in range(bars):
        is_chorus = bar >= chorus_from
        chord, root = CHORDS[bar % 8][1], CHORDS[bar % 8][2]
        root *= bass_oct
        bar_start = int(bar*4*spb*SR)
        # — pad 和弦（全小节）—
        pdur = 4*spb
        pad = sum(sine(f*(2 if is_chorus else 1), pdur) for f in chord) / 3
        pad *= adsr(int(pdur*SR), a=0.4, d=0.1, s=0.6, r=0.5) * 0.10
        mix[bar_start:bar_start+len(pad)] += pad
        # — bass 8分（副歌16分）—
        steps = 16 if is_chorus else 8
        for st in range(steps):
            t0 = bar_start + int(st*4*spb/steps*SR)
            bdur = 4*spb/steps*0.9
            b = square(root, bdur) * adsr(int(bdur*SR), 0.005, 0.05, 0.8, 0.05) * 0.30
            mix[t0:t0+len(b)] += b
        # — arp 16分 —
        for st in range(16):
            f = ARP[arp_pat[st]] * (2 if is_chorus else 1)
            t0 = bar_start + int(st*s16*SR)
            dur = s16*0.95
            if lead_wave == 'saw':
                a = saw(f, dur, detune=0.003) + saw(f, dur, detune=-0.003)*0.5
            else:
                a = square(f, dur)
            a *= adsr(int(dur*SR), 0.002, 0.08, 0.35, 0.06) * (0.16 if is_chorus else 0.12)
            mix[t0:t0+len(a)] += a
        # — kick 每拍 —
        for bt in range(4):
            t0 = bar_start + bt*beat_n
            t = np.arange(int(0.12*SR))/SR
            k = np.sin(2*np.pi*(50+90*np.exp(-t*35))*t) * np.exp(-t*18) * 0.9
            mix[t0:t0+len(k)] += k
        # — hat 反拍 —
        for bt in range(4):
            t0 = bar_start + int((bt+0.5)*beat_n)
            h = np.random.randn(int(0.04*SR)) * np.exp(-np.arange(int(0.04*SR))/ (0.012*SR)) * 0.09
            mix[t0:t0+len(h)] += h
        # — snare 2/4 拍（副歌）—
        if is_chorus:
            for bt in (1, 3):
                t0 = bar_start + bt*beat_n
                s = np.random.randn(int(0.09*SR)) * np.exp(-np.arange(int(0.09*SR))/(0.03*SR)) * 0.20
                n_s = len(s)
                ttn = np.arange(n_s)/SR
                tonal = np.sin(2*np.pi*190*ttn) * 0.28 * np.exp(-ttn*22)
                mix[t0:t0+n_s] += s + tonal
    # 后期：混响 + 侧链 + 软限幅
    mix = mix[:total + SR]
    wet = reverb(mix, decay=0.32) * 0.9
    final = sidechain(wet, beat_n)
    final = np.tanh(final * 1.4) * 0.85   # 软饱和
    # 立体声：Haas 微延迟拓宽 arp（简化：整体 6ms + 反相梳状）
    L = final
    R = np.roll(final, int(0.006*SR)); R[:int(0.006*SR)] = 0
    st = np.stack([L, R], axis=1)
    return st

def save_ogg(name, stereo, gain=1.0):
    data = (np.clip(stereo*gain, -1, 1) * 32767).astype(np.int16)
    wav_path = f'/tmp/{name}.wav'
    with wave.open(wav_path, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data.tobytes())
    out = Path(__file__).resolve().parents[1] / 'assets' / 'music' / f'{name}.ogg'
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav_path, '-c:a', 'libvorbis', '-q:a', '5', out], check=True)
    os.remove(wav_path)
    print(name, f'{os.path.getsize(out)//1024}KB', f'{len(stereo)/SR:.0f}s')

# 4 章节曲：32 小节（主歌16+副歌16），不同 arp 型/主音色
save_ogg('theme_0_downtown', render_track(140, 32, ARPS[0], 'saw', 1, 16), 0.9)
save_ogg('theme_1_industrial', render_track(140, 32, ARPS[2], 'square', 1, 16), 0.85)
save_ogg('theme_2_skyport', render_track(128, 32, ARPS[3], 'saw', 2, 16), 0.8)   # 天港：慢+高八度
save_ogg('theme_4_golden', render_track(140, 32, ARPS[1], 'saw', 1, 16), 0.9)
# 新章节专属曲（v1.3.0：深海/极地/日落）
save_ogg('theme_3_electric', render_track(146, 32, [0,2,4,2,6,2,4,2,0,2,4,6,5,4,2,1], 'square', 1, 16), 0.85)  # 电磁禁区：急促电流感
save_ogg('theme_5_deepsea', render_track(112, 32, ARPS[3], 'saw', 1, 20), 0.8)    # 深海：慢速空灵
save_ogg('theme_6_polar', render_track(132, 32, ARPS[2], 'saw', 1, 16), 0.85)    # 极地：冷冽
save_ogg('theme_7_sunset', render_track(122, 32, ARPS[0], 'saw', 1, 20), 0.8)   # 日落：慵懒
# BOSS 战歌：150bpm 全程副歌感、bass 厚
save_ogg('boss_theme', render_track(150, 32, ARPS[1], 'square', 1, 0), 0.95)   # chorus_from=0 全程高能
