# Building VietTelex

Hai phần: package Swift thuần (`TelexCore`) và app bundle (`VietTelex.app`) bọc nó
thành một IMK input method.

## Requirements

- macOS 14+ (deployment target), Apple Silicon hoặc Intel
- Xcode 26 / Swift 6.3 toolchain
- `xcodegen` (Homebrew: `brew install xcodegen`) — chỉ để regenerate project

## 1. TelexCore (engine + validator)

```bash
cd TelexCore
swift build -c release      # clean release build
swift test                  # unit + benchmark tests (debug)
swift test -c release       # số benchmark chuẩn (ghi vào BENCHMARKS.md)
```

Package không có dependency, không cần Xcode GUI.

## 2. VietTelex.app (input method)

Xcode project được sinh từ `project.yml`:

```bash
xcodegen generate
xcodebuild -project VietTelex.xcodeproj \
           -scheme VietTelex -configuration Release \
           -destination 'platform=macOS' build
```

Build tay như trên thì bundle nằm trong DerivedData mặc định của Xcode; còn
`Scripts/notarize-install.sh` build vào đường dẫn cố định
`$TMPDIR/viettelex-derived/Build/Products/Release/VietTelex.app` (tránh vụ nhiều
DerivedData tồn đọng làm cài nhầm bản cũ). `TelexCore` link tĩnh, bundle tự chứa.

### Cài để test tay

**macOS 26 (Tahoe) yêu cầu input method phải NOTARIZED mới đăng ký được làm input
source.** Đã chứng minh bằng đối chứng: một input method bên thứ ba đã notarized thả
vào `~/Library/Input Methods` đăng ký được sau một lần logout, trong khi build
đúng-từng-byte nhưng *chưa notarize* của mình thì không bao giờ — thử đủ ad-hoc,
Developer ID (chưa notarize), Apple Development, sandbox on/off, `~/Library` lẫn
`/Library`. Không có log; login scanner lặng lẽ bỏ qua bundle chưa notarize.
`spctl -a -t exec` phân biệt được: notarized = "accepted", chưa = "rejected".

Cài bằng **`Scripts/notarize-install.sh`** (build → ký Developer ID + hardened
runtime → notarize → staple → install). Vòng lặp dev nhanh hơn:
**`Scripts/dev-install.sh`** — cài bản local GIỮ NGUYÊN quyền Accessibility và
settings (cùng Developer ID identity; ad-hoc sign sẽ mất quyền). Setup credential một lần (tự chạy để secret
không đi qua agent): tạo app-specific password ở appleid.apple.com, rồi
`xcrun notarytool store-credentials VietTelexNotary --apple-id <email> --team-id 84T567KMYD`.

Các yêu cầu khác cũng bắt buộc (mỗi cái đều từng độc lập chặn registration khi debug):

1. **Bundle id phải chứa "inputmethod"** — `com.viettelex.inputmethod.telex`. Input-mode
   key có prefix là nó (`com.viettelex.inputmethod.telex.vi`).
2. **`TISInputSourceID` top-level** (= bundle id), `NSPrincipalClass` = NSApplication,
   `LSBackgroundOnly` = false.
3. **Không sandbox** cho bản Developer ID (`VietTelex.entitlements`,
   `app-sandbox = false`, không `get-task-allow` — notarization từ chối flag này).
   Sandbox chỉ thuộc bản MAS (`VietTelex-MAS.entitlements`).
4. Cài vào **`~/Library/Input Methods`** (user-owned, không cần sudo).
5. **Log out / log in một lần** sau lần cài đầu hoặc sau khi đổi bundle id /
   input-mode metadata. Mỗi lần đổi code phải re-notarize (staple theo từng build);
   `notarize-install.sh` lo trọn gói.

Sau đó: System Settings → Keyboard → Input Sources → + → Vietnamese →
"Tiếng Việt (VietTelex)".

Chọn input source và gõ thử trong TextEdit. Menu bộ gõ (icon thanh menu) có dòng
tình trạng quyền Accessibility và **Cài đặt…**

## Icons

- **App icon**: Asset Catalog `App/Resources/Assets.xcassets/AppIcon.appiconset`
  (sinh từ `assets/VietTelex-logo.png`, PNG nén palette 256 màu, dedup còn 7 slice).
  actool compile ra `Assets.car` (~366KB với `ASSETCATALOG_COMPILER_OPTIMIZATION=space`,
  so với `.icns` cũ 671KB). Regenerate: `python3 Scripts/make_appicon.py` (cần Pillow).
