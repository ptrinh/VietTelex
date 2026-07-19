# VietTelex

Bộ gõ tiếng Việt kiểu **Telex** cho macOS. Gõ tự nhiên, mượt: **không gạch chân từ đang gõ, con trỏ luôn ở cuối**, dấu được bỏ trực tiếp vào chữ trên màn hình — và gõ được cả trong **Terminal / iTerm** mà không phá autocomplete của shell.

## Cài đặt

**Cách 1 — Trình cài đặt (khuyên dùng):**
1. Tải **`VietTelex-x.y.z.pkg`** từ [Releases](https://github.com/ptrinh/VietTelex/releases) (đã ký + notarized bởi Apple).
2. Double-click → làm theo hướng dẫn. Installer tự cài vào `~/Library/Input Methods`, đăng ký bộ gõ và mở sẵn **System Settings → Keyboard**.
3. Ở **Input Sources** bấm **Edit… / ＋** → **Vietnamese** → **ViệtTelex** → **Add**.

**Cách 2 — Thủ công (file `.zip`):** giải nén, chép `VietTelex.app` vào `~/Library/Input Methods` (Finder: ⌘⇧G dán đường dẫn), đăng xuất/đăng nhập một lần, rồi thêm input source như bước 3.

Cuối cùng, để gõ tiếng Việt trong **Terminal, iTerm và trình duyệt Chrome/Edge/Brave**:
bật quyền **Accessibility** cho VietTelex (System Settings → Privacy & Security →
Accessibility). Không bật thì các app thường vẫn gõ bình thường.

Chuyển giữa tiếng Việt và tiếng Anh bằng phím chuyển input source của macOS
(mặc định 🌐 hoặc ⌃Space) — macOS tự nhớ lựa chọn theo từng app.

## Cách gõ

Telex chuẩn: `s f r x j` = sắc huyền hỏi ngã nặng · `aa ee oo` = â ê ô ·
`aw ow uw` = ă ơ ư · `dd` = đ · `z` xóa dấu.

Ví dụ: `vieejt` → việt · `truowngf` → trường · `hoas` → hóa.

## Tính năng

- **Không gạch chân, không nhảy con trỏ** — dấu hiện trực tiếp khi gõ, như thói quen của người dùng Việt.
- **Gõ trong Terminal/iTerm/TUI** mà shell autocomplete (Tab, zsh-autosuggestions) vẫn hoạt động — điều các bộ gõ dùng IMKit thuần không làm được.
- **Không phá autocomplete** của thanh địa chỉ Chrome, Spotlight, ô Excel.
- **Tự khôi phục từ tiếng Anh**: `windows`, `google`, `SaaS`… tự trả về nguyên văn thay vì bị dính dấu.
- **Gõ tắt**: định nghĩa `vn` → `Việt Nam`… trong Cài đặt, import/export được.
- **Tùy chọn**: Simple Telex (w đứng một mình là w), bỏ dấu tự do, kiểu bỏ dấu cũ/mới (hòa/hoà), kiểm tra chính tả khi gõ.
- **Nhẹ và riêng tư**: không timer chạy nền, không mạng, không thu thập bất kỳ dữ liệu nào. Engine xử lý một phím trong ~0.1 micro giây.

Mọi tùy chọn nằm ở menu bộ gõ trên thanh menu → **Cài đặt…**

## Khắc phục sự cố

- **Không thấy trong Input Sources sau khi cài** → đăng xuất/đăng nhập lại một lần.
- **Không gõ được tiếng Việt trong Terminal/Chrome** → kiểm tra quyền Accessibility (menu bộ gõ hiện "Tình trạng: Thiếu quyền" khi chưa cấp; nếu đã bật mà vẫn không được, bỏ tick rồi tick lại).
- **Ô mật khẩu** → VietTelex tự tắt trong secure field, đó là hành vi đúng.

## Đóng góp / tự build

Xem [`CONTRIBUTE.md`](CONTRIBUTE.md) — hướng dẫn build, kiến trúc, benchmark và checklist test.

## Bản quyền

© Phil Trinh @ SenPrints
