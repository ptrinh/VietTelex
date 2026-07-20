# VietTelex — 5 đường gõ per-app: Pros/Cons & logic chọn

Phân tích 5 chiến lược đưa chữ Việt vào app, dựa trên code thực tế
(`AppState.swift`, `TelexInputController.swift`, `TerminalTap.swift`,
`TelexCore/InPlaceProbe.swift`, `TelexCore/ClientPolicy.swift`) và số đo
trong `docs/latency-baseline.md`.

**AX = Accessibility** (quyền *Privacy & Security → Accessibility*, API
`AXIsProcessTrusted` / `AXUIElement`). Quyền này cho phép process (a) đặt
**CGEventTap** chặn phím của app khác và post synthetic key event, (b) đọc/ghi
**AX tree** — nội dung thật của text field theo cách app không tự "khai báo"
được. Cả 3 đường tap đều cần nó; process sandbox (MAS) không bao giờ được cấp.

## Tổng quan nhanh

Latency ghi 2 mức: **phím thường** (chữ không transform, đi qua từng phím) và
**burst sửa dấu** (lúc gõ `s/f/r/x/j/w/aa…`, phải xóa-ghi lại). Nguồn:
A2 signpost + pty-arrival trong `latency-baseline.md`; 1 frame 60 Hz ≈ 16.7 ms.

| # | Đường | Kênh | Cần AX? | MAS? | Underline? | Phím thường | Burst sửa dấu |
|---|---|---|---|---|---|---|---|
| 1 | **In-place** | IMKit `insertText(_:replacementRange:)` | Không | ✅ | Không | ~1.9 ms p50 (XPC `insertText`/`selectedRange`) | như phím thường (vẫn 1 call `insertText`) |
| 2 | **Marked text** | IMKit `setMarkedText` | Không | ✅ | **Có** (khi đang gõ) | ~in-place (cùng kênh IMKit XPC) | ~in-place |
| 3 | **Tap: backspace-retype** | CGEventTap + synthetic events | **Có** | ❌ | Không | +5 ms so với không IME (round-trip IMKit vẫn xảy ra dù tap-defer); callback tap chỉ ~18 µs | **~+13 ms p50** (pty đo, Terminal; p90 ~24 ms — vừa lố 1 frame) |
| 4 | **Tap: selection-replace** | CGEventTap, Shift+←×N rồi ghi đè | **Có** | ❌ | Không | ~như #3 (cùng hạ tầng tap + fast-path) | **~3 ms × 2(N+1) events** → sửa dấu giữa từ 3 ký tự (N=3) ≈ 24 ms, chậm nhất 5 đường; D1 (1 AX write thay cả burst) tồn tại nhưng default OFF |
| 5 | **Tap: empty-reset** | CGEventTap, chèn U+202F rồi backspace-retype | **Có** | ❌ | Không | ~như #3 | ~#3 + 2 events (~6 ms) cho chèn/xóa ký tự mồi → **~+19 ms** |

(Ngoài 5 đường còn **passthrough** cho remote-desktop/VM — IME hành xử như tắt,
xem `ClientPolicy.forcePassthroughBundleIDs`.)

---

## Phân tích từng đường

### 1. In-place (mặc định) — `insertText(_:replacementRange:)`

**Dùng cho:** app Cocoa chuẩn tôn trọng `replacementRange` — TextEdit, Safari,
Mail, Notes, Word/PowerPoint body…

**Pros**
- UX tốt nhất: không gạch chân, con trỏ luôn ở cuối, chữ là text "thật" ngay
  lập tức → undo, spell-check, autocorrect, VoiceOver của macOS đều đúng.
- Không cần quyền gì; hoạt động trong sandbox → MAS OK.
- Không synthetic event → không rủi ro treo/reorder.

**Cons**
- Đắt nhất *bên trong process của mình*: mỗi phím một round-trip XPC đồng bộ
  `insertText`/`selectedRange` tới client, p50 ~1.9 ms (vẫn dưới 1 frame 60 Hz).
- Chỉ đúng khi app **thật sự** thay `bs` ký tự tại range. App bỏ qua range
  (Terminal, iTerm2 đường CJK, Catalyst như WhatsApp, Electron/CEF như Lark)
  sẽ **append** thay vì replace → dấu chồng lên nhau, mất dấu âm thầm.
- Vì lỗi là "âm thầm" nên cần probe (mục Logic bên dưới) để phát hiện.

### 2. Marked text — `setMarkedText`

**Dùng cho:** (a) app đã học được là bỏ qua `replacementRange`; (b) **fallback
phổ quát** khi không có quyền Accessibility (tức toàn bộ bản MAS với những app
hỏng in-place); (c) app pin cứng trong `markedTextApps` (hiện rỗng).

