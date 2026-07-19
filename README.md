<p align="center">
  <img src="assets/VietTelex-logo.png" width="128" alt="VietTelex">
</p>

<h1 align="center">VietTelex</h1>

Bộ gõ tiếng Việt kiểu **Telex** cho macOS. Gõ tự nhiên, mượt: **không gạch chân từ đang gõ, con trỏ luôn ở cuối**, dấu được bỏ trực tiếp vào chữ trên màn hình — và gõ được cả trong **Terminal / iTerm** mà không phá autocomplete của shell.

## Giới thiệu

VietTelex (ViệtTelex/ViếtTelex) là một dự án của **Phil Trịnh** — ra đời sau nhiều năm dùng macOS mà vẫn chưa tìm được một bộ gõ tiếng Việt nào thật sự *ngon, chuẩn và mượt* trên nền tảng này. VietTelex được viết lại từ đầu để giải quyết đúng những điểm đó.

### Điểm khác biệt so với các bộ gõ khác trên macOS

**1. Tích hợp đúng chuẩn IMKit của macOS.** VietTelex là một input method thật sự của hệ thống (Input Method Kit), chứ không phải một app chặn phím bên ngoài. Nhờ vậy nó được thừa hưởng **miễn phí** các tính năng của một bộ gõ tích hợp sẵn mà không phải tự code lại:
- Tự đổi kiểu gõ / bàn phím **theo từng nguồn input** — macOS nhớ lựa chọn Việt/Anh riêng cho mỗi ứng dụng.
- Kiểm tra chính tả, dự đoán từ, tự viết hoa đầu câu, thay thế văn bản… của hệ thống vẫn hoạt động bình thường trên nền tảng bộ gõ.
- Con trỏ, undo, chọn văn bản, VoiceOver… đều đúng chuẩn vì bộ gõ nói cùng "ngôn ngữ" với macOS.

**2. Engine nhanh nhờ nén luật thành máy trạng thái.** Toàn bộ luật chính tả tiếng Việt (onset, vần, ràng buộc thanh–coda) được **compile thành trie phẳng + bitmap** trên một bảng chữ nén, thay cho tra cứu chuỗi/từ điển. Cộng thêm phân tích tăng dần (mỗi phím chỉ xử lý một bước), so khớp bằng SIMD và **không cấp phát bộ nhớ trên đường xử lý phím**, mỗi keystroke chỉ tốn **~0.13 µs (≈130 ns)** — dưới ngưỡng cảm nhận của con người hàng vạn lần, nên gõ nhanh cỡ nào cũng mượt, không trễ, không mất/loạn ký tự.

**3. Gõ được ở những nơi bộ gõ khác thường vỡ.** Terminal/iTerm (giữ được autocomplete của shell), thanh địa chỉ Chrome, ô Excel, Spotlight — mỗi loại được xử lý bằng một chiến lược riêng, tự học theo từng ứng dụng.

**4. Thông minh với tiếng Anh & code.** Tự khôi phục từ không phải tiếng Việt (`google`, `github`…), nhận biết token kiểu camelCase (`OmS`, `JavaScript`) để không "bỏ dấu nhầm", và có chế độ Telex nghiêm ngặt cho lập trình viên.

**5. Nhẹ và riêng tư.** Không chạy nền tốn CPU, không mạng, không thu thập bất kỳ dữ liệu nào.

## Cài đặt

1. Tải **`VietTelex-x.y.z.pkg`** từ [Releases](https://github.com/ptrinh/VietTelex/releases) (đã ký + notarized bởi Apple).
2. Double-click → làm theo hướng dẫn. Installer tự cài vào `~/Library/Input Methods`, đăng ký bộ gõ và mở sẵn **System Settings → Keyboard**.
3. Ở **Input Sources** bấm **Edit… / ＋** → **Vietnamese** → **ViệtTelex** → **Add**.

| ① Input Sources → Edit… | ② ＋ → Vietnamese → ViệtTelex → Add |
|---|---|
| ![Keyboard → Input Sources → Edit](assets/instructions-1.png) | ![Add Vietnamese ViệtTelex](assets/instructions-2.png) |

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

## Ảnh màn hình

| Menu trên thanh menu | Cửa sổ Cài đặt |
|---|---|
| ![Menu bộ gõ trên thanh menu](assets/Menu-Bar-Screenshot.png) | ![Cửa sổ Cài đặt](assets/Settings-Screenshot.png) |

## Khắc phục sự cố

- **Không thấy trong Input Sources sau khi cài** → đăng xuất/đăng nhập lại một lần.
- **Không gõ được tiếng Việt trong Terminal/Chrome** → kiểm tra quyền Accessibility (menu bộ gõ hiện "Tình trạng: Thiếu quyền" khi chưa cấp; nếu đã bật mà vẫn không được, bỏ tick rồi tick lại).
- **Ô mật khẩu** → VietTelex tự tắt trong secure field, đó là hành vi đúng.

## Đóng góp / tự build

Xem [`CONTRIBUTE.md`](CONTRIBUTE.md) — hướng dẫn build, kiến trúc, benchmark và checklist test.

## Giấy phép

[MIT License](LICENSE) — © 2026 Phil Trinh (SENPRINTS LLC).

Bạn được tự do dùng, sửa, tích hợp VietTelex vào hệ thống/sản phẩm khác (kể cả
thương mại, mã đóng), miễn là **giữ lại thông báo bản quyền và giấy phép** trong
bản phân phối.
