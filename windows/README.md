# VietTelex for Windows

Spec: [docs/WINDOWS-SPEC.md](docs/WINDOWS-SPEC.md). Engine C ABI: [engine/API.md](engine/API.md).

| Dir | What |
|---|---|
| `engine/` | C++ port of TelexCore (static lib `viettelex_engine`), plus `viettelex_text`: text tools, NFC/NFD + Unicode case mapping, Thêm dấu with the vnlexicon / enlexicon / vnlm v3 readers (VietTelex.exe only, never the TIP) |
| `ime/core/` | Portable typing core: key mapping, `TypingSession` (composition / in-place), settings + snapshot, shortcuts, per-app policy, hotkey. Unit-tested on any OS. |
| `ime/src/` | `VietTelexTIP.dll`: the TSF text service (COM, `ITfTextInputProcessorEx`, key sink, composition with a no-underline display attribute, in-place mode, registration; no language-bar item since 1.0.8) |
| `app/` | `VietTelex.exe`: tray, Settings window, updater, per-app hook fallback, per-user setup |
| `installer/` | WiX MSI (x64, ARM64 with ARM64X forwarder), Store checklist `STORE.md`, winget templates, Azure Trusted Signing script, `build.ps1`, optional MSIX template |

## Build

```
# any OS: core + tests
cmake -S windows -B build && cmake --build build && ctest --test-dir build
# RELEASE (macOS): cross-compile x86/x64/ARM64 in Docker, sign, build MSIs, verify
windows/scripts/release.sh --version 1.0.0          # -> windows/dist/release/
# Windows dev build (MSVC), one per architecture
cmake -S windows -B build-x64 -A x64 && cmake --build build-x64 --config Release
```

`release.sh` does the following, and publishes nothing:

1. **Build.** It builds with llvm-mingw inside `mstorsjo/llvm-mingw` (`scripts/cross-build.sh`) and installs nothing on the host.
2. **Sign binaries.** It signs every `.dll` and `.exe` with `jsign --storetype TRUSTEDSIGNING`, timestamped (RFC 3161, `timestamp.acs.microsoft.com`).
3. **Build MSIs.** It builds them with `wixl`. The ARM64 MSI is an x64-shaped database with the Template `Arm64;1033`.
4. **Sign MSIs and verify.** It checks every signature with `osslsigncode` against `installer/microsoft-identity-verification-root-2020.pem`, then writes `SHA256SUMS`.

The signing target comes from `VTX_SIGN_ENDPOINT`, `VTX_SIGN_ACCOUNT` and `VTX_SIGN_PROFILE`, set in the environment or in the gitignored `installer/signing.local.env`. Signed releases also need `VTX_EXPECTED_PUBLISHER`: the certificate's subject CN, compiled into `VietTelex.exe` as the only publisher the self-updater accepts. `release.sh` checks it against the actual signatures. A build without it (dev builds, `build.ps1` without `-DVTX_EXPECTED_PUBLISHER=...`) refuses every downloaded update and only offers the release page. The access token comes from `az login`, or in CI from `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET`. No secret is stored in the repo.

### MSI registration (no regsvr32)

The MSI writes the COM and TSF registration as Registry-table rows:

- `CLSID\{…}\InprocServer32` with `ThreadingModel=Apartment`,
- `CTF\TIP\{CLSID}` with `Enable`,
- the vi-VN `LanguageProfile` (Description, IconFile, IconIndex, Enable, `SubstituteLayout=0x04090409`),
- both `Category\Category` and `Category\Item` keys for every category.

These go into the 64-bit view (`TipNative`) and the 32-bit view (`TipX86`).

The rows are generated from `ime/core/registration.h`, the same data `DllRegisterServer` uses. The DLL refuses to register if its SDK GUIDs drift from that data. `vtx_regtable check` diffs the built MSI against it, and CTest (`vtx_regtable_roundtrip`) covers the checker.

There is no AppContainer ACL, because wixl has no `Permission` element. It isn't needed: the default `Program Files` ACL already grants read and execute to ALL (RESTRICTED) APPLICATION PACKAGES.

## Upgrading

To upgrade, install the new MSI over the old one. There are no repair packages. A normal major upgrade does this:

1. **QuitApp** (immediate, before InstallValidate) runs `VietTelexSetupHelper.exe --quit-app` from the MSI's Binary table. It sends `WM_CLOSE` to every VietTelex.exe main window, waits 3 s, then terminates only `VietTelex.exe` images. The app also answers `WM_QUERYENDSESSION`/`WM_ENDSESSION` by exiting.
2. **ReleaseTip** (deferred as SYSTEM, before RemoveFiles/InstallFiles) moves every in-use `VietTelexTIP*.dll` of this version or older (`--max-version`) aside to `*.old`, scheduled for silent deletion at the next boot. It is skipped when this package is the old version being removed (`NOT UPGRADINGPRODUCTCODE`).
3. The new files are installed. TIP DLL names carry the version (`VietTelexTIP_1_0_7.dll`) and get a per-version component GUID, so nothing overwrites a DLL that running apps have loaded, and the registry points at the new file immediately.
   - The old version is removed afterwards: RemoveExistingProducts sits between InstallExecute and InstallFinalize, one of the positions ICE63 allows. 1.0.6 put it elsewhere and failed with error 2613.
   - The COM/TSF registration lives in registry-only components that keep the ≤1.0.5 component GUIDs, so removing the old version keeps the keys the new one wrote.
   - `REBOOT=ReallySuppress` and Restart Manager disabled: no prompts.
