"""合成 51.5 秒原创配乐（120 BPM），段落与 scene.html 的时间轴对齐；音效由 sfx_earshot.py 用 earshot 另行混入。

python3 music.py bed.wav
"""
import sys
import wave

import numpy as np

SR = 48000
DUR = 51.5
N = int(SR * DUR)
BEAT = 0.5
rng = np.random.default_rng(1991)

def hz(note):
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    name, octave = note[:-1], int(note[-1])
    return 440.0 * 2 ** ((names[name] + 12 * (octave + 1) - 69) / 12)


def tt(dur):
    return np.arange(int(SR * dur)) / SR


def place(bus, sig, at, gain=1.0, pan=0.0):
    i = int(round(at * SR))
    if i >= N or i < 0:
        return
    sig = sig[: N - i]
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[0, i : i + len(sig)] += sig * gain * left * 1.414
    bus[1, i : i + len(sig)] += sig * gain * right * 1.414


def onepole(x, cutoff):
    """一阶低通，cutoff 可为逐样本数组。"""
    cutoff = np.broadcast_to(np.asarray(cutoff, dtype=float), x.shape)
    a = 1 - np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a[i] * (x[i] - acc)
        y[i] = acc
    return y


def hp(x, cutoff):
    return x - onepole(x, cutoff)


def norm(x):
    return x / (np.abs(x).max() + 1e-9)


# ---------- 鼓组与乐器（预先合成，重复使用） ----------
def make_kick():
    t = tt(0.45)
    f = 45 + 110 * np.exp(-t * 28)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    click = hp(rng.standard_normal(len(t)), 2000) * np.exp(-t * 400) * 0.3
    return np.tanh((body + click) * 1.6) * 0.9


def make_clap():
    t = tt(0.3)
    n = rng.standard_normal(len(t))
    band = hp(onepole(n, 2600), 900)
    env = np.zeros_like(t)
    for d in (0.0, 0.011, 0.022):
        env += np.where(t >= d, np.exp(-(t - d) * 120), 0)
    env += np.where(t >= 0.03, np.exp(-(t - 0.03) * 18), 0) * 0.6
    return norm(band * env) * 0.55


def make_hat(decay=60):
    t = tt(0.12)
    n = hp(hp(rng.standard_normal(len(t)), 7000), 7000)
    return norm(n * np.exp(-t * decay)) * 0.22


def make_snare():
    t = tt(0.22)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 30)
    n = hp(onepole(rng.standard_normal(len(t)), 6000), 1200) * np.exp(-t * 22)
    return norm(tone * 0.6 + n) * 0.45


KICK, CLAP, HAT, OHAT, SNARE = make_kick(), make_clap(), make_hat(), make_hat(18), make_snare()


def bass(f, dur=0.45, vel=1.0):
    t = tt(dur)
    sig = sum(np.sin(2 * np.pi * f * k * t) / k for k in range(1, 7))
    sig = onepole(sig, 900 + 1400 * np.exp(-t * 18))
    env = np.minimum(1, t / 0.004) * np.exp(-t * 3.5) * np.clip((dur - t) / 0.02, 0, 1)
    return np.tanh(sig * env * 1.5) * vel * 0.42


def pad(freqs, dur, attack=0.6, release=1.2, bright=1.0):
    t = tt(dur)
    sig = np.zeros_like(t)
    for f in freqs:
        for det in (-0.1, 0.0, 0.11):
            ff = f * 2 ** (det / 12)
            ph = rng.uniform(0, 2 * np.pi)
            sig += np.sin(2 * np.pi * ff * t + ph) + 0.25 * bright * np.sin(4 * np.pi * ff * t + ph) + 0.1 * bright * np.sin(6 * np.pi * ff * t)
    env = np.clip(np.minimum(t / attack, (dur - t) / release), 0, 1) ** 1.5
    return sig * env * (0.06 / len(freqs))


def pluck(f, dur=0.5, vel=1.0):
    t = tt(dur)
    sig = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) * np.exp(-t * 10) + 0.15 * np.sin(6 * np.pi * f * t) * np.exp(-t * 16)
    return sig * np.exp(-t * 7) * np.minimum(1, t / 0.002) * vel * 0.16


