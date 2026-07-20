# VietTelex — Per-App Compatibility Checklist

Tổng hợp từ research lỗi thực tế của các bộ gõ tiếng Việt trên macOS.
Mỗi mục = test case cần chạy tay (và automate được thì automate). Trạng thái: ☐ chưa test / ✅ pass / ❌ fail (ghi bug kèm theo).

**Chuỗi test chuẩn dùng cho mọi app** (gõ liên tục, tốc độ nhanh):
- `Tieengs Vieejt raats hay` → `Tiếng Việt rất hay` (hoa đầu câu — bắt lỗi nhân đôi "TTh")
- `ddaay laf nguwowif` → `đây là người`
- Gõ `hoas` rồi backspace 2 lần rồi gõ tiếp `uyeenf` → không vỡ dấu, không lặp chuỗi
- Gõ tắt (nếu bật): `vn ` → mở rộng đúng, không nhân đôi kiểu "Googoogle"
- Gõ 1 câu ~15 từ tốc độ tối đa → không mất/lặp ký tự nào

---

## 1. Google Chrome

| # | Test case | Lỗi đã biết cần né | Expected |
|---|---|---|---|
| 1.1 | ✅ Gõ chuỗi chuẩn vào **omnibox (address bar)** khi có suggestion hiện inline | "d"→"dđ", lặp ký tự do inline autocomplete giữ suggestion ~0.8s, backspace xoá lệch (Chromium 514928) | Đúng dấu, không nhân đôi |
| 1.2 | ☐ Gõ vào ô Google search có autocomplete dropdown | Tương tự 1.1 | Đúng dấu |
| 1.3 | ☐ Gõ trong **Google Docs** | Docs có editor riêng, từng lỗi khác biệt | Đúng dấu, con trỏ không nhảy |
| 1.4 | ☐ Gõ trong Google Sheets (ô có autocomplete từ cột) | Autocomplete ô như Excel | Đúng dấu |
| 1.5 | ☐ Gõ trong `<input>` / `<textarea>` / `contenteditable` thường | Regression composition của Chromium theo version (issue 409342979) | Đúng dấu. Ghi lại version Chrome khi test |

## 2. Microsoft Word — ✅ đã test pass

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 2.1 | ✅ Gõ chuỗi chuẩn với **AutoCorrect + spell-check BẬT** (mặc định) | AutoCorrect/spell-check phá chuỗi sửa từ, mất dấu, smart cut-and-paste tự chèn space | Đúng dấu không cần user tắt AutoCorrect |
| 2.2 | ✅ Gõ với font **Palatino** và vài font serif khác | ư/ơ từng render sai với Palatino ở các bộ gõ khác | Precomposed NFC → hiển thị đúng |
| 2.3 | ✅ Gõ nhanh rồi Enter xuống dòng ngay sau từ có dấu | Mất chữ khi gõ nhanh | Từ cuối commit đúng |
| 2.4 | ✅ Gõ trong comment/textbox/header | Text engine khác nhau trong cùng app | Đúng dấu |

## 3. Microsoft Excel — ✅ đã test pass

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 3.1 | ✅ Cột đã có "đông", gõ "đ" vào ô dưới khi **AutoComplete for cell values BẬT** | Lỗi kinh điển "đ"→"dđ", "â"→"aâ": suggestion inline làm backspace xoá lệch | Đúng "đ" — test quan trọng nhất nhóm Office |
| 3.2 | ✅ Gõ từ có dấu rồi Enter/Tab ngay lập tức | Mất dấu khi commit nhanh | Từ commit đủ dấu |
| 3.3 | ✅ Gõ trong formula bar | Đường nhập khác cell editor | Đúng dấu |

## 4. Adobe Photoshop

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 4.1 | ☐ Gõ chuỗi chuẩn vào text layer | Text engine Adobe không implement NSTextInputClient đầy đủ, có thể **bỏ qua replacementRange** → nhảy dấu/lỗi dấu | Nếu replacementRange bị ignore → detect + tự động chuyển fallback |
| 4.2 | ☐ Gõ vào ô tên layer, ô số liệu (native field) | Field native thường ổn, text layer mới hỏng | Đúng dấu |
| 4.3 | ☐ Verify cơ chế **detect app bỏ qua replacementRange** hoạt động (so sánh text sau insert) | — | Tự fallback không cần user cấu hình |

