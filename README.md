# VietTelex

Bộ gõ tiếng Việt kiểu **Telex** cho macOS. Gõ tự nhiên, mượt: **không gạch chân từ đang gõ, con trỏ luôn ở cuối**, dấu được bỏ trực tiếp vào chữ trên màn hình.

## Tính năng

- **Engine Telex** (mặc định Simple Telex): thanh điệu `s f r x j`, mũ `aa/ee/oo`,
  móc/trăng `w`, `đ` gõ `dd`, xóa dấu bằng `z`. Rule-based, hot path không cấp phát heap.
- **Simple Telex** (bật/tắt) — chữ `w` đứng một mình luôn là `w` (gõ `uw` để ra `ư`),
  nên gõ tiếng Anh/code không bị biến dạng. Tắt đi thì `w` lẻ thành `ư` như Telex đầy đủ.
- **Bỏ dấu tự do** (bật/tắt) — mặc định TẮT (Telex nghiêm ngặt): dấu chỉ nhận khi gõ sát
  nguyên âm, nhờ đó `data`→data, `ama`→ama. Bật lên thì dấu quét ngược qua phụ âm
  (`ama`→âm, `trangw`→trăng).
- **Kiểu bỏ dấu cũ / mới** — `hòa, thủy` (cũ, mặc định) hoặc `hoà, thuý` (mới).
- **Kiểm tra chính tả khi gõ** — ngừng bỏ dấu ngay khi từ không thể là tiếng Việt
  (`google`, `github`…), cộng với **tự khôi phục** ở ranh giới từ: từ không hợp lệ được
  trả về đúng chuỗi phím đã gõ. Dùng validator âm vị học (`SyllableValidator`),
  không cần từ điển.
- **Gõ tắt** (bảng gõ tắt): định nghĩa `vn` → `Việt Nam`…, import/export plist.
- **Gõ được trong Terminal** (iTerm, Terminal, Claude Code…) qua CGEventTap — vừa gõ
  tiếng Việt vừa giữ nguyên autocomplete/Tab của shell, điều IMKit thuần không làm được.
- **Xử lý autocomplete thông minh** cho Chrome/Spotlight (chọn-rồi-ghi-đè bằng Shift+←)
  và Excel (chèn ký tự rỗng để hủy suggestion) — inline suggestion không còn phá chữ.
- **Không có nút bật/tắt VI/EN riêng** — VietTelex bật khi nó là input source đang chọn;
  muốn gõ tiếng Anh thì chuyển input source (macOS tự nhớ theo từng app).

## Cài đặt & sử dụng

1. Build và cài bằng `Scripts/notarize-install.sh` (macOS yêu cầu input method phải
   **notarized** mới đăng ký được — xem [`BUILD.md`](BUILD.md)).
2. System Settings → Keyboard → Input Sources → **+** → Vietnamese →
   **Tiếng Việt (VietTelex)**.
3. Chọn input source VietTelex và gõ. Menu bộ gõ (icon trên thanh menu) có
   **Cài đặt…** (2 tab: Chung, Gõ tắt) và dòng tình trạng quyền Accessibility.
4. Để gõ tiếng Việt trong Terminal/iTerm/trình duyệt Chromium: cấp quyền
   **Accessibility** (System Settings → Privacy & Security → Accessibility → bật
   VietTelex).

## Build

Yêu cầu macOS 14+, Xcode 26 / Swift 6.3, và [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# Test engine (không cần Xcode)
cd TelexCore && swift test

# Sinh Xcode project và build app
xcodegen generate
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex -configuration Release build
```

Chi tiết ký, notarize, cài đặt: [`BUILD.md`](BUILD.md). Các ghi chú "xương máu" về
đăng ký input method trên macOS: [`MACOS_IME_NOTES.md`](MACOS_IME_NOTES.md).

## Tài liệu

- [`DESIGN.md`](DESIGN.md) — kiến trúc và các quyết định thiết kế.
- [`checklist.md`](checklist.md) — ma trận test tương thích theo từng app.

## Bản quyền

© Phil Trinh @ SenPrints