- **Menu badge** (`MenuIcon.pdf` — VECTOR 26×16pt, hộp golden-ratio, VT khoét even-odd;
  PDF là format chuẩn cho icon input method, theo cách Squirrel làm — TIFF bitmap từng
  gây mờ/bé/lệch): `swift Scripts/make_icon.swift App/Resources`.

## Cấu trúc

- **TelexCore** — engine + validator, Swift 6 strict-concurrency clean, có benchmark.
- **App target** — Swift 5 language mode (AppKit/IMK singleton sống trên main thread;
  strict concurrency chỉ thêm noise, không thêm an toàn).
- Đường gõ chính: `insertText(replacementRange:)` in-place; app không tôn trọng
  replacementRange được **probe read-back** tự phát hiện rồi chuyển marked-text hoặc
  tap-mode. Chi tiết 5 chiến lược per-app: DESIGN.md.
- Gõ tắt chỉ tra ở word boundary.

## Compatibility hardening

1. **Remote-desktop force-passthrough** — `ClientPolicy.forcePassthroughBundleIDs`
   (TelexCore, có unit test) hard-code bundle id của RDP/VM/screen-share (Microsoft
   Remote Desktop *và* Windows App mới cùng dùng `com.microsoft.rdc.macos`, cộng
   Parallels, VMware Fusion, UTM, Screen Sharing, Citrix, TeamViewer, RealVNC,
   Remotix). Các client này forward scancode thô nên IME hành xử như OFF.
2. **Secure input** — `IsSecureEventInputEnabled()` được check đầu `handle()`; khi
   active thì passthrough sạch và reset buffer (không xử lý, không log). Chi phí đo
   được ≈ **0.06 µs/call** — an toàn trên hot path.
3. **replacementRange probe** — lần replace thật đầu tiên vào app lạ được kiểm chứng
   bằng cách đọc lại text (`attributedSubstring(from:)`). App bỏ qua replacementRange
   được nhớ vào `AppState.fallbackApps` (persist), các keystroke sau đi đường
   marked-text/tap. Probe một lần mỗi app, app đã phân loại giữ hot path sạch.

## Signing & phân phối

Kênh phân phối chính thức: **Developer ID + notarize** (`notarize-install.sh` cho
app, `make-pkg.sh` cho installer). Đây là kênh DUY NHẤT khả thi cho input method.

**Đóng gói một bản release** (sau khi `notarize-install.sh` đã notarize + staple app):
`Scripts/make-release.sh` tạo artifact vào `~/Desktop` — `VietTelex-<VER>.app.zip`
(zip từ app đã staple), `VietTelex-<VER>.pkg`, và copy `typing-modes.plist` — rồi in
sha256 của app.zip + lệnh upload. **Homebrew cask tải `.app.zip`** (stanza `artifact`
vào `~/Library/Input Methods`, vì pkg là user-home domain), nên release nào cũng PHẢI
đính `.app.zip`. Sau khi `gh release upload`:

1. Bump `Casks/viettelex.rb` trong tap `ptrinh/homebrew-viettelex`: `version` + `sha256`.
2. Khi bản đó đủ tin cậy → **promote lên kênh stable**: bump `docs/stable.json`
   (`version` + `url`) trên GitHub Pages. Auto-update hàng tuần trong app (opt-in)
   CHỈ theo kênh này — release chưa promote thì user không được nhắc update.

**Mac App Store: ĐÃ VERIFY — KHÔNG KHẢ THI (2026-07).** App MAS cài vào
`/Applications`, nhưng macOS chỉ nạp input method từ `~/Library/Input Methods`;
app sandbox không được phép tự copy bundle ra ngoài container, và App Review cấm
cài thêm code. macOS không có cơ chế keyboard-extension như iOS. Vì vậy KHÔNG có
bộ gõ bên thứ ba nào trên MAS (OpenKey/EVKey/Squirrel/vChewing đều ngoài Store).
Refs: Apple DevForums #134115, #43817. `VietTelex-MAS.entitlements` giữ lại
phòng khi Apple mở đường sau này; đừng tốn công submit trước đó.

## Checklist thủ công còn lại

- [ ] Test tay các mục còn mở trong `checklist.md`: Google Docs/Sheets, Photoshop,
      Lark Docs/Sheets, VS Code EditContext (watch item), nhóm cross-app.
      (Đã pass: Terminal/iTerm2, Word, Excel, Chrome/Safari, Discord, Lark, Slack,
      VSCode, Spotlight, WhatsApp — mode chốt trong `typing-modes.plist`.)
- [ ] Đo RSS sau 1h (< 20MB), cold start (< 300ms) — Instruments / `footprint`
      trên bản đã cài. (Engine latency đã đo: BENCHMARKS.md.)
