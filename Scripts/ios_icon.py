#!/usr/bin/env python3
"""The iPhone app's icon, made from the Mac's (Assets/icon.png).

The macOS icon is a squircle body on a transparent 1024 canvas; its body spans
exactly 100..923, and its corner is Apple's icon-grid curve, the same one iOS
masks with. So the body scaled to full bleed is the iOS icon, pixel for pixel.
Two things differ: the App Store refuses an icon with alpha, and the body's
darker rim would show as a sliver wherever the two masks disagree — so only
the body eroded by 8px is kept, over its own flat green.

Run after changing Assets/icon.png:  python3 Scripts/ios_icon.py
"""
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Assets/icon.png"
TARGET = ROOT / "iOS/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
BODY = (100, 100, 924, 924)

src = Image.open(SOURCE).convert("RGBA")
body = src.crop(BODY).resize((1024, 1024), Image.LANCZOS)
mask = body.split()[3].point(lambda a: 255 if a >= 250 else 0).filter(ImageFilter.MinFilter(17))
mask = mask.filter(ImageFilter.GaussianBlur(2))
green = body.getpixel((512, 960))[:3]
out = Image.new("RGB", (1024, 1024), green)
out.paste(body.convert("RGB"), (0, 0), mask)
out.save(TARGET)
print(f"wrote {TARGET.relative_to(ROOT)}")