4. **LaunchApp** starts the new app, which opens Settings.
5. **Single-instance handoff:** a newer exe that finds an older instance running (compared by the version in the hidden window's title) closes it and takes over.
6. **In-app update:** it starts `msiexec` (by its full path in the system folder) plus a detached watcher (a copy of the exe in `%TEMP%`), then exits. If the install is cancelled, the watcher restarts the installed app.
   - **Single flight (2026-11):** one check, one prompt, one download at a time (`UpdateFlow`, `app/core/update_check.h`). A click during an automatic check joins it; during a download it only says "Đang tải bản cập nhật". The automatic prompt has **No** as its default button.
   - **Once a day:** a one-shot timer to the next due time and a check on resume from sleep (`autoCheckDelayMs`), not only at app start.
   - **Failures:** a failed download offers the download page. A signature whose revocation status could not be fetched (offline, proxy) says so and offers the page; it is retried once and never installed. The pinned publisher check is unchanged.
7. **Uninstall from Settings:** `msiexec /x` goes through the same watcher (`--wait-install <pid> --uninstall`): a cancelled UAC prompt or MSI dialog brings the app back. "Gỡ sạch" (`--cleanup-user`) waits for the running app to exit, then deletes every file VietTelex writes in `%LOCALAPPDATA%\VietTelex` by name (`isUserDataFileName`: settings.bin, learned-words.bin, applang.txt, debug.log, debug.1.log, update-*.log and their `.tmp`) and removes the folder when empty.

## Per-host text policy (1.1.2)

In-place is the default and needs a document that really contains the text before the caret. At each word start the TIP classifies the focused context with `classifyContext()` in `ime/core/app_policy.h`, following Mozc's rule in `tip_transitory_extension.cc`:

| Context | What happens |
|---|---|
| No context, `GUID_COMPARTMENT_KEYBOARD_DISABLED` or `EMPTYCONTEXT` set (games, canvases) | Keys are not eaten. |
| Read-only, or an ANSI focus window (`!IsWindowUnicode`: VBA editor, ANSI apps) | Keys pass through literally. |
| `TF_TMAE_CONSOLE` (conhost, OpenConsole, Windows Terminal) | Composition only; never read back. |
| Not `TF_SS_TRANSITORY` (Word, Firefox) | Full context: in-place. |
| Not `TF_SS_TRANSITORY`, focus window `HwndWrapper[…]` (a WPF TextBox / RichTextBox) | Composition from the first key; a claimed key is never let through (see WPF below). |
| Transitory with a transitory-extension parent (classic Edit/RichEdit) | Read and edit through the parent context if that parent is not transitory. If the parent refuses an edit session, composition for that focus. |
| Transitory and CUAS-emulated (compartment `{A94C5FD2-…}` bit 1: IMM32 apps such as Qt/Telegram, Java/JetBrains, AutoCAD, Adobe) | Composition from the first key. |
| Transitory otherwise (Chromium: Chrome, Edge, Brave, Electron, WebView2 always report transitory) | Full context: in-place. 1.1.1 wrongly composed here. |

Also:
- **Terminal rules:** built-in composition rules for terminals (conhost, openconsole, windowsterminal, mintty, alacritty, wezterm, ConEmu, PuTTY, KiTTY, Tabby) and off rules for VM and remote viewers.
- **Unrecognised hosts:** if a field shows none of the typed text, composition from the second key. The letters let through before that are composed too (#134: in an IMM32 app they never arrived).
- **Not a text field:** in a TSF-native store (not transitory, or a transitory-extension parent whose focus window is no Edit/RichEdit: `passedKeysReachApp`) the app did get those letters, so a store that shows none of them is not the element's text — a WPF list with type-to-filter sits on WPF's empty default store. Composing there typed into nothing. The word goes on as typed; after a second such word in the same focus the session stops claiming keys (`notTextField`) until the focus changes, and the TIP asks the hook (Direct) to type there.
- **WPF list (1.3.16):** a WPF window whose context is a transitory-extension parent with no Edit (`wpfDefaultStore`: WPF's default store behind a list, One Commander's type-to-filter file list) is known to be no text field from the context alone. At the first word start the session latches `notTextField` (keys pass as typed, nothing composed) and the TIP asks the hook, which types there with backspaces + Unicode. The hook's ack comes after the first letter already reached the list, and a hook engaged mid-focus waits for a word boundary — but the filter is one word (Space ends it), so the TIP also records the raw keys of the word in progress (`typed_word.h`: up to 5 ASCII letters/digits, 6 bits each, in the `VietTelex.TypedWord` property on its focus root, kept current while keys pass as typed) and asks with `kDirectAdoptTyped` (DirectMode lParam bit 1). Only for that request the hook adopts the word at the FIRST key it handles (`app/core/word_adopt.h`): it reads the record, feeds those keys to its engine with no output, and treats the raw letters as what the screen shows — "do" then `j` sends ⌫ + "ọ"; "doj" then `c` sends ⌫⌫ "ọ" + "c" in one batch; ⌫ first deletes the last raw letter and re-adopts the rest. An unknown record (longer than 5 keys, a bracket key, a key VietTelex injected or retyped, English) keeps the old wait-for-boundary rule; a click, arrows, chords, Enter/Tab/Esc as the first key end the word as typed. Other handovers (consoles, terminals, in-place failures) carry no flag and are unchanged. Residual race: a key typed before the hook was installed that the app has not yet processed when the next key reaches the hook is missing from the record (two keys within a few milliseconds of the request). TSF focus changes inside the same WPF window (the filter bar appearing, a list refresh) keep that handover (`directSurvivesFocusChange`); it is released when the focus window changes or the window leaves the foreground. A WPF TextBox in that same window is then typed by the hook too. With debug logging on, the TIP logs one `context:` line per focus change (transitory, parent, Edit, WPF, CUAS, host, focus class).
- **WPF:** WPF calls TSF's keystroke manager itself. A key the TIP claims in `OnTestKeyDown` becomes `Key.ImeProcessed`; if `OnKeyDown` then lets it through, WPF marks its `KeyDown` handled, the message is never translated and the TextBox gets no `TextInput`. In-place lets the first letter of each word (and the Space, `@`, `.` ending it) through, so in WPF text boxes nearly every key was lost (One Commander: e-mail field, inline rename). In a WPF element's own store (`wpfOwnsClaimedKeys`) the TIP composes from the first key and takes the #134 path: a boundary goes out with the word, any other claimed key is retyped. Each composition start is read back; a store that holds none of it is no text field (`setCompositionMustShow`), and keys pass from that key on.
- **Symbol shortcut keys** (`=>`, `<>`, `->`, `:D`, `k2`): not letters only, so never one word in Telex. The session tracks the run of non-whitespace text it saw before the caret and, at space / Enter / Tab, replaces run + word in progress when it is such a key, standing alone and verified on screen (the hook, which reads nothing, needs a space it saw before the run).
- **IMM32 hosts (#134):** a key `OnTestKeyDown` claims there becomes `VK_PROCESSKEY`, so a claimed key `OnKeyDown` lets through is lost (MISA SME 2022: first letter, Space and digits after a word). In such fields (CUAS-emulated, or shown none of the typed text) a Space/punctuation ending a word goes out with the word in the result string, ⌫ never re-opens, and any other claimed key the TIP does not eat is retyped by the TIP (`SendInput`, `kInjectedMagic`).
- **Classic Edit whose parent store misreads (Win10 Notepad, 2026-11):** in a file that already has text, the Edit's transitory-extension parent read nothing before the caret although the letters let through were on screen, and a composition set there showed nowhere (no Vietnamese letter ever appeared; an empty file worked). Before taking the #134 path the session now asks the Edit itself (`EM_GETSEL` + `EM_GETLINE`, `TextSink::appTextEndsWith`). If the Edit shows the letters, the store misreads: that word goes on as typed (the hook adopts it, `kDirectAdoptTyped`), and for the rest of the focus the TIP drops the parent, asks for Direct and otherwise composes in the keystroke (CUAS) context. If the Edit does not show them (MISA), the #134 path is unchanged.
- **Single-key web shortcuts (2026-11, Gmail `#`):** a key the TIP claims reaches a page, but not as the genuine key event its shortcuts listen to. With no word in progress, a key Telex does not transform (`#` `?` `/` `[` digits, Enter, arrows, chords) is never claimed; an armed ⌫ re-open / retro undo is disarmed by `noteKeyPassedBy` instead. A browser context (async store) that has no caret or refuses the edit session at a word start is a page with no editable element focused (`NoEditableContext`): no key at all is claimed there (j / k / x shortcuts too) until a read-only probe at a word start finds a caret, the store reports an edit, or the focus changes. A symbol that ends a word is still claimed, so the word is committed before the symbol reaches the app.
- **Emptied composition:** a composition the app empties (Excel autocomplete) ends the word.
- **Windows search (2026-11 report):** in the Start / taskbar search box the first word of each search lost its tone key after a doubled vowel (`taafng` → `tâfng`, `taangf taangf` → `tângf tầng`). On an async store (`setAsyncStore`) that is the #139 path: right after the first in-place replace the store shows the page between the deletion and the insertion, the next key that needs an edit goes through as typed, and only then the field composes (`chromium_store_tests`: `start_search_*` reproduce it). For SearchHost / SearchApp / StartMenuExperienceHost on an async store (`shellSearchPrefersComposition`, by app identity) the TIP composes from the first letter. Sync stores are unchanged. Every decision that drops a word is now in the debug log (lengths only): stale view, focus change / context push mid-word, composition ended by the app, refused edit session, re-edit off after a word, `deactivated`.
- **Fields that undo an in-place edit (2026-11, Word's Navigation search box):** `đầu mối` came out `đàu môi`: the box took a replace and then put its own text back (search-as-you-type), so the next tone key re-edited the unaccented word and a word's last replace was simply lost. After every in-place replace the session keeps what the screen would show if it were undone (`undoneSig_`); the check that already runs at the next key (and at OnEndEdit / the word's commit) compares against it — no extra read on a normal field, one short read at the commit of a word that had an edit. On that signature (sync stores only) the word is pulled back into a composition with all its marks, the field composes from then on, and the TIP remembers the focus window class for the rest of the app's life (`UnreliableControls`), so that control kind composes from the first letter next time. Log: `in-place: the field undid our last replace…`, `in-place unreliable in this control kind (class …)`. Tests: `field_undoing_*`, `hard_field_matrix_types_the_phrase`.
  - **Through TSF (1.3.19 report: the portable hook was fixed, the installed TIP was not):** the TSF store reports the app putting its text back as several edits (field emptied or all selected, or part of the word, then the text), each with an OnEndEdit. `verifyScreen` dropped the word at the first of them, so the undo was never seen. Such a mid-rewrite state (sync store: nothing before the caret, a selection, or the screen ending in a proper prefix of the word) now only marks the word (`rewritePending_`); the next OnEndEdit, the next key or the word's commit decide on the finished text (undone: re-taken; anything else: dropped, never read as "the store shows nothing"). Also: Word's own UI text boxes (`winword.exe`, focus class `NetUIHWND`: Navigation pane search, ribbon search) compose from the first letter (`officeUiPrefersComposition`, log `Word UI text box (NetUIHWND)…`). Tests: `FakeDocument::Rewrite` / `appRewrite`, `field_undoing_a_replace_through_tsf_rewrite_steps_*`, `field_rewriting_the_same_text_in_steps_*`, `field_seen_mid_rewrite_*`, `word_ui_text_boxes_*`.
  - **The same key offered twice (1.3.20 report, debug log of 1.3.18–1.3.20):** the Navigation search box is focus class `RICHEDIT60W` (Office's RichEdit, its own sync TSF store), not `NetUIHWND`, so the policy above never matched and the box stayed in place. There every key the TIP lets through is handed to the keystroke manager a second time before the box inserts it (Word's message loop, then the RichEdit). The second offer saw the word without that letter: "the store shows none of the typed keys" at the first word's 2nd key, then "no longer ends with the word" on the following keys, every word dropped and re-started mid-way (`ddaauf moois` → `đâù môí`; no rewrite or undo line in the log). Fixes: the TIP ignores a second offer of a key event it already let through (`KeyEventRepeat`, tip_caches.h: same wParam, lParam and message time; a key-up or a new message is a new press; log `the app offers a key we let through a second time…` once per focus), and `officeUiPrefersComposition` also matches `winword.exe` + `RICHEDIT60W` (composition lets no letter through). Tests: `word_navigation_search_offering_passed_keys_twice_reproduces_the_log` (the log's exact lines and lengths), `word_navigation_search_second_offer_is_ignored`, `key_event_repeat_only_matches_the_same_passed_event`.
- **Shortcut case follows the typing** (2026-11 report: key `ko`, typing `Ko` stayed `Ko`): `shortcutExpansion` = macOS / iOS / Android `ShortcutTable.expansion` — exact key first, else a lowercase key with `Ko` → `Không`, `KO` → `KHÔNG`, mixed case no match. Word and symbol keys, TIP and hook alike (same session).
- **WebView2:** `msedgewebview2.exe` takes its per-app rules and memory from the root-owner exe (new Teams, new Outlook).
- **Hook mode:** it warns once, non-modally, when the foreground app is elevated. UIPI blocks SendInput there.

## Direct mode and the underline (1.1.3)

The goal is no underline anywhere possible.

- **Direct hosts:** where TSF cannot edit in place, VietTelex.exe's low-level hook types UniKey/OpenKey-style. It eats the key and sends one `SendInput` batch of N backspaces plus `KEYEVENTF_UNICODE` text, so a user key can never interleave, and the engine tracks the word blind. The hosts:
  - consoles (conhost, OpenConsole, Windows Terminal, mintty, Alacritty, WezTerm, ConEmu, PuTTY, KiTTY, Tabby) through built-in `direct` rules;
  - fields the TIP classifies at run time: CUAS/IMM apps (Qt/Telegram, Java/JetBrains, Adobe, AutoCAD) and fields that show none of the typed text (xterm.js in the VS Code terminal). The TIP posts `AppCommand::DirectMode` for them.
- **Java AWT hosts (1.3.17):** JetBrains IDEs and other Swing apps lose characters when the backspaces and the text arrive in one batch (AWT runs VK_BACK as an editor action and the Unicode text as typed characters by another path). For a top-level window whose class starts with `SunAwt` (`splitsCorrection`, `app/core/direct_policy.h`) the hook sends the backspaces at once and the text `kSplitCorrectionDelayMs` (50 ms, ~50–63 ms with the timer tick) later, from a timer on the hook thread; the hook callback never waits. Keys typed during the pause are eaten and queued behind the text (`SplitInjection`), so nothing overtakes it; Shift and Caps Lock pass. Ctrl/Alt/Win, F-keys, chords, a click or other software's input send the pending text at once, then that key. A foreground change drops what is pending and resets the word. Other hosts keep the single batch.
- **Injected keys:** they carry `dwExtraInfo = kInjectedMagic` and are never processed again, by the hook or by the TIP (`GetMessageExtraInfo`).
- **Hook thread:** the hook runs on its own high-priority thread. A raw-input watchdog reinstalls it when Windows removes it (`LowLevelHooksTimeout`).
- **Handover ack between the two halves of one key (1.3.36, Excel cell, debug log of 1.3.33):** the first word typed in a cell sometimes stayed raw (`khoong`, `YKTDD`), mostly when typing fast; the formula bar was fine. The TIP asks for Direct at a word start in `OnTestKeyDown` and claims the key; the hook acks about a millisecond later. In an IMM32 host `OnKeyDown` of that key is a separate message and saw the ack: the TIP let the key through, the hook (engaged mid-focus) waited for a word boundary, nobody typed the word. A key claimed in `OnTestKeyDown` now stays the TIP's in `OnKeyDown` of the same key (`TestClaim`, tip_caches.h); the word is then active there and the hook starts at the next boundary as designed. Test: `test_claim_holds_for_the_same_key_only`.
- **When composition remains:** only if VietTelex.exe is not running, or an app is set to composition by hand. It always uses the `TF_LS_NONE` attribute (no line, no colours). Hosts that may still draw their own marking: legacy conhost's conversion area and some IMM-based Java/Qt builds. Chromium honours `TF_LS_NONE` when the attribute provider is registered, which is checked in tests.
- **Chromium address bar (#173):** the browser's native address bar (Edge, Chrome, Brave, Cốc Cốc…; input scope `IS_URL`, `fieldPrefersComposition`) cannot take an in-place replace while inline autocomplete shows ("thế" -> "theêz"), and it underlines any composition whatever the display attribute. So the TIP hands that field to the hook (`omniboxStepAtWordStart`, `AppCommand::DirectMode` with `kDirectAdoptTyped | kDirectInlineAutocomplete`). Until the hook acks, keys reach the field as typed and the hook adopts that word at its first key (`word_adopt.h`), so the TIP never composes a word the hook could type over. There every replace is one batch: U+202F (typing replaces the selected suggestion), Backspace × (N + 1), the text (`usesPlaceholderEdit`, `directEditEvents`; macOS `.emptyReset` since 1.4.14). A plain append needs nothing; a pure deletion stays plain Backspaces (no stray character). The user's own ⌫ goes through untouched and the hook forgets the word and its ⌫ trail (`userBackspaceDropsWord`): with a suggestion showing, the browser removes only the suggestion. **Not verified after an edit:** no echo check runs there (`echoCheckedAfterEdit`), because UI Automation on the browser can switch on its accessibility mode for the whole browser; the field is treated like any unreadable host and the hook keeps typing. Only a refused `SendInput` sends it back to composition.
  - **Fallback = composition, as before:** VietTelex.exe not running, UIPI, the field marked `VietTelex.NoDirect` (send refused), or no ack within `kOmniboxAckWaitMs` (500 ms; the request is released). An explicit per-app Composition / Direct / Off rule keeps winning (the rule needs output mode InPlace).
  - **Portable build:** unchanged. It has no TIP, cannot see `IS_URL`, and plain backspaces are what it sends in the address bar.

## Direct fallback per field (1.1.4)

Direct stays on only where it provably works; otherwise that one field goes back to composition (`TF_LS_NONE`, done by the TIP in-process).

- **Integrity (UIPI):** if the target process runs at a higher integrity than VietTelex.exe, or its token cannot be read, the hook does not type for it and the TIP composes. This replaces the old balloon-only warning. Since #134 the TIP does not even request the handover there.
- **Echo check:** after each Direct edit a background thread (not on the key path, ~80 ms later, latest edit only) reads what the host really shows before the caret. For conhost it uses `AttachConsole` + `ReadConsoleOutputCharacter` (with a console control handler that ignores Ctrl+C / Ctrl+Break, installed before the first attach: those reached VietTelex.exe while attached and ended it); for Windows Terminal and other hosts it uses UIA `TextPattern`, else `ValuePattern` (Qt/Java/Adobe). Two mismatches in the same field (focus hwnd + control id) mark it `VietTelex.NoDirect` for the rest of the focus, and the event is logged (debug logging). Hosts that expose nothing stay on Direct.
- **Send failures:** if `SendInput` sends fewer events than requested, that field switches to composition at once.
- **Races:** if the foreground changes between the key and the injection, or the secure desktop is up, the edit is dropped and the word resets.
- The rules are pure functions in `app/core/direct_policy.*` with unit tests.

## Consoles, handover, per-app Việt/Anh, debug log (1.1.5)

- **Console identity:** for a console window (`ConsoleWindowClass`), `GetWindowThreadProcessId` reports the client (cmd.exe) and that client's thread, not conhost. The hook and the tray now key such windows as `conhost.exe`, the name the TIP and the built-in Direct rule use. In 1.1.4 the hook looked up `cmd.exe`, found no rule and did nothing, while the TIP stayed out on its own `conhost.exe` rule, so every word came out raw.
- **Handover ack:** the TIP stays out of a field only while the hook's `VietTelex.DirectOn` property is on the window. Until then it composes (no underline). When the hook takes over mid-focus, it waits for a word boundary (`HookArming`), so the TIP and the hook never type the same word.
  - **Stale properties (2026-11):** `VietTelex.DirectOn` and `VietTelex.Suspend` hold the app's main window as their value, and the TIP honours them only while that is the live app window (`propFromLiveApp`, 32-bit compare for WOW64 TIPs). A killed VietTelex.exe (no cleanup) no longer leaves a field typed by nobody or every key passing through.
  - **Per-key cost:** the TIP reads its own integrity once per process and the app's once per focus and app process (`HookReachCache`); the property checks stay per key.
- **Foreground between two hooked windows (2026-11):** a foreground update naming another window drops the word in progress and the engine context (`foregroundUpdate`). Before, `ba` in Notepad, Win, `w` in Start search sent a backspace + `ă` there (portable build). The same window keeps its state.
- **Việt/Anh for the hook and tray:** the TIP sets `VietTelex.Lang` (1 = Việt, 2 = Anh) on its focus window and removes it on deactivation. That property is the only source for consoles; other windows fall back to the keyboard layout plus the per-app memory. Injected backspaces now carry a scan code.
- **Per-app memory (in-TIP switch: Ctrl+Shift, Alt+Z):** kept in `HKCU\Software\VietTelex\AppLanguage\<exe>` and restored whenever a window gets focus. AppContainer and low-IL hosts (Start search, UWP) can't use HKCU: the TIP asks the app to store the value (`AppCommand::SetAppLanguage`), and the app mirrors the map to `%LOCALAPPDATA%\VietTelex\applang.txt`, which those hosts can read. Every restore decision is logged.
- **Win+Space / input source (VietTelex ↔ ENG):** this is Windows' own per-app setting ("Let me use a different input method for each app window", `SPI_GETTHREADLOCALINPUTSETTINGS`). Settings → Gõ phím → Chuyển Việt/Anh → Nâng cao shows its state and has a button that turns it on (`SPI_SETTHREADLOCALINPUTSETTINGS`, saved and broadcast). If turning it on doesn't work, the button opens `ms-settings:typing` instead.
- **Debug log:** when "Ghi nhật ký gỡ lỗi" is on, the TIP (in every host), the app, the hook and the verifier append to `%LOCALAPPDATA%\VietTelex\debug.log` (writer `ime/src/debug_file.cpp`, rules in `ime/core/debug_log.h` and `debug_header.h`, unit-tested). AppContainer hosts fall back to their own temp folder (`VietTelex-debug.log`). The log records decisions (rule, window class, handover, SendInput counts, echo results, fallbacks) and never typed text, only key classes and lengths. Compact format (1.3.18):
  - Lines are `HH:MM:SS.mmm pid exe [component] message`. A `=== yyyy-mm-dd ===` line comes first in a new file and whenever the file was last written on another day. The pid and exe stay on every line because several processes append to the same file.
  - Identical consecutive lines of one process within 60 s are written once, followed by `^ repeated Nx more until <time>` before that process's next different line. The app also writes the line at exit; a TIP host that exits right after a burst loses only that count.
  - Lines that were re-announced at every focus change are now written only on a change: `applang restore` (per app, per process) and `tray state`. A settings change while logging is one `settings changed:` line.
  - **Hook thread (2026-11):** the keyboard hook never writes the file itself. Its lines are queued with their time and written in order by one thread-pool writer (`app/core/log_queue.h`); the queue is written out at exit. The format is unchanged.
  - Rotation: to `debug.1.log`, the only old file kept, past about 1 MB or when the file was last written more than 7 days ago. The log therefore stays under about 2 MB and does not keep an old session's lines forever.
  - **Context header:** each process writes one `# context:` line before its first line, at the start of a new file and on its first line of a new day. It holds the version, the module (`viettelex.exe` or `viettelextip_<arch>_<ver>.dll`), the process and OS architecture (emulation on arm64), the Windows build, the integrity level, elevation and AppContainer. With logging on, VietTelex.exe adds its header at start, when logging is switched on, and for each new file or day: the app version, the registered TIP DLL version (flagged `DIFFERS FROM THE APP` or `FILE MISSING`), the install kind (MSI per-machine or per-user, Store MSIX, portable) with its folder, the Windows edition and display version, the UI language, the keyboard layouts (and whether VietTelex is in the list), the count and languages of other enabled text services (no names), DPI and monitors, a settings summary (input method, options that are on, hotkeys, per-app rule counts by mode, shortcut count, never their contents) and the update check (on/off, hours since the last automatic check). Nothing personal is included: no user or machine name, and paths under `%USERPROFILE%` become `~`. Nothing is gathered while logging is off.

## Text tools (Công cụ văn bản)

The macOS text tools (`App/Sources/TextActions.swift`) for the selection in any app: Thêm dấu cho vùng chọn, HOA, thường, Hoa Đầu Từ, Hoa đầu câu, Xoá dấu.

- **Entry points:** the tray menu's **Công cụ văn bản** submenu (setting `textToolsInMenu`, default on; the tray icon itself is off by default) and an optional global **Thêm dấu hotkey** (`addTonesHotkey`: `off` (default), `ctrl-alt-t`, `ctrl-shift-t`, `win-alt-t`; `RegisterHotKey`, so it also works when another keyboard is active). Both are on the Spelling tab. There is no language-bar menu: the TIP has had no language-bar item since 1.0.8.
- **Transforms:** `engine/src/text_tools.cpp` and `engine/src/add_tones.cpp`, a port of `TextTools.swift`, `AddTones.swift` and the `SyllableLM.swift` v3 reader. They produce the same results as iOS and Android on the shared fixtures `iOS/KeyboardTests/Fixtures/{text-tools,add-tones,vnlm-parity}.txt`, tested by CTest `text_tools`. The Unicode tables (NFC/NFD, full case mapping with Final_Sigma, General Category) are generated by `engine/tools/gen_unicode.py` and cross-checked against Python's `unicodedata` with `engine/tests/unicode-sample.txt`.
- **Data:** `vnlexicon.bin`, `enlexicon.bin` and `vnlm.bin` from `iOS/Keyboard/Resources` (the same files as iOS, Android and macOS) are embedded as RCDATA in `VietTelex.exe`. The readers work in place on the image-mapped resource, which is demand-paged and never copied, and they load on first use. If the LM is missing or doesn't match the lexicon, Thêm dấu runs on the lexicon alone. The TIP never loads any of it.
- **Read and replace, in this order:**
  1. **Through TSF.** VietTelex.exe posts a request to the TIP's message-only window for the focused thread (`ime/core/text_tool_ipc.h`). The TIP reads the selection in an edit session, handling classic Edit/RichEdit through the transitory-extension parent like typing does. It sends the text to the app (`WM_COPYDATA`); the app transforms it and sends the result back. The TIP replaces exactly the range it read, and only if that range is still the selection with the same text, then puts the caret after it.
     - Password/PIN input scopes are refused.
     - In a readable store, an empty selection means "nothing selected": it beeps rather than send Ctrl+C, which in VS Code copies the whole line.
  2. **Ctrl+C / Ctrl+V fallback.** This runs when there is no TSF selection: consoles, CUAS/IMM32 apps, another keyboard active, or no answer within 600 ms. It works like macOS `PasteboardBridge`:
     1. Wait for the hotkey's modifiers to be released.
     2. Snapshot every clipboard format (HGLOBAL formats byte for byte, EMF copied; GDI/private handles skipped, and CF_BITMAP is re-synthesised from CF_DIB).
     3. Send Ctrl+C (marked `kInjectedMagic`) and wait for the sequence number to change. Then transform the text and put it on the clipboard, with the Windows opt-out formats for clipboard history, cloud clipboard and monitors.
     4. Send Ctrl+V. After 600 ms, restore the snapshot if the clipboard is still ours.
  - The fallback never runs in terminals or consoles (Ctrl+C would interrupt), VM/remote viewers, `ES_PASSWORD` edits or elevated apps (UIPI).
- **The TIP window** is titled `VietTelexTip:<thread id>` and found by that title. Its class name includes the version and module address, so a class that an unloaded TIP left registered can never supply a stale window procedure. `DllCanUnloadNow` also unregisters it.
- **One request at a time.** A failure beeps. Decisions go to the debug log (lengths only, never text).
- **Hotkey and Ctrl+Shift:** RegisterHotKey eats the T of Ctrl+Shift+T, so the TIP disarms its Ctrl+Shift switch chord when a request arrives.

## Caret hints (Gợi ý cạnh con trỏ, macOS 1.8.2)

Five suggestions shown in a small window at the caret. Each has its own switch in Settings → Gợi ý & công cụ → Gợi ý cạnh con trỏ. None replaces anything by itself: **Tab** applies (Enter too for maths), **Esc** hides it (and, for typo fixes, stops suggesting that word this session; for tones, that sentence), any other key hides it and goes through.

| Setting | Default | Example |
|---|---|---|
| `mathResults` | on | `12*3=`, `200+10%=`, `125 x (4 + 5.5) =` → `= 36` (inserts `36`) |
| `numberChips` | on | `50k␣`, `1tr2␣`, `2 tỷ␣` → `1.200.000 ₫` (money formats only) |
| `typoHints` | on | `tpoi␣` → `tôi`: one neighbour key on a physical keyboard or two keys swapped, only for words that are not Vietnamese, English or chat words. With no Vietnamese fix, an **English** one on the raw keys (`spellnig␣` → `spelling`, `teh␣` → `the`; a dropped / extra key too from 5 letters) — `typo::englishDefaults()` = macOS `TypoFixLogic.englishDefaults` |
| `filterSensitive` | on | "Lọc từ nhạy cảm" (iOS / macOS): word prediction and typo fixes never offer `SensitiveWords` words. Read by VietTelex.exe (`HintJobs::setFilterSensitive`) |
| `learnWords` | on | "Học từ bạn gõ" (iOS / macOS): word prediction learns the words and word pairs you type (see *Learning* below). Only while Windows text suggestions are on |
| `toneHints` | off | `toi di hoc.` or a 0.9 s pause after a space → `tôi đi học` (≥ 3 unaccented syllables) |
| `dateHints` | on | `hôm nay␣`/`ngày mai␣`/`hôm qua␣` → `28/09/2026`, `bây giờ␣` → `21:35`; `âm lịch␣`/`ngày âm␣`/`ÂL␣` → today's Vietnamese lunar date `30/9 năm Bính Ngọ` (UTC+7 calendar; leap month `1/6 nhuận năm Ất Tỵ`); `Tết␣` → the date of the next mùng 1 Tết `06/02/2027` (Tab keeps the word: `Tết 06/02/2027`); `today`/`tomorrow`/`yesterday`/`now` only after an English word |

- **Logic:** pure and shared-fixture tested. `ime/core/caret_hints.*` holds the TIP side: maths and number chips (`math-results.txt`, `number-chips.txt`), dates, the tone-run tracker and the typo gate. `app/core/typo_fix.*` holds the typo fixer, which uses the lexicon. Its precision eval (`typo_eval_precision_floor`, now with English fixes on) gives P 97.2 %, R 23.6 %; the English eval (`typo_eval_english_precision`, Tatoeba TEST words with 15 % slips) reproduces the macOS numbers exactly: P 97.5 %, R 38.7 % (Vietnamese fixes only: R 0.7 %).
- **Cost:** with all five off, a key costs one flag read. With any on, the TIP keeps the chunk being typed (raw keys since the last space). Only a trigger (`=`, or a space or `. ! ?` worth checking) arms a 40 ms timer, so the app has inserted the key first. After that come one async read session and the caret rectangle (`ITfContextView::GetTextExt`, then the character before the caret, then `GetGUIThreadInfo`).
- **Out of process:** typo fixes and tones need the language data, which stays in VietTelex.exe like the text tools (`ime/core/caret_hint_ipc.h`, `WM_COPYDATA` both ways). The TIP only shows an answer if no key was typed since, and it re-reads the screen before showing and again before replacing.
- **Window:** `ime/src/hint_popup.*` — a top-most `WS_EX_NOACTIVATE | WS_EX_TRANSPARENT` popup that never takes focus or clicks. It is light or dark following `AppsUseLightTheme`, auto-hides after 8 s, and hides when the caret moves.
- **Not here:** password/PIN input scopes, `ES_PASSWORD` edits, secure desktop, consoles and fields typed by the hook (Direct mode), composition-only contexts, and English mode (the TIP is not typing then).

## Word prediction (Gợi ý từ, macOS 1.8.x WordPrediction.swift)

**One** word in the caret hint window — the top-ranked one, shown like every other caret hint (`đừng  Tab`), no list and no numbers. Two cases:

- **Completing the word being typed**, including Telex state: `tôi đư` → `đừng`. It suggests English words when the previous word was English, when no Vietnamese syllable matches (`keyb` → `keyboards`), or when the raw keys (≥ 4) are an English prefix clearly ahead of every Vietnamese reading (`predict::prefersEnglish`: `pers` shown as `pé` → `person`; never when the word on screen is already a common Vietnamese syllable: `toi`, `duoc`, `cam`, `ther` → `thẻ`). English completion uses the raw keys, so `this` shown as `thí` still completes as `this…`.
- **The next word** right after a space: the `vnlm.bin` trigram row for two context words (`cảm ơn ` → `anh`, `thành phố hồ ` → `Chí`), or an iOS **seed** pair for one context word (`cảm ` → `ơn`, `xin ` → `lỗi`; `app/core/seed_next.inc`, generated by `Scripts/gen-seed-next.sh` from iOS UserLangModel itself). The trigram row comes first, as in iOS `SuggestRank.nextFill`. There is no statistical one-word bigram guess, so `Tên ` suggests nothing.

Keys and clicks:

- **Tab** or a **click** takes the word; the popup is clickable only for predictions and still never takes focus.
- **Esc** hides it. On a completion, Esc also mutes suggestions until the next word.
- **Enter, the arrow keys and digits never pick a word.** Any other key hides the popup and goes through.
- Nothing is replaced automatically. The screen is re-read before the popup shows and again before a word is inserted.
- An accepted word is followed by a space, then a next-word suggestion, as on macOS. If the **very next key** is `. , ? ! ; :` or a closing `) ] } ” ’ » ›`, it attaches to the word and the space moves after it (`được. `), and the space typed right after that is swallowed; `/` only removes the space (`hints::acceptSpaceKey`, re-read first). Any other key leaves it alone.

**Switch.** There is no VietTelex setting. It follows the Windows setting **Settings → Time & language → Typing → "Show text suggestions when typing on the physical keyboard"**:

- The value is `HKCU\Software\Microsoft\Input\Settings`, `EnableHwkbTextPrediction` (REG_DWORD; 1 = on, 0 = off).
- If the value is missing (the toggle was never used), the setting counts as **off**, which is the Windows default.
- Microsoft does not document this value. The name comes from community guides that write the same toggle.
- VietTelex.exe reads it at start and watches it with `RegNotifyChangeKeyValue` plus a thread-pool wait. It uses no thread of its own and polls nothing.
- VietTelex.exe mirrors the value into the snapshot bit `systemTextPrediction` (`isSystemMirror`), never into `HKCU\Software\VietTelex`. TIPs pick a change up at their next focus change.
- The settings window shows it so users can find it: Chính tả → Gợi ý cạnh con trỏ → **Gợi ý chữ khi gõ** ("Đang bật" / "Đang tắt — bật trong Cài đặt Windows…", `textPredictionDesc`) with a button that opens `ms-settings:typing`. The state is read when the page is built and again when the window is activated (one `RegGetValue`, rebuilt only if it changed).

**Where it never runs:**

- password/PIN fields;
- consoles, terminals and Direct (hook) fields;
- composition-only contexts;
- code editors and IDEs (`hints::predictionAllowedForApp`: VS Code, Cursor, Visual Studio, JetBrains, Sublime, Notepad++…), where Tab indents;
- English mode, VietTelex off, game mode.

Completion also needs the word to be on screen (in-place). A TSF composition is never replaced. Other caret hints win: a prediction is armed after them and only if they find nothing.

**Ranking.** `app/core/word_prediction.*` is a C++ port of `PredictionLogic` + `PredictionModel` and the shared iOS ranking: `SuggestRank.rankInline` / `inlinePmi` / `topNext` (trigram row only), `VNSuggest.matches`, `SyllableLM.Context`, `DisplayCase`, `SuggestionCase`, `SensitiveWords`, the `SeedData` unigram counts and `EnglishLite`.

- It uses the same data files and weights. The data is `vnlexicon.bin`, `vnlm.bin` and `enlexicon.bin`, already embedded for the text tools. The seed counts are `app/core/seed_unigrams.inc`, generated by `app/tools/gen_seed_unigrams.py`.
- `app/tests/fixtures/word-prediction.tsv` is generated **by the Swift code itself** (`app/tools/gen_prediction_golden.sh`, macOS + swiftc). `app_tests` checks every line: 146 cases (24 with learned data) covering next word (trigram and seed), completion, case, English (also in a Vietnamese context) and sensitive words with the filter on and off. The ranking keeps its top three (`kRankDepth`) so the golden compares three ranks per case; VietTelex.exe answers the TIP with the first one only.

**Learning ("Học từ bạn gõ", `learnWords`, default on like iOS).** The TIP tracks only the words its typing session composed and committed (`TypingSession::lastCommitWord`: a printable boundary or Enter/Tab/Esc; never a shortcut expansion, never app-typed text) with the ≤ 2 previous words of the same sentence (`hints::LearnTracker`, = macOS `LearnTracker`). Each word is held until the next event: ⌫ right after the boundary, a Ctrl chord, or a hint replacing it drops it; an accepted typo fix learns the fixed form; an accepted prediction counts double. Gates: word prediction on, `learnWords`, not a code editor/terminal (`predictionAllowedForApp`), `hintsUsable()` (no secure desktop, console, Direct; literal/password input scopes are never composed), not a classic `ES_PASSWORD` edit, Vietnamese on. Events are queued and sent from a 50 ms TIP timer — never inside a key handler — as one `WM_COPYDATA` (`HintJob::Learn`, one-way). VietTelex.exe keeps the model (`app/core/learned_words.*`, a port of `App/Sources/LearnedModel.swift` on the iOS `UserLMTables` + VTL2 format: same caps 3000/6000/3000, weekly 0.7 decay, unknown words need 3 uses, learned pairs/triples need 2 before they are offered after one word / lead the static trigram) in `%LOCALAPPDATA%\VietTelex\learned-words.bin`, saved atomically (temp file + `MoveFileEx`) 5 s after the last word and at exit; a corrupt file starts empty. No network, no sync. Settings → Chính tả → "Xoá từ đã học…" clears RAM and file. Sensitive words are counted but filtered when suggesting, per `filterSensitive`. The golden fixture has a `learn` column and `learned-words.bin` is the Swift encoder's output: the C++ model must produce the same ranking and the same bytes.

**Cost:**

| Path | Cost |
|---|---|
| Windows setting off | One bool test per key in the TIP. VietTelex.exe builds nothing. |
| Setting on, per letter / space / ⌫ | A few string copies and a 0.3 s timer that every key re-arms, so steady typing reads nothing. |
| After a 0.3 s pause | One async read session, one `WM_COPYDATA` to VietTelex.exe (`HintJob::Predict`), ranking there, a re-read, then the popup. |

- **Time:** about 5 µs per request, 13 µs worst, on an Apple M-series host build. It has not been measured on Windows.
- **Memory:** the model adds about 5–10 KB of heap in VietTelex.exe. The data indexes (about 360 KB) are shared with typo fixes and Thêm dấu. The TIP holds no data.
- **Binary size** (x64, MinSizeRel):

  | Binary | Before | After | Change |
  |---|---|---|---|
  | TIP | 438,272 | 452,096 | +13.5 KB |
  | VietTelex.exe | 2,497,536 | 2,544,640 | +46 KB |

  For x86 the TIP grows by 11.5 KB and the app by 47 KB; for ARM64 the TIP grows by 13 KB and the app by 43 KB.

## Onboarding (first run)

Decisions are pure functions in `app/core/onboarding.*` with unit tests; the Win32 side is `main.cpp` (`--setup-user`), `welcome.cpp` and `conflicts.cpp`.

- **Per-user activation through Active Setup.** The MSI writes `HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{D1246D27-55D1-45DC-96F6-60BF26027142}` with `StubPath = "<exe>" --setup-user --active-setup`, `Version = 1,0` and `IsInstalled = 1`. At every user's next logon, Windows runs the stub once for that user, so a Store/Intune/`msiexec /qn` install as SYSTEM reaches everyone.
  - **Why Active Setup:** HKLM RunOnce only reaches the first user to log on. HKLM Run runs at every logon, forever. A logon scheduled task needs the Task Scheduler API, which wixl cannot author. Writing other users' HKCU from SYSTEM misses users created later.
  - **Fixed version:** the stub runs once per user, not once per release, so an upgrade never re-adds a keyboard the user removed. Uninstall (`--cleanup-user`) deletes the user's Active Setup entry, so a reinstall sets them up again.
  - **No UI in the stub:** it runs before the desktop exists and only sets `welcomePending`. The autostart (`--background`) then shows the welcome window.
  - **Idempotent (`planUserSetup`):**

    | Run | What happens |
    |---|---|
    | As SYSTEM | Nothing. |
    | The installer, as a user | Always makes sure of the keyboard and autostart. |
    | Active Setup or app start | Acts only for a user who was never set up. |

  - **Limit:** a user who is already signed in when the Store installs gets the keyboard when they open VietTelex or sign in again.
- **Welcome window (`decideWelcome`):** shown once per user. It offers Telex/VNI, the switch key, the tray icon, other input methods and "Chuyển gõ tắt từ UniKey / OpenKey…".
  - **How to start:** one line says to pick the VietTelex keyboard on the taskbar (ENG/VIE) or with Win+Space, and to quit UniKey & co. A UniKey user has never picked a Windows keyboard; installing leaves Windows on ENG (2026-10 field report: "không gõ được tiếng Việt").
  - **Default keyboard:** when Windows' default input method is another keyboard and the switch key is in the TIP (`welcomeOffersDefaultInput`), a pre-ticked box makes VietTelex the default (`SetDefaultLayoutOrTip`, current session too) when the window closes.
  - `showTrayIcon` stays off by default, but the box is pre-ticked: the tray icon is the only lasting Việt/Anh indicator.
  - Users upgrading from a version without onboarding never see it.
- **Other Vietnamese input methods:** detected only when the welcome window or the Gõ phím page is shown, and never in the background. Three kinds are checked:
  - running UniKey (`UniKeyNT.exe`), EVKey, OpenKey, VKey and GoTiengViet, by process image name;
  - Microsoft's Vietnamese keyboards in the user's list: any enabled vi-VN profile that is not VietTelex (Telex, Number-key, or the legacy layout), found with `ITfInputProcessorProfileMgr::EnumProfiles`;
  - **Windows' own Ctrl+Shift** (`winHotkeyClash`, `HKCU\Keyboard Layout\Toggle`): with our switch key on Ctrl+Shift, a Windows "between input languages" hotkey on Ctrl+Shift flips VIE↔ENG on the same press (the taskbar then says VIE while VietTelex is in Anh), and the default "switch keyboard layout" Ctrl+Shift jumps to a Microsoft Vietnamese keyboard if one is in the list.

  The warning shows on the Gõ phím page and in the welcome window, and opens a task dialog with these actions:
  - open the other app's folder;
  - show how to quit it (from its tray icon) and how to keep it from starting with Windows;
  - remove a Microsoft keyboard from the list with `InstallLayoutOrTip(ILOT_UNINSTALL)`, falling back to `ms-settings:regionlanguage`;
  - take Ctrl+Shift off Windows' hotkeys (`winToggleFix`: languages → Left Alt+Shift, layouts → none), then `SPI_SETLANGTOGGLE`; falls back to `ms-settings:typing`.

  VietTelex never quits or uninstalls other software.
- **"Chuyển từ UniKey" (`app/core/macro_import.*`):** Nhập… reads the formats below. The fixtures in `app/tests/fixtures/macros` are byte-exact.

  | Format | Source | How it is read |
  |---|---|---|
  | UniKey | `ukengine/mactab.cpp` | Header `;DO NOT DELETE THIS LINE*** version=1 ***` with a UTF-8 BOM (Windows build), then `key:text` split at the first colon, untrimmed. |
  | OpenKey | `Macro.cpp` | Header `;Compatible OpenKey Macro Data file for UniKey*** version=1 ***`, then the first-colon split. A key starting with `:` takes the next field. |
  | Generic | — | VietTelex/macOS JSON and YAML, `key:value` and `key<TAB>value` text. |

  - **Encodings:** UTF-8 with or without BOM, UTF-16LE with or without BOM, and UTF-16BE with BOM. Anything else is refused, never imported as mojibake.
  - **Old UniKey files** (VIQR, without the `version=1` line) are imported unconverted, with a warning.
  - **EVKey's** export format could not be checked against public sources. Its files go through the generic path.
  - **UniKey's switch-key setting** is not imported: its registry location could not be checked against public sources.

## Games, fullscreen, V/E indicator

Decisions are pure functions in `app/core/game_logic.*`, the TIP side is `ime/core/game_ipc.h`, and the Win32 side is `app/src/game_mode.cpp` and `switch_toast.cpp`.

- **Tự tắt tiếng Việt khi chơi game toàn màn hình** (`autoOffFullscreen`, default on). VietTelex.exe watches foreground changes with a WinEvent hook, installed only while the setting is on. It asks `SHQueryUserNotificationState`:

  | State | Result |
  |---|---|
  | `QUNS_RUNNING_D3D_FULL_SCREEN` | Keys pass through. |
  | `QUNS_PRESENTATION_MODE`, with a captionless foreground that covers its monitor | Keys pass through. |
  | `QUNS_BUSY` (Chrome F11, YouTube fullscreen, video players) | Typing as usual. |

  - **Late fullscreen:** a game often turns exclusive-fullscreen after it comes to the front. So a new foreground window that covers its monitor gets at most three one-shot re-checks (0.3, 1.5 and 4 s). Nothing polls, and nothing runs per key.
  - **Telling the TIP:** VietTelex.exe posts `kTipSuspendMsg` to the TIP window of the game's threads and sets `VietTelex.Suspend` on its top-level window. A TIP activated later reads that property on focus.
  - **While suspended:** the TIP eats nothing, including Ctrl+Shift and Alt+Z, which games bind. A word in progress is committed as typed, and the hook types nothing. Việt/Anh is never changed, so leaving the game restores everything.
  - **Borderless-window games are not detected.** Use Chế độ game, or "Luôn tiếng Anh" for the game on the Ứng dụng page.
- **Chế độ game** (`gameMode`, Ứng dụng page → Chơi game / toàn màn hình, and an optional hotkey `gameModeHotkey`):
  - **What it does:** every key passes through, in every app. It reaches every TIP through the snapshot, and the foreground TIP at once.
  - **Never stuck on:** it is cleared whenever VietTelex.exe starts, and a TIP ignores it while the app is not running.
  - **Hotkey:** the default is off, because a global hotkey takes its chord away from every app, and Ctrl+Alt is AltGr on some layouts. The choices are `ctrl-alt-g` and `ctrl-shift-alt-g`, never Win+G or Win+Alt+G (Xbox Game Bar).
- **Switch sound** (`switchSound`, off by default, next to the indicator setting): VietTelex.exe plays two synthesised notes (`core/switch_sound.cpp`, `PlaySound` from memory, async), rising for Việt and falling for Anh, at the same four places as the indicator (TIP `UserSwitched`, tray click, portable chord, chord that brings VietTelex in) and never while keys pass through. It took bit 31, the last bit of the first 32-bit bool word of the snapshot; bit 32 on live in a second word (see `autoCircumflex`).
- **Floating V/E indicator** (`switchIndicator`: `auto` by default, `on`, `off`; `auto` means "while the tray icon is hidden").
  - **Trigger:** the TIP posts `AppCommand::UserSwitched` only for a Ctrl+Shift or Alt+Z switch, not for a focus change.
  - **Window:** a click-through, never-activated popup shows V or E for 1 s, below the caret (`GetGUIThreadInfo`) or in the work area's bottom-right corner.
  - **Never shown** over a D3D or presentation fullscreen, or while keys pass through.
  - **Cost:** nothing on the typing path.

## Terminals and AI CLIs (Direct mode Backspace)

- **The bug class:** with other IMEs, a CLI that reads the pty (Claude Code, Gemini CLI, other Node/Ink apps) receives BS `0x08` instead of DEL `0x7F` for Backspace. It does not delete, and the retyped word doubles.
- **What VietTelex sends** (`directEditEvents`, unit-tested): each backspace is `VK_BACK` as a virtual key with scan code `0x0E`, exactly like the physical key. Windows Terminal and conhost's VT input translate it to DEL, and legacy console readers get the same `KEY_EVENT` record. A control character is never sent as `KEYEVENTF_UNICODE`. The text goes as Unicode, and there are no modifier events.
- **New guard (`injectionModifiersSafe`):** a batch is dropped (the word resets) if Ctrl, Alt or Win is down at injection. Otherwise `VK_BACK` would become Ctrl+Backspace (`0x08`, or delete-word in GUI apps) or Alt+Backspace (`ESC DEL`, delete-word in readline).
- **Residual risk, not fixable from the IME:** a CLI that treats one pty read as one key would get "DEL DEL text" together. Windows Terminal stays Direct by default, which means no underline and shell autocomplete intact. For such a CLI, set `windowsterminal.exe` (and `conhost.exe`) to Composition on the Ứng dụng page; then only committed text reaches the app. The override beating the built-in rule is unit-tested.

## Icons

All icons come from the macOS artwork, regenerated by `installer/icons/make_icons.py` (macOS only; it uses `sips`, nothing gets installed).

- **App icon:** `ime/res/viettelex.ico` holds 16–256 px. Sizes that exist as AppIcon PNGs are copied byte for byte; the rest are `sips` downscales. It is used for the exe, the MSI's Add/Remove entry, the Start menu shortcut and the Settings window.
- **Keyboard icon (settings `menuIcon`):** five choices — `vt` (default), `star`, `flag`, `logo`, `vi`. The retired `letter` value migrates to `vt`. The mapping lives in `ime/res/icon_ids.h` and is unit-tested.
  - **Tray icon** (optional, the only Việt/Anh indicator since 1.0.8, when the TIP's separate language-bar item was dropped because it doubled the taskbar icon). It follows the foreground app: the TIP posts `AppCommand::StateChanged`, and the app watches foreground changes. Its tooltip names the state too ("Tiếng Việt (V)" / "Tiếng Anh (E)").
    - **Style `trayIconStyle`** (registry-only, Kiểu gõ → Giao diện): `letter` (default since the 2026-10 field report "không rõ đang E hay V") draws a UniKey-style badge at runtime (`trayBadge`, `CreateBadgeIcon`): an opaque rounded square, white bold **V** on red (Việt) or **E** on blue (Anh), contrast ≥ 4.5:1 and the same on both taskbar themes (unit-tested). `keyboard` follows `menuIcon` as below.
    - **Windows 11** puts a new notification-area icon under the ^ overflow by default; there is no documented API to promote it, so the welcome window and the setting tell the user to drag it onto the taskbar.
    - With `keyboard` it uses theme glyphs `glyph_<vt|star|flag>_<v|e>_<dark|light>.ico`. `dark` is white for the dark taskbar and `light` is dark for the light taskbar, chosen from `SystemUsesLightTheme`; `e` is the English state at 40% opacity. `logo` uses the colour app icon, dimmed in English. `vi` draws "VI"/"EN" text at runtime.
  - **Static profile icon** (Win+Space list): `profile_<choice>.ico`, a white glyph with a dark outline so it reads on both flyout themes. The default is monochrome Vᴛ at IconIndex 13, which a unit test checks against the resource order. Changing the choice in Settings runs `VietTelex.exe --set-profile-icon <choice>` elevated, with one UAC prompt, to update the HKLM IconIndex.

  Why an elevated helper and not a user-writable icon file: the profile icon is loaded into every process, including elevated ones and the secure desktop, and no user-writable file should be parsed there. Installing a new version resets the icon to Vᴛ.
- **Tray icon:** off by default (`showTrayIcon`), but pre-ticked in the welcome window: the taskbar shows only the static keyboard icon, so the tray icon is the only lasting Việt/Anh indicator. Start menu → VietTelex opens Settings. With `startHidden` ("Mở app không hiện cửa sổ Cài đặt", off by default, #159) a plain start stays in the tray; starting the app again while it runs still opens Settings.

## How typing works

- **Composition mode (default):** the word being typed is a TSF composition whose display attribute is `TF_LS_NONE`, so it is not underlined. A word boundary commits `vtx_commit_text`, and the boundary key then goes on to the app.
- **In-place mode (per app):** engine REPLACE actions become "delete N chars before the caret, insert text". Each delete is checked against the text actually on screen; if they differ, the session resets and the key is typed as-is.
- Re-edit (`reEditWord`) follows macOS: only diacritic-only keys (`s f r x j z w`, or VNI digits) re-open the word before the caret. ⌫ right after a boundary re-opens the last word.
- The keyboard hook (portable build, Direct / hook-fallback apps) cannot read text, so it only has the ⌫ part, from its own record (`app/core/hook_reopen.h`): the last 3 words it committed and the separators typed after them (space `. , ; : ! ?`, up to 4). ⌫ that deletes the last separator after a word puts the word back in the engine; ⌫ through it walks on to the word before. A click, arrows / Home / End / Delete / Insert, Enter / Tab / Esc, any Ctrl / Alt / Win combination, Alt or Win alone, other keys, a focus change, foreign injected input, English mode, a settings change or any failed edit forgets the record.
- Literal fields: password, PIN, number, telephone, e-mail. Two exceptions are deliberate:
  - `IS_URL` is not literal, because the Chrome/Edge address bar is where people search in Vietnamese.
  - `IS_PRIVATE` is not literal, because it only means "do not learn" (InPrivate windows).
- The TIP registers with the US layout as substitute. Keys it passes through therefore never go through the stock Vietnamese layout, which would turn `1` into `ă`.
- **Switch hotkey (`switchHotkey`):**
  - `ctrl-shift` (default): a clean press-and-release, detected inside the TIP.
  - `win-space`: the system switcher.
  - `alt-z`: a TSF preserved key.
  - `off`.
- Vietnamese/English is remembered per exe under `HKCU\Software\VietTelex\AppLanguage`. It is kept in memory only inside AppContainers and on the secure desktop.

## Settings

- `VietTelex.exe` writes `HKCU\Software\VietTelex`: one value per key, with `shortcuts` and `appModes` stored as REG_BINARY JSON.
- It also writes a binary snapshot to `%LOCALAPPDATA%\VietTelex\settings.bin`. The folder ACL grants read access to ALL (RESTRICTED) APPLICATION PACKAGES.
- The TIP only parses the snapshot, so there is one parser for normal and AppContainer processes. It re-checks the file's timestamp on focus change and after a menu command. There is no timer and no polling.
- Deviation from spec §9: the TIP does not read the registry directly.
- **UI language** (`uiLanguage`, the "Ngôn ngữ / Language" picker, Typing tab): `vi` by default whatever the Windows display language, `en` switches the Settings window and the tray menu immediately. All strings, including the text tools, live in `app/src/strings.cpp` in both languages, and a `static_assert` keeps the table complete.
- `addTonesHotkey`, `gameModeHotkey` and `switchIndicator` are registry-only: they are not in the TIP snapshot. `autoOffFullscreen` and `gameMode` are appended snapshot bits. `textToolsInMenu` and the five caret-hint switches are appended snapshot bits (an older snapshot leaves them at their defaults). `systemTextPrediction` (bit 24) mirrors the Windows text-suggestion setting: it is only in the snapshot, never stored under `HKCU\Software\VietTelex`.
- **Tự sửa từ phía trước** (`retroactiveEnglish`, bit 27, experimental, default off; docs/DESIGN.md "Sửa ngược tiếng Anh"). Settings → Gõ phím → Gõ lẫn tiếng Anh → Nâng cao (Chính tả before 05/11/2026) shows it right under "Quyết định theo ngữ cảnh", and only while that is on. `VTX_RETRO_ENGLISH` is set whenever `contextualEnglish` is on (off = nothing); the switch picks auto-apply or offer. The TIP (`TypingSession`, `ime/core/retro_english.h`) reports every boundary character to the engine: keys it handles anyway through `handleKey`, keys it lets through with one engine call (`noteKeyPassedBy`, no edit session), so the cost when nothing is pending stays one call per boundary key. A correction is used only at a typed boundary (space or punctuation) and only when the text before the caret reads back exactly as the engine's `expected`; Enter and Tab only end the phrase. Switch **on**: applied ("Hí cả í very fast" → "His car is very fast"); a ⌫ as the very next key reverts it, only if the text before the caret still ends with what was inserted plus the boundary. Switch **off**: offered as a caret hint (`hints::Kind::Retro`, "His car is"), shown after the app typed the boundary; Tab re-reads the text and applies it, any other key hides it. It wins over every other caret hint of that key (`hints::withRetro`), and shows even when the other caret hints are off. Never in the hook (Direct / HookFallback), in console / composition-only contexts, on the secure desktop, or in terminals, remote viewers and games (`retro::allowedForApp`).
- **Đoán từ trùng theo tần suất** (`englishByFrequency`, bit 28, experimental, default off; engine `englishByFrequency`). Shown right under "Tự sửa từ phía trước", with the same condition. `VTX_ENGLISH_BY_FREQUENCY` is set only when the switch is on and `VTX_RETRO_ENGLISH` is (off = the engine pays one bool test per commit). At the start of a phrase a word that is both a common English word and a rare Vietnamese syllable commits as English ("His car…"); when the next word shows the phrase is Vietnamese (a known pair "hí hửng", or a repeat "hí hí") the engine hands back a retro edit with `flip_back = 1`. `TypingSession::finishRetro` applies a flip-back automatically through the same verified delete + insert, even in offer mode, and also on Enter / Tab / Esc — before the key goes through (`vtx_forget_last_commit` waits until then). Same field rules as above (never blind, never unverifiable).
- **Bắt đầu bằng tiếng Anh trong app mới** (`startEnglish`, bit 29, default off): an app with no remembered Việt/Anh state (`AppLanguage`) starts in English (`config::init` reads it after the first snapshot load). Set by the onboarding profile `en`.
- **Tự thêm dấu mũ** (`autoCircumflex`, bit 32, default off; engine `autoCircumflex`, issue #166). Settings → Gõ phím → Kiểu gõ → Nâng cao, under the `[` `]` switch. `VTX_AUTO_CIRCUMFLEX` is set only when the switch is on (off = the engine pays one bool test per render). Once the word has a live tone and the plain rime is not a Vietnamese syllable while the circumflexed one is, the circumflex shows: "vietj" → việt, "nguyenx" → nguyễn, "benhj" → bệnh, "luanj" → luận; "quanr" → quản stays. Render-only: parse state, ⌫ and typing the full "ee"/"aa" behave as before; keys with an English reading still restore at the boundary. It is the first bool of the snapshot's second word, which `serialize()` appends after the appModes block (only when there are more than 32 bools); an older TIP stops at bit 31 and ignores the trailing word, and a 32-bool snapshot leaves the switch off.
- **Onboarding** (docs/ONBOARDING-SPEC.md, `app/core/onboarding.h` `decideOnboarding`): a new user's welcome window goes on with "Bạn thường gõ thế nào?" (vi / mixed / en — `applyProfile` writes the switches) and "Gõ thử". Registry: `onboardingDone` (0 while a new user's run is unfinished), `onboardingProfile` (display only), `mixedCardPending` (one-time card on Kiểu gõ for users set up by a version without onboarding; their values are never changed). The mixed-typing switches live in Kiểu gõ → **Gõ lẫn tiếng Anh**: auto-restore, collisions, context, fix earlier words, frequency, the switch key, start in English.

## ARM64 (supported from v1)

Windows on ARM runs native ARM64 apps and emulated x64 apps side by side, and both read the same 64-bit `InprocServer32` path. The ARM64 MSI therefore installs three DLLs:

| File | What |
|---|---|
| `VietTelexTIP.dll` | ARM64X **pure forwarder**. This is the registered COM server. |
| `VietTelexTIP_arm64.dll` | The real TIP for native ARM64 apps. |
| `VietTelexTIP_x64.dll` | The real TIP for emulated x64 apps. It is the x64 build, renamed. |

The forwarder follows Microsoft's "Arm64X pure forwarder DLL" recipe. `ime/src/arm64x/empty.cpp` is compiled once for ARM64 and once for ARM64EC. The two objects are linked with `/MACHINE:ARM64X /DEFARM64NATIVE:arm64_exports.def /DEF:x64_exports.def` into one DLL, and the linker needs `_load_config_used`, or the loader cannot see the EC view.

- **Release (macOS):** `scripts/cross-build.sh` does this with llvm-mingw's `lld-link`. It takes the load config from the ARM64X-aware mingw-w64 CRT, then checks that the result is COFF-ARM64X, carries CHPE metadata, and forwards native exports to `_arm64` and EC exports to `_x64`.
- **Windows dev builds:** MSVC ARM64 builds do the same through CMake (`ime/CMakeLists.txt`).
- **Registration:** the MSI registers the forwarder as `InprocServer32`. The icon comes from `VietTelexTIP_arm64.dll`, which is exactly what `DllRegisterServer` in the arm64 half writes (`ime/core/com_path.h`).
- 32-bit x86 apps use the separately registered x86 DLL, as on x64 machines.

## Microsoft Store

VietTelex is submitted as a Partner Center **"MSI or EXE app"** that points at the signed MSI. Requirements:

- a signed MSI (Azure Trusted Signing),
- a versioned, HTTPS, immutable download URL per architecture: Partner Center uses the no-redirect website mirror `https://viettelex.com/download/windows/<VERSION>/VietTelex-<VERSION>-<arch>.msi` (`docs/download/windows/`); the same bytes are the GitHub release assets under tag `windows-v<VERSION>` (used by `docs/stable.json`, winget and Chocolatey); never replaced,
- silent install `msiexec /i <msi> /qn /norestart` and uninstall `msiexec /x {ProductCode} /qn`.

Checklist and listing text: [installer/STORE.md](installer/STORE.md). Package managers: `installer/winget/submit.sh` (generates + validates the winget-pkgs manifests, prints the PR commands) and `installer/chocolatey/update.sh` (bumps the Chocolatey package); neither publishes anything. An MSIX package cannot register a system-wide TSF text service, so `installer/msix/AppxManifest.xml` is an **optional, companion-only** template and is not part of the submission.

## Needs a real Windows machine

- Everything in the TSF layer: activation, composition behaviour, OnEndEdit caret tracking, input scopes, the taskbar V/E button, and hotkey semantics. In particular, confirm that a key which `OnTestKeyDown` claims and `OnKeyDown` then does not eat still reaches the app. (#134: in IMM32/CUAS apps it does not — handled for the fields the TIP recognises as such; still to confirm on TSF-native hosts.)
- The spec §5.2 app matrix.
- **MSI install and uninstall on Windows.** Export `HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}` after `regsvr32 VietTelexTIP.dll` and after an MSI install, then diff the two. The values to confirm are `SubstituteLayout` (stored as a DWORD) and the `Enable` values.
- **Chrome underline.** Web page fields are in place (no composition). The address bar draws an underline under any composition (#173, Edge on Windows 10 22H2), so it is typed by the hook. Check in Edge and Chrome, with debug logging on: `thees` while a suggestion shows gives `thế` with no underline and no stray character; `google` + Enter navigates to google; ⌫ while a suggestion shows removes only the suggestion; typing with no suggestion; editing mid-text (caret moved with the arrows); the log shows `the hook types here` / `address bar (inline autocomplete)` and no `verify` line for the address bar. Quit VietTelex.exe: the address bar composes again (underline expected).
- **Store installs (Active Setup).** After a `/qn` install as SYSTEM, sign out and in (or sign in as a second user): the keyboard must be in the list without opening VietTelex, the welcome window must appear once the desktop is up, and `HKCU\Software\Microsoft\Active Setup\Installed Components\{D1246D27-…}` must hold `Version=1,0`. Remove the keyboard by hand, sign out and in: it must not come back. Upgrade the MSI: the stub must not run again.
- **Onboarding:** the welcome window (DPI, keyboard navigation), conflict detection with UniKey/EVKey/OpenKey running, and with Microsoft's Vietnamese Telex / Number-key keyboard in the list — including that "remove from list" (InstallLayoutOrTip ILOT_UNINSTALL) really removes it, and falls back to ms-settings otherwise. Import a real UniKey (`Lưu` from its macro dialog) and OpenKey export.
- **2026-10 UniKey-user report** (fresh install, "không gõ được tiếng Việt / không chuyển được bằng Ctrl+Shift / không rõ E hay V"):
  - Fresh user, Windows default ENG: the welcome box "Đặt VietTelex làm bàn phím mặc định" really switches the current session and new apps to VietTelex (`SetDefaultLayoutOrTip` flags 0), and Notepad types Vietnamese at once.
  - Set Windows' "Between input languages" to Ctrl+Shift (Advanced keyboard settings → Input language hot keys): the Gõ phím page shows the warning; "Bỏ Ctrl+Shift khỏi phím tắt của Windows" changes it to Left Alt+Shift without a sign-out (`SPI_SETLANGTOGGLE`), and Ctrl+Shift then only toggles V/E.
  - With the default "Switch keyboard layout" Ctrl+Shift and only VietTelex in vi-VN: whether the TIP's key sink still sees the Ctrl/Shift events (it must, or the in-TIP toggle never fires).
  - UniKey running with its default Ctrl+Shift: both toggle on one press; confirm the warning text says so.
  - The tray badge at 100/125/150/200% DPI on light and dark taskbars, V red / E blue clearly readable, the tooltip state, and the Windows 11 ^ overflow hint.
- **Games / fullscreen:** a D3D exclusive-fullscreen game (WASD not eaten, Ctrl+Shift not toggling), Alt+Tab out and back, Chrome F11 / YouTube fullscreen still typing, a PowerPoint slideshow, the Chế độ game hotkey, the V/E indicator near the caret (Notepad) and in the corner (Chrome), never stealing focus.
- **Terminals + AI CLIs:** Claude Code / Gemini CLI in Windows Terminal and in a legacy conhost window, Direct mode (default) and with `windowsterminal.exe` set to composition.
- **Word prediction:**
  - Turn "Show text suggestions when typing on the physical keyboard" on and off. Confirm that it writes `EnableHwkbTextPrediction`, and that VietTelex follows it after the next focus change.
  - On a fresh profile, where the value is missing, nothing is suggested.
  - Check Notepad, Word, Chrome/Edge and a UWP field:
    - the popup shows after a 0.3 s pause and never while typing steadily;
    - the popup shows one word; Tab or a click inserts it, without stealing focus;
    - Enter, the arrow keys and digits pass through;
    - `Tên ` (one context word, no seed) shows nothing; `cảm ` shows `ơn`; `cảm ơn ` shows a word;
    - Tab on a suggestion, then `.`: `được. ` (no space before the period).
  - Check that nothing shows in VS Code, Windows Terminal or password fields.
  - Learning: type `tên tôi ` twice (Enter between), then `Tên ` suggests `tôi`; `%LOCALAPPDATA%\VietTelex\learned-words.bin` appears ~5 s later; "Xoá từ đã học…" removes it and the suggestion. Typing in a password field, VS Code or Windows Terminal adds nothing (check the file size).
- **Caret hints:** that the popup sits at the caret (GetTextExt) in Notepad, Word, WordPad, Chrome/Edge, VS Code and a UWP/WinUI field. Check too that it never steals focus, that Tab/Enter/Esc are eaten only while it shows, and that Tab replaces exactly the suggested text.
- **Text tools:**
  - The TSF path in Word, Notepad, WordPad (classic RichEdit through the parent context), Chrome/Edge/VS Code (Chromium TSF) and a UWP/WinUI field.
  - The clipboard fallback in a Qt/Java app with ENG active, including that the original clipboard (text, image, files) comes back.
  - The tray path's refocus.
  - That clipboard history (Win+V) skips our content.
  - That Ctrl+Shift+T does not also toggle Việt/Anh.
- The ARM64X forwarder on Snapdragon hardware: check that both a native ARM64 app and an emulated x64 app (e.g. an x64-only Electron app) type Vietnamese, and that the forwarded DLLs load from the install folder.
