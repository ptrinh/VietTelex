# Building VietTelex

Two pieces: a pure-Swift package (`TelexCore`) and the app bundle (`VietTelex.app`)
that wraps it in an IMK input method.

## Requirements

- macOS 13+ (deployment target), Apple Silicon or Intel
- Xcode 26 / Swift 6.3 toolchain
- `xcodegen` (Homebrew: `brew install xcodegen`) — only to regenerate the project

## 1. TelexCore (engine + validator)

```bash
cd TelexCore
swift build -c release      # clean release build
swift test                  # unit + benchmark tests (debug)
swift test -c release       # optimized benchmark numbers
```

The package has no dependencies and needs no Xcode GUI.

## 2. VietTelex.app (input method)

The Xcode project is generated from `project.yml`:

```bash
xcodegen generate                                   # writes VietTelex.xcodeproj
xcodebuild -project VietTelex.xcodeproj \
           -scheme VietTelex -configuration Release \
           -destination 'platform=macOS' build
```

The built bundle lands in
`~/Library/Developer/Xcode/DerivedData/VietTelex-*/Build/Products/Release/VietTelex.app`.
`TelexCore` is linked statically, so the bundle is self-contained.

### Installing for a manual test (TextEdit etc.)

**macOS 26 (Tahoe) requires input methods to be NOTARIZED to register as input
sources.** This was proven with a control experiment: a notarized Squirrel/RIME
build dropped into `~/Library/Input Methods` registered after one logout, while our
byte-for-byte-correct but *unnotarized* build never did — across ad-hoc, Developer
ID (unnotarized), and Apple Development signing, sandbox on/off, `~/Library` and
`/Library`. There is no log; the login scanner silently skips unnotarized bundles.
`spctl -a -t exec` tells them apart: notarized = "accepted", ours = "rejected".

Install with **`Scripts/notarize-install.sh`** (build → Developer ID sign +
hardened runtime → notarize → staple → install). One-time credential setup (run it
yourself so the secret never passes through the agent): create an app-specific
password at appleid.apple.com, then
`xcrun notarytool store-credentials VietTelexNotary --apple-id <email> --team-id 84T567KMYD`.

Other requirements that also matter (each independently blocked registration while
being debugged):

1. **Bundle id must contain "inputmethod"** — `com.viettelex.inputmethod`. Input-mode
   keys are prefixed by it (`com.viettelex.inputmethod.vi`).
2. **Top-level `TISInputSourceID`** (= bundle id), `NSPrincipalClass` = NSApplication,
   `LSBackgroundOnly` = false, mirroring Squirrel's plist.
3. **Not sandboxed** for the Developer ID build (`VietTelex.entitlements`,
   `app-sandbox = false`, no `get-task-allow` — the latter is rejected by
   notarization). Sandbox belongs only to the MAS build (`VietTelex-MAS.entitlements`).
4. Install to **`~/Library/Input Methods`** (user-owned, no sudo).
5. **Log out / log in once** after first install or after changing bundle id /
   input-mode metadata. Re-notarizing after code changes is required each time (the
   staple is per-build); `notarize-install.sh` handles it end to end.

Then: System Settings → Keyboard → Input Sources → + → Vietnamese →
"Tiếng Việt (Telex)".

Select the input source and type in TextEdit. The controller uses
`insertText(_:replacementRange:)` only (no marked text / underline).

Use the input-method menu (menu-bar flag icon) for: Tiếng Việt / Tắt (English),
Bảng gõ tắt…, Cài đặt…, Giới thiệu. Toggle also works with the global hotkey
(default ⌃⇧Space) and shows a VI/EN HUD.

## Icons

The "V" app icon and template menu icon are generated (already committed under
`App/Resources/`). To regenerate:

```bash
swift Scripts/make_icon.swift /tmp/VietTelex.iconset App/Resources/MenuIcon.tiff
iconutil -c icns /tmp/VietTelex.iconset -o App/Resources/AppIcon.icns
```

