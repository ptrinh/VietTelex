# VietTelex — Design

Bộ gõ tiếng Việt cho macOS. Ưu tiên tuyệt đối: **performance** (latency, CPU, RAM) và **simplicity**.

## Phạm vi

- Kiểu gõ: **Telex** đầy đủ (mặc định): aa→â, aw→ă, dd→đ, ee→ê, oo→ô, ow→ơ, uw→ư,
  `w` đầu từ → ư, s/f/r/x/j = sắc/huyền/hỏi/ngã/nặng, z = xóa dấu. Tùy chọn
  **Simple Telex** (OFF mặc định): `w` lẻ giữ nguyên. **Bỏ dấu tự do** ON mặc định
  (dấu/mũ gõ muộn tự tìm về nguyên âm — `dauas`→dấu). Hỗ trợ teencode qua onset
  mapping (wá→quá, zô→dô, dzị→dị) và whitelist `đc`; từ tiếng Anh va chạm
  (was/wow/yes) force-restore. Không VNI, không hỗn hợp.
- Bảng mã: **Unicode dựng sẵn (NFC precomposed)** duy nhất.
- Tùy chọn: Simple Telex, bỏ dấu tự do, kiểu bỏ dấu cũ/mới (hòa/hoà), kiểm tra chính tả
  khi gõ, tự khôi phục từ không hợp lệ, bảng gõ tắt.
- **Không có bật/tắt VI/EN nội bộ, không hotkey riêng**: Vietnamese bật khi VietTelex là
  input source đang chọn; chuyển input source để gõ tiếng Anh (macOS nhớ theo app).
- KHÔNG làm: nhớ theo browser tab (IME không thấy được tab), từ điển file
  (dùng phonotactic validator).

## Kiến trúc

```
VietTelex.app  (một bundle duy nhất, LSUIElement)
├── IMKServer + TelexInputController   ← process do macOS launch khi user chọn input source
│     đường IMKit: in-place insertText (mặc định) hoặc marked-text (app học được qua probe)
├── TerminalTapController              ← CGEventTap cho terminal / Chromium / Excel
│     (cần quyền Accessibility — chỉ bản Developer ID; bản sandbox tự rơi về marked-text)
├── TelexEngine        (TelexCore — pure Swift, zero-heap hot path)
├── SyllableValidator  (rule-based, không từ điển)
├── AppState           (UserDefaults, cache in-memory, học chiến lược per-app;
│     rule mặc định load từ typing-modes.yml bundle — sửa rule = sửa data, không sửa Swift)
└── SettingsWindow     (SwiftUI: Chung, Gõ tắt + khi bật "tính năng nâng cao":
      Bảng cơ chế gõ, Thử Nghiệm; chỉ tạo khi mở, đóng là giải phóng)
```

Quy tắc cứng:
1. **Một process duy nhất.** Không helper app, không XPC, không login item (input method
   được macOS tự khởi động).
2. **Không timer, không polling trên đường gõ.** Toàn bộ event-driven. Ngoài main
   có đúng MỘT thread thường trực: run loop của event tap (ngủ trong mach_msg,
   zero CPU khi idle) — để callback tap không xếp hàng sau XPC IMKit ~2ms/phím
   trên main (jitter terminal + nguy cơ macOS disable tap vì callback chậm).
   Shared state giữa hai thread đều có lock (AppState, Accessibility,
   SpotlightDetector, FrontmostApp, SyntheticKeyboard, activation). Hai ngoại lệ
   có chủ đích, đều KHÔNG chạy khi idle thuần: watchdog 3s trên main CHỈ tồn tại
   khi tap đang sống (phát hiện revoke quyền — xem lịch sử treo bàn phím), và
   auto-update check theo tuần (opt-in, throttle bằng timestamp lúc activate).
3. **Không NSStatusItem.** Dùng menu do IMK cung cấp: dòng tình trạng (quyền
   Accessibility) + Cài đặt….
4. Settings UI chỉ instantiate khi user mở; đóng là giải phóng.

## Chiến lược gõ theo app (5 đường, tự học)

| Đường | Áp dụng cho | Cơ chế |
|---|---|---|
| **In-place** (mặc định) | App Cocoa chuẩn (TextEdit, Safari, Mail…) | `insertText(_:replacementRange:)`, không gạch chân, track anchor cục bộ |
| **Marked text** | App bỏ qua replacementRange, khi KHÔNG có quyền AX | `setMarkedText`, có gạch chân tạm khi gõ |
| **Tap: backspace-retype** | Terminal, iTerm, Electron (Lark/Slack/Discord/VSCode) — cần AX | CGEventTap chặn phím, synth Backspace×N + Unicode |
| **Tap: selection-replace** | Address bar browser (qua `axDetect` per-field) — cần AX | Shift+←×N chọn rồi ghi đè — né race với inline autocomplete; D1 gộp burst thành 1 AX write (default ON) |
| **Tap: empty-reset** | Excel (cần AX) | Chèn U+202F hủy suggestion rồi Backspace-retype (Shift+← trong ô sẽ chọn ô kề) |

- Rule mặc định per-app nằm trong **`typing-modes.yml`** (repo root, bundle vào app,
  đính kèm release) — đóng góp rule = sửa plist, không sửa Swift. Mode `axDetect`
  dò theo Ô đang focus (address bar → selection, nội dung trang → in-place).
- App chưa phân loại được **probe** (2 tầng: verdict sơ bộ sync từ read-back/caret —
  honored cần xác nhận ở 2 offset khác nhau, chống caret rác hằng số kiểu Lark;
  AX ground truth async override sau). Kết quả persist (`probedApps` / `fallbackApps`).
