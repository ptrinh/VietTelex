<p align="center">
  <img src="assets/VietTelex-logo.png" width="128" alt="VietTelex">
</p>

<h1 align="center">VietTelex</h1>

Bộ gõ tiếng Việt **Telex** cho macOS — không gạch chân, con trỏ luôn ở cuối, dấu bỏ trực tiếp vào chữ, và gõ được cả trong **Terminal / iTerm** mà không phá autocomplete của shell.

> Dự án của **Phil Trịnh** (ViệtTelex / ViếtTelex), viết lại từ đầu sau nhiều năm dùng macOS mà chưa thấy bộ gõ tiếng Việt nào thật sự *ngon, chuẩn, mượt*.

**Triết lý:** *Minimalist* — chỉ Telex, chỉ Unicode dựng sẵn, không tính năng thừa · *Intuitive* — hoạt động đúng như bộ gõ hệ thống, không cần học lại · *Performant* — ~130ns/phím, không chạy nền.

## Điểm nổi bật

- **Chuẩn IMKit** — là input method thật của hệ thống (không phải app chặn phím), nên thừa hưởng miễn phí: tự đổi kiểu gõ theo từng app, chính tả/dự đoán/viết hoa của macOS, con trỏ/undo/VoiceOver đều đúng.
- **Nhanh** — luật chính tả compile thành trie + bitmap, incremental parse, SIMD, zero-alloc: **~130 ns/phím**, gõ nhanh cỡ nào cũng mượt.
- **Gõ được ở nơi bộ gõ khác hay vỡ** — Terminal/iTerm (giữ autocomplete shell), address bar Chrome, ô Excel, Spotlight; tự học theo từng app.
- **Thông minh với English/code** — tự khôi phục `google`/`github`, nhận token camelCase (`OmS`, `JavaScript`) để không bỏ dấu nhầm, có Telex nghiêm ngặt.
- **Nhẹ & riêng tư** — không chạy nền, không thu thập dữ liệu; chỉ gọi mạng khi bạn bấm *Kiểm tra cập nhật*.

| Menu trên thanh menu | Cửa sổ Cài đặt |
|---|---|
| ![Menu bộ gõ](assets/Menu-Bar-Screenshot.png) | ![Cửa sổ Cài đặt](assets/Settings-Screenshot.png) |

## Cài đặt

**Website:** [ptrinh.github.io/viettelex](https://ptrinh.github.io/viettelex/) · **Homebrew:** `brew tap ptrinh/viettelex && brew install --cask viettelex`

1. Tải **`VietTelex-x.y.z.pkg`** từ [Releases](https://github.com/ptrinh/viettelex/releases) (đã ký + notarized).
2. Double-click → làm theo hướng dẫn (tự cài, đăng ký bộ gõ, mở sẵn System Settings → Keyboard).
3. **Input Sources → Edit… / ＋ → Vietnamese → ViệtTelex → Add.**

| ① Input Sources → Edit… | ② ＋ → Vietnamese → ViệtTelex → Add |
|---|---|
| ![Input Sources → Edit](assets/instructions-1.png) | ![Add ViệtTelex](assets/instructions-2.png) |

Để gõ trong **Terminal, iTerm, Chrome/Edge/Brave**: bật quyền **Accessibility** cho VietTelex (Privacy & Security → Accessibility). Chuyển Việt/Anh bằng phím 🌐 hoặc ⌃Space (macOS nhớ theo từng app).

## Cách gõ

`s f r x j` = sắc huyền hỏi ngã nặng · `aa ee oo` = â ê ô · `aw ow uw` = ă ơ ư · `dd` = đ · `z` xóa dấu.
Ví dụ: `vieejt` → việt · `truowngf` → trường · `hoas` → hóa.

Tùy chọn (Simple Telex, bỏ dấu tự do, kiểu cũ/mới, kiểm tra chính tả, gõ tắt) ở menu bộ gõ → **Cài đặt…**

## Khắc phục sự cố

- **Không thấy trong Input Sources** → đăng xuất/đăng nhập lại một lần.
- **Không gõ được trong Terminal/Chrome** → cấp quyền Accessibility (đã bật mà vẫn lỗi thì bỏ tick rồi tick lại).
- **Ô mật khẩu** → tự tắt trong secure field (đúng hành vi).

## Đóng góp & giấy phép

Build, kiến trúc, benchmark: xem [`CONTRIBUTE.md`](CONTRIBUTE.md).

[MIT License](LICENSE) — © 2026 Phil Trinh (SENPRINTS LLC). Tự do dùng/sửa/tích hợp (kể cả thương mại), miễn giữ lại thông báo bản quyền.
