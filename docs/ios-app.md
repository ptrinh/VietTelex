# VietTelex Keyboard cho iOS — Kế hoạch

> Trạng thái: PLAN (2026-07-22). Chưa bắt đầu code. Quyết định còn mở ở cuối file.

Bàn phím tiếng Việt Telex cho iOS qua **Keyboard Extension** (`UIInputViewController`),
tái sử dụng nguyên engine TelexCore của bản macOS. Khác macOS: iOS keyboard extension
**lên được App Store**.

## Nguyên tắc thiết kế (đã chốt với Phil)

- **MINIMAL & TỐI ƯU TUYỆT ĐỐI — CPU/RAM/size** (cùng triết lý bản macOS):
  - **Extension**: chỉ link TelexCore (vài trăm KB), KHÔNG kéo framework nào
    khác vào target keyboard dù "tiện tay" (WebKit/audio/analytics… cấm).
    Mục tiêu: cold-start bàn phím < 200ms, RAM extension < 20MB (trần hệ
    thống ~60MB), 0% CPU khi không gõ (event-driven, không timer).
  - **Container app**: cũng phải nhẹ — SwiftUI thuần, không dependency bên
    thứ ba, asset nén (bài học từ size-diet macOS: strip + -Osize + LTO,
    palette-compress ảnh). Mục tiêu download size cả bundle < 15MB.
  - Hai process tách biệt hoàn toàn (app nặng không ảnh hưởng keyboard),
    nhưng KHÔNG lấy đó làm cớ để app phình — minimal là giá trị thương hiệu.
  - Mỗi milestone đo lại: binary size, RAM (Instruments), thời gian hiện
    bàn phím. Ghi số vào bảng như BENCHMARKS.md.

- **UI/behavior CLONE đúng bàn phím gốc Apple** (bàn phím Tiếng Việt của iOS,
  spacebar có chữ "VI EN" mờ): kích thước phím, khoảng cách, font, màu light/dark,
  balloon preview, shift/caps double-tap, backspace repeat + tăng tốc, giữ space
  di chuyển con trỏ. KHÔNG sáng tạo thêm.
- **Không long-press phụ** (không popup ă/â khi giữ phím).
- **Không suggestion/predictive bar** (bản 1).
- **Không Full Access** — engine chạy local 100%, không mạng. Điểm mạnh privacy
  so với đa số bàn phím Việt trên iOS.

## Vì sao engine dùng nguyên xi

`textDocumentProxy` của iOS chỉ có `deleteBackward()` + `insertText()` — khớp
chính xác với output diff tối thiểu `(backspaces, insert)` mà TelexEngine đã xuất
cho tap-mode macOS. Không viết lại logic gõ nào.

**Reuse trực tiếp** (pure Swift, zero-alloc, ~0.1µs/phím — thừa sức trong giới hạn
RAM ~60MB của extension): TelexEngine, SyllableValidator, Tables,
EnglishCollisions (+ gen-english), teencode, whitelist đc/ĐSQ, contract cancel.
Chỉ cần thêm `.iOS(.v16)` vào TelexCore/Package.swift.

**Không mang theo**: toàn bộ tap/AX/probe/per-app strategy (đặc sản macOS).
AppState: tách phần settings thuần thành struct dùng chung qua App Group.

## Kiến trúc

```
VietTelex-iOS (cùng repo, project riêng qua xcodegen)
├── VietTelexKeyboard (app extension)
│   ├── KeyboardViewController: UIInputViewController
│   ├── KeyboardView: vẽ toàn bộ bàn phím (clone Apple metrics)
│   └── TelexCore (link tĩnh)
├── VietTelex (container app — App Store bắt buộc có)
│   ├── Onboarding: hướng dẫn bật bàn phím (Settings → General → Keyboard)
│   ├── Cài đặt: Simple Telex, bỏ dấu tự do, spell-check, tự khôi phục, gõ tắt
│   └── 🎓 Link mở https://ptrinh.github.io/viettelex/learn/ trong browser
│       (KHÔNG nhúng WebView — app chỉ để settings, giữ minimal)
└── App Group "group.com.viettelex" — UserDefaults chia sẻ settings
```

