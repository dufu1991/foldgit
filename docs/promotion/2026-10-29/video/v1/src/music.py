"""合成 30 秒原创配乐与音效，时间点与 scene.html 的时间轴对齐。

python3 music.py out.wav
"""
import sys
import wave

import numpy as np

SR = 48000
DUR = 30.0
N = int(SR * DUR)
rng = np.random.default_rng(1991)


def hz(note):
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    name, octave = note[:-1], int(note[-1])
    return 440.0 * 2 ** ((names[name] + 12 * (octave + 1) - 69) / 12)


def tt(dur):
    return np.arange(int(SR * dur)) / SR


def place(bus, sig, at, gain=1.0, pan=0.0):
    i = int(at * SR)
    if i >= N:
        return
    sig = sig[: N - i]
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[0, i : i + len(sig)] += sig * gain * left * 1.414
    bus[1, i : i + len(sig)] += sig * gain * right * 1.414


def onepole(x, cutoff):
    """一阶低通，cutoff 可为逐样本数组。"""
    cutoff = np.broadcast_to(cutoff, x.shape)
    a = 1 - np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a[i] * (x[i] - acc)
        y[i] = acc
    return y


# ---------- 乐器 ----------
def piano(f, dur=3.5, vel=1.0):
    t = tt(dur)
    sig = np.zeros_like(t)
    for k, amp in enumerate([1.0, 0.42, 0.22, 0.12, 0.07, 0.04], start=1):
        fk = f * k * np.sqrt(1 + 0.0004 * k * k)
        sig += amp * np.sin(2 * np.pi * fk * t) * np.exp(-t * (1.1 + 0.9 * k))
    attack = np.minimum(1, t / 0.004)
    return sig * attack * vel * 0.32


def pad(freqs, dur, attack=1.6, release=1.8):
    t = tt(dur)
    sig = np.zeros_like(t)
    for f in freqs:
        for det in (-0.12, 0.0, 0.13):
            ff = f * 2 ** (det / 12)
            ph = rng.uniform(0, 2 * np.pi)
            sig += np.sin(2 * np.pi * ff * t + ph) + 0.18 * np.sin(4 * np.pi * ff * t + ph) + 0.06 * np.sin(6 * np.pi * ff * t)
    env = np.minimum(1, t / attack) * np.minimum(1, (dur - t) / release)
    env = np.clip(env, 0, 1) ** 1.6
    trem = 1 + 0.06 * np.sin(2 * np.pi * 0.23 * t)
    return sig * env * trem * (0.05 / len(freqs))


def pluck(f, dur=1.6, vel=1.0):
    t = tt(dur)
    sig = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) * np.exp(-t * 8) + 0.12 * np.sin(6 * np.pi * f * t) * np.exp(-t * 14)
    return sig * np.exp(-t * 3.2) * np.minimum(1, t / 0.002) * vel * 0.22


def bell(f, dur=4.0, vel=1.0):
    t = tt(dur)
    sig = np.zeros_like(t)
    for ratio, amp, decay in [(1, 1, 1.2), (2.76, 0.45, 2.4), (5.4, 0.25, 4.0), (8.93, 0.12, 6.0)]:
        sig += amp * np.sin(2 * np.pi * f * ratio * t) * np.exp(-t * decay)
    return sig * np.minimum(1, t / 0.003) * vel * 0.12


# ---------- 音效 ----------
def whoosh(dur, apex, lo=300, hi=5200, vel=1.0):
    t = tt(dur)
    noise = rng.standard_normal(len(t))
    x = np.clip(t / apex, 0, None)
    env = np.where(t < apex, (t / apex) ** 2.2, np.exp(-(t - apex) / (0.18 * (dur - apex) + 1e-3)))
    sweep = np.where(t < apex, lo + (hi - lo) * x**1.5, hi * np.exp(-(t - apex) * 3))
    s = onepole(noise, sweep) - onepole(noise, sweep * 0.25)
    return s / (np.abs(s).max() + 1e-9) * env * vel * 0.5


def tok(f=520, vel=1.0):
    t = tt(0.18)
    freq = f * (1 + 0.6 * np.exp(-t * 60))
    body = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-t * 32)
    click = onepole(rng.standard_normal(len(t)), 3000) * np.exp(-t * 300) * 0.4
    return (body + click) * np.minimum(1, t / 0.001) * vel * 0.35


def subdrop(f0=95, f1=42, dur=1.6, vel=1.0):
    t = tt(dur)
    freq = f1 + (f0 - f1) * np.exp(-t * 5)
    sig = np.sin(2 * np.pi * np.cumsum(freq) / SR)
    return sig * np.exp(-t * 2.4) * np.minimum(1, t / 0.006) * vel * 0.55


def shimmer(base, dur=2.8, vel=1.0):
    t = tt(dur)
    sig = np.zeros_like(t)
    for i, m in enumerate([2, 3, 4, 6, 8]):
        ph = rng.uniform(0, 2 * np.pi)
        sig += np.sin(2 * np.pi * base * m * (1 + 0.002 * i) * t + ph) * (0.6 ** i)
    env = np.minimum(1, t / 0.25) * np.exp(-np.maximum(0, t - 0.25) * 1.5)
    return sig * env * (1 + 0.3 * np.sin(2 * np.pi * 7 * t)) * vel * 0.05


def riser(dur, vel=1.0):
    t = tt(dur)
    noise = rng.standard_normal(len(t))
    x = t / dur
    s = onepole(noise, 200 + 6000 * x**2) - onepole(noise, 120 + 1500 * x**2)
    return s / (np.abs(s).max() + 1e-9) * x**2.5 * vel * 0.3


# ---------- 编排 ----------
music = np.zeros((2, N))
sfx = np.zeros((2, N))

