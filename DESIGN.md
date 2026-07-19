# VietTelex — Design

Bộ gõ tiếng Việt cho macOS. Ưu tiên tuyệt đối: **performance** (latency, CPU, RAM) và **simplicity**.

## Phạm vi

- Kiểu gõ: **Telex** (mặc định Simple Telex — `w` lẻ giữ nguyên, gõ `uw` để ra `ư`):
  aa→â, aw→ă, dd→đ, ee→ê, oo→ô, ow→ơ, uw→ư, s/f/r/x/j = sắc/huyền/hỏi/ngã/nặng,
  z = xóa dấu. Không VNI, không hỗn hợp.
- Bảng mã: **Unicode dựng sẵn (NFC precomposed)** duy nhất.
- Tùy chọn: Simple Telex, bỏ dấu tự do, kiểu bỏ dấu cũ/mới (hòa/hoà), kiểm tra chính tả
  khi gõ, tự khôi phục từ không hợp lệ, phát hiện từ tiếng Anh (Rule A), bảng gõ tắt
  (kèm auto-caps), whitelist từ ngoại lệ.
- Tiện ích không cần setting (luôn bật): resume từ trước bằng Backspace-sau-space,
  Ctrl-tap bỏ qua biến đổi cho một từ, guard 4+ phím lặp (jjjj trong vim),
  tolerance phụ âm mượn z/w/j/f.
- **Không có bật/tắt VI/EN nội bộ, không hotkey riêng**: Vietnamese bật khi VietTelex là
  input source đang chọn; chuyển input source để gõ tiếng Anh (macOS nhớ theo app).
