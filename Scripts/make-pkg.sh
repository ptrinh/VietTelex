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

echo "→ productbuild"
if security find-identity -v 2>/dev/null | grep -q "Developer ID Installer"; then
    productbuild --distribution "$WORK/distribution.xml" \
                 --package-path "$WORK" \
                 --resources "$RES" \
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
                 --resources "$RES" \
                 "$OUT" >/dev/null
    echo "⚠️  UNSIGNED installer (local test only): $OUT"
    echo "   Create a 'Developer ID Installer' certificate, then re-run to ship it."
fi
