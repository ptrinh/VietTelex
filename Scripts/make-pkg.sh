#!/bin/zsh
# make-pkg.sh — wrap the notarized VietTelex.app into a distributable .pkg
# installer that copies it to ~/Library/Input Methods and (in the user's GUI
# session) registers the input source + opens Keyboard settings, so the user
# never hand-copies into a hidden folder and doesn't need to log out.
#
# Prereqs:
#   1. Run Scripts/notarize-install.sh first — the app itself must be notarized
#      + STAPLED (an input method only registers if its own bundle is notarized;
#      the pkg's notarization does not staple a ticket onto the app inside).
#   2. To DISTRIBUTE, a "Developer ID Installer" certificate is required (you
#      currently have only "Developer ID Application"). Create it free at
#      developer.apple.com → Certificates → Developer ID Installer, download +
#      double-click to add to the keychain. Without it this script still builds
#      an UNSIGNED pkg you can test locally (right-click → Open, or
#      `installer -pkg … -target CurrentUserHomeDirectory`).
set -e
cd "$(dirname "$0")/.."

APP_SIGN_ID="Developer ID Application: Phil Trinh (84T567KMYD)"
INSTALLER_SIGN_ID="Developer ID Installer: SENPRINTS LLC (84T567KMYD)"
PROFILE="VietTelexNotary"
PKGID="com.viettelex.inputmethod.telex.pkg"

VER=$(plutil -extract CFBundleShortVersionString raw App/Resources/Info.plist)
APP="${TMPDIR:-/tmp}/viettelex-derived/Build/Products/Release/VietTelex.app"
RES="Scripts/pkg-resources"
WORK="${TMPDIR:-/tmp}/viettelex-pkg"
OUT="${TMPDIR:-/tmp}/VietTelex-$VER.pkg"

# 1. The app must exist and be stapled (notarize-install produces this).
[ -d "$APP" ] || { echo "App not found at $APP — run Scripts/notarize-install.sh first."; exit 1; }
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "App is not notarized+stapled — run Scripts/notarize-install.sh first"
    echo "(an input method only registers when its own bundle is notarized)."; exit 1
fi

# 2. Fresh staging: payload (the app) + scripts (postinstall + register helper).
rm -rf "$WORK"; mkdir -p "$WORK/payload" "$WORK/scripts"
/usr/bin/ditto "$APP" "$WORK/payload/VietTelex.app"

echo "→ compiling + signing register helper"
swiftc -O "$RES/register-source.swift" -framework Carbon -o "$WORK/scripts/register-source"
codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" "$WORK/scripts/register-source"
cp "$RES/postinstall" "$WORK/scripts/postinstall"
chmod +x "$WORK/scripts/postinstall"

# 3. Component pkg — installs payload into <userHome>/Library/Input Methods.
echo "→ pkgbuild"
pkgbuild --root "$WORK/payload" \
         --install-location "Library/Input Methods" \
         --scripts "$WORK/scripts" \
         --identifier "$PKGID" \
         --version "$VER" \
         "$WORK/VietTelex-component.pkg" >/dev/null

# 4. Product archive with a bilingual conclusion screen. Installer's HTML pane
#    renders neither data: URIs nor relative <img> files (WKWebView sandbox), so
#    the conclusion ships as RTFD — the format Installer supports natively for
#    images (rendered like the license pane: light document background, so no
#    dark-mode color issues). textutil converts our HTML sources and EMBEDS the
#    (downscaled, quantized) screenshots into each .rtfd. English at top level =
#    default/fallback; Vietnamese in vi.lproj → shown on Vietnamese-language macOS.
sed "s/__VERSION__/$VER/g" "$RES/distribution.xml" > "$WORK/distribution.xml"

