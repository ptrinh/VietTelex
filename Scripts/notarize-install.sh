#!/bin/zsh
# Build → Developer ID sign (hardened runtime) → notarize → staple → install.
# macOS 26 requires input methods to be NOTARIZED to register as input sources.
#
# One-time setup (run yourself, interactive, so the secret never passes through
# the agent). First create an app-specific password at appleid.apple.com
# (Sign-In and Security → App-Specific Passwords), then:
#   xcrun notarytool store-credentials VietTelexNotary \
#         --apple-id <your-apple-id-email> --team-id 84T567KMYD
#   (paste the app-specific password when prompted)
set -e
cd "$(dirname "$0")/.."

SIGN_ID="Developer ID Application: Phil Trinh (84T567KMYD)"
PROFILE="VietTelexNotary"
DEST="$HOME/Library/Input Methods/VietTelex.app"
SCRATCH="${TMPDIR:-/tmp}/viettelex-notarize"

echo "→ building"
xcodegen generate >/dev/null 2>&1 || true
# Explicit derivedDataPath: multiple stale DerivedData dirs made the old
# `ls | head -1` pick an OUTDATED build (shipped old icons/name once). Build
# and install from ONE deterministic location.
DERIVED="${TMPDIR:-/tmp}/viettelex-derived"
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex \
           -configuration Release -destination 'platform=macOS' \
           -derivedDataPath "$DERIVED" \
           build | grep -E "BUILD" || true
APP="$DERIVED/Build/Products/Release/VietTelex.app"
[ -d "$APP" ] || { echo "build product not found: $APP"; exit 1; }

echo "→ cleaning stray legacy code seal + Developer ID sign + hardened runtime"
# xcodebuild leaves a legacy top-level Contents/CodeResources that no valid app
# (Apple's own IMEs, normal .apps) has. Strip it and the existing seal,
# then sign fresh so the bundle matches a clean modern signature.
rm -f "$APP/Contents/CodeResources"
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --options runtime --timestamp \
         --entitlements App/Resources/VietTelex.entitlements \
         --sign "$SIGN_ID" "$APP"
if [ -f "$APP/Contents/CodeResources" ]; then
  echo "  WARNING: stray Contents/CodeResources reappeared after signing"; fi

echo "→ zipping + submitting to Apple notary (waits for result)"
mkdir -p "$SCRATCH"
ZIP="$SCRATCH/VietTelex.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "→ installing to $DEST"
pkill -x VietTelex 2>/dev/null || true
rm -rf "$DEST"
/usr/bin/ditto "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
spctl -a -t exec -vv "$DEST" 2>&1 | head -2
# A re-signed build makes the old Accessibility grant STALE: AXIsProcessTrusted()
# still returns true but CGEvent.post is silently dropped -> letters type but no
# diacritics in tap-mode apps (see MACOS_IME_NOTES.md). Reset so the user re-grants.
tccutil reset Accessibility com.viettelex.inputmethod.telex >/dev/null 2>&1 || true
pkill -x VietTelex 2>/dev/null || true

echo "Done. Log out / log in ONCE (first install only), then add it: Keyboard → Input Sources → + → Vietnamese → Tiếng Việt (VietTelex)."
echo "NOTE: Accessibility grant was reset (stale after re-sign) — re-enable VietTelex in"
echo "System Settings → Privacy & Security → Accessibility for Terminal/Chromium typing."