## What each part covers

- **TelexCore** — engine + validator, Swift 6 strict-concurrency clean, benchmarked.
- **App target** — Swift 5 language mode (AppKit/IMK singletons live on the main
  thread; Swift 6 strict concurrency would add no safety here and much noise).
- Per-app on/off (`AppState`, 500ms debounced disk write via a cancel/reschedule
  `DispatchWorkItem`), global hotkey (`HotkeyManager`, Carbon `RegisterEventHotKey`,
  sandbox-safe), toggle HUD (`ToggleHUD`, `.hudWindow` NSPanel, 800ms fade, respects
  Reduce Motion), SwiftUI settings (`SettingsWindow`, 3 tabs, created on open /
  released on close), shortcut expansion checked only at word boundary.
- `insertText(replacementRange:)` primary path; NSNotFound-caret fallback synthesises
  backspaces via `CGEvent` then inserts (`TelexInputController.replace`).

## Compatibility hardening (from real-world IME bug research)

1. **Remote-desktop force-passthrough** — `ClientPolicy.forcePassthroughBundleIDs`
   (TelexCore, unit-tested) hard-codes RDP/VM/screen-share bundle ids (Microsoft
   Remote Desktop *and* the new Windows App both use `com.microsoft.rdc.macos`,
   plus Parallels, VMware Fusion, UTM, Screen Sharing, Citrix, TeamViewer, RealVNC,
   Remotix). These clients forward raw scancodes, so the IME behaves exactly as OFF.
   Users add their own via **Ứng dụng → Luôn tắt** (`AppState.alwaysOff`).
2. **Secure input** — `IsSecureEventInputEnabled()` is checked at the top of
   `handle()`; when active the IME passes through cleanly and resets its buffer (no
   processing, no logging). Measured cost ≈ **0.06 µs/call** — safe on the hot path.
3. **replacementRange probe** — the first real replace into an unknown app is
   verified by reading the text back (`attributedSubstring(from:)`). If the app
   ignored replacementRange (Photoshop is the suspect) the bundle id is remembered in
   `AppState.fallbackApps` (persisted) and every later keystroke uses backspace
   synthesis. The probe is one-shot per app, so classified apps keep a clean hot path.

## Signing & Mac App Store (needs the user's real identity)

The project signs ad-hoc (`CODE_SIGN_IDENTITY = -`), which is enough to run and test
locally. For distribution you (the user) must supply:

1. **Signing identity** — set in `project.yml` under `settings.base`:
   `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY` ("Apple Distribution" for MAS), and a
   `PROVISIONING_PROFILE_SPECIFIER`. Regenerate with `xcodegen generate`.
2. **App Store Connect** record + bundle id `com.viettelex.VietTelex` registered.
3. Verify the current Apple flow for **MAS-distributed input methods** (install to
   /Applications, first-run guidance to System Settings → Keyboard → Input Sources)
   before submitting — this has changed across macOS releases (DESIGN.md §Packaging).
4. The sandbox entitlement is present and there are **no network entitlements**
   (zero-network is a review + privacy selling point). `PrivacyInfo.xcprivacy`
   declares zero data collection / zero tracking.

Do not attempt real signing in this environment — ad-hoc is correct for local dev.

## Remaining manual checklist (user)

- [ ] Real signing identity + provisioning profile; App Store Connect setup.
- [ ] Per-app manual test matrix (DESIGN.md): TextEdit, Safari, Chrome, Terminal,
      VS Code, Xcode, Slack, MS Word — especially the NSNotFound backspace fallback
      path (Electron/terminal apps) and secure/password fields (IMK auto-bypass).
- [ ] Cold-start timing (< 300ms), RSS after 1h (< 20MB), 0% idle CPU — measure with
      Instruments / `footprint` on the installed build.
- [ ] Localised store description / "collects no data" copy.
```
