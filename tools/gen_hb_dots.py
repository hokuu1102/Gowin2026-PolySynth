#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
生成 TJC 串口屏 p_hb 心跳圆点 PNG（10x10，透明背景，抗锯齿）
颜色对齐 TJC 565 色值：
  亮绿   RGB(  0,200,  0)  —— 推荐联机色（bco2 可配 2016）
  深绿   RGB(  0,130,  0)  —— 对齐 bco2=1024 原色
  灰     RGB(197,194,197)  —— 对齐 bco=50712 断联色
  琥珀橙 RGB(217,119,  6)  —— 对齐 55264 琥珀金（⭐ p_bpm 节拍橙点）
"""
import struct, zlib, math, os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hb_dots")

def write_png(path, w, h, rgba_rows):
    """最小 PNG 编码器：RGBA8 + filter 0"""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in rgba_rows)
    png  = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))  # 8bit RGBA
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("written:", path, os.path.getsize(path), "bytes")

def make_dot(size=10, rgb=(0, 200, 0), ss=8):
    """4x~8x 超采样抗锯齿圆点，直径占满画布留 0.5px 边"""
    n = size * ss
    cx = cy = (n - 1) / 2.0
    r  = (size - 1) / 2.0 * ss          # 直径 9px，留边防裁切
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            hit = 0
            for sy in range(ss):
                for sx in range(ss):
                    px = x * ss + sx
                    py = y * ss + sy
                    if (px - cx) ** 2 + (py - cy) ** 2 <= r * r:
                        hit += 1
            alpha = int(round(255.0 * hit / (ss * ss)))
            row.append((rgb[0], rgb[1], rgb[2], alpha))
        rows.append(row)
    return rows

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    # (文件名, RGB)
    for name, rgb in [
        ("p_hb_on_green.png",  (0, 200, 0)),
        ("p_hb_on_darkgreen.png", (0, 130, 0)),
        ("p_hb_off_gray.png",  (197, 194, 197)),
        ("p_hb_off_darkgray.png", (120, 120, 120)),
        ("p_bpm_on_amber.png",  (217, 119, 6)),   # ⭐ 节拍橙点（55264 琥珀金）
        ("p_bpm_off_gray.png",  (197, 194, 197)), # ⭐ 节拍灭（复用灰）
    ]:
        write_png(os.path.join(OUT_DIR, name), 10, 10, make_dot(10, rgb))
    print("done ->", OUT_DIR)
