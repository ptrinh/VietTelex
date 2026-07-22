#!/bin/zsh
# Dev loop: build → sign → kill IME → replace bundle in ~/Library/Input Methods.
# No logout needed after the input source has been registered once.
# (Logout/login IS required the first time, or when bundle id /
#  Info.plist input-mode metadata changes.)
#
# Install location is the USER dir (~/Library/Input Methods): user-owned,
# no sudo, correct ownership. NOTE: the bundle must NOT be sandboxed for a
# Developer ID / local build — sandbox without a provisioning profile blocks
# input-source registration. VietTelex.entitlements is sandbox=false; the
# sandboxed entitlements live in VietTelex-MAS.entitlements (App Store only).
set -e
cd "$(dirname "$0")/.."

SIGN_ID="Developer ID Application: Phil Trinh (84T567KMYD)"
DEST="$HOME/Library/Input Methods/VietTelex.app"

# FIXED derived path — the default DerivedData grows one dir per xcodegen
# regeneration, and `ls | head -1` then installs a STALE build (bit us
# 2026-07-22: engine changes "didn't take"). Same pattern as notarize-install.
DERIVED="${TMPDIR:-/tmp}/viettelex-derived-dev"
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex \
           -configuration Release -destination 'platform=macOS' \
           -derivedDataPath "$DERIVED" \
           build | grep -E "BUILD" || true

APP="$DERIVED/Build/Products/Release/VietTelex.app"
codesign --force --options runtime \
         --entitlements App/Resources/VietTelex.entitlements \
         --sign "$SIGN_ID" "$APP"

pkill -x VietTelex 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

# The keyboard menu is drawn by TextInputMenuAgent, which keeps an IMK
# connection to the OLD (now dead) IME process. Without this restart the
# VietTelex menu section vanishes in EVERY app until the agent is bounced.
killall TextInputMenuAgent 2>/dev/null || true

echo "Installed to $DEST. Type anywhere (or switch input source away and back) to relaunch."
echo "NOTE: apps hold their own IMK connection — an app that stopped responding to"
echo "      the IME needs an input-source flip; Chrome/iTerm need a full app relaunch."
echo "Live logs: log stream --predicate 'process == \"VietTelex\"'"
