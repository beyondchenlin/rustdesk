#!/usr/bin/env python3
"""Derive product icons from the byte-verified, immutable BK Remote master."""
from pathlib import Path
from io import BytesIO
import hashlib
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / 'assets/brand/BK-Remote-Official-Logo.png'
EXPECTED = 'c1eac2a9a49541a8ed7fbee8a0780f564432131a6e4332d92fbf4753d49dbec1'
raw = MASTER.read_bytes()
if len(raw) != 342376 or hashlib.sha256(raw).hexdigest() != EXPECTED:
    raise SystemExit('Official brand master hash does not match')
original = Image.open(BytesIO(raw)).convert('RGBA')
if original.size != (1254, 1254):
    raise SystemExit('Official brand master dimensions do not match')
bounds = original.getchannel('A').point(lambda a: 255 if a >= 32 else 0).getbbox()
if bounds is None:
    raise SystemExit('Brand master has no visible pixels')
logo = original.crop(bounds)
outputs = []

def fitted(size, monochrome=False):
    im = logo.copy()
    if monochrome:
        im = Image.new('RGBA', logo.size, (255, 255, 255, 0))
        im.putalpha(logo.getchannel('A'))
    im.thumbnail((round(size * .92), round(size * .92)), Image.Resampling.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.alpha_composite(im, ((size - im.width) // 2, (size - im.height) // 2))
    return out

def save(path, size, monochrome=False):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    im = fitted(size, monochrome)
    if p.suffix == '.ico':
        im.save(p, sizes=[(s, s) for s in [16, 24, 32, 48, 64, 128, 256]])
    else:
        im.save(p, optimize=True)
    outputs.append({'path': path, 'size': list(im.size), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'monochrome': monochrome})

for path in ['res/icon.png', 'flutter/assets/icon.png']:
    save(path, 512)
for path in ['res/icon.ico', 'res/tray-icon.ico', 'flutter/windows/runner/resources/app_icon.ico']:
    save(path, 256)
for density, size, notification in [('mdpi',48,24),('hdpi',72,36),('xhdpi',96,48),('xxhdpi',144,72),('xxxhdpi',192,96)]:
    base = 'flutter/android/app/src/main/res/mipmap-' + density
    save(base + '/ic_launcher.png', size)
    save(base + '/ic_stat_logo.png', notification, monochrome=True)
manifest = {'master': str(MASTER.relative_to(ROOT)).replace('\\','/'), 'master_sha256': EXPECTED, 'master_size': [1254,1254], 'visible_alpha_threshold': 32, 'crop_bounds': list(bounds), 'content_fraction': .92, 'generator': 'scripts/bk-remote/generate-brand.py', 'assets': outputs}
(ROOT / 'assets/brand/DERIVED-ASSETS.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
assert MASTER.read_bytes() == raw
print(json.dumps({'master_verified': True, 'derivatives':len(outputs), 'crop_bounds':bounds}))