**Pros**
- **Luôn render đúng**: composition đi qua đường hiển thị IME chuẩn của app,
  độc lập với việc app có tôn trọng range hay báo caret láo hay không.
  Đây là lý do nó là fallback an toàn ("khi nghi ngờ, chọn đường luôn chạy").
- Không cần quyền, sandbox OK → **đường duy nhất cứu các app hỏng trên MAS**.
- Cùng kênh IMKit, chi phí tương đương in-place.

**Cons**
- **Gạch chân** dưới từ đang gõ — nhược điểm thuần thẩm mỹ nhưng thấy rõ.
- Từ ở trạng thái "đang compose": một số app xử lý composition kỳ quặc
  (autocomplete/shortcut của app có thể không thấy text cho tới khi commit).
- Terminal/TUI vẽ marked text xấu hoặc phá autocomplete của shell → với
  terminal, marked chỉ là fallback khi thiếu AX, không phải đích.

### 3. Tap: backspace-retype

**Dùng cho:** Terminal.app, iTerm2, TextMate, WhatsApp, Lark
(`builtInFallbackApps`) + app học được (`fallbackApps`) — khi có AX.

**Cơ chế:** CGEventTap chặn phím trước khi tới app; sửa dấu = synth
Backspace×N + keyDown mang chuỗi Unicode.

**Pros**
- Chữ là text thật, không gạch chân, **không phá shell autocomplete** —
  lời hứa cốt lõi "gõ được trong Terminal/iTerm".
- Callback tap cực rẻ (~18 µs p50); phím không transform đi đường native
  fast-path (zero synthetic event).
- Đã tối ưu: B1 modify-event-in-place (sửa CGEvent vật lý thay vì suppress+post),
  B2 bỏ synthetic keyUp.

**Cons**
- **Cần quyền Accessibility** → chỉ bản Developer ID, ❌ MAS.
- Synthetic event là bề mặt rủi ro lớn nhất của cả app: cascade tự nhận nhầm
  event của chính mình từng **treo cả bàn phím** (fix v1.2.1: pid-recognition
  + cascade breaker ~256 events/500 ms → tự tắt tap, phím về native).
- Burst dấu tới chậm hơn phím thường ~13 ms p50 (round-trip re-post).
- Vỡ khi app có inline autocomplete đua với backspace (→ sinh ra đường 4, 5).

### 4. Tap: selection-replace (Shift+←×N rồi ghi đè)

**Dùng cho:** omnibox các trình duyệt Chromium (`selectionApps`: Chrome, Edge,
Brave, Arc, Vivaldi, Opera, Chromium) và **Spotlight** (nhận diện qua window
list, không phải bundle id) — khi có AX.

**Vì sao không dùng #3:** inline autocomplete của omnibox đua với
backspace-retype → "gôgleogle". Chọn bằng Shift+← rồi overtype thì phần
autocomplete (đang selected) bị thay thế luôn → né race.

**Pros**
- Đường duy nhất gõ đúng trong omnibox/Spotlight mà vẫn ra text thật.
- Cùng hạ tầng tap → hưởng fast-path, breaker.

**Cons**
- Cần AX → ❌ MAS.
- Nhiều event nhất: 2(N+1) posted events, mỗi round-trip ~3 ms → đường chậm
  nhất về cảm nhận. Tối ưu D1 (một AX write thay cả burst) tồn tại nhưng
  **default OFF** — AX call đồng bộ cross-process ngay trong tap callback là
  bề mặt treo mới, chỉ opt-in ở Settings → Thử Nghiệm.
- Giả định "Shift+← chọn ký tự" — đúng trong text field, sai trong grid
  (→ Excel cần đường 5).

### 5. Tap: empty-reset (Excel)

**Dùng cho:** chỉ `com.microsoft.Excel` — khi có AX.

**Vì sao riêng:** cell autocomplete của Excel đua với backspace-retype
("Tiếngếng Việt") như omnibox, nhưng Shift+← trong ô lại **chọn ô kề** chứ
không chọn ký tự → không dùng được #4. Giải pháp: chèn U+202F (narrow no-break
space) để hủy suggestion, rồi backspace-retype bình thường.

**Pros**
- Cứu được đúng case Excel cell mà cả #3 lẫn #4 đều vỡ.
- Word/PowerPoint **không** đi đường này (không có race, tap chỉ thêm lag) —
  scope hẹp có chủ đích.

**Cons**
- Cần AX → ❌ MAS.
- Hack nhất trong 5 đường: phụ thuộc hành vi suggestion của Excel; thêm
  2 events (chèn + xóa ký tự mồi) mỗi lần sửa dấu.
