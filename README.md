# VietTelex

A macOS Vietnamese **Telex** input method (IMKit), built for a clean, OpenKey/EVKey-style
typing feel — **no marked-text underline, caret always at the end**, diacritics applied
in place.

## Features

- **Telex** engine (Simple Telex by default): tones `s f r x j`, circumflex `aa/ee/oo`,
  horn/breve `w`, `đ` via `dd`. Rule-based, zero-heap hot path.
- **Simple Telex** toggle — a lone `w` stays literal (type `uw` for `ư`); OpenKey #223.
- **Bỏ dấu tự do** (free mark placement) toggle — strict "Minimal Telex" by default so
  English/code types cleanly (`data`→data), or free like OpenKey (`ama`→âm).
- **Old vs modern** tone placement (`hòa` / `hoà`).
- **Live spell-check** — stops composing a word once it can't be valid Vietnamese
  (`google`, `github`…), plus word-boundary **auto-restore** — a phonotactic
  `SyllableValidator`, no dictionary.
- **Terminal support** (iTerm/Terminal/Claude Code) via a CGEventTap so both Vietnamese
  **and** shell autocomplete/Tab work — the case pure IMKit can't serve.
- Autocomplete-aware editing for **Chrome/Spotlight** (Shift+Left selection-replace) and
  **Excel** (empty-char reset) so inline suggestions don't corrupt the text.
- No internal VI/EN switch — Vietnamese is on whenever VietTelex is the active macOS
  input source; relies on macOS per-app input switching.

## Build

Requires macOS 14+, Xcode 26 / Swift 6.3, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# Engine tests (no Xcode needed)
cd TelexCore && swift test

# Generate the Xcode project and build the app
xcodegen generate
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex -configuration Release build
```

See [`BUILD.md`](BUILD.md) for signing, notarization, and installation notes, and
[`MACOS_IME_NOTES.md`](MACOS_IME_NOTES.md) for hard-won macOS input-method details.

macOS requires a third-party input method to be **notarized** to register — use
`Scripts/notarize-install.sh`.

## Design notes

- [`DESIGN.md`](DESIGN.md) — architecture.
- [`OPENKEY_LESSONS.md`](OPENKEY_LESSONS.md) — Telex edge-cases distilled by studying
  OpenKey/EVKey **behavior**. OpenKey is GPL; VietTelex learns behavior only and is
  implemented independently — **no GPL code is copied**.
- [`checklist.md`](checklist.md) — per-app compatibility test matrix.

## Credits

© Phil Trinh @ SenPrints