Bundle id mới, không đụng registration macOS: `com.viettelex.ios` +
`com.viettelex.ios.keyboard`.

## Cơ chế gõ

- Mỗi phím → engine → `.replace(bs, insert)` → `deleteBackward()`×bs + `insertText`.
  Không race (mình vẽ bàn phím, không có event tap, không app chen giữa).
- Secure field (`isSecureTextEntry`) → literal passthrough, tắt engine.
- Word boundary (space/return/dấu câu) → commit + auto-restore y hệt macOS.
- Đổi field/app (`textDidChange`/`textWillChange`) → reset buffer.
- Autocorrect của host app là lớp bug số 1 của bàn phím iOS — test sớm ở M1
  (Messages, Safari form). Phương án B cho field hư: `setMarkedText` trên proxy
  (iOS 13+) — lại đúng dual-strategy như macOS.

## Giới hạn hệ thống (đã thống nhất chấp nhận)

1. **Phím emoji 😀**: bàn phím thứ ba KHÔNG gọi được bàn phím emoji hệ thống.
   → đề xuất BỎ phím emoji, giữ globe (user bấm globe sang emoji keyboard của
   Apple). Phương án khác: tự làm emoji picker (nhiều công — không làm bản 1).
   ⏳ CHỜ CHỐT.
2. **Haptic khi gõ**: extension chỉ được rung khi có Full Access → chấp nhận
   không haptic. Âm click hệ thống có đủ (`playInputClick` — đúng tiếng gốc).
3. **Phím mic (dictation)**: API không mở cho bàn phím thứ ba (Apple cũng tự ẩn
   mic khi dùng bàn phím ngoài). Bỏ.
4. **Balloon preview hàng Q–P**: extension không vẽ ra ngoài khung bàn phím —
   balloon hàng trên cùng có thể thấp hơn bản gốc vài px.

## Milestones

| Giai đoạn | Nội dung | Ước lượng |
|---|---|---|
| M0 | TelexCore + platform iOS, project xcodegen 2 target, App Group | 0.5 ngày |
| M1 | Bàn phím chữ hoạt động: QWERTY + shift + backspace + engine diff-edit; gõ được tiếng Việt trong Notes/Messages trên máy thật | 1–2 ngày |
| M2 | Clone đủ Apple: plane 123/#+= , globe, return theo `returnKeyType`, secure field, backspace repeat, giữ-space di chuyển con trỏ, balloon, âm click, dark mode, iPad layout, "VI EN" trên spacebar | 2–3 ngày |
| M3 | Container app: onboarding, settings (App Group), link mở Learn trên browser | 1 ngày |
| M4 | Field-test matrix (Messages, Safari, Notes, mật khẩu, Zalo, Telegram…), TestFlight, App Store submit | ~1 tuần calendar (review) |

## Rủi ro

- RAM extension ~60MB: engine vài trăm KB ✓; theo dõi nếu UI SwiftUI nặng.
- Autocorrect host chen giữa composition → test sớm, plan B marked text.
- Latency `insertText` là IPC mỗi phím (~ tương đương 1.9ms IMKit macOS) — diff
  tối thiểu giữ burst sửa dấu rẻ.
- App Review: container phải có giá trị độc lập → onboarding + settings đầy đủ;
  không Full Access nên privacy review nhẹ. (Learn chỉ là link ra browser.)

## Quyết định còn mở (chốt trước khi bắt đầu M0)

1. Phím emoji: bỏ (giữ globe) hay tự làm picker? — đề xuất BỎ.
2. iOS tối thiểu: đề xuất **iOS 16**.
3. Suggestion bar: phase 2 hay bỏ hẳn (cần từ điển tần suất, ngoài scope engine).


> Thiết kế chi tiết hệ thống gợi ý (suggestion bar, datastore cá nhân hóa, inline suggestion): xem [IOS-SUGGESTIONS.md](IOS-SUGGESTIONS.md).
