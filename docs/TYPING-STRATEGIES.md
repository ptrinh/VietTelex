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
| 1 | **In-place** | IMKit `insertText(_:replacementRange:)` | ❌ | ✅ | ❌ | ~2 ms | ~2 ms |
| 2 | **Marked text** | IMKit `setMarkedText` | ❌ | ✅ | ✅ (khi đang gõ) | ~2 ms | ~2 ms |
| 3 | **Tap: backspace-retype** | CGEventTap + synthetic events | ✅ | ❌ | ❌ | ~+5 ms | **~13–24 ms** |
| 4 | **Tap: selection-replace** | CGEventTap, Shift+←×N rồi ghi đè | ✅ | ❌ | ❌ | ~+5 ms | **~12–24 ms** |
| 5 | **Tap: empty-reset** | CGEventTap, chèn U+202F rồi backspace-retype | ✅ | ❌ | ❌ | ~+5 ms | **~19–30 ms** |

Ghi chú:
- #1/#2: một call XPC `insertText`/`setMarkedText`, p50 ~1.9 ms — burst dấu
  không đắt hơn phím thường.
- #3: pty đo trên Terminal: p50 +13 ms, p90 ~24 ms (vừa lố 1 frame 60 Hz).
  Phím thường vẫn +5 ms vì round-trip IMKit xảy ra dù tap-defer.
- #4: ngoại suy ~3 ms/event × 2(N+1); D1 (gộp cả burst thành 1 AX write)
  **default ON từ 1.3.1** — fail thì tự rơi về posted-events path.
- #5: như #3 + 2 events (~6 ms) chèn/xóa ký tự mồi. #4/#5 chưa đo trực tiếp —
  hàng A1 tương ứng trong `latency-baseline.md` còn trống.

**Threading (từ `d7e44a0`)** — hai cải thiện không đổi con số trung vị trong
bảng nhưng cắt đuôi phân phối (tail latency):

- **Tap chạy trên thread riêng** (trước đó: main run loop). Callback tap không
  còn xếp hàng sau XPC IMKit ~2 ms/phím của app khác hay SwiftUI Settings —
  hết **jitter** cho #3/#4/#5 khi main bận, và giảm hẳn nguy cơ
  `tapDisabledByTimeout` (macOS tự tắt tap chậm → phím lọt ra đường hỏng).
  Các số +5 ms / 13–24 ms ở trên đo TRƯỚC thay đổi này — p50 dự kiến giữ
  nguyên (chi phí là round-trip liên-process), p90/p99 dự kiến giảm; cần
  chạy lại pty-harness để xác nhận.
- **AX probe read chuyển sang queue nền**: keystroke probe một app mới không
  còn stall tiềm ẩn 50 ms (timeout của AX call) — verdict sơ bộ tính ngay từ
  caret/read-back, AX ground truth về sau và có quyền override.

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
- Gạch chân đã làm **gần vô hình** bằng công thức `underlineStyle: 1` +
  `underlineColor: alpha 0.004` (tìm ra 21/07/2026): style 0 = "unspecified"
  nên app vẽ default; màu clear thuần là sentinel "dùng màu chữ" của Chromium;
  style 1 + alpha gần-0 thì được transport và vẽ trong suốt. Verified sạch
  trên Chrome/Safari/Notes.

**Cons**
- Gạch chân chỉ tắt được ở app TÔN TRỌNG attribute — Excel tự vẽ gạch đậm bất
  chấp mọi style gửi xuống (đã thử cạn 4 biến thể 21/07/2026), nên Excel đi
  đường 5 thay vì marked. Kênh chính chủ `mark(forStyle: kTSMHiliteNoHilite)`
  cũng vô dụng: dict trả về chỉ chứa `NSMarkedClauseSegment`.
- Từ ở trạng thái "đang compose": một số app xử lý composition kỳ quặc
  (autocomplete/shortcut của app có thể không thấy text cho tới khi commit).
- Terminal/TUI vẽ marked text xấu hoặc phá autocomplete của shell → với
  terminal, marked chỉ là fallback khi thiếu AX, không phải đích.

### 3. Tap: backspace-retype

**Dùng cho:** Terminal.app, iTerm2 + nhóm Electron field-tested (Lark, Slack,
Discord, VSCode, Claude Desktop — rule `tap` trong typing-modes.yml; in-place
của nhóm này hỏng Ở BIÊN TỪ dù giữa dòng trông ổn) + app học được qua probe
(`fallbackApps`) — khi có AX.

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

