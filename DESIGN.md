# VietTelex — Design Spec

Bộ gõ tiếng Việt cho macOS. Ưu tiên tuyệt đối: **performance** (latency, CPU, RAM) và **simplicity**. Target: Mac App Store.

## Scope (MVP — không thêm gì ngoài list này)

- Kiểu gõ: **Simple Telex, strict** (aa→â, aw→ă, dd→đ, ee→ê, oo→ô, ow→ơ, uw/w→ư, s/f/r/x/j = sắc/huyền/hỏi/ngã/nặng, z = xóa dấu). Không VNI, không hỗn hợp.
- Bảng mã: **Unicode dựng sẵn (NFC precomposed)** duy nhất.
- Chế độ: Bật/Tắt only.
- Settings: hotkey toggle, nhớ on/off theo app (bundle ID), option auto-restore từ không hợp lệ, bảng gõ tắt.
- KHÔNG làm: nhớ theo browser tab (IME không thấy được tab — đã quyết định bỏ), check update (App Store tự lo), từ điển file (dùng phonotactic validator).

## Kiến trúc

```
VietTelex.app  (một bundle duy nhất, LSUIElement, sandbox)
├── IMKServer + TelexInputController   ← process do macOS launch khi user chọn input source
├── TelexEngine (pure Swift, không import Foundation trên hot path)
├── SyllableValidator (rule-based, không dictionary)
├── SettingsWindow (SwiftUI, chỉ tạo khi mở từ menu Input Method)
└── HotkeyManager (Carbon RegisterEventHotKey — sandbox-safe)
```

Quy tắc cứng:
1. **Một process duy nhất.** Không helper app, không XPC, không login item ( input method được macOS tự khởi động — "start on boot" tự có).
2. **Không timer, không polling, không background thread thường trực.** Toàn bộ event-driven.
3. **Không NSStatusItem.** Dùng menu do IMK cung cấp (icon trên input menu của hệ thống): các item Bật/Tắt (checkmark), Settings…, About.
4. Settings UI chỉ được instantiate khi user mở; đóng là giải phóng.

## Hot path — `handle(_ event: NSEvent, client:) -> Bool`

Đường đi mỗi keystroke, budget **< 50µs, zero heap allocation**:

1. Nếu OFF hoặc có modifier (⌘⌃⌥) → return false (passthrough), reset buffer khi cần.
2. Map keycode/char → feed vào `TelexEngine`.
3. Engine trả về một trong:
   - `.passthrough` — trả false cho hệ thống tự xử lý
   - `.replace(count: Int, text: <fixed buffer>)` — gọi `client.insertText(_:replacementRange:)` thay `count` ký tự cuối bằng text mới
4. Word boundary (space/enter/punct/click/focus đổi): commit, chạy validator + bảng gõ tắt, reset buffer.

Yêu cầu implementation cho Engine:
- `struct TelexEngine`, buffer là `InlineArray`/fixed `[Unicode.Scalar]` capacity 32, **không** dùng `String` interpolation/regex/NSString trên hot path.
- Bảng biến đổi nguyên âm + đặt thanh là `static let` lookup tables (mảng phẳng index theo scalar value), build sẵn lúc compile hoặc lazy một lần.
- Đặt dấu thanh theo quy tắc **kiểu cũ** (òa, úy — "hòa" không phải "hoà"). Không có setting đổi kiểu — giữ simplicity.
- Double-key để hủy (aaa → aa, ss → s giữ nguyên như Telex chuẩn strict).
- Backspace: pop buffer, engine tự tính lại, không re-parse cả từ từ client.

**Không dùng marked text** (setMarkedText): gây gạch chân + hành vi khác nhau giữa app. Chỉ dùng `insertText(replacementRange:)`. Nếu client trả `NSNotFound` cho selectedRange (app không hỗ trợ replacementRange — hiếm), fallback: gửi backspace count + text qua chính insertText từng phần. Test kỹ trên: TextEdit, Safari, Chrome, Terminal, VS Code, Xcode, Slack, MS Word.

## SyllableValidator (thay từ điển)

Âm tiết tiếng Việt đóng theo luật → validate bằng phonotactics, không cần file:
- Parse: onset (∅, b, c, ch, d, đ, g/gh, gi, h, kh, l, m, n, ng/ngh, nh, p, ph, qu, r, s, t, th, tr, v, x) + nucleus (bảng vần hợp lệ) + coda (∅, c, ch, m, n, ng, nh, p, t) + tone.
- Luật kết hợp: coda p/t/c/ch chỉ đi với sắc/nặng; c/k/gh/ngh theo nguyên âm; bảng vần hợp lệ hard-code (~160 vần).
- Nếu option "auto-restore" bật và từ commit không parse được → thay bằng chuỗi phím raw (engine giữ raw keystrokes song song trong buffer thứ hai cùng capacity).
- Chi phí: O(độ dài từ) một lần mỗi word boundary. Zero RAM ngoài static tables.

