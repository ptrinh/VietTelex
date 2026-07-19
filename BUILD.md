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
runtime → notarize → staple → install). Setup credential một lần (tự chạy để secret
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
tình trạng quyền Accessibility và **Cài đặt…** (2 tab: Chung, Gõ tắt).

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

## Signing & Mac App Store (cần identity thật của user)

Project ký ad-hoc (`CODE_SIGN_IDENTITY = -`), đủ để chạy và test local. Để distribute:

1. **Signing identity** — set trong `project.yml` dưới `settings.base`:
   `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY` ("Apple Distribution" cho MAS), và
   `PROVISIONING_PROFILE_SPECIFIER`. Regenerate bằng `xcodegen generate`.
2. **App Store Connect** record + đăng ký bundle id.
3. Verify quy trình Apple hiện hành cho **input method phân phối qua MAS** (cài vào
   /Applications, first-run hướng dẫn System Settings → Keyboard → Input Sources)
   trước khi submit — quy trình này đã đổi qua các bản macOS.
4. Entitlement sandbox có sẵn và **không có network entitlement** (zero-network là
   selling point review + privacy). `PrivacyInfo.xcprivacy` khai báo zero data
   collection / zero tracking.

Không ký thật trong môi trường dev — ad-hoc là đúng cho local.

## Checklist thủ công còn lại

- [ ] Signing identity thật + provisioning profile; setup App Store Connect.
- [ ] Test tay các app còn lại trong `checklist.md`: Chrome (ngoài omnibox), VS Code
      (EditContext — blocker), Photoshop, Lark/Feishu, Slack, RDP, nhóm cross-app.
      (Đã pass: Chrome omnibox, Word, Excel, Terminal, iTerm2, Discord.)
- [ ] Đo RSS sau 1h (< 20MB), cold start (< 300ms), 0% idle CPU — Instruments /
      `footprint` trên bản đã cài. (Engine latency đã đo: BENCHMARKS.md.)
- [ ] Store description bản địa hóa / copy "không thu thập dữ liệu".