## 5. Terminal.app / iTerm2 — ✅ đã test pass

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 5.1 | ✅ Gõ chuỗi chuẩn tại shell prompt (zsh) | Terminal **không có replace range** — bắt buộc đi đường tap (gửi backspace event thật) | Đúng dấu qua tap-mode |
| 5.2 | ✅ Gõ trong vim/nano | TUI tự xử lý raw keystroke | Đúng dấu, không vỡ buffer |
| 5.3 | ✅ Gõ trong TUI hiện đại (Claude Code CLI — claude-code #10429 vỡ dấu với mọi bộ gõ) | Framework TUI (Ink…) không hiểu composition | Đúng dấu qua tap-mode |
| 5.4 | ✅ Gõ password prompt (`sudo`) — **secure input** | Secure input có thể làm bộ gõ tê liệt/treo | IME tự bypass sạch, không treo, không nuốt phím (`IsSecureEventInputEnabled`) |
| 5.5 | ✅ Lặp 5.1–5.2 trên iTerm2 | iterm2 #5199 | Như Terminal.app |

## 6. Visual Studio Code

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 6.1 | ☐ Gõ chuỗi chuẩn trong editor, **EditContext BẬT** (`editor.editContext: true` — đang thành mặc định) | EditContext là đường composition mới nhất, nhiều bộ gõ hỏng hẳn với nó | Đúng dấu — test blocker, chạy cả 2 chế độ on/off |
| 6.2 | ☐ Gõ khi IntelliSense/suggest popup đang hiện | Suggest nuốt backspace | Đúng dấu, popup không phá từ |
| 6.3 | ☐ Gõ trong file Markdown với extension Markdown All in One | Từng có bộ gõ không gõ được khi cài extension này | Đúng dấu |
| 6.4 | ☐ Gõ trong integrated terminal của VS Code | Kết hợp lỗi nhóm 5 + Electron | Đúng dấu qua fallback |
| 6.5 | ☐ Gõ vào ô Search/Find & Replace | Field khác editor chính | Đúng dấu |

## 7. Discord — ✅ đã test pass

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 7.1 | ✅ Gõ chuỗi chuẩn vào chat box, câu bắt đầu bằng chữ hoa | Editor Slate.js xử lý composition kém; nhân đôi đầu câu | Không nhân đôi ký tự đầu câu |
| 7.2 | ✅ Gõ từ có dấu ngay sau khi popup @mention / emoji `:` hiện | Autocomplete popup can thiệp DOM giữa chừng | Đúng dấu |
| 7.3 | ✅ Sửa message đã gửi (edit mode) | Editor state khác | Đúng dấu |

## 8. Lark / Feishu

⚠️ Không có dữ liệu lỗi công khai — **điểm mù, phải test thực nghiệm kỹ hơn các app khác.**

| # | Test case | Rủi ro dự đoán | Expected |
|---|---|---|---|
| 8.1 | ☐ Gõ chuỗi chuẩn vào chat | Electron + editor tự viết → cùng lớp rủi ro Slack/Discord | Đúng dấu |
| 8.2 | ☐ Gõ trong **Lark Docs** (block editor riêng) | Block editor can thiệp DOM mạnh | Đúng dấu, không nhảy block |
| 8.3 | ☐ Gõ sau khi popup @mention hiện | Autocomplete race | Đúng dấu |
| 8.4 | ☐ Gõ trong Lark Sheets | Autocomplete ô như Excel | Đúng dấu |

## 9. Slack

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 9.1 | ☐ Gõ chuỗi chuẩn vào composer, câu bắt đầu chữ hoa | Composer Quill + Chromium: lặp ký tự đầu message | Không lặp |
| 9.2 | ☐ Gõ khi popup @mention / emoji / channel `#` hiện | Autocomplete can thiệp | Đúng dấu |
| 9.3 | ☐ Gõ trong thread reply + edit message | — | Đúng dấu |
| 9.4 | ☐ Gõ trong canvas/post editor | Editor khác composer | Đúng dấu |

## 10. Microsoft Remote Desktop / Windows App

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 10.1 | ☐ Focus vào session RDP khi VietTelex đang là input source | RDP forward scancode, không forward text; ký tự Unicode tổng hợp không map được → ký tự sai hoàn toàn | **Thiết kế chủ đích**: client RDP/Windows App (bundle ID `com.microsoft.rdc.macos`…) → IME tự passthrough hoàn toàn (như OFF); dùng bộ gõ phía Windows |
| 10.2 | ☐ Rời RDP sang app khác | Composition phải reset sạch | Gõ bình thường ở app kia |

## 11. Cross-app / hệ thống (mọi app)

| # | Test case | Expected |
|---|---|---|
| 11.1 | ☐ Password field (Safari, Chrome, System Settings) — secure input | IME bypass sạch, không log, không treo |
| 11.2 | ☐ Click chuột giữa từ đang gõ | Buffer reset, không sửa nhầm text cũ |
| 11.3 | ☐ Cmd+Tab đổi app giữa từ đang gõ | Commit/reset sạch |
| 11.4 | ☐ Gõ giữ phím (key repeat) và gõ >120 wpm | Không mất/lặp ký tự |
| 11.5 | ☐ App bỏ qua replacementRange (trả NSNotFound) | Probe read-back tự phát hiện → chuyển marked-text/tap |
| 11.6 | ☐ Spotlight, Raycast/Alfred | Field đặc biệt, hay bị bỏ quên |
| 11.7 | ☐ Save dialog / rename file trong Finder | Field nhỏ native |
| 11.8 | ☐ Stress gõ 500 phím/s (`swift Scripts/stress-typing.swift`) vào TextEdit / terminal / Chrome | Văn bản ra khớp 100% kỳ vọng — không mất/lặp/đảo dấu (lớp bug chỉ lộ khi gõ nhanh) |

---

## Hàm ý thiết kế đã rút ra (đối chiếu DESIGN.md)

1. **`insertText(replacementRange:)` né được đúng lớp lỗi lớn nhất** ("dđ" trong Chrome omnibox/Excel — race giữa synthesized backspace và inline autocomplete). Nhưng phải test theo version Chromium vì đường composition này từng nhiều regression.
2. **Fallback tap-mode là bắt buộc** (không phải nice-to-have): Terminal/iTerm2/TUI và app bỏ qua replacementRange (Photoshop nghi vấn). Cơ chế **probe read-back** tự phát hiện app không tôn trọng replacementRange → tự chuyển, không bắt user cấu hình.
3. **Per-app profile tối thiểu**: RDP/Windows App → force passthrough (danh sách bundle ID hard-code trong `ClientPolicy`).
4. **Secure input**: kiểm tra `IsSecureEventInputEnabled`, bypass sạch — tránh case một app chiếm secure input làm bộ gõ chết toàn hệ thống.
5. **VS Code EditContext** là chiến trường mới nhất — test 6.1 thuộc blocker list trước khi release.
6. **Slack/Lark**: dữ liệu công khai mỏng, chủ yếu suy luận từ lớp Electron — kết quả test thực nghiệm quyết định, không tin dự đoán. (Discord đã test pass.)
