"""用 earshot（https://github.com/Leonxlnx/earshot）渲染全部音效，并按配乐响度混进 music.py 生成的配乐。

每类音效是一个 earshot kit 角色：launch 预设里的角色沿用它的电平（bed_db：比配乐高多少）、
对齐点（onset / peak / end）、相对切点的提前量和最小间隔；点击、打字、玻璃、kalimba 等角色按同样规则补充。
每个音效的位置用 kit.place 对齐到画面时间，电平用 kit.gain_db 对着该时刻之前一秒的配乐计算。

需要装好 earshot 的 Python 运行：
venv/bin/python -I sfx_earshot.py bed.wav mix.wav 工作目录
"""
import json
import os
import sys
from collections import defaultdict

import numpy as np
import soundfile as sf
from earshot.forge import kit

BED, OUT, WORK = sys.argv[1:4]
os.makedirs(WORK, exist_ok=True)

PRESET = kit.preset("launch")["roles"]
KIT = {
    "kit": 1,
    "name": "foldgit",
    "sr": 48000,
    "roles": {
        **{r: PRESET[r] for r in ("tick", "tick.crisp", "tock", "land", "land.light", "pop", "whoosh.short", "whoosh.long")},
        "pop.small": {"sound": "pro_pop/tink", "takes": 4, "align": "onset", "bed_db": 4.0, "offset_ms": 0, "min_gap_ms": 60, "level_db": -10.0},
        "click": {"sound": "pro_click/mouse", "takes": 3, "align": "onset", "bed_db": 5.0, "offset_ms": -10, "min_gap_ms": 80, "level_db": -8.0},
        "key": {"sound": "pro_typing_key/soft", "takes": 8, "align": "onset", "bed_db": 2.0, "offset_ms": 0, "min_gap_ms": 22, "width": 0.4, "level_db": -14.0},
        "impact": {"sound": "pro_impact/deep", "takes": 1, "align": "onset", "bed_db": 9.0, "offset_ms": 0, "level_db": -2.0},
        "sting.glass": {"sound": "logo_sting/whoosh_glass", "takes": 1, "align": "peak", "bed_db": 7.0, "offset_ms": 40, "level_db": -4.0},
        "sting.end": {"sound": "logo_sting/soft_bloom", "takes": 1, "align": "onset", "bed_db": 7.0, "offset_ms": 0, "level_db": -4.0},
        "shimmer": {"sound": "pro_shimmer/m1", "takes": 2, "align": "onset", "bed_db": 5.0, "offset_ms": 0, "level_db": -8.0},
        "riser": {"sound": "riser/build", "takes": 1, "align": "end", "bed_db": 6.0, "offset_ms": 0, "level_db": -6.0},
        "riser.short": {"sound": "pro_riser/air_gate", "takes": 1, "align": "end", "bed_db": 5.0, "offset_ms": 0, "level_db": -8.0},
        "drip": {"sound": "drip/bubble", "takes": 3, "align": "onset", "bed_db": 6.0, "offset_ms": 0, "min_gap_ms": 120, "level_db": -6.0},
        "glass.tap": {"sound": "pro_tap/glass", "takes": 5, "align": "onset", "bed_db": 5.0, "offset_ms": 0, "min_gap_ms": 70, "width": 0.3, "level_db": -8.0},
        "zip": {"sound": "pro_zip/down", "takes": 1, "align": "peak", "bed_db": 6.0, "offset_ms": 0, "level_db": -7.0},
        "swish": {"sound": "swish/soft", "takes": 2, "align": "peak", "bed_db": 6.0, "offset_ms": 20, "level_db": -7.0},
        "ding": {"sound": "pro_notify/ding_2045", "takes": 1, "align": "onset", "bed_db": 6.0, "offset_ms": 0, "level_db": -6.0},
        "bell": {"sound": "mallet/celesta", "takes": 1, "align": "onset", "bed_db": 6.0, "offset_ms": 0, "level_db": -6.0},
        "kalimba": {"sound": "pluck/kalimba_soft", "pitches": ["D6", "A5", "C#6", "E6", "F#5"], "align": "onset", "bed_db": 5.0, "offset_ms": 0, "level_db": -6.0},
        "kalimba.up": {"sound": "pluck/kalimba_soft", "pitches": ["D5", "E5", "F#5", "A5", "B5"], "align": "onset", "bed_db": 5.0, "offset_ms": 0, "level_db": -6.0},
        "toggle": {"sound": "toggle/on", "takes": 2, "align": "onset", "bed_db": 5.0, "offset_ms": -10, "min_gap_ms": 120, "level_db": -8.0},
    },
}

# (秒, 角色, 声像[, 指定第几个 take])：时间取自 scene.html 的时间轴
CUES = []
cue = lambda t, role, pan=0.0, take=None: CUES.append((t, role, pan, take))
for c in (2.0, 4.0, 6.0, 11.5, 18.5, 22.5, 26.0, 30.5, 33.0, 35.5, 39.0, 43.5):   # 切镜（9、14.5、45.5 另有专门的声音）
    cue(c, "whoosh.short", 0.1)
for i, t in enumerate((0.12, 0.52, 0.92, 1.32)):                          # A：Agent 逐词弹出
    cue(t, "pop", -0.2 + 0.13 * i)
cue(2.0, "land")                                                          # B：计数器砸下
for k in range(10):
    cue(2.1 + k * 0.12, "tick", (k % 3 - 1) * 0.5)
for t in (4.0, 4.45, 4.9, 5.3):                                           # C：逐词替换
    cue(t, "tock")
for i in range(6):                                                        # D：IDE 窗口砸进来
    cue(6.05 + i * 0.2 + 0.25, "land", [-0.6, 0.6, -0.4, 0.5, 0.0, 0.2][i])
