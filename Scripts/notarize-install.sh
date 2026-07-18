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
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex \
           -configuration Release -destination 'platform=macOS' \
           build | grep -E "BUILD" || true
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/VietTelex-*/Build/Products/Release/VietTelex.app | head -1)

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
echo "Done. Log out / log in ONCE, then add it: Keyboard → Input Sources → + → Vietnamese → Tiếng Việt (VietTelex)."