def piano(f, dur=3.0, vel=1.0):
    t = tt(dur)
    sig = np.zeros_like(t)
    for k, amp in enumerate([1.0, 0.42, 0.22, 0.12, 0.07], start=1):
        sig += amp * np.sin(2 * np.pi * f * k * np.sqrt(1 + 0.0004 * k * k) * t) * np.exp(-t * (1.2 + 0.9 * k))
    return sig * np.minimum(1, t / 0.004) * vel * 0.3


def bell(f, dur=3.0, vel=1.0):
    t = tt(dur)
    sig = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d) for r, a, d in [(1, 1, 1.4), (2.76, 0.45, 2.6), (5.4, 0.25, 4.5), (8.93, 0.12, 7)])
    return sig * np.minimum(1, t / 0.003) * vel * 0.12


# ---------- 编排 ----------
drums = np.zeros((2, N))
music = np.zeros((2, N))
padbus = np.zeros((2, N))

PROG = [("D", ["D3", "A3", "C#4", "F#4"], ["D5", "F#5", "A5", "C#6"]),
        ("B", ["B2", "F#3", "A3", "D4"], ["B4", "D5", "F#5", "A5"]),
        ("G", ["G2", "D3", "F#3", "B3"], ["G4", "B4", "D5", "F#5"]),
        ("A", ["A2", "E3", "G3", "C#4"], ["A4", "C#5", "E5", "B5"])]

# 0–4：开场脉冲，低音八分音符 + 轻踩镲
for k in range(16):
    at = k * 0.25
    place(music, bass(hz("D2"), 0.22, vel=0.5 + 0.03 * k), at)
    place(drums, HAT, at + 0.125, 0.6 + 0.02 * k, pan=0.3)
for k in range(8):
    place(music, pluck(hz(["D5", "A4", "F#5", "A4"][k % 4]), vel=0.5), k * 0.5 + 0.25, pan=-0.3)
place(padbus, pad([hz(n) for n in ["D3", "A3", "E4"]], 4.2, attack=1.5, release=0.5, bright=0.5), 0.0)

# 4–6：「但是」—— 鼓组退出，只剩钢琴
for at, notes in [(4.0, ["B2", "F#4", "D5"]), (4.45, ["A4"]), (4.9, ["F#4", "B4"]), (5.3, ["G2", "D4", "B4", "F#5"])]:
    for n in notes:
        place(music, piano(hz(n), vel=0.8), at)
place(padbus, pad([hz(n) for n in ["G2", "D3", "B3", "F#4"]], 1.8, attack=0.2, release=0.8), 5.3)

# 6–9：IDE 涌入，底鼓渐密，军鼓滚奏推到揭晓
for k in range(6):
    place(drums, KICK, 6.0 + k * 0.5, 0.75)
for k in range(12):
    place(music, bass(hz("B1") if k < 6 else hz("C#2"), 0.22, vel=0.55), 6.0 + k * 0.25)
roll = [8.0 + 0.125 * k for k in range(4)] + [8.5 + 0.0625 * k for k in range(8)]
for k, at in enumerate(roll):
    place(drums, SNARE, at, 0.35 + 0.05 * k)

# 9：揭晓，大和弦
place(padbus, pad([hz(n) for n in ["D2", "A2", "F#3", "C#4", "E4", "A4"]], 2.6, attack=0.05, release=1.4, bright=1.2), 9.0, gain=1.4)
for at, n in [(9.0, "D5"), (9.5, "A5"), (10.15, "F#5"), (10.5, "E5"), (10.85, "C#5")]:
    place(music, piano(hz(n), vel=0.7), at)