- KHÔNG làm: nhớ theo browser tab (IME không thấy được tab), check update, từ điển file
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
├── AppState           (UserDefaults, cache in-memory, học chiến lược per-app)
└── SettingsWindow     (SwiftUI, 2 tab: Chung + Gõ tắt; chỉ tạo khi mở, đóng là giải phóng)
```

Quy tắc cứng:
1. **Một process duy nhất.** Không helper app, không XPC, không login item (input method
   được macOS tự khởi động).
2. **Không timer, không polling, không background thread thường trực.** Toàn bộ event-driven.
3. **Không NSStatusItem.** Dùng menu do IMK cung cấp: dòng tình trạng (quyền
   Accessibility) + Cài đặt….
4. Settings UI chỉ instantiate khi user mở; đóng là giải phóng.

## Chiến lược gõ theo app (5 đường, tự học)

| Đường | Áp dụng cho | Cơ chế |
|---|---|---|
| **In-place** (mặc định) | App Cocoa chuẩn (TextEdit, Safari, Mail…) | `insertText(_:replacementRange:)`, không gạch chân, track anchor cục bộ |
| **Marked text** | App bỏ qua replacementRange, khi KHÔNG có quyền AX | `setMarkedText`, có gạch chân tạm khi gõ |
| **Tap: backspace-retype** | Terminal, iTerm, TUI (cần AX) | CGEventTap chặn phím, synth Backspace×N + Unicode |
| **Tap: selection-replace** | Chromium omnibox, Spotlight (cần AX) | Shift+←×N chọn rồi ghi đè — né race với inline autocomplete |
| **Tap: empty-reset** | Excel (cần AX) | Chèn U+202F hủy suggestion rồi Backspace-retype (Shift+← trong ô sẽ chọn ô kề) |

- App chưa phân loại được **probe một lần**: sau lần replace đầu tiên, đọc lại text
  (`attributedSubstring`) để kiểm tra app có tôn trọng replacementRange không; kết quả
  persist (`probedApps` / `fallbackApps`).
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

Âm tiết tiếng Việt đóng theo luật → validate bằng phonotactics, không cần file.
Mô hình compositional **Onset · (Glide) · Nucleus · (Coda) · Tone** trên bảng integer
packed (~330 byte static, zero heap khi validate):
- Onset (28, gồm ∅/qu/gi) + spelling gate: `k/gh/ngh` chỉ trước e ê i y; `c/ng` không
  trước e ê i y; `g` non-front trừ `gi`-parse (gì, gìn).
- Nucleus: 30 chuỗi nguyên âm (kèm glide) → bitmask 13 coda cho phép + cờ
  zeroOnsetOnly (ya/yê). Nucleus không ổn định (ă â iê oă uâ uô ươ oo yê trần) không
  được đứng cuối.
- 2 retry zero-cost: `qu`+y → thử nucleus `u…` (quỳnh/quýt/quých); `gi`+ê → thử `i…`
  (giêng/giếc) — nhờ đó bỏ được vần rởm `êng`.
- Ràng buộc: coda p/t/c/ch chỉ đi với sắc/nặng. Độ dài raw tối đa 1 âm tiết = 9 phím
  (`nghieengs`).
- `isValidSyllable` dùng ở ranh giới từ cho auto-restore; `isValidPrefix` (fold nguyên
  âm về gốc để chấp nhận trạng thái Telex trung gian) dùng cho live spell-check.
- Chi phí: O(độ dài từ), một lượt duyệt, không cấp phát.

**Phát hiện từ tiếng Anh (Rule A, setting "Phát hiện từ tiếng Anh", mặc định bật):**
với người gõ dấu cuối từ, mọi từ Việt hợp lệ có tone key là phím hiệu lực cuối cùng.
Từ tiếng Anh trùng âm tiết hợp lệ (`test`→tét, `here`→hể) vi phạm đúng điều này
(có phím literal/mark sau tone key đã tiêu thụ). 3 cờ vị trí trong parse pass sẵn có,
0 byte bảng; khi nghi ngờ → re-render literal ngay (thấy `test` chứ không phải
`tét`-rồi-khôi-phục). Miễn trừ: có mark trước tone (`tieesng`), tone replacement, `z`,
đuôi `d` của `dd`. Kill-switch: 2 từ hợp lệ kiểu gõ-dấu-sớm → tắt vĩnh viễn
(`toneEarlyStyle`, persist). Tự tắt khi bật bỏ dấu tự do. Hạn chế còn lại (chấp nhận):
từ tiếng Anh có chuỗi phím trùng hệt cách gõ Việt (`his`≡hí, `seen`≡sên) — về nguyên
tắc không phân biệt được nếu không có từ điển.

## State & Settings

- `UserDefaults` (suite riêng): autoRestore, freeMarking, modernOrthography,
  liveSpellCheck, simpleTelex, englishToneDetection, toneEarlyCount, restoreWhitelist,
  shortcuts `[String: String]`, fallbackApps, probedApps.
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

- Zero network. Zero log keystroke. Không Analytics SDK.
- `PrivacyInfo.xcprivacy` khai báo zero data collection / zero tracking.
- Store description: "Không thu thập bất kỳ dữ liệu nào."

## Ngoài phạm vi (đã quyết định không làm)

- Phím ngoặc `[`→ơ `]`→ư, quick consonants (f→ph, w→qu, g→ng), `oo` literal cho từ mượn
  (xoong, boong), tự viết hoa đầu câu.
- VNI (phím 6/7/8/9), Quick Telex (cc=ch, gg=gi), smart switch EN/VI, Dvorak,
  Windows/Linux.

## Testing

1. **Engine unit tests** (`TelexCore/Tests`) — golden table: biến đổi cơ bản, hủy dấu,
   lan horn ươ, ràng buộc coda-tone, w-lẻ, auto-restore từ hiếm hợp lệ, free-marking,
   modern orthography, live spell-check (corpus 40+ từ), Simple Telex.
2. **Validator tests**: đủ bảng vần, coda-tone constraints.
3. **Benchmark test** cho latency budget — kết quả ghi vào `BENCHMARKS.md`.
4. Manual checklist per-app: `checklist.md`.
