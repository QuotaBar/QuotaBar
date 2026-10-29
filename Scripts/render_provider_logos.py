#!/usr/bin/env python3
"""Render the "supported services" logo wall for the READMEs.

Each provider's logo (some are white or monochrome) sits on a dark rounded
chip, so every mark reads on GitHub's light and dark themes alike. Writes
Assets/readme/providers-en.png and providers-zh.png.

    python3 Scripts/render_provider_logos.py

Needs Pillow. Run from the macOS/ directory.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGOS = os.path.join(ROOT, "Sources/QuotaBar/Resources/logos")
OUT = os.path.join(ROOT, "Assets/readme")

# (logo file, English name, 中文名), in the order they appear on the wall.
PROVIDERS = [
    ("codex.png", "Codex", "Codex"),
    ("claude.png", "Claude", "Claude"),
    ("cursor.png", "Cursor", "Cursor"),
    ("grok.png", "Grok", "Grok"),
    ("antigravity.png", "Antigravity", "Antigravity"),
    ("opencode-go.png", "OpenCode Go", "OpenCode Go"),
    ("kimi.png", "Kimi Code", "Kimi Code"),
    ("zai.png", "z.ai", "z.ai"),
    ("minimax.png", "MiniMax", "MiniMax"),
    ("manus.png", "Manus", "Manus"),
    ("deepseek.png", "DeepSeek", "DeepSeek"),
    ("qwen.png", "Qwen", "千问"),
    ("copilot.png", "Copilot", "Copilot"),
    ("alibaba.png", "Alibaba", "阿里云百炼"),
    ("volcengine.png", "Volcengine", "火山方舟"),
    ("zhipu.png", "Zhipu GLM", "智谱 GLM"),
    ("openrouter.png", "OpenRouter", "OpenRouter"),
    ("mimo.png", "Xiaomi MiMo", "小米 MiMo"),
    ("qoder.png", "Qoder", "Qoder"),
    ("windsurf.png", "Windsurf", "Windsurf"),
    ("kiro.png", "Kiro", "Kiro"),
]

COLS = 7
SCALE = 3  # supersample, then downscale for crisp edges

BG = (13, 13, 15, 255)
CHIP = (28, 28, 31, 255)
CHIP_BORDER = (255, 255, 255, 20)
NAME = (200, 200, 205, 255)


def _font(paths, size):
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def render(language):
    chip = 120 * SCALE
    gap = 14 * SCALE
    pad = 28 * SCALE
    logo_box = 58 * SCALE
    name_h = 20 * SCALE
    rows = math.ceil(len(PROVIDERS) / COLS)
    width = pad * 2 + COLS * chip + (COLS - 1) * gap
    height = pad * 2 + rows * chip + (rows - 1) * gap

    latin = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc", "/Library/Fonts/Arial.ttf"]
    cjk = ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"]
    name_font = _font((cjk + latin) if language == "zh" else latin, 15 * SCALE)

    img = Image.new("RGBA", (width, height), BG)
    draw = ImageDraw.Draw(img)
    for i, (file, en, zh) in enumerate(PROVIDERS):
        name = zh if language == "zh" else en
        r, c = divmod(i, COLS)
        x = pad + c * (chip + gap)
        y = pad + r * (chip + gap)
        draw.rounded_rectangle([x, y, x + chip, y + chip], radius=22 * SCALE,
                               fill=CHIP, outline=CHIP_BORDER, width=SCALE)
        try:
            logo = Image.open(os.path.join(LOGOS, file)).convert("RGBA")
        except OSError:
            continue
        logo.thumbnail((logo_box, logo_box), Image.LANCZOS)
        lx = x + (chip - logo.width) // 2
        ly = y + (chip - name_h - logo.height) // 2 - 2 * SCALE
        img.alpha_composite(logo, (lx, ly))
        box = draw.textbbox((0, 0), name, font=name_font)
        tw = box[2] - box[0]
        draw.text((x + (chip - tw) // 2, y + chip - name_h - 6 * SCALE), name, font=name_font, fill=NAME)

    img = img.resize((width // SCALE, height // SCALE), Image.LANCZOS)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"providers-{language}.png")
    img.save(path)
    print("wrote", os.path.relpath(path, ROOT), img.size)


if __name__ == "__main__":
    if not os.path.isdir(LOGOS):
        sys.exit(f"logos not found at {LOGOS}; run from the macOS/ directory")
    for lang in ("en", "zh"):
        render(lang)
