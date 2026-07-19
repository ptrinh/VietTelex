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

# 4. Product archive (adds title + conclusion screen + user-home domain).
sed "s/__VERSION__/$VER/g" "$RES/distribution.xml" > "$WORK/distribution.xml"

# Assemble localized conclusion screens. The screenshots are INLINED as data
# URIs (productbuild only ships Distribution-referenced files, so external <img>
# files wouldn't travel). English at the top level = default/fallback; Vietnamese
# in vi.lproj → Installer.app shows it automatically on Vietnamese-language macOS.
# Images are downscaled + palette-quantized here to keep the pkg small.
mkdir -p "$WORK/resources/vi.lproj"
python3 - "$RES" "$WORK/resources" assets/instructions-1.png assets/instructions-2.png <<'PY'
import sys, base64, tempfile, os
from PIL import Image
res, out, i1, i2 = sys.argv[1:5]
def datauri(p):
    im = Image.open(p).convert("RGB")
    im.thumbnail((900, 900), Image.LANCZOS)
    q = im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
    t = tempfile.mktemp(suffix=".png"); q.save(t, optimize=True)
    b = base64.b64encode(open(t, "rb").read()).decode(); os.remove(t)
    return "data:image/png;base64," + b
u1, u2 = datauri(i1), datauri(i2)
def emit(src, dst):
    html = open(src).read().replace("__IMG1__", u1).replace("__IMG2__", u2)
    open(dst, "w").write(html)
emit(f"{res}/conclusion.en.html", f"{out}/conclusion.html")          # default (fallback)
emit(f"{res}/conclusion.vi.html", f"{out}/vi.lproj/conclusion.html")  # Vietnamese systems
PY

echo "→ productbuild"
if security find-identity -v 2>/dev/null | grep -q "Developer ID Installer"; then
    productbuild --distribution "$WORK/distribution.xml" \
                 --package-path "$WORK" \
                 --resources "$WORK/resources" \
                 --sign "$INSTALLER_SIGN_ID" \
                 "$OUT" >/dev/null
    echo "→ notarizing pkg (waits for result)"
    xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
    echo "✅ Signed + notarized installer: $OUT"
else
    productbuild --distribution "$WORK/distribution.xml" \
                 --package-path "$WORK" \
                 --resources "$WORK/resources" \
                 "$OUT" >/dev/null
    echo "⚠️  UNSIGNED installer (local test only): $OUT"
    echo "   Create a 'Developer ID Installer' certificate, then re-run to ship it."
fi