- Chỉ hardcode 1 bundle id; app khác cùng bệnh phải thêm tay.

---

## Khi nào dùng loại nào (tóm tắt quyết định)

- **App Cocoa bình thường** → in-place. Nhanh nhất về UX, sạch nhất.
- **App bỏ qua replacementRange + có AX** → tap backspace-retype (text thật,
  không underline).
- **App bỏ qua replacementRange + KHÔNG có AX** (MAS, hoặc user chưa cấp quyền)
  → marked text. Chịu gạch chân, nhưng luôn đúng chữ.
- **Field có inline autocomplete đua với backspace**:
  - chọn-ký-tự được (omnibox, Spotlight) → selection-replace;
  - chọn-ký-tự là chọn ô (Excel) → empty-reset.
- **Remote desktop / VM / screen sharing** → passthrough hoàn toàn (synthetic
  Unicode vô nghĩa với guest OS).
- **Secure field (mật khẩu)** → IME tự tắt (hành vi chuẩn hệ thống).

## MAS (Mac App Store)

Chỉ **in-place** và **marked text** sống được trong sandbox — cả hai thuần
IMKit, không quyền đặc biệt. Ba đường tap đều cần `AXIsProcessTrusted`, mà
process sandbox **không bao giờ** được cấp → `usesTapMode` /
`usesSelectionReplace` / `usesEmptyReset` đều gate bằng `Accessibility.isTrusted`
và tự trả `false`, bản MAS **trong suốt rơi về marked text** cho nhóm app hỏng.
Hệ quả chấp nhận được của bản MAS: Terminal/iTerm gõ qua marked text (xấu hơn),
omnibox Chromium/Spotlight/Excel không có fix race (memory ghi nhận: "MAS build
chấp nhận không fix").

## Logic chọn method hiện tại (theo code)

Thứ tự quyết định mỗi keystroke trong `TelexInputController.handle` +
`TerminalTap`:

```
1. ClientPolicy.isRemoteDesktop(bundleID)?        → passthrough (IME như tắt)
2. manualMode(bundleID) (user pin, Thử Nghiệm → App mode)
     .inPlace / .marked / .tap                    → override tất cả, không probe
     (.tap vẫn đòi Accessibility.isTrusted)
3. usesTapMode ∥ usesSelectionReplace ∥ usesEmptyReset (đều cần AX)?
     → controller "tap-defer" (trả false), CGEventTap xử lý;
       emitMode = .selection (Chromium/Spotlight) / .emptyReset (Excel)
                / .backspace (còn lại)
4. usesMarkedText? (learned fallbackApps ∪ builtInFallbackApps ∪ markedTextApps)
     → setMarkedText
5. Còn lại → in-place; nếu needsProbe(bundleID) → probe 1 lần
```

**Probe** (`InPlaceProbe`, chỉ chạy trên replace thật `bs > 0` — pure insert
không phân biệt được):
- Ground truth ưu tiên: **đọc AX tree** vùng đích — `axRegion == inserted`
  → honored, khác → appended (Lark fake được caret lẫn read-back nhưng không
  fake được AX tree… trừ khi fake nốt, nên Lark bị pin cứng).
- Không có AX read: region read-back **mâu thuẫn** với text đã chèn → appended
  (bằng chứng fail thắng caret). Rồi mới tới caret: `caret == start+len`
  → honored, khác → appended.
- Kết quả ghi vào UserDefaults: honored → `probedApps` (khóa in-place),
  appended → `fallbackApps` (→ marked, và → tap nếu có AX).
- `builtInFallbackApps` **không bao giờ probe**: Terminal/iTerm2/WhatsApp/Lark
  từng false-positive probe (echo read-back, caret láo), mà cache learned là
  per-install UserDefaults — reinstall là mất; Terminal là lời hứa cốt lõi nên
  pin trong binary. Settings có "reset learned apps" cho probe hỏng vì app bận.

## Fallback chain

**Marked text là fallback cuối cùng của mọi đường** — vì nó là mode duy nhất
*luôn render đúng* mà không cần quyền:

```
in-place ──probe fail──────────────► marked text
tap (3/4/5) ──không có AX──────────► marked text
tap ──cascade breaker trip─────────► tắt tap, phím native (giữ bàn phím sống)
selection-replace D1 ──AX call fail─► posted-events path (Shift+← burst)
mọi đường ──remote desktop─────────► passthrough
```

Triết lý (ghi trong `InPlaceProbe.verdict`): đoán sai in-place = **mất dấu âm
thầm**; marked text sai = chỉ tốn một cái gạch chân. Khi không chắc, chọn
đường luôn chạy.