# 0–8s：安静开场，D 大九和弦铺底，稀疏钢琴
place(music, pad([hz(n) for n in ["D3", "A3", "E4", "F#4"]], 8.6, attack=2.4), 0.0)
for i, (at, n, v) in enumerate([(0.35, "F#5", 0.8), (1.1, "A4", 0.5), (2.2, "E5", 0.55), (3.5, "D5", 0.9), (3.5, "A4", 0.45), (4.3, "F#5", 0.55), (5.4, "E5", 0.5), (6.5, "A5", 0.4)]):
    place(music, piano(hz(n), vel=v), at, pan=0.25 if i % 2 else -0.2)

# 8–12s：B 小调，脉冲逐渐紧张
place(music, pad([hz(n) for n in ["B2", "F#3", "D4", "C#5"]], 4.2, attack=0.6, release=0.6), 7.9, gain=1.1)
for k in range(12):
    at = 8.0 + k * 0.3125
    place(music, pluck(hz("B2"), dur=0.4, vel=0.35 + k * 0.03), at)
for i in range(6):
    place(sfx, tok(420 + i * 35, vel=0.7), 8.47 + i * 0.32, pan=[-0.5, 0.5, -0.3, 0.35, -0.1, 0.15][i])
place(sfx, whoosh(1.1, 0.68, lo=180, hi=3600, vel=0.9), 10.95)

# 12s：折叠收拢，图标出现 —— 低频落点 + 闪光
place(sfx, subdrop(vel=0.9), 11.98)
place(sfx, shimmer(hz("D5"), vel=1.0), 11.95)
place(music, pad([hz(n) for n in ["G2", "D3", "B3", "F#4", "A4"]], 3.3, attack=0.25, release=1.0), 11.98, gain=1.2)
for at, n in [(12.0, "D5"), (12.55, "A5"), (12.95, "F#5"), (13.3, "E5")]:
    place(music, piano(hz(n), vel=0.75), at)

# 15–24s：界面展示，轻拨弦琶音
place(sfx, whoosh(1.0, 0.36, lo=250, hi=4800, vel=0.75), 14.95)
chords = [
    (15.0, ["D3", "A3", "F#4"], ["D4", "F#4", "A4", "E5"]),
    (17.5, ["B2", "F#3", "D4"], ["B3", "D4", "F#4", "C#5"]),
    (20.0, ["G2", "D3", "B3"], ["G3", "B3", "D4", "A4"]),
    (22.5, ["A2", "E3", "C#4"], ["A3", "C#4", "E4", "B4"]),
]
beat = 0.3125
for start, pad_notes, arp in chords:
    place(music, pad([hz(n) for n in pad_notes], 2.9, attack=0.5, release=1.0), start)
    for k in range(8):
        n = arp[[0, 1, 2, 3, 2, 1, 2, 3][k]]
        place(music, pluck(hz(n), vel=0.5 if k % 2 else 0.7), start + k * beat, pan=0.3 if k % 2 else -0.3)
for at in (18.35, 19.95, 21.6):
    place(sfx, whoosh(0.7, 0.4, lo=400, hi=3000, vel=0.35), at)
place(sfx, whoosh(1.2, 0.6, lo=150, hi=1800, vel=0.4), 22.6)

# 24–27s：四个关键词，逐级上行
place(music, pad([hz(n) for n in ["D3", "A3", "F#4", "A4"]], 3.2, attack=0.3, release=1.2), 24.0)
for i, n in enumerate(["D5", "E5", "F#5", "A5"]):
    place(music, piano(hz(n), vel=0.8), 24.1 + i * 0.38)
    place(sfx, tok(900 + i * 120, vel=0.25), 24.1 + i * 0.38)
place(music, piano(hz("D6"), vel=0.6), 25.75)
place(music, piano(hz("A4"), vel=0.5), 25.75)

# 27–30s：收尾
place(sfx, subdrop(80, 40, vel=0.7), 27.08)
place(sfx, shimmer(hz("A4"), dur=2.9, vel=0.8), 27.05)
place(music, pad([hz(n) for n in ["D2", "A2", "F#3", "C#4", "E4"]], 2.95, attack=0.2, release=2.2), 27.05, gain=1.3)
for at, n, v in [(27.1, "D4", 0.7), (27.1, "A4", 0.6), (27.4, "F#5", 0.7), (27.75, "A5", 0.55)]:
    place(music, piano(hz(n), vel=v), at)
place(music, bell(hz("D6"), vel=0.9), 27.75)

# ---------- 混响与母带 ----------
def reverb(x, seconds=2.6, mix=0.28):
    n = int(SR * seconds)
    t = np.arange(n) / SR
    out = np.zeros_like(x)
    for c in range(2):
        ir = rng.standard_normal(n) * np.exp(-t * 6.9 / seconds)
        ir = onepole(ir, 6000)
        ir /= np.sqrt((ir**2).sum())
        size = 1 << int(np.ceil(np.log2(x.shape[1] + n)))
        wet = np.fft.irfft(np.fft.rfft(x[c], size) * np.fft.rfft(ir, size), size)[: x.shape[1]]
        out[c] = x[c] * (1 - mix) + wet * mix * 1.6
    return out


mix = reverb(music, 3.2, 0.32) + reverb(sfx, 1.6, 0.18)
fade = np.ones(N)
fade[: int(0.3 * SR)] = np.linspace(0, 1, int(0.3 * SR))
fade[-int(1.4 * SR):] = np.linspace(1, 0, int(1.4 * SR)) ** 2
mix *= fade
mix = np.tanh(mix * 1.2) / np.tanh(1.2)
mix *= 0.89 / np.abs(mix).max()

with wave.open(sys.argv[1] if len(sys.argv) > 1 else "music.wav", "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix.T * 32767).astype("<i2").tobytes())
