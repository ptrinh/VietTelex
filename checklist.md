# VietTelex — Per-App Compatibility Checklist

Tổng hợp từ research lỗi thực tế của các bộ gõ hiện có (bộ gõ Apple, EVKey, OpenKey) trên macOS.
Mỗi mục = test case cần chạy tay (và automate được thì automate). Trạng thái: ☐ chưa test / ✅ pass / ❌ fail (ghi bug kèm theo).

**Chuỗi test chuẩn dùng cho mọi app** (gõ liên tục, tốc độ nhanh):
- `Tieengs Vieejt raats hay` → `Tiếng Việt rất hay` (hoa đầu câu — bắt lỗi nhân đôi "TTh" của bộ gõ Apple)
- `ddaay laf nguwowif` → `đây là người`
- Gõ `hoas` rồi backspace 2 lần rồi gõ tiếp `uyeenf` → không vỡ dấu, không lặp chuỗi
- Gõ tắt (nếu bật): `vn ` → mở rộng đúng, không nhân đôi kiểu "Googoogle"
- Gõ 1 câu ~15 từ tốc độ tối đa → không mất/lặp ký tự nào

---

## 1. Google Chrome

| # | Test case | Lỗi đã biết cần né | Expected |
|---|---|---|---|
| 1.1 | ☐ Gõ chuỗi chuẩn vào **omnibox (address bar)** khi có suggestion hiện inline | "d"→"dđ", lặp ký tự do inline autocomplete giữ suggestion ~0.8s, backspace xoá lệch (OpenKey #37, Chromium 514928) | Đúng dấu, không nhân đôi. `replacementRange` phải né được race này — verify |
| 1.2 | ☐ Gõ vào ô Google search có autocomplete dropdown | Tương tự 1.1 | Đúng dấu |
| 1.3 | ☐ Gõ trong **Google Docs** | Docs có editor riêng, từng lỗi khác biệt | Đúng dấu, con trỏ không nhảy |
| 1.4 | ☐ Gõ trong Google Sheets (ô có autocomplete từ cột) | Chế độ "Sửa lỗi Chromium" của OpenKey chính nó gây lỗi ở Sheets | Đúng dấu |
| 1.5 | ☐ Gõ trong `<input>` / `<textarea>` / `contenteditable` thường | Regression composition của Chromium theo version (issue 409342979) | Đúng dấu. Ghi lại version Chrome khi test |

## 2. Microsoft Word

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 2.1 | ☐ Gõ chuỗi chuẩn với **AutoCorrect + spell-check BẬT** (mặc định) | AutoCorrect/spell-check phá chuỗi sửa từ, mất dấu, smart cut-and-paste tự chèn space | Đúng dấu không cần user tắt AutoCorrect |
| 2.2 | ☐ Gõ với font **Palatino** và vài font serif khác | ư/ơ render sai với Palatino (OpenKey changelog từng phải fix) | Precomposed NFC → phải hiển thị đúng |
| 2.3 | ☐ Gõ nhanh rồi Enter xuống dòng ngay sau từ có dấu | Mất chữ khi gõ nhanh | Từ cuối commit đúng |
| 2.4 | ☐ Gõ trong comment/textbox/header | Text engine khác nhau trong cùng app | Đúng dấu |

## 3. Microsoft Excel

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 3.1 | ☐ Cột đã có "đông", gõ "đ" vào ô dưới khi **AutoComplete for cell values BẬT** | Lỗi kinh điển "đ"→"dđ", "â"→"aâ": suggestion inline làm backspace xoá lệch | Đúng "đ" — test quan trọng nhất nhóm Office |
| 3.2 | ☐ Gõ từ có dấu rồi Enter/Tab ngay lập tức | Mất dấu khi commit nhanh | Từ commit đủ dấu |
| 3.3 | ☐ Gõ trong formula bar | Đường nhập khác cell editor | Đúng dấu |

## 4. Adobe Photoshop

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 4.1 | ☐ Gõ chuỗi chuẩn vào text layer | OpenKey ≥1.6 không gõ được hoàn toàn (#113); nhảy dấu/lỗi dấu — text engine Adobe không implement NSTextInputClient đầy đủ, có thể **bỏ qua replacementRange** | Nếu replacementRange bị ignore → detect + tự động chuyển fallback |
| 4.2 | ☐ Gõ vào ô tên layer, ô số liệu (native field) | Field native thường ổn, text layer mới hỏng | Đúng dấu |
| 4.3 | ☐ Verify cơ chế **detect app bỏ qua replacementRange** hoạt động (so sánh text sau insert) | — | Tự fallback không cần user cấu hình |

## 5. Terminal.app / iTerm2

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 5.1 | ☐ Gõ chuỗi chuẩn tại shell prompt (zsh) | Terminal **không có replace range** — bắt buộc fallback backspace-synthesis (gửi backspace event thật) | Đúng dấu qua đường fallback |
| 5.2 | ☐ Gõ trong vim/nano | TUI tự xử lý raw keystroke | Đúng dấu hoặc ít nhất không vỡ buffer |
| 5.3 | ☐ Gõ trong TUI hiện đại (Claude Code CLI — claude-code #10429 vỡ dấu với mọi bộ gõ) | Framework TUI (Ink…) không hiểu composition | Ghi nhận hành vi; nếu không fix được thì document |
| 5.4 | ☐ Gõ password prompt (`sudo`) — **secure input** | Secure input làm bộ gõ tê liệt/treo (case Zalo chiếm secure input) | IME tự bypass sạch, không treo, không nuốt phím; kiểm tra `IsSecureEventInputEnabled` |
| 5.5 | ☐ Lặp 5.1–5.2 trên iTerm2 | iterm2 #5199 | Như Terminal.app |

## 6. Visual Studio Code

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 6.1 | ☐ Gõ chuỗi chuẩn trong editor, **EditContext BẬT** (`editor.editContext: true` — đang thành mặc định) | EVKey hỏng hẳn với EditContext (EVKey #76); đây là đường composition mới nhất, nhiều bug nhất | Đúng dấu — test blocker, chạy cả 2 chế độ on/off |
| 6.2 | ☐ Gõ khi IntelliSense/suggest popup đang hiện | Suggest nuốt backspace | Đúng dấu, popup không phá từ |
| 6.3 | ☐ Gõ trong file Markdown với extension Markdown All in One | OpenKey #152: không gõ được khi cài extension này | Đúng dấu |
| 6.4 | ☐ Gõ trong integrated terminal của VS Code | Kết hợp lỗi nhóm 5 + Electron | Đúng dấu qua fallback |
| 6.5 | ☐ Gõ vào ô Search/Find & Replace | Field khác editor chính | Đúng dấu |

## 7. Discord

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 7.1 | ☐ Gõ chuỗi chuẩn vào chat box, câu bắt đầu bằng chữ hoa | Editor Slate.js xử lý composition kém ("today is"→"ttodayi" trên Windows); nhân đôi đầu câu với bộ gõ Apple | Không nhân đôi ký tự đầu câu |
| 7.2 | ☐ Gõ từ có dấu ngay sau khi popup @mention / emoji `:` hiện | Autocomplete popup can thiệp DOM giữa chừng | Đúng dấu |
| 7.3 | ☐ Sửa message đã gửi (edit mode) | Editor state khác | Đúng dấu |

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
| 9.1 | ☐ Gõ chuỗi chuẩn vào composer, câu bắt đầu chữ hoa | Composer Quill + Chromium: lặp ký tự đầu message với bộ gõ Apple | Không lặp |
| 9.2 | ☐ Gõ khi popup @mention / emoji / channel `#` hiện | Autocomplete can thiệp | Đúng dấu |
| 9.3 | ☐ Gõ trong thread reply + edit message | — | Đúng dấu |
| 9.4 | ☐ Gõ trong canvas/post editor | Editor khác composer | Đúng dấu |

## 10. Microsoft Remote Desktop / Windows App

| # | Test case | Lỗi đã biết | Expected |
|---|---|---|---|
| 10.1 | ☐ Focus vào session RDP khi VietTelex đang BẬT | EVKey #43: ký tự sai hoàn toàn — RDP forward scancode, không forward text; ký tự Unicode tổng hợp không map được | **Thiết kế chủ đích**: khi client là RDP/Windows App (bundle ID `com.microsoft.rdc.macos`…) → IME tự passthrough hoàn toàn (như OFF), per-app default = off |
| 10.2 | ☐ Toggle hotkey khi đang trong RDP | Bộ gõ 2 đầu cùng bật → dấu xử lý 2 lần | HUD hiện nhưng khuyến cáo trong docs: dùng bộ gõ phía Windows |
| 10.3 | ☐ Rời RDP sang app khác | State per-app phải khôi phục đúng | Trở lại trạng thái đã nhớ của app kia |

## 11. Cross-app / hệ thống (mọi app)

| # | Test case | Expected |
|---|---|---|
| 11.1 | ☐ Password field (Safari, Chrome, System Settings) — secure input | IME bypass sạch, không log, không treo |
| 11.2 | ☐ Click chuột giữa từ đang gõ | Buffer reset, không sửa nhầm text cũ |
| 11.3 | ☐ Cmd+Tab đổi app giữa từ đang gõ | Commit/reset sạch, state per-app đúng |
| 11.4 | ☐ Gõ giữ phím (key repeat) và gõ >120 wpm | Không mất/lặp ký tự |
| 11.5 | ☐ App bỏ qua replacementRange (trả NSNotFound) | Fallback backspace-synthesis kích hoạt tự động |
| 11.6 | ☐ Spotlight, Raycast/Alfred | Field đặc biệt, hay bị bỏ quên |
| 11.7 | ☐ Save dialog / rename file trong Finder | Field nhỏ native |

---

## Hàm ý thiết kế đã rút ra (đối chiếu DESIGN.md)

1. **`insertText(replacementRange:)` né được đúng lớp lỗi lớn nhất** ("dđ" trong Chrome omnibox/Excel — race giữa synthesized backspace và inline autocomplete). Đây là lợi thế cạnh tranh so với EVKey/OpenKey (event-tap). Nhưng phải test theo version Chromium vì đường composition này từng nhiều regression.
2. **Fallback backspace-synthesis là bắt buộc** (không phải nice-to-have): Terminal/iTerm2/TUI và app bỏ qua replacementRange (Photoshop nghi vấn). Cần cơ chế **detect** app không tôn trọng replacementRange → tự chuyển, không bắt user cấu hình.
3. **Cần per-app profile tối thiểu**: RDP/Windows App → force passthrough; danh sách bundle ID hard-code + user override được ở tab Ứng dụng.
4. **Secure input**: kiểm tra `IsSecureEventInputEnabled`, bypass sạch — tránh case "Zalo chiếm secure input làm bộ gõ chết toàn hệ thống".
5. **VS Code EditContext** là chiến trường mới nhất — đưa test 6.1 vào blocker list trước khi release.
6. **Slack/Discord/Lark**: dữ liệu công khai mỏng, chủ yếu suy luận từ lớp Electron — kết quả test thực nghiệm 3 app này quyết định, không tin dự đoán.
