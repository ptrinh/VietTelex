# Báo lỗi VietTelex

Gửi issue tại **https://github.com/ptrinh/viettelex/issues/new**. Trước khi báo: cập nhật bản mới nhất (tab **Giới thiệu** → *Kiểm tra cập nhật*) và thử lại.

## Mẫu issue

Phiên bản, macOS, chế độ gõ… đã nằm sẵn trong nhật ký — chỉ cần điền:

```markdown
**App / website bị lỗi:** Chrome — docs.google.com
**Gõ chuỗi phím:** `theme ` (ghi đúng phím bấm, không phải chữ mong muốn)
**Mong đợi:** thêm — **Thực tế:** themee
**Nhật ký gỡ lỗi:** (kéo-thả file vào đây)
```

Lỗi hiển thị (chữ nhảy, bôi đen, mất chữ…) → kèm video quay màn hình (⌘⇧5) càng tốt.

## Lấy nhật ký gỡ lỗi

Nhật ký chỉ ghi sự kiện của bộ gõ, **không ghi nội dung bạn gõ**.

1. Menu **Ｖ** → **Cài đặt…** → tab **Tùy chỉnh** → bật **Mở tính năng nâng cao** (cuối trang).
2. Sang tab **Thử nghiệm** → mục **Chẩn đoán** → bật **Ghi nhật ký gỡ lỗi** → bấm **Xoá**.
3. Tái hiện lỗi trong app bị lỗi, rồi quay lại bấm **Lưu nhật ký gỡ lỗi…** ngay (log chỉ giữ 400 dòng gần nhất).

<img src="assets/debug-log-1.png" alt="Bật Mở tính năng nâng cao" width="440"> <img src="assets/debug-log-2.png" alt="Ghi nhật ký gỡ lỗi" width="440">