for t in (6.1, 6.95, 7.75):
    cue(t, "pop.small")
cue(9.0, "riser")
cue(8.92, "whoosh.long")
cue(9.0, "impact")                                                        # E：揭晓
cue(9.0, "shimmer")
for i in range(7):
    cue(9.5 + i * 0.045, "tick.crisp", -0.45 + 0.15 * i)
cue(10.15, "pop")
cue(11.9, "whoosh.long")                                                  # F：主视觉立起
cue(14.5, "sting.glass")                                                  # 液态玻璃
for i in range(5):
    cue(14.85 + i * 0.09, "glass.tap", -0.5 + 0.25 * i)
cue(15.5, "drip")
cue(15.5, "kalimba", 0.0, 0)
for t, n in ((15.9, 1), (16.7, 2), (17.55, 3)):
    cue(t, "drip", 0.2)
    cue(t, "kalimba", 0.2, n)
cue(18.5 + 0.05, "shimmer")
for i in range(8):                                                        # G：仓库卡片落进侧边栏
    cue(18.5 + 1.05 + i * 0.07, "pop.small", 0.3)
for t in (1.95, 2.3, 2.8):
    cue(18.5 + t, "click", 0.2)
cue(22.5 + 1.85, "click", 0.1)                                            # H：搜索
for k in range(4):
    cue(22.5 + 2.0 + k / 9, "key", 0.1)
cue(22.5 + 2.6, "swish", 0.2)
cue(26.0 + 2.45, "click", 0.5)                                            # I：按块暂存
cue(26.0 + 2.95, "zip", 0.3)
cue(26.0 + 3.2, "pop", 0.0)
cue(30.5 + 0.35, "click", -0.3)                                           # J：提交、推送
for k in range(6, len("feat: add adaptive hover feedback")):
    cue(30.5 + 0.42 + (k - 6) / 40, "key", ((k * 5) % 7 - 3) / 10)
cue(30.5 + 1.4, "click", 0.4)
cue(30.5 + 2.0, "click", -0.2)
cue(30.5 + 2.12, "ding")
cue(33.0 + 0.4, "swish", 0.3)                                             # K：亮暗擦除、语言轮换
cue(33.0 + 0.95, "swish", -0.3)
for k in range(8):
    cue(33.0 + 1.4 + k * 0.13, "tick", (k % 2 - 0.5) * 0.6)
cue(35.5 + 1.5, "riser.short")                                            # L：体积对比
cue(35.5 + 1.7, "bell")
for i in range(6):                                                        # M：客户端卡片铺开
    cue(39.05 + i * 0.07, "pop.small", 0.4 - 0.05 * i)
cue(39.1, "pop")
cue(40.0, "pop")
for k in range(5):                                                        # 五个开关逐个打开，音高逐级上行
    t = 39.0 + 1.6 + k * 0.45
    cue(t, "toggle", -0.3)
    cue(t, "kalimba.up", 0.0, k)
cue(42.75, "shimmer")                                                     # 只剩 FoldGit，翻面
cue(43.05, "kalimba", 0.0, 0)
cue(43.05, "pop")
cue(44.0, "bell")                                                         # 收尾句
cue(45.5, "impact")                                                       # N：结尾
cue(45.5, "sting.end")
brew = "brew install --cask dufu1991/tap/foldgit"
for k in range(len(brew)):
    cue(45.5 + 1.2 + k / 26, "key", ((k * 3) % 5 - 2) / 8)

problems = kit.problems(KIT)
if problems:
    sys.exit("kit problems:\n" + "\n".join(problems))
kit_path = os.path.join(WORK, "kit.json")
with open(kit_path, "w") as fh:
    json.dump(KIT, fh, indent=1)
lock = kit.render(kit_path, os.path.join(WORK, "takes"))
print(lock["summary"])

bed, sr = sf.read(BED, always_2d=True)
assert sr == 48000
mix = bed.copy()
takes_dir = os.path.join(WORK, "takes")
cache = {}
used = defaultdict(int)

by_role = defaultdict(list)
for t, role, pan, take in CUES:
    by_role[role].append((t, pan, take))
placed = 0
for role, items in by_role.items():
    spec = lock["roles"][role]
    roledef = {**KIT["roles"][role], **{k: v for k, v in spec.items() if k != "takes"}}
    times = kit.space_run([t for t, _, _ in items], roledef.get("min_gap_ms"))
    items = sorted(items, key=lambda x: x[0])
    for (t0, pan, take), t in zip(items, times):
        tk = spec["takes"][take if take is not None else used[role] % len(spec["takes"])]
        used[role] += 1
        if tk["file"] not in cache:
            y, _ = sf.read(os.path.join(takes_dir, tk["file"]), always_2d=True)
            cache[tk["file"]] = y if y.shape[1] == 2 else np.repeat(y, 2, axis=1)
        y = cache[tk["file"]]
        try:
            bed_lufs = kit.bed_level(bed, t)
        except kit.KitError:
            bed_lufs = None
        g = 10 ** (kit.gain_db(tk, roledef, bed_lufs) / 20)
        start = int(round(kit.place(tk, roledef, t) * sr))
        a, b = max(0, start), min(len(mix), start + len(y))
        if b <= a:
            continue
        seg = y[a - start : b - start] * g
        seg = seg * np.array([np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)]) * 1.414
        mix[a:b] += seg
        placed += 1
print(f"placed {placed} cues from {len(by_role)} roles")

# 软限幅，留 -1 dBFS 余量；最终响度交给 ffmpeg loudnorm
mix = np.tanh(mix * 1.2) / np.tanh(1.2)
mix *= 0.89 / np.abs(mix).max()
sf.write(OUT, mix, sr, subtype="PCM_16")
print("wrote", OUT)
