#!/usr/bin/env python3
# make_appicon.py — build the AppIcon Asset Catalog from assets/VietTelex-logo.png.
#
# Emits App/Resources/Assets.xcassets/AppIcon.appiconset/ with palette-quantized
# (256-color, dithered) PNG slices + Contents.json. Xcode's actool compiles this
# into Assets.car, which is much smaller than a raw .icns: iconutil re-encodes
# every slice to uncompressed ARGB (~670 KB), whereas the car keeps our optimized
# PNGs and deduplicates shared sizes (16@2x==32@1x, 128@2x==256@1x, 256@2x==512@1x
# → 7 unique files, not 10).
#
# Usage: python3 Scripts/make_appicon.py [logo] [xcassetsDir]
import json, os, sys
from PIL import Image

logo = sys.argv[1] if len(sys.argv) > 1 else 'assets/VietTelex-logo.png'
xcassets = sys.argv[2] if len(sys.argv) > 2 else 'App/Resources/Assets.xcassets'
appiconset = os.path.join(xcassets, 'AppIcon.appiconset')
os.makedirs(appiconset, exist_ok=True)

# (size pt, scale) entries for the macOS idiom → pixel dimension.
specs = [(16, 1), (16, 2), (32, 1), (32, 2),
         (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

img = Image.open(logo).convert('RGBA')
pngs = {}   # pixel size → filename (dedup shared sizes)

def png_for(px):
    if px not in pngs:
        name = f'icon_{px}.png'
        q = img.resize((px, px), Image.LANCZOS).quantize(
            colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
        q.save(os.path.join(appiconset, name), optimize=True)
        pngs[px] = name
    return pngs[px]

images = []
for pt, scale in specs:
    images.append({
        'size': f'{pt}x{pt}', 'idiom': 'mac',
        'filename': png_for(pt * scale), 'scale': f'{scale}x',
    })

with open(os.path.join(appiconset, 'Contents.json'), 'w') as f:
    json.dump({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, f, indent=2)

# Top-level catalog metadata.
with open(os.path.join(xcassets, 'Contents.json'), 'w') as f:
    json.dump({'info': {'version': 1, 'author': 'xcode'}}, f, indent=2)

total = sum(os.path.getsize(os.path.join(appiconset, n)) for n in pngs.values())
print(f'{appiconset}: {len(pngs)} unique PNGs, {total/1024:.0f} KB source '
      f'(compiles to a smaller Assets.car)')