**Dùng cho:** address/search bar của các browser (Chrome, Edge, Brave, Arc,
Vivaldi, Opera, Chromium, **Safari** — mode `axDetect` trong typing-modes.yml)
— khi có AX. **Spotlight từng đi đường này** nhưng trên macOS 26 in-place đã
sạch (race autocomplete lịch sử hết) → default hiện tại là inPlace; tap branch
cho Spotlight chỉ còn chạy khi user pin tay.

**Per-field (từ 94083cc):** browser không còn đi selection-replace nguyên-app.
`FocusedFieldDetector` đi ngược cây AX của element đang focus (cache TTL 200 ms,
scan queue nền — không AX call nào trên keystroke): gặp `AXWebArea` → field
trong trang → **in-place ~2 ms**; gặp `AXToolbar` → address bar → selection;
không rõ → selection (đường luôn chạy). Mode `axDetect` này cũng chọn được thủ
công trong Bảng chế độ gõ cho app lạ có cấu trúc tương tự.

**Vì sao không dùng #3:** inline autocomplete của omnibox đua với
backspace-retype → "gôgleogle". Chọn bằng Shift+← rồi overtype thì phần
autocomplete (đang selected) bị thay thế luôn → né race.

**Pros**
- Đường duy nhất gõ đúng trong omnibox mà vẫn ra text thật.
- Cùng hạ tầng tap → hưởng fast-path, breaker.

**Cons**
- Cần AX → ❌ MAS.
- Nhiều event nhất: 2(N+1) posted events, mỗi round-trip ~3 ms. Tối ưu D1
  (một AX write thay cả burst) **default ON từ 1.3.1**; AX call fail thì tự
  rơi về posted-events path. Tắt được ở Settings → Thử Nghiệm.
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
  - chọn-ký-tự được (omnibox) → selection-replace;
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
2. manualMode(bundleID) (user pin trong Bảng cơ chế gõ)
     .inPlace / .marked / .tap                    → override tất cả, không probe
     (.tap vẫn đòi Accessibility.isTrusted)
3. usesTapMode ∥ usesSelectionReplace ∥ usesEmptyReset (đều cần AX)?
     → controller "tap-defer" (trả false), CGEventTap xử lý;
       emitMode = .selection (address bar qua axDetect) / .emptyReset (Excel)
                / .backspace (còn lại)
4. usesMarkedText? (learned fallbackApps ∪ builtInFallbackApps ∪ markedTextApps)
     → setMarkedText
5. Còn lại → in-place; nếu needsProbe(bundleID) → probe 1 lần
```

**Probe** (`InPlaceProbe`, chỉ chạy trên replace thật `bs > 0` — pure insert
không phân biệt được). Hai tầng:

- **Verdict sơ bộ (sync, trên keystroke)** từ self-report của app: region
  read-back **mâu thuẫn** với text đã chèn → appended (bằng chứng fail thắng
  caret). Rồi tới caret: `caret == start+len` → honored, khác → appended.
- **Honored sơ bộ KHÔNG commit ngay** (`HonorTracker`): cần honored ở **2
  offset expReplace khác nhau** mới ghi `probedApps`. Lý do: Lark trả caret
  rác hằng số (= 1, đo 2026-07-21) — trùng expReplace khi gõ đầu ô trống →
  một-lần-probe từng lock nó vào in-place hỏng; caret hằng số không thể trùng
  ở 2 offset. Appended cần 2 lần liên tiếp (một lần có thể do app bận).
- **AX ground truth (async, queue nền)**: đọc AX tree vùng đích SAU khi tree
  settle (Chromium dựng AX lazy — đọc tại T+0 dính cache stale). Khi về, nó
  override verdict sơ bộ: match → commit in-place ngay; mismatch → rút lại cả
  promotion đã lỡ commit (`unmarkInPlaceGood`) + đẩy vào `fallbackApps`.
- Kết quả ghi UserDefaults: honored (đã confirm) → `probedApps`,
  appended → `fallbackApps` (→ tap nếu có AX, marked nếu không).
- App có rule trong `typing-modes.yml` **không bao giờ probe** — rule là
  kết quả field-test, tin hơn probe (probe vẫn phân loại đúng Lark nhờ rule
  2-offset, nhưng ship sẵn rule thì user mới không phải "học lại" sau reinstall).
  Settings có "Đặt lại (dò lại từ đầu)" cho probe hỏng vì app bận.

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