echo "→ building RTFD conclusion screens (textutil, images embedded)"
RTFDSRC="$WORK/rtfd-src"
rm -rf "$RTFDSRC" "$WORK/resources"
mkdir -p "$RTFDSRC" "$WORK/resources/vi.lproj"
cp "$RES/conclusion.en.html" "$RES/conclusion.vi.html" "$RTFDSRC/"
python3 - "$RTFDSRC" assets/instructions-1.png assets/instructions-2.png <<'PY2'
import sys
from PIL import Image
out, i1, i2 = sys.argv[1:4]
for src, name in [(i1, "instructions-1.png"), (i2, "instructions-2.png")]:
    im = Image.open(src).convert("RGB"); im.thumbnail((880, 880), Image.LANCZOS)
    q = im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
    # dpi=144 -> RTFD/NSTextAttachment shows 880px as 440pt: fits the ~800pt
    # Summary pane (textutil sizes attachments by POINTS from the PNG's pHYs),
    # and stays crisp on Retina (2x pixels available).
    q.save(f"{out}/{name}", optimize=True, dpi=(144, 144))
PY2
(cd "$RTFDSRC" && textutil -convert rtfd conclusion.en.html -output en.rtfd \
                && textutil -convert rtfd conclusion.vi.html -output vi.rtfd)

# Force a FIXED display width on every embedded image, preserving aspect. textutil
# sizes attachments from the PNG's DPI, which Installer's text view interprets
# inconsistently (one image could overflow the Summary pane while another fit).
# Rewriting NeXTGraphic \width/\height in the RTF pins both to the same on-screen
# size, well inside the pane, independent of DPI.
python3 - "$RTFDSRC/en.rtfd/TXT.rtf" "$RTFDSRC/vi.rtfd/TXT.rtf" <<'PY2'
import sys, re
TARGET_W = 7200  # twips (=360pt), comfortably inside the Summary pane
for path in sys.argv[1:]:
    s = open(path, encoding="utf-8", errors="surrogateescape").read()
    def fix(m):
        w, h = int(m.group(1)), int(m.group(2))
        nh = round(TARGET_W * h / w) if w else h
        return f"\\width{TARGET_W} \\height{nh}"
    s = re.sub(r"\\width(\d+) \\height(\d+)", fix, s)
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
PY2
# productbuild cannot stream an .rtfd (directory) resource itself — it errors
# with "conclusion.rtfd couldn't be opened". So: build the product with NO
# conclusion resource, then post-process the archive: expand, drop the .rtfd
# bundles into Resources (top-level + vi.lproj) and point the Distribution's
# <conclusion> at them, flatten again. pkgutil handles directories fine.
echo "→ productbuild + inject RTFD conclusions"
sed 's#<conclusion file="conclusion.rtfd"/>##' "$WORK/distribution.xml" > "$WORK/distribution-noconclusion.xml"
productbuild --distribution "$WORK/distribution-noconclusion.xml" \
             --package-path "$WORK" \
             "$WORK/plain.pkg" >/dev/null
rm -rf "$WORK/expand"
pkgutil --expand "$WORK/plain.pkg" "$WORK/expand"
mkdir -p "$WORK/expand/Resources/vi.lproj"
/usr/bin/ditto "$RTFDSRC/en.rtfd" "$WORK/expand/Resources/conclusion.rtfd"
/usr/bin/ditto "$RTFDSRC/vi.rtfd" "$WORK/expand/Resources/vi.lproj/conclusion.rtfd"
# Re-add the conclusion element to the embedded Distribution.
python3 - "$WORK/expand/Distribution" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
assert "<conclusion" not in s
s = s.replace("<options ", '<conclusion file="conclusion.rtfd"/>\n    <options ', 1)
open(p, "w").write(s)
PY2
rm -f "$WORK/injected.pkg"
pkgutil --flatten "$WORK/expand" "$WORK/injected.pkg"

echo "→ sign"
if security find-identity -v 2>/dev/null | grep -q "Developer ID Installer"; then
    productsign --sign "$INSTALLER_SIGN_ID" "$WORK/injected.pkg" "$OUT"
    echo "→ notarizing pkg (waits for result)"
    xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
    echo "✅ Signed + notarized installer: $OUT"
else
    cp "$WORK/injected.pkg" "$OUT"
    echo "⚠️  UNSIGNED installer (local test only): $OUT"
    echo "   Create a 'Developer ID Installer' certificate, then re-run to ship it."
fi
