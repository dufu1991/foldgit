"""生成液态玻璃折射用的位移贴图，写入 glass.js。

每张贴图的 R/G 通道编码取样偏移（128 为不位移）：中心轻微放大，
越靠近边缘沿法线弯折越强，模拟玻璃厚边的折射；scale 随贴图一起写出。

python3 glassmaps.py
"""
import base64
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image

# 名称: (宽, 高, 边缘宽度占半高的比例, 边缘折射像素, 中心放大比例)
SHAPES = {
    "lens": (340, 340, 0.5, 14.0, 0.24),
    "g76": (76, 76, 0.75, 9.0, 0.06),
    "g150": (150, 76, 0.75, 9.0, 0.06),
    "g260": (260, 76, 0.75, 9.0, 0.06),
    "g180": (180, 76, 0.75, 9.0, 0.06),
}


def smooth(a, r=2):
    k = np.exp(-0.5 * (np.arange(-2 * r, 2 * r + 1) / r) ** 2)
    k /= k.sum()
    a = np.apply_along_axis(lambda v: np.convolve(v, k, "same"), 0, a)
    return np.apply_along_axis(lambda v: np.convolve(v, k, "same"), 1, a)


def capsule_map(w, h, bevel, edge_px, mag):
    """位移场 v（像素）：中心向内取样产生放大，边缘沿法线向内取样产生厚玻璃的弯折。
    feDisplacementMap 取样点 = P + scale * (C - 0.5)，所以 C = 0.5 + v / scale，scale = 2 * max|v|。"""
    r = h / 2
    y, x = np.mgrid[0:h, 0:w] + 0.5
    px = np.clip(x, r, w - r)
    dx, dy = x - px, y - r
    dist = np.hypot(dx, dy) + 1e-6
    inside = r - dist
    nx, ny = dx / dist, dy / dist
    e = np.clip(1 - inside / (r * bevel), 0, 1) ** 2
    cx, cy = x - w / 2, y - h / 2
    vx = -cx * mag - nx * edge_px * e
    vy = -cy * mag - ny * edge_px * e
    mask = inside > 0
    vx, vy = smooth(vx * mask), smooth(vy * mask)
    scale = 2 * max(np.abs(vx).max(), np.abs(vy).max()) + 1e-6
    rgb = np.zeros((h, w, 3), np.uint8)
    rgb[..., 0] = np.clip(np.round(255 * (0.5 + vx / scale)), 0, 255)
    rgb[..., 1] = np.clip(np.round(255 * (0.5 + vy / scale)), 0, 255)
    rgb[..., 2] = 128
    buf = io.BytesIO()
    Image.fromarray(rgb, "RGB").save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode(), round(float(scale), 2)


maps = {}
for name, (w, h, b, e, m) in SHAPES.items():
    src, scale = capsule_map(w, h, b, e, m)
    maps[name] = {"w": w, "h": h, "scale": scale, "src": src}
out = Path(__file__).with_name("glass.js")
out.write_text("// 由 glassmaps.py 生成：液态玻璃位移贴图\nwindow.GLASS_MAPS = " + json.dumps(maps) + ";\n")
print(out, sum(len(m["src"]) for m in maps.values()), "bytes")
