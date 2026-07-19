#!/bin/zsh
# make-release.sh — produce the two distributable artifacts for a GitHub release:
#   VietTelex-<VER>.app.zip   ← the Homebrew cask downloads THIS (artifact stanza)
#   VietTelex-<VER>.pkg       ← direct-download installer (registers input source)
#
# The .app.zip is zipped from the NOTARIZED + STAPLED app so the ticket travels
# inside it (Gatekeeper works offline; an input method only registers when its
# bundle is stapled). notarize-install.sh's own zip is made BEFORE stapling (for
# the notary submit) — that one is NOT distributable, which is why this exists.
#
# Prereq: run Scripts/notarize-install.sh first (builds → signs → notarizes →
# staples the app at the derived path below). Re-run it if the app changed.
#
# Usage: Scripts/make-release.sh [OUTDIR]     (default OUTDIR = ~/Desktop)
set -e
cd "$(dirname "$0")/.."

VER=$(plutil -extract CFBundleShortVersionString raw App/Resources/Info.plist)
APP="${TMPDIR:-/tmp}/viettelex-derived/Build/Products/Release/VietTelex.app"
OUTDIR="${1:-$HOME/Desktop}"
mkdir -p "$OUTDIR"

[ -d "$APP" ] || { echo "Stapled app not found at $APP — run Scripts/notarize-install.sh first."; exit 1; }
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "App is not notarized+stapled — run Scripts/notarize-install.sh first."; exit 1
fi

ZIP="$OUTDIR/VietTelex-$VER.app.zip"
echo "→ zipping stapled app → $ZIP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ building pkg (Scripts/make-pkg.sh)"
Scripts/make-pkg.sh
PKG_SRC="${TMPDIR:-/tmp}/VietTelex-$VER.pkg"
PKG="$OUTDIR/VietTelex-$VER.pkg"
cp "$PKG_SRC" "$PKG"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo
echo "✅ Release artifacts for v$VER in $OUTDIR:"
ls -lh "$ZIP" "$PKG"
echo
echo "app.zip sha256 (for the Homebrew cask):"
echo "  $SHA"
echo
echo "Next — publish (needs your OK; these push to the public release + tap):"
echo "  gh release upload v$VER \"$ZIP\" \"$PKG\""
echo "  # then in ptrinh/homebrew-viettelex bump Casks/viettelex.rb:"
echo "  #   version \"$VER\""
echo "  #   sha256 \"$SHA\""
