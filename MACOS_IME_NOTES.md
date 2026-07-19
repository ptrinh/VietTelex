# macOS Input Method — Hard-Won Registration Notes

Why a third-party IMKit input method does / doesn't appear in
**System Settings → Keyboard → Input Sources**. Written after a long debugging
session on **macOS 26.5 Tahoe**. Read this BEFORE touching signing / bundle id /
Info.plist again — every item below cost real time to discover.

## The working recipe (do all of these; they are AND, not OR)

1. **Notarize + staple.** macOS 26 silently refuses to register an un-notarized
   input method — no log, survives logout. Proven with a control: a notarized
   third-party input method in the same `~/Library/Input Methods` registered on
   the first logout; our identical-but-unnotarized builds never did.
   `spctl -a -t exec <app>` must say **accepted** (Notarized), not "rejected
   (Unnotarized)". Sign Developer ID Application + hardened runtime, then
   `notarytool submit --wait` + `stapler staple`. See `Scripts/notarize-install.sh`.

2. **Bundle id must contain `inputmethod` as a segment.** e.g.
   `com.viettelex.inputmethod.telex`. `com.viettelex.ime` did NOT register.
   (Apple's own use `com.apple.inputmethod.*`.)
   The input-mode id must be the bundle id + a suffix
   (`com.viettelex.inputmethod.telex.vi`).

3. **`InputMethodServerControllerClass` in Info.plist must match the REAL ObjC
   class name.** This was the single nastiest bug. The Swift class had
   `@objc(TelexInputController)`, which registered it in the ObjC runtime as bare
   `TelexInputController`, but Info.plist declared `VietTelex.TelexInputController`.
   `NSClassFromString("VietTelex.TelexInputController")` → nil → IMK can't
   instantiate the controller → macOS never registers the input method.
   **Fix:** no explicit `@objc(name)` on the controller class. A Swift class that
   subclasses `IMKInputController` is auto-exposed as `Module.Class`
   (mangled `_TtC9VietTelex20TelexInputController`), which is exactly what
   `NSClassFromString("VietTelex.TelexInputController")` resolves. Verify with:
   `otool -ov <binary> | grep TelexInputController` → must show `_TtC9VietTelex...`,
   NOT bare `TelexInputController`.

4. **Bundle ids get POISONED — use a FRESH id after any broken install.**
   Installing a bundle id even once while it is invalid (unsigned / sandboxed /
   wrong class) caches a negative verdict for that id. After fixing everything,
   that same id STILL never registers (`TISRegisterInputSource` → noErr but the
   source is never enumerated, even after logout). We burned
   `com.viettelex.inputmethod` and `com.viettelex.ime` this way. The moment we
   used a brand-new id (`com.viettelex.inputmethod.telex`) with all the fixes, it
   registered. **Corollary: always notarize + fix BEFORE the first install of any
   id, so you never poison the id you intend to ship.**

5. Install to **`~/Library/Input Methods`** (user-owned, no sudo). `/Library`
   needs root:wheel ownership; a hand-copied bundle there is owned wrong and gets
   skipped.

6. **Sandbox OFF for the dev / Developer ID build.** Sandbox without a provisioning
   profile blocks registration; `get-task-allow` is rejected by notarization.
   Sandbox belongs ONLY to the MAS build (`VietTelex-MAS.entitlements`), signed
   Apple Distribution + a provisioning profile at submission.

## Things that are NOT the cause (ruled out — don't chase these again)

- **`Contents/CodeResources`** as a real file: that is the **stapled notarization
  ticket** (magic bytes `s8ch`), normal for a stapled app. Apps distributed without
  stapling lack it. Harmless.
- **`com.apple.provenance` / `com.apple.macl` xattrs**: kernel-managed, can't be
  stripped, present on other input methods too. Irrelevant.
- **MDM / config profiles**: none restrict input methods here.
- **Location `/Library` vs `~/Library`**: both work if ownership is right.
- **Missing localization (lproj / InfoPlist.strings)**: only affects the display
  name, not whether it enumerates.
- **A new Sequoia/Tahoe "approval" gate for IMEs**: does not exist (that's for
  DriverKit extensions, not input methods).

## Display name in the picker (not the raw id)

Once registered, the picker showed the raw id `com.viettelex.inputmethod.telex.vi`
instead of a readable name. The picker name comes from **`InfoPlist.strings` in an
`.lproj`**, keyed by the input-source id — NOT from
`tsInputModeAlternateMenuTitleStringKey` (that key only names the menu-bar item).

Fix: `App/Resources/{en,vi}.lproj/InfoPlist.strings` (bundled via `project.yml`):

```
"CFBundleName" = "VietTelex";
"com.viettelex.inputmethod.telex"    = "Tiếng Việt (VietTelex)";
"com.viettelex.inputmethod.telex.vi" = "Tiếng Việt (VietTelex)";
```

Changing the name needs a re-notarize + refresh (remove & re-add the source, or log
out/in) because the name is cached with the registration.

## Typing mechanism: NO marked text (Vietnamese habit)

Vietnamese typists expect: **no underline, caret always at the end**, characters
transform in place. So the controller does NOT use marked
text. Each engine transform is a minimal `(backspaces, insert)` diff applied in
place via `client.insertText(insert, replacementRange:)`, where the range is
`(selectedRange().location - backspaces, backspaces)`.

- This requires `client.selectedRange()` to return a real caret. It does in Cocoa
  apps (TextEdit, Safari, Mail, Office…). Verified: 0 "unusable" log events typing
  in TextEdit.
- Apps that return `NSNotFound` for `selectedRange()` (some terminals / Electron)
  can't be edited this way — the controller logs
  `selectedRange unusable … app=<bundleid>` (subsystem
  `com.viettelex.inputmethod.telex`, category `controller`) and best-effort inserts
  without deleting. Those apps need a per-app strategy (see checklist.md). Do NOT
  fall back to CGEvent backspaces from an IMKInputController: the synthesized
  Delete key re-enters `handle()` as `kDelete` and corrupts the engine — that was
  the original garbled-output bug.
**Dual-mode (final design).** Default = in-place (no underline). An unclassified
app is probed once (read-back after the first real replace); if it silently ignores
replacementRange (Terminal / iTerm — valid caret but no actual replace), it flips to
**marked-text mode** for every future keystroke and the choice is persisted
(`AppState.usesMarkedText` / `fallbackApps`). So normal apps stay clean (no
underline), and only terminals show the brief composing underline. This keeps the
IMKit architecture — no Accessibility permission, Mac-App-Store-compatible.

Why can't the no-underline feel cover iTerm too via pure IMKit? A CGEventTap app
that simulates real Backspace+retype keystrokes can, but that needs Accessibility
permission and cannot ship on the Mac App Store (sandbox forbids global event
posting). We chose the IMKit + App-Store path deliberately; terminals get marked
text as the trade-off — UNLESS the Developer ID build has Accessibility (see
terminal tap-mode below).

**Terminal tap-mode (Developer ID only).** Marked text in a terminal breaks shell
autocomplete (each key sits in the composition buffer until the boundary, so
zsh-autosuggestions / Tab never see partial input), and terminals also don't honor
IMKit `return true` suppression without a marked-text op — an IME literally cannot
stop the raw key there. So for terminal-class apps we bypass IMKit entirely:
`TerminalTapController` runs a `CGEventTap` (`.cgSessionEventTap`,
`.headInsertEventTap`) that intercepts keyDown BEFORE the terminal. Plain letters
pass through natively (shell sees them live → autocomplete works); a tone edit is
SUPPRESSED (return nil) and applied by synthesizing real Backspace + Unicode
(`SyntheticKeyboard`, posting to the session tap). Both Vietnamese AND autocomplete
work — the case pure IMKit cannot serve.

Key details (all learned the hard way):
- Needs Accessibility to create the tap and post events → Developer ID (non-sandbox)
  only. `usesTapMode` = `fallbackApps.contains(id) && AXIsProcessTrusted()`; the
  sandboxed MAS build can't be trusted and transparently stays on marked text.
- Re-entrancy: our posted events re-enter the tap and the IME. They are stamped via
  the event SOURCE's `userData` (`CGEventSource.userData = magic`) — the PER-EVENT
  `.eventSourceUserData` field does NOT survive posting; the source's value does.
  Both the tap and `handle()` check `isSynthetic` and pass them straight through.
  (Missing this caused a 9× Backspace cascade that wiped the line.)
- The tap only acts while VietTelex is the active input source (`imeActive`, set in
  activate/deactivateServer) so switching to ABC/US in a terminal really types
  English. It reads the frontmost app via `NSWorkspace`, and only for terminal
  (`fallbackApps`) apps; everything else passes through to the normal IMKit path.
- Grant/menu: the input-method menu's status line ("Tình trạng: Thiếu quyền")
  prompts + opens the Accessibility pane when clicked. After granting, restart the
  IME (or it re-attempts `TerminalTapController.start()` on the next activateServer).
- Gotcha: if Accessibility is stale (granted to an earlier signature) `AXIsProcessTrusted()`
  can return true while `CGEventPost` is silently dropped. Remove + re-add VietTelex
  in the Accessibility list to fix.
- **Gotcha: nothing expensive in the tap callback, or `tapDisabledByTimeout` leaks keys.**
  The callback runs per keystroke; if it's too slow the system DISABLES the tap
  (`.tapDisabledByTimeout`) and, until we re-enable it, physical keys fall through to
  the (terminal-broken) IMKit marked-text path → intermittent garbage
  ("wirwiwriaărirw" in a Claude Code TUI). Caused by calling
  `SpotlightDetector.isVisible` (a full `CGWindowListCopyWindowInfo` enumeration) on
  every key — now cached with a ~200ms TTL. Keep the callback O(1): set/dict lookups
  only, no window-list/AX/Workspace scans per key.
- **Gotcha: the IMKit controller and the tap MUST decide "is this a tap app?" from the
  SAME source.** The tap uses `NSWorkspace.frontmostApplication`; the controller used
  `currentBundleID` (the IMK client id from activateServer), which can be nil/stale.
  When nil, the controller thought "unknown app → in-place" and composed into a
  terminal the tap was already handling; a leaked physical key (brief tapDisabled
  window) then got composed by IMKit → intermittent garbage in iTerm/Claude Code
  ("Khoông..."). Debug snapshot showed `App: ?` + `in-place` while the tap was running.
  Fix: the controller's tap-defer check also consults `NSWorkspace.frontmostApplication`,
  so the two never disagree.
- **Arrow / navigation / F-keys must pass through, never re-emit as text.** In iTerm,
  `keyboardGetUnicodeString` returns arrows as CONTROL chars (len 1): Left 0x1C, Right
  0x1D, Up 0x1E, Down 0x1F — NOT the 0xF700–0xF8FF function-key range (that range shows
  up in some other apps). The non-letter branch would `emitBoundary` + `reemit` them as
  INSERTED TEXT (keyboardSetUnicodeString), so the terminal got a raw 0x1C instead of the
  arrow's escape sequence (`ESC[D`) → cursor/history navigation dead. Fix: in `handle()`,
  if `buf[0] < 0x20` (any control char — Return/Tab/Esc/Backspace are already handled by
  keycode before this point) or in 0xF700–0xF8FF, flush the word and `return pass` to
  deliver the real key. Verified with file-logging (`/tmp/viettelex-tap.log`) because
  os_log is not captured for this background input-method agent.
- **Fast-typing race → force strictly-increasing timestamps on every posted event.**
  Symptom: slow typing is correct, fast typing corrupts order — `nuwax` (→ "nữa")
  came out "nuẵ" (= as if "nuawx": the 'a' overtook the ư edit from 'w'). Root cause:
  `CGEvent.post` delivers in TIMESTAMP order, and events we create back-to-back get
  equal/near-equal `mach_absolute_time` stamps, so the window server reorders same-
  stamp events. Fix: `SyntheticKeyboard.stamp()` sets each posted event's `.timestamp`
  to `max(mach_absolute_time(), lastStamp+1)` before posting — strict monotonic order,
  FIFO restored. (Verified decisive: adding os_log to the hot path also "fixed" it by
  adding latency between posts — a Heisenbug; the timestamp fix holds with NO logging,
  ~17/17 fast `nuwax` correct.)
- **Native fast path + in-flight guard (fewer synthetic round trips).** Originally
  EVERY key was suppressed and re-emitted synthetically so that ordering versus
  synthetic edits could never break. That costs 2 posted events per plain letter.
  The current design restores native passthrough for NON-TRANSFORMING letters,
  guarded by an in-flight counter: each posted synthetic keyDown increments it, and
  it decrements when that event re-enters the tap. A letter passes natively ONLY
  when the counter is 0 (queue drained); while a burst is draining, keys still go
  through the timestamped synthetic channel. The tap callback is serial, so the
  decision cannot race; a 500ms silence self-heals a counter wedged by a dropped
  event (tap flap). Backspace/Return/Tab on an empty buffer get the same guard.
  Kill switch if reordering ever reappears on some setup:
  `defaults write com.viettelex.settings tapNativeFastPath -bool false`.

Two in-place gotchas (both fixed):
- **`insertText("", replacementRange:)` is a no-op in some apps (TextEdit).** So a
  pure-deletion backspace (delete a glyph, insert nothing) silently did nothing;
  the engine drained invisibly and only the Nth physical Backspace deleted. Fix:
  for a backspace whose action has an empty insert, return `false` and let the
  physical Backspace delete the (single) char. A tone-replacing backspace
  ("toán"→"tóa") has a non-empty insert and still goes through insertText.
- **Do NOT call `selectedRange()` after every insert.** Under fast typing it returns
  a stale caret (the app hasn't applied the previous insert yet), so the next
  replace lands at the wrong offset and corrupts the word ("được"→"đựoc"). Fix:
  track the composition locally — `anchor` (caret at the word's first key, read
  once) + `onLen` (UTF-16 length on screen) — and compute every replace range from
  those, not from a fresh selectedRange().
- **Never mix system passthrough-inserts with your own insertText.** Returning
  `false` for a non-transforming letter lets the SYSTEM insert it, on a different
  (async) channel than the `insertText` used for transforms. Under fast typing the
  system insert lags behind the insertText, they land out of order, and the word
  corrupts (still "được"→"đựoc" even with local tracking). Fix: insert EVERY
  composing letter yourself with `insertText` (consume the key, return true) so all
  edits go through one ordered channel. Likewise do backspace via insertText
  (rewrite the whole composition), reserving the physical Backspace only for
  deleting the final remaining glyph (where insertText("") would no-op).

Check the log after typing in a new app:
```bash
log show --last 5m --predicate 'subsystem == "com.viettelex.inputmethod.telex"' --style compact | grep unusable
```

## Registration only PERSISTS via the login scan

`TISRegisterInputSource` returns noErr and makes the source appear **transiently**
in `TISCreateInputSourceList`, but `cfprefsd` wipes it on reload — it does NOT
persist. The durable registration happens during the **login scan** (log out / log
in). So: install the correct, notarized, fresh-id bundle, then log out / log in
once. After that it stays.

Do NOT `killall cfprefsd` after registering — it erases the transient registration.

## Debug commands

```bash
# Is it registered right now?
swift -e 'import Carbon; let l=TISCreateInputSourceList(nil,true)!.takeRetainedValue() as! [TISInputSource]; for s in l { if let p=TISGetInputSourceProperty(s,kTISPropertyInputSourceID){ let id=Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String; if id.contains("viettelex"){print(id)} } }'

spctl -a -t exec ~/Library/Input\ Methods/VietTelex.app          # must be "accepted"
xcrun stapler validate ~/Library/Input\ Methods/VietTelex.app    # must be "worked"
otool -ov ~/Library/Input\ Methods/VietTelex.app/Contents/MacOS/VietTelex | grep TelexInputController  # must be _TtC9VietTelex...
```

## Dev loop (minimize logouts)

- **Engine only** (`TelexCore`): `swift test` — no install, no logout.
- **IMK / controller / Info.plist**: `Scripts/notarize-install.sh` (~2 min for
  notarization) then log out / log in ONCE. As long as the bundle id does not
  change and each install is notarized, the id stays healthy and one logout after
  the first correct install is enough; subsequent notarized swaps of the same id
  refresh in place after re-selecting the input source.