# 11.5–43.5：完整律动（含 39–43.5 的筛选段落）；14.5–18.5 液态玻璃段落收掉拍手与踩镲，留出空气感
GROOVE, AIRY = (11.5, 43.5), (14.5, 18.5)
duck = np.ones(N)
k = 0
t = GROOVE[0]
while t < GROOVE[1] - 1e-6:
    root, pad_notes, arp = PROG[int((t - GROOVE[0]) // 4.0) % 4]
    airy = AIRY[0] <= t < AIRY[1]
    beat_in_bar = k % 4
    place(drums, KICK, t, 0.55 if airy else 0.9)
    i = int(t * SR)
    env = 1 - 0.55 * np.exp(-np.arange(int(0.3 * SR)) / SR * 14)
    duck[i : i + len(env)] = np.minimum(duck[i : i + len(env)], env[: N - i])
    if not airy:
        if beat_in_bar in (1, 3):
            place(drums, CLAP, t, 0.75)
        place(drums, HAT, t + 0.25, 0.8, pan=0.25)
        if k % 8 == 7:
            place(drums, OHAT, t + 0.25, 0.7, pan=-0.2)
    place(music, bass(hz(root + "2"), 0.22, vel=0.6 if airy else 0.8), t)
    place(music, bass(hz(root + "2") * 2, 0.2, vel=0.45), t + 0.25)
    for s in range(4 if not airy else 2):
        place(music, pluck(hz(arp[(k * 4 + s) % 4]), vel=0.55 if s % 2 else 0.75), t + s * (0.125 if not airy else 0.25), pan=0.35 if s % 2 else -0.35)
    if beat_in_bar == 0 and k % 8 == 0:
        place(padbus, pad([hz(n) for n in pad_notes], 4.1, attack=0.3, release=0.8, bright=1.3 if airy else 1.0), t)
    t += BEAT
    k += 1

# 43.5–45.5：收尾句，留白
place(padbus, pad([hz(n) for n in ["G2", "D3", "B3", "F#4"]], 1.2, attack=0.1, release=0.5), 43.5)
place(padbus, pad([hz(n) for n in ["A2", "E3", "C#4", "G4"]], 1.2, attack=0.2, release=0.4), 44.4)
place(music, piano(hz("D5"), vel=0.7), 43.55)
place(music, piano(hz("A4"), vel=0.6), 44.0)
place(music, piano(hz("C#5"), vel=0.6), 44.0)

# 45.5–51.5：结尾和弦
place(padbus, pad([hz(n) for n in ["D2", "A2", "F#3", "C#4", "E4", "A4"]], 6.0, attack=0.05, release=3.5, bright=1.1), 45.5, gain=1.3)
for at, n, v in [(45.5, "D4", 0.7), (45.5, "A4", 0.6), (45.8, "F#5", 0.7), (46.05, "A5", 0.6), (48.3, "E5", 0.5), (48.7, "D5", 0.6)]:
    place(music, piano(hz(n), vel=v), at)
place(music, bell(hz("D6"), 3.0, 0.9), 46.05)
for k in range(4):
    place(drums, KICK, 45.5 + k * 0.5, 0.5 - 0.1 * k)


# ---------- 混响与母带 ----------
def reverb(x, seconds=2.4, mix=0.25):
    n = int(SR * seconds)
    t = np.arange(n) / SR
    out = np.zeros_like(x)
    for c in range(2):
        ir = onepole(rng.standard_normal(n) * np.exp(-t * 6.9 / seconds), 7000)
        ir /= np.sqrt((ir**2).sum())
        size = 1 << int(np.ceil(np.log2(x.shape[1] + n)))
        wet = np.fft.irfft(np.fft.rfft(x[c], size) * np.fft.rfft(ir, size), size)[: x.shape[1]]
        out[c] = x[c] * (1 - mix) + wet * mix * 1.6
    return out


mix = reverb(padbus * duck, 3.0, 0.4) + reverb(music, 1.8, 0.22) + drums * 0.85
fade = np.ones(N)
fade[: int(0.05 * SR)] = np.linspace(0, 1, int(0.05 * SR))
fade[-int(2.5 * SR):] = np.linspace(1, 0, int(2.5 * SR)) ** 1.5
mix *= fade
mix = np.tanh(mix * 1.3) / np.tanh(1.3)
mix *= 0.6 / np.abs(mix).max()  # 给音效留出余量，母带响度由 sfx_earshot.py 统一处理

with wave.open(sys.argv[1] if len(sys.argv) > 1 else "bed.wav", "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix.T * 32767).astype("<i2").tobytes())