- **Remote desktop / VM / screen-share** (`ClientPolicy.forcePassthroughBundleIDs`):
  forward scancode thô nên IME passthrough hoàn toàn.
- **Secure input** (password field): kiểm tra `IsSecureEventInputEnabled()` đầu
  `handle()` — bypass sạch, không xử lý, không log.

## Hot path — `handle(_ event:client:) -> Bool`

Đường đi mỗi keystroke, budget **< 50µs, zero heap allocation** (đo thực tế:
xem [`BENCHMARKS.md`](BENCHMARKS.md)):

1. Synthetic event của chính mình / secure input / remote desktop / modifier (⌘⌃⌥)
   → passthrough, reset khi cần.
2. Map keycode/char → feed vào `TelexEngine`.
3. Engine trả về `.passthrough` / `.none` / `.replace(backspaces, insert)` — diff tối
   thiểu giữa render mới và text đang trên màn hình.
4. Word boundary (space/enter/punct/click/focus đổi): commit, chạy validator + bảng
   gõ tắt, reset buffer.

Yêu cầu engine:
- `struct TelexEngine`, buffer cố định capacity 32, **không** String
  interpolation/regex/NSString trên hot path.
- Bảng biến đổi nguyên âm + đặt thanh là `static let` lookup tables, build một lần.
- Double-key hủy dấu (aaa→aa, ss→s) + latch: từ đã hủy dấu là tiếng Anh, các phím sau
  literal.
- Backspace xóa nguyên ký tự hiển thị cuối (không chỉ pop một phím raw), re-render.

Quy tắc ổn định đã rút ra khi implement (chi tiết trong `MACOS_IME_NOTES.md`):
- Mọi edit đi qua **một kênh có thứ tự duy nhất** (không trộn passthrough hệ thống với
  insertText của mình — race khi gõ nhanh làm "được"→"đựoc").
- Không gọi `selectedRange()` sau mỗi insert (caret stale khi gõ nhanh) — track anchor
  cục bộ, chỉ đọc một lần ở phím đầu của từ.
- Tap callback phải O(1); event synth phải đóng dấu timestamp tăng nghiêm ngặt để
  window server không đảo thứ tự.

## SyllableValidator (thay từ điển)

Âm tiết tiếng Việt đóng theo luật → validate bằng phonotactics, không cần file:
- Parse: onset (∅, b, c, ch, d, đ, g/gh, gi, h, kh, l, m, n, ng/ngh, nh, p, ph, qu, r,
  s, t, th, tr, v, x) + rime (bảng ~180 vần hợp lệ hard-code) + tone.
- Ràng buộc: coda p/t/c/ch chỉ đi với sắc/nặng.
- `isValidSyllable` dùng ở ranh giới từ cho auto-restore; `isValidPrefix` (fold nguyên
  âm về gốc để chấp nhận trạng thái Telex trung gian) dùng cho live spell-check.
- Chi phí: O(độ dài từ), zero RAM ngoài static tables.
- Hạn chế cố hữu (chấp nhận): từ tiếng Anh trùng âm tiết Việt hợp lệ (`test`→tét,
  `list`→lít) không khôi phục được — cần từ điển/tần suất, ngoài phạm vi.

## State & Settings

- `UserDefaults` (suite riêng): autoRestore, freeMarking, modernOrthography,
  liveSpellCheck, simpleTelex, shortcuts `[String: String]`, fallbackApps, probedApps.
- Cache in-memory load một lần; hot path chỉ đọc cache, không đọc disk.
- Bảng gõ tắt chỉ tra ở word boundary.

## Performance budgets (phải đo, không ước)

| Metric | Target | Thực tế | Cách đo |
|---|---|---|---|
| Keystroke latency (engine) | < 50µs p99 | **0.27µs** (xem BENCHMARKS.md) | unit benchmark (XCTest measure, release) |
| RSS sau 1h dùng | < 20MB | chưa đo | Activity Monitor / `footprint` |
| CPU idle | 0.0% | không timer nào tồn tại | Instruments |
| Cold start (chọn input source → gõ được) | < 300ms | chưa đo | log timestamp |

## Privacy

- Zero network trên đường gõ (chỉ gọi mạng khi user bấm *Kiểm tra cập nhật* — GitHub Releases API, xem `Updater.swift`). Zero log keystroke. Không Analytics SDK.
- `PrivacyInfo.xcprivacy` khai báo zero data collection / zero tracking.
- Store description: "Không thu thập bất kỳ dữ liệu nào."

## Ngoài phạm vi (đã quyết định không làm)

- Phím ngoặc `[`→ơ `]`→ư, quick consonants (f→ph, w→qu, g→ng), `oo` literal cho từ mượn
  (xoong, boong), macro auto-caps, tự viết hoa đầu câu.
- VNI (phím 6/7/8/9), Quick Telex (cc=ch, gg=gi), smart switch EN/VI, Dvorak,
  Windows/Linux.

## Testing

1. **Engine unit tests** (`TelexCore/Tests`) — golden table: biến đổi cơ bản, hủy dấu,
   lan horn ươ, ràng buộc coda-tone, w-lẻ, auto-restore từ hiếm hợp lệ, free-marking,
   modern orthography, live spell-check (corpus 40+ từ), Simple Telex.
2. **Validator tests**: đủ bảng vần, coda-tone constraints.
3. **Benchmark test** cho latency budget — kết quả ghi vào `BENCHMARKS.md`.
4. **App-target tests** (`AppTests/`, chạy qua `xcodebuild test`): ma trận routing
   per-app × quyền AX, import plist idempotent, Updater (network stub), DebugLog.
   TelexCore ~99% line coverage; phần IMK/tap plumbing loại trừ có chủ đích.
5. Manual checklist per-app: `checklist.md`.