## State & Settings

- `UserDefaults` (suite riêng): hotkey, autoRestore, shortcuts `[String: String]`, perApp `[String: Bool]` (bundleID → on/off), globalDefault on/off.
- Per-app: đọc khi `activateServer(client)` (lấy bundleID của client), ghi **debounce 500ms** khi toggle — không ghi disk mỗi lần bấm hotkey liên tục.
- Bảng gõ tắt: load một lần vào `[String: String]` khi start + khi settings thay đổi (Darwin notification / KVO trên UserDefaults). Chỉ tra ở word boundary.
- Hotkey: `RegisterEventHotKey` (Carbon, hoạt động trong sandbox, không cần Accessibility permission). Default: ⌃⇧Space. UI record hotkey trong Settings.

## UX

- **Toggle feedback**: HUD nhỏ (NSPanel non-activating, `.hudWindow`) hiện "VI" / "EN" giữa màn hình đang focus, fade out 800ms. Respect Reduce Motion (không animation nếu bật). Không sound.
- Menu input method: `✓ Tiếng Việt` / `Tắt (English)` / separator / `Bảng gõ tắt…` / `Cài đặt…` / `Giới thiệu`.
- Settings window (SwiftUI, 3 tab): **Chung** (hotkey recorder, auto-restore toggle, mặc định bật/tắt cho app mới), **Gõ tắt** (table thêm/xóa/sửa, import/export plist), **Ứng dụng** (list app đã nhớ trạng thái, xóa từng dòng).
- Khi user gõ trong secure field (password): IMK tự bypass — không xử lý gì thêm, không log.

## Performance budgets (phải đo, không ước)

| Metric | Target | Cách đo |
|---|---|---|
| Keystroke latency (engine) | < 50µs p99 | unit benchmark (XCTest measure) |
| RSS sau 1h dùng | < 20MB | Activity Monitor / `footprint` |
| CPU idle | 0.0% | không timer nào tồn tại |
| Wake-up khi không gõ | 0/s | Instruments |
| Cold start (chọn input source → gõ được) | < 300ms | log timestamp |

## Privacy (điểm review App Store + selling point)

- Zero network. Zero log keystroke. Không Analytics SDK. Entitlements tối thiểu: sandbox + không network client.
- Privacy manifest khai báo rõ. README/store description: "Không thu thập bất kỳ dữ liệu nào."

## Packaging (cần verify với docs Apple hiện hành)

- Info.plist: `InputMethodConnectionName`, `InputMethodServerControllerClass`, `tsInputMethodIconFileKey`, `LSBackgroundOnly`/`LSUIElement`, `ComponentInputModeDict` với mode "vi".
- MAS: app cài vào /Applications, lần đầu mở hiện hướng dẫn add input source (System Settings → Keyboard → Input Sources). Verify quy trình MAS-distributed input method mới nhất trước khi hard-code.

## Testing

1. **Engine unit tests** — golden table, tối thiểu các case:
   - `ddaay` → `đây`, `tieengs` → `tiếng`, `vieejt` → `việt`, `hoas` → `hóa`, `huyeenf` → `huyền`, `nguwowif` → `người`, `quaan` → `quân`, `thuowr` → `thuở`
   - Hủy dấu: `aa`+`a` → `aa`, `as`+`s` → `as`, `az` → `a`
   - Restore: `windows` (không phải âm tiết Việt) → giữ nguyên khi autoRestore on
   - Backspace giữa chừng, gõ hoa/thường lẫn (ĐÂY, Đây)
2. **Validator tests**: đủ bảng vần, coda-tone constraints.
3. **Benchmark test** cho latency budget.
4. Manual checklist per-app (danh sách app ở trên).

## Thứ tự implement

1. `TelexEngine` + `SyllableValidator` + full unit tests + benchmark (thuần Swift package, chạy được bằng `swift test` không cần Xcode GUI)
2. Xcode project: IMK skeleton, gõ được trong TextEdit
3. Per-app state + hotkey + HUD
4. Settings UI + bảng gõ tắt
5. Sandbox/entitlements, icon, MAS packaging
