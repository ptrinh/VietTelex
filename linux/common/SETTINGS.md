# VietTelex Linux — hợp đồng cài đặt (settings contract)

Chủ sở hữu: frontend (Fcitx5/IBus, agent L1) **đọc**; `viettelex-settings` (GTK4, agent L2) **ghi**.
Parser tham chiếu: `linux/common/src/settings.cpp` (C++17, không phụ thuộc thư viện ngoài).

## 1. Vị trí file

| File | Đường dẫn | Ai ghi |
|---|---|---|
| Cài đặt | `$XDG_CONFIG_HOME/viettelex/config.toml` (mặc định `~/.config/viettelex/config.toml`) | settings app |
| Gõ tắt | `$XDG_CONFIG_HOME/viettelex/shortcuts.yml` | settings app (import/export) |
| Trạng thái Việt/Anh theo app | `$XDG_STATE_HOME/viettelex/app-state` (mặc định `~/.local/state/viettelex/app-state`) | **frontend** (settings app không đụng) |
| Lối tắt Chrome/Electron có cờ IME Wayland (§9) | `$XDG_DATA_HOME/applications/<id>.desktop` có dòng `X-VietTelex-Generated=` | settings app — chỉ file mang dòng đó |

- Thiếu file / thiếu key / giá trị sai kiểu → dùng **mặc định** bên dưới (không lỗi, không crash).
- **Ghi nguyên tử**: ghi file tạm tên duy nhất `config.toml.XXXXXX` (mkstemp — app cài đặt và
  hộp cấu hình Fcitx5 có thể ghi cùng lúc) rồi `rename()` sang `config.toml` (cùng thư mục),
  giữ quyền file cũ. `config.toml` là symlink (dotfiles) ⇒ ghi vào đích (`realpath`), symlink
  giữ nguyên (inotify khi đó không thấy — frontend nhận qua kiểm tra `mtime` lúc focus-in).
  Ghi lỗi (~/.config chỉ đọc / đầy) ⇒ app cài đặt báo "Không ghi được cấu hình trong ~/.config."
  và vẽ lại theo đúng file trên đĩa; hộp Fcitx5 hiện lại giá trị cũ.
  Frontend theo dõi **thư mục** `viettelex/` bằng inotify (`IN_CLOSE_WRITE | IN_MOVED_TO |
  IN_DELETE`) và nạp lại ngay — không cần restart IM. Frontend cũng tự kiểm tra `mtime`
  mỗi lần focus-in (dự phòng khi inotify không có).
- Mã hoá UTF-8, xuống dòng `\n`.

## 2. `config.toml` — tập con TOML

Chỉ dùng: bảng `[section]`, `key = value`, giá trị `true`/`false`, số nguyên, chuỗi
`"..."` (escape `\"` `\\` `\n` `\t`), comment `#`. Key trong `[app_modes]` là chuỗi có
ngoặc kép. Không dùng mảng, inline table, chuỗi nhiều dòng.

```toml
[typing]
input_method = "telex"              # "telex" | "vni"
simple_telex = false                # w đứng một mình không thành ư
free_marking = true                 # Bỏ dấu tự do
modern_tone = false                 # Kiểu dấu mới (hoà/khoẻ/thuý); false = kiểu cũ (hòa)
quick_telex = false                 # Gõ nhanh cc→ch, gg→gi, kk→kh, nn→ng, pp→ph, qq→qu, tt→th
spell_check = true                  # Kiểm tra chính tả khi gõ (dừng biến đổi từ không hợp lệ)
auto_restore = true                 # Tự khôi phục từ không phải tiếng Việt (tiếng Anh)
teencode = false                    # Chấp nhận teencode (wá, zô, kó, thík…)
auto_circumflex = false             # Tự thêm dấu mũ (vietj → việt, benhj → bệnh)
contextual_english = true           # Quyết định theo ngữ cảnh (từ trước là tiếng Anh)
retroactive_english = false         # Tự sửa từ phía trước (thử nghiệm; chỉ khi contextual_english bật)
english_by_frequency = false        # Đoán từ trùng theo tần suất (thử nghiệm; chỉ khi contextual_english bật)
collision_prefers_vietnamese = true # last/lát, his/hí: giữ tiếng Việt
bracket_vowels = false              # [ → ơ, ] → ư
shortcuts_enabled = true            # Bật bảng gõ tắt (shortcuts.yml)
re_edit_word = true                 # Sửa dấu từ đã gõ khi đặt con trỏ ngay sau nó ("toan" + s → toán)

[general]
display_mode = "preedit"            # "preedit" = "Soạn từ rồi chèn" (mặc định) | "surrounding" = "Sửa thẳng trong ô"
preedit_underline = false           # "Hiện gạch chân chữ đang gõ" (false = gửi attr "không gạch chân")
underline_misspelled = false        # Gạch đỏ âm tiết sai chính tả khi gõ (chỉ preedit; IBus: gạch lỗi + chữ đỏ, Fcitx5: gạch chân)
terminal_direct = true              # Terminal: gõ thẳng, sửa dấu bằng BackSpace forward (khi host hỗ trợ)
toggle_hotkey = "Ctrl+space"        # xem §4; "" = tắt phím chuyển
per_app_state = true                # Nhớ Việt/Anh theo từng app
switch_sound = false                # Phát tiếng khi đổi Việt/Anh (lên = Việt, xuống = Anh; cần pw-play, paplay hoặc aplay)
default_vietnamese = true           # Trạng thái khi gặp app lần đầu
ui_language = "vi"                  # Ngôn ngữ giao diện (app cài đặt + menu bộ gõ): "vi" | "en" — xem §6
text_tools_menu = true              # Hiện "Công cụ…" (công cụ văn bản) trong menu bộ gõ — xem §7
add_tones_hotkey = ""               # Phím tắt "Thêm dấu cho vùng chọn" (cú pháp §4); "" = tắt (mặc định)
math_results = true                 # Gợi ý cạnh con trỏ (§8): kết quả phép tính "12*3=" → 36
number_chips = true                 # chip số dạng tiền "1tr2 " → 1.200.000 ₫
typo_hints = true                   # sửa lỗi gõ sai "tpoi " → tôi
tone_hints = false                  # thêm dấu cho câu không dấu "toi di hoc." → tôi đi học.
date_hints = true                   # ngày giờ "hôm nay " → 28/09/2026, "bây giờ " → 21:35, "âm lịch " → 30/9 năm Bính Ngọ, "Tết " → Tết 06/02/2027
double_space_period = false         # Văn bản tự động (§8b): "chào  " → "chào. "
auto_capitalize = false             # tự viết hoa đầu câu
smart_punctuation = false           # " ' → “ ” ‘ ’, "--" → "—"
quote_style = "curly"               # "curly" “ ” ‘ ’ | "low9" „ “ ‚ ‘ | "guillemets" « » ‹ ›
word_prediction = false             # gợi ý từ (hoàn thành từ / từ kế tiếp) trong ô ứng viên
filter_sensitive = true             # "Lọc từ nhạy cảm": gợi ý từ / sửa lỗi gõ không đưa từ tục
learn_words = true                  # "Học từ bạn gõ": gợi ý từ học từ / cặp từ hay gõ (cần word_prediction)

[experimental]
no_underline = "off"                # "off" | "forward-keys": Chromium/Electron không gạch chân (§9)

[app_modes]
# key = định danh app (Fcitx5: program; IBus: client name / app-id Wayland / WM_CLASS, chữ thường)
# value = "preedit" | "surrounding" | "direct" | "off" (off = không gõ tiếng Việt trong app này)
"org.gnome.texteditor" = "surrounding"
"kitty" = "preedit"
```

Mặc định = giống bản macOS hiện tại (bảng trên là mặc định chính xác, trừ ví dụ `[app_modes]`
vốn rỗng). Map sang cờ engine (`vt_engine_set_flag`):
`input_method=vni→VT_FLAG_VNI`, `simple_telex→SIMPLE_TELEX`, `free_marking→FREE_MARKING`,
`modern_tone→MODERN_TONE`, `quick_telex→QUICK_TELEX`, `spell_check→LIVE_SPELL_CHECK`,
`teencode→TEENCODE`, `auto_circumflex→AUTO_CIRCUMFLEX`, `contextual_english→CONTEXTUAL_ENGLISH`,
`contextual_english→RETRO_ENGLISH` (`retroactive_english` chọn tự áp / mời bằng gợi ý),
`contextual_english && english_by_frequency→ENGLISH_BY_FREQUENCY`,
`collision_prefers_vietnamese→COLLISION_PREFERS_VIETNAMESE`, `bracket_vowels→BRACKET_VOWELS`;
`auto_restore` là tham số của `vt_commit` (không phải cờ).

**Chế độ Surrounding tự hạ về Preedit** khi surrounding text chưa được *chứng minh* trong lần
focus này (Fcitx5: có cờ SurroundingText và `surroundingText().isValid()`; IBus: client đã thực
sự gửi `SetSurroundingText` có chữ — chỉ cờ capability thì chưa đủ), hoặc app nằm trong danh
sách ép preedit dựng sẵn (`isForcedPreeditApp` trong `app.cpp`): terminal (gnome-terminal, kgx,
ptyxis, konsole, kitty, alacritty, wezterm, foot, xterm, tilix, terminator, VTE…), LibreOffice,
Chromium/Electron/VS Code (mọi trình duyệt Chromium: Cốc Cốc, Yandex, Thorium, Cromite, Helium,
Slimjet…; editor AI họ VS Code: Antigravity, Windsurf, Kiro, Trae, Void, PearAI, Positron; app
Electron: Signal, Element, Mattermost, Rocket.Chat, Caprine, Ferdium, Beeper, Vesktop, Feishu,
Notion, Logseq, Joplin, Typora, Notesnook, Anytype, Bitwarden, 1Password, Postman, Insomnia,
GitHub Desktop, GitKraken, Claude…; Spotify (CEF); kể cả id Flatpak/snap/AppImage của chúng; web
app/PWA `crx_*` / `chrome-*-default`), Firefox/LibreWolf/Zen/Thunderbird, Wine, gnome-shell (+ overview),
krunner/plasmashell, JetBrains/Java, WPS/OnlyOffice, Steam. Ghi đè tay trong `[app_modes]`
thắng danh sách dựng sẵn (trừ khi surrounding text chưa được chứng minh). Khi không được sửa
chữ quanh con trỏ, sửa dấu từ đã gõ (re-edit) và ⌫ mở lại từ cũng tắt; có vùng chọn (thanh
URL sau Ctrl+L / autocomplete) thì không bao giờ xoá chữ trước con trỏ.

**Kiểm tra trước khi xoá** (`checkScreen` trong `session.cpp`): mọi lần xoá chữ trước con trỏ
(sửa dấu tại chỗ ở Surrounding, ⌫ mở lại từ, re-edit, gõ tắt / tự khôi phục) đọc lại chữ app báo
và so byte với chữ VietTelex đã đặt ở đó (⌫ mở lại: từ + đúng ký tự ranh giới đã gõ). Khớp ⇒ làm.
App chưa kịp nhận commit mới nhất (chữ báo về là tiền tố của chữ mong đợi, hoặc rỗng) ⇒ sửa tại
chỗ vẫn làm (kênh IM giữ thứ tự), ⌫ mở lại / re-edit thì bỏ qua — không bao giờ chờ app. Không
khớp (app tự sửa chữ, commit bị nhân đôi kiểu Draft.js, chữ dạng NFD…) ⇒ bỏ lần sửa đó (phím đi
như thường: ⌫ của app, phím dấu gõ thành chữ) và **đến lần focus sau** coi surrounding của ô này
là không tin được: không re-edit / ⌫ mở lại, từ mới gõ bằng preedit. Không ghi vào config.

**Chế độ Direct** (không bao giờ là `display_mode` toàn cục): terminal (cờ ô nhập hoặc
`isTerminalApp`) hoặc app ép `"direct"`, *chỉ khi* host giữ đúng thứ tự phím forward —
IBus client `gtk3-im:`/`gtk-im:`, Fcitx5 D-Bus có `KeyEventOrderFix` (bảng đầy đủ:
`docs/LINUX-SPEC.md` §3.1). Host khác → Preedit. `terminal_direct = false` hoặc
`"x" = "preedit"` tắt Direct. Pin `"direct"` trên định danh chung chung bị bỏ qua. Direct không
đọc lại chữ (không re-edit, ⌫ không mở lại từ).

**Gạch chân** (`preedit_underline`): chỉ app vẽ đúng attr của IM mới bỏ được gạch chân (GTK/Qt/VTE
qua module IBus/Fcitx5). Chromium/Electron và app Wayland dùng text-input-v3 (GNOME) luôn tự gạch (Chromium/Electron trên
Wayland: thử nghiệm `no_underline = "forward-keys"`, §9).

**Định danh app chung chung** (`isUnknownAppId`): rỗng, `default`, `gnome-shell`,
`qibusinputcontext`, `xim`, `wayland`, `sdl2_application`, `sdl3_application`, `gtk-im`, chỉ
có pid (`(1234)`) — một id cho nhiều app, nên pin `"surrounding"` trên id này bị bỏ qua. Snap
`x_x` được rút về `x` (`firefox_firefox` → `firefox`).

**Kiểu ô nhập** thắng mọi luật theo app: terminal (IBus `PURPOSE_TERMINAL` / Fcitx5
`Terminal`) → Preedit, không sửa chữ quanh con trỏ; URL/email → Preedit; số/điện thoại
(`DIGITS`/`NUMBER`/`PHONE`, Fcitx5 `Digit`/`Number`/`Dialable`) → gõ thẳng không biến đổi;
ô nhạy cảm (Fcitx5 `Sensitive`, IBus `HINT_PRIVATE`) → gõ thẳng và không lưu Việt/Anh theo app.

**Mặc định tắt (English)** (`isDefaultOffApp`): remote desktop / máy ảo — remmina, anydesk,
rustdesk, virtualboxvm, vmware, vmplayer, remote-viewer, gnome-connections, krdc, xfreerdp,
wlfreerdp, sdl-freerdp, moonlight, parsec: phía bên kia tự có bộ gõ. Chương trình Wine
(`wine*-preloader`, id đuôi `.exe`) KHÔNG nằm trong danh sách này (từ 1.0.5) — app chạy tại máy,
gõ tiếng Việt bình thường, ép gạch chân (`isWineApp`, nhận chữ qua XIM). Muốn gõ tiếng Việt ở đó thì thêm bất kỳ mục nào cho app
trong `[app_modes]` (`"remmina" = "preedit"`), mục đó thắng danh sách dựng sẵn.

**Ghi chung file**: hộp cấu hình Fcitx5 (các tuỳ chọn cơ bản) cũng ghi `config.toml`, nhưng chỉ
sửa đúng dòng của key nó quản lý (`setConfigValue`), giữ nguyên comment và key lạ — settings app
nên làm tương tự (hoặc ít nhất giữ key nó không biết).

**Định danh app**: Fcitx5 = `program` của input context; IBus = client name từ `focus_in_id`
(IBus ≥ 1.5.28, Ubuntu 24.04+). Trên Ubuntu 22.04 (IBus 1.5.26) IBus không báo app → mọi app
dùng chung key `default` (nhớ Việt/Anh chung, `[app_modes]` không áp dụng); Fcitx5 thì có đủ.

## 3. `shortcuts.yml` — cùng định dạng macOS

Port 1:1 `ShortcutImporter` của macOS (`App/Sources/AppState.swift`; cùng iOS/Android/Windows).
Flat YAML `key: value`, một mục mỗi dòng (`\n`, `\r\n`, `\r`; BOM đầu file bỏ qua); bỏ qua
dòng trống và dòng bắt đầu bằng `#`, `;`, `//`. Key: nếu dòng mở đầu bằng `"` và có nháy đóng
thì key là chuỗi trong ngoặc kép (unescape), sau đó (bỏ khoảng trắng) phải là `:`; không thì `:`
đầu tiên tách key/value. Key không chứa khoảng trắng, ≤ 64 ký tự. Value được trim; bọc `"…"` ⇒
bỏ ngoặc và unescape `\n` `\t` `\\` `\"` (escape khác giữ nguyên); bọc `'…'` ⇒ chỉ bỏ ngoặc.

Export: header `# VietTelex — bảng gõ tắt`, key sắp xếp (thứ tự byte). Key chứa `:` hoặc bắt đầu
bằng `#` `;` `//` `"` `'` ⇒ `"…"` có escape (`":D": 😀`, `"a:b": x`). Value nhiều dòng (`\n`/`\r`),
có khoảng trắng đầu/cuối, hoặc bắt đầu bằng `'` `"` `#` ⇒ `"…"` có escape (`\\` `\"`, xuống dòng
→ `\n`): `sig: "Thân mến,\nPhil"`. Còn lại ghi nguyên văn — file cũ không ngoặc đọc như trước.
Mẫu byte-chuẩn do macOS ghi: `linux/common/tests/data/shortcuts-macos.yml` (test C++ và Python
cùng so). File `sample-shortcuts.yml` ở gốc repo là ví dụ hợp lệ. Import (settings app) chấp
nhận thêm JSON object `{"key":"value"}` như macOS, nhưng **file lưu trên đĩa luôn là flat YAML**.

Khớp khi gõ: ở boundary, tra từ đã ghép (`composed`) trước, rồi phím thô (`raw`) — như macOS.

## 4. Phím chuyển Việt/Anh (`toggle_hotkey`)

Chuỗi `Mod+Mod+key`: modifier trong `Ctrl`/`Control`, `Alt`, `Shift`, `Super`/`Meta` (không
phân biệt hoa thường, không lặp), `key` là: một ký tự ASCII in được (`z`, `2`, `+` — `Ctrl++`),
`F1`–`F24`, hoặc tên keysym X11 trong bảng `names` của `parseHotkey` (`space`, `Tab`, `Return`,
`Escape`, `BackSpace`, `Left`/`Right`/`Up`/`Down` và tên mọi dấu câu ASCII: `grave`, `period`,
`at`, `greater`, `exclam`…; app cài đặt giữ bản sao `config.HOTKEY_NAMES`, có test so khớp).
Phím so theo **keysym nhận được** (sau Shift): app cài đặt lưu đúng keyval GTK báo, nên
Ctrl+Shift+2 trên bàn phím US là `Ctrl+Shift+at` (hiện "Ctrl+Shift+@"). Phím in được (kể cả
`space`) phải có Ctrl/Alt/Super (`Shift+a` sẽ nuốt chữ A); không modifier chỉ được F1–F24.
Chuỗi không đọc được ⇒ frontend không có phím đó (app cài đặt hiện "Tắt", hộp bắt phím từ chối
ngay: "Không dùng được …"). Mặc định `Ctrl+space`. Không cho phép `Super+space` (GNOME dùng). Trên Fcitx5, `Ctrl+space` trùng trigger key mặc định của Fcitx5: khi
VietTelex đang là IM hiện hành, VietTelex bắt phím trước và chỉ đổi Việt/Anh (vẫn ở VietTelex);
khi đang ở keyboard-us thì trigger của Fcitx5 chuyển sang VietTelex như thường. Chuỗi rỗng = không có phím chuyển (vẫn đổi qua menu IM).

## 5. `app-state` (frontend sở hữu)


Dòng `app<TAB>vi|en`, app đặt lâu nhất trước. Chỉ frontend đọc/ghi; settings app có thể xoá
file để "quên tất cả". Tối đa 200 app (đầy thì bỏ app đặt lâu nhất). Id không chỉ một app cụ
thể (`window:N` của GNOME, pid `(1234)`, `default`, `gnome-shell`…) không bao giờ được ghi
hay tra — số cửa sổ / pid dùng lại sẽ mang trạng thái của app khác.

## 6. Ngôn ngữ giao diện (`ui_language`)

`"vi"` (mặc định) hoặc `"en"`; thiếu / giá trị lạ → `"vi"`. **Không bao giờ theo locale của
máy** (quy ước chung với iOS `L10n`): máy tiếng Anh vẫn mở tiếng Việt cho tới khi người dùng
chọn English ở trang Chung → "Ngôn ngữ / Language". Áp dụng ngay: app cài đặt dựng lại cửa sổ;
frontend (qua inotify) đổi nhãn menu bộ gõ (Tiếng Việt/English, Công cụ…, tên 6 công cụ,
Cài đặt…). Tên riêng (VietTelex, Fcitx5, IBus, Telex, VNI) giữ nguyên. Hộp cấu hình gốc của
Fcitx5 (`fcitx5-config-qt`) và tên bộ gõ "Tiếng Việt (VietTelex)" vẫn tiếng Việt.

## 7. Công cụ văn bản (`text_tools_menu`, `add_tones_hotkey`)

Như bản macOS (menu VietTelex → Công cụ…): bôi đen chữ ở app bất kỳ rồi chọn trong menu bộ gõ
(Fcitx5: action "Công cụ…" ở status area/tray; IBus: property menu "Công cụ…") — **Thêm dấu cho
vùng chọn** (toi di hoc → tôi đi học), **HOA**, **thường**, **Hoa Đầu Từ**, **Hoa đầu câu**,
**Xoá dấu**. `add_tones_hotkey` (vd `"Ctrl+Alt+v"`, phải có Ctrl/Alt/Super, không trùng
`toggle_hotkey` — trùng thì phím chuyển thắng) chạy Thêm dấu; bộ gõ nuốt phím đó.

- Biến đổi chạy ở **process con** `/usr/lib/<multiarch>/viettelex/viettelex-text-tool`
  (gói `viettelex-text-tools`, dữ liệu `/usr/share/viettelex/*.bin`) — cùng mã Swift với
  iOS/macOS (`linux/engine-capi/Sources/TextToolCLI`), dữ liệu không bao giờ nằm trong process
  bộ gõ. Thiếu gói → menu tự ẩn. Vùng chọn > 20.000 ký tự: bỏ qua.
- Lấy chữ: surrounding text có vùng chọn (GTK4, Qt, LibreOffice…). App báo surrounding mà không
  có vùng chọn (GTK3 — Firefox, Chromium, app GTK3 — không bao giờ báo vùng chọn): lấy vùng chọn
  PRIMARY nhưng chỉ khi nó nằm sát con trỏ (chữ ngay trước/sau con trỏ trùng nó), không thì không
  làm gì. App không báo surrounding: vùng chọn PRIMARY (Fcitx5: addon
  clipboard; IBus/dự phòng: `wl-paste --primary` / `xclip` / `xsel` nếu có sẵn — không phải
  phụ thuộc bắt buộc). Trên đường phím (trước re-edit / ⌫ mở lại / xoá của gõ tắt), đọc
  PRIMARY bên ngoài (≤ 150 ms mỗi công cụ, dừng ở công cụ đầu tiên trả lời) chỉ khi cần:
  không khi app đã báo anchor ≠ cursor trong lần focus này (GTK4, Qt — anchor thật), không khi
  bản cache của addon clipboard Fcitx5 không nằm sát con trỏ (`selectionAtCaretProbe`).
- Thay: commit kết quả đè lên vùng chọn (gõ đè thay vùng chọn). **Không đụng clipboard** nên
  không có gì phải khôi phục. Nếu menu làm app mất focus, kết quả được commit ở lần focus lại
  (trong 3 giây).
- Không chạy ở ô mật khẩu / ô nhạy cảm và terminal (gõ đè không thay được gì ở đó).

## 8. Gợi ý cạnh con trỏ (`math_results`, `number_chips`, `typo_hints`, `tone_hints`, `date_hints`)

Như bản macOS 1.8.2 (`App/Sources/MathHint.swift`, `CaretSuggestions.swift`). Mỗi loại một
công tắc; tắt hết = một lần đọc cờ mỗi phím, không theo dõi gì.

| Key | Mặc định | Kích hoạt → gợi ý |
|---|---|---|
| `math_results` | bật | phép tính + `=` (`12*3=`, `200+10%=`, `125 x (4 + 5.5) =`) → `= 36`; Tab **hoặc Enter** chèn kết quả sau `=` |
| `number_chips` | bật | `50k` / `1tr2` / `2 tỷ` + dấu cách → `1.200.000 ₫` (chỉ dạng tiền, không đọc số thành chữ); Tab thay |
| `typo_hints` | bật | từ vừa gõ (ranh giới ` , ; ! ? )`) không là âm tiết Việt / tiếng Anh / từ chat → sửa MỘT phím kề trên bàn phím cứng hoặc đảo hai phím liền nhau, cùng ngưỡng macOS (tần suất ≥ 150, hơn ứng viên thứ hai ≥ 80); không có bản sửa tiếng Việt ⇒ bản sửa **tiếng Anh** một sửa trên phím thô (đảo / phím kề; sót / thừa phím khi ≥ 5 chữ — `spellnig` → spelling, `teh` → the), tần suất ≥ 140 (từ ≥ 7 chữ: ≥ 60), hơn ứng viên thứ hai ≥ 60 (`TypoFixLogic.englishDefaults`); Tab thay (giữ ký tự ranh giới), Esc = không gợi ý lại từ đó trong phiên |
| `tone_hints` | **tắt** | ≥ 3 âm tiết không dấu liên tiếp, rồi `. ! ?` hoặc dừng gõ 0,9 s sau dấu cách → cụm có dấu (Thêm dấu); Tab thay cả cụm, Esc = không mời lại cụm đó |
| `date_hints` | bật | `hôm nay` / `ngày mai` / `hôm qua` + dấu cách → `dd/MM/yyyy`; `bây giờ` → `HH:mm`; `âm lịch` / `ngày âm` / `ÂL` → âm lịch hôm nay `30/9 năm Bính Ngọ` (lịch Việt Nam UTC+7; tháng nhuận `1/6 nhuận năm Ất Tỵ`); `Tết` → ngày dương mùng 1 Tết kế tiếp `06/02/2027` (đúng mùng 1 thì là hôm nay; Tab giữ chữ: `Tết 06/02/2027`); today / tomorrow / yesterday / now chỉ sau một từ tiếng Anh; Tab thay cụm |

Luật chung: chỉ Tab áp dụng (Enter chỉ cho phép tính — sau `50k␣` Enter là gửi tin), phím khác
tắt gợi ý rồi đi tiếp như thường, không bao giờ tự thay, không chạy ở ô mật khẩu / ô nhạy cảm /
khi đang English. Hiển thị: Fcitx5 = aux text của input panel, IBus = auxiliary text — UI của
khung (classicui/kimpanel, ibus-ui-gtk3, popup của GNOME Shell) vẽ ngay cạnh con trỏ; preedit
không bị đụng. Loại thay chữ đã chốt (mọi loại trừ phép tính) chỉ ở nơi bộ gõ được sửa chữ quanh
con trỏ (surrounding đã chứng minh, không phải app ép preedit — Chrome/Firefox/LibreOffice…; hoặc
terminal Direct); trước khi thay, chữ trước con trỏ được đọc lại (khi app báo) và phải khớp.

Chạy ở đâu: bộ gõ chỉ theo dõi đuôi chữ vừa gõ và xét cổng rẻ ở ranh giới từ / phím `=`
(`common/src/caret_hints.cpp`, `vt_is_valid_syllable` / `vt_is_unaccented_syllable`); việc tính
(MathResults, NumberChips, lexicon sửa lỗi, Thêm dấu — mã Swift chung iOS/macOS) ở
`viettelex-text-tool --serve`: một process con sống lâu, bật ở lần kích hoạt đầu, tự thoát sau
2 phút rảnh. Thiếu gói `viettelex-text-tools` → không có gợi ý nào.

## 8b. Văn bản tự động (`double_space_period`, `auto_capitalize`, `smart_punctuation`, `quote_style`, `word_prediction`, `filter_sensitive`)

Port bản macOS (16/10/2026: `App/Sources/SystemAutoText.swift`, `WordPrediction.swift`). macOS
theo cài đặt Nhập văn bản của hệ thống; Linux không có cài đặt chung nên mỗi tính năng là một
công tắc của VietTelex, **mặc định TẮT hết** (người dùng Linux hay gõ trong terminal / code) —
trừ `filter_sensitive` (bật, như iOS / macOS).
Tắt = một lần đọc cờ ở phím cách / chữ đầu từ / `"` `'` `-`; không theo dõi gì, không nạp dữ liệu.

| Key | Mặc định | Làm gì |
|---|---|---|
| `double_space_period` | tắt | Dấu cách thứ hai trong 1,1 s sau chữ / số / ngoặc-nháy đóng → thay dấu cách đầu bằng `. ` (nuốt phím). Không sau dấu câu / đầu văn bản; giữ phím cách (autorepeat: hai lần nhấn không có nhả ở giữa) không tính. Chỉ nơi bộ gõ được sửa chữ quanh con trỏ (surrounding đã chứng minh); đọc lại 2 ký tự trên màn hình, lệch ⇒ dấu cách thường |
| `auto_capitalize` | tắt | Chữ a–z đầu từ, ngay sau `. ? !` + khoảng trắng (bỏ ngoặc/nháy đóng), xuống dòng, hoặc đầu văn bản **chỉ ở ô nhiều dòng** (Fcitx5 `CapabilityFlag::Multiline`; IBus không có cờ này ⇒ không viết hoa đầu ô) → đưa chữ HOA vào engine (Telex vẫn ghép: `dduwowcj` → `Được`). Bỏ qua viết tắt (`Mr.`, `TP.`, `e.g.`…), `...`, email / URL / tên miền, tên viết tắt một chữ (`J.`). ⌫ xoá đúng chữ hoa đó ⇒ chữ đầu kế tiếp giữ thường. Ngữ cảnh từ đuôi phím đã gõ; không biết thì đọc tối đa 24 ký tự (chỉ khi surrounding đã chứng minh) |
| `smart_punctuation` | tắt | `"` / `'` → ngoặc mở sau khoảng trắng / đầu văn bản / ngoặc mở / gạch dài, còn lại ngoặc đóng (`don't` → `don’t`) — chèn thay phím, không sửa chữ cũ (chạy cả ở Chrome); ký tự trước không biết ⇒ giữ phím thẳng. `--` → `—`, gõ `-` tiếp ngay sau `—` vừa đổi → `---`; không đổi `<!--`, `!--` và chuỗi ≥ 3 gạch. Phần gạch sửa chữ cũ ⇒ như `double_space_period` |
| `quote_style` | `"curly"` | `"curly"` `“ ” ‘ ’`, `"low9"` `„ “ ‚ ‘`, `"guillemets"` `« » ‹ ›` (= NSUserQuotesArray macOS) |
| `word_prediction` | tắt | Dừng gõ 0,3 s → **một** từ (hạng 1, không danh sách, không số thứ tự): **hoàn thành** từ đang gõ (≥ 2 chữ; tiếng Anh khi ngữ cảnh tiếng Anh, khi không âm tiết Việt nào khớp, hoặc khi phím thô ≥ 4 là tiền tố tiếng Anh rõ ràng hơn mọi cách đọc tiếng Việt — `pers` (hiện `pé`) → person; không bao giờ khi chữ đang gõ đã là âm tiết Việt phổ biến: `toi`, `duoc`, `cam`, `ther`→`thẻ`; theo phím thô) hoặc **từ kế tiếp** ngay sau một dấu cách — dòng trigram cho 2 từ ngữ cảnh (`cảm ơn ␣` → bạn), hoặc cặp **seed** chọn tay của iOS với một từ ngữ cảnh (`cảm ␣` → ơn, `xin ␣` → lỗi; bảng `App/Sources/SeedNextData.swift`, sinh bằng `Scripts/gen-seed-next.sh` từ chính UserLangModel iOS); không bao giờ đoán bigram thống kê một từ (`Tên ␣` → không gì). Tab / click = nhận (+ dấu cách; phím **ngay sau** là `. , ? ! ; :` hoặc ngoặc / nháy đóng cong ⇒ dấu câu dính vào từ, dấu cách dời ra sau — `được. ` — và phím cách kế bị nuốt; `/` ⇒ chỉ gỡ dấu cách; đọc lại màn hình trước khi gỡ; dấu cách đó cũng là dấu cách thứ nhất của `double_space_period`), Esc = bỏ (không gợi ý lại khi từ vẫn bắt đầu bằng chữ đã từ chối), phím khác bỏ qua rồi đi tiếp — **phím số không chọn ứng viên**. Gợi ý cạnh con trỏ khác (§8) luôn thắng. Không bao giờ tự thay. Học từ người dùng: `learn_words`. **Tên miền email** (như iOS/Android/macOS/Windows): gõ `ten@` → `gmail.com`, `ten@ic` → `icloud.com` (thứ tự gmail.com, icloud.com, yahoo.com, outlook.com; khớp tiền tố sau `@`, không phân biệt hoa thường; hết khớp / đã gõ đủ ⇒ không gì). Phần trước `@` phải là `[A-Za-z0-9._%+-]+` thấy trọn trong chữ đã gõ (đầu ô / sau khoảng trắng hay `, ; < ( : " '`; chữ trước con trỏ không đọc được ⇒ không gợi ý). Hiện ngay (so chuỗi trong process IME, không hỏi process con), cả ở ô URL / email (vẫn không ở terminal / trình soạn code / Direct). Tab / click chèn **nguyên văn** phần còn thiếu (không lặp `@` / chữ đã gõ, không thêm dấu cách, không học); Telex đã đổi chữ đang soạn (`yahoo` → `yahô`) ⇒ thay chữ đó; engine reset nên chữ gõ sau không bị bỏ dấu theo. Esc ⇒ không gợi ý lại cho địa chỉ đó |
| `filter_sensitive` | **bật** | "Lọc từ nhạy cảm" (= iOS `filterSensitive`, macOS Cài đặt): gợi ý từ (hoàn thành, từ kế tiếp seed / trigram, tiếng Anh) và sửa lỗi gõ không chủ động đưa từ trong `SensitiveWords.set`; tắt ⇒ như iOS, seed hiện nguyên (`vãi ␣` → lồn thay vì cả). Gõ tay luôn bình thường. Gửi theo từng yêu cầu `predict` / `typo` (trường cuối `0` khi tắt) |
| `learn_words` | **bật** | "Học từ bạn gõ" (= iOS học từ hay dùng, macOS Cài đặt; chỉ có tác dụng khi `word_prediction` bật). Session (process IME) chỉ theo dõi từ **chính nó soạn và chốt** ở ranh giới từ — không nội dung gõ tắt nở, không chữ app tự gõ — và gửi lượt học (`learn <từ> <prev1> <prev2> <trọng số>`, một chiều, không bao giờ bị yêu cầu mới đè) cho process con `viettelex-text-tool --serve`, nơi giữ mô hình (`LearnStore.swift` + `App/Sources/LearnedModel.swift` dùng chung macOS; bảng + file VTL2 của iOS). Mỗi từ được giữ chờ tới sự kiện kế: ⌫ ngay sau ranh giới / Ctrl-tổ hợp / gợi ý thay chữ ⇒ bỏ; nhận gợi ý sửa lỗi gõ ⇒ học dạng đã sửa; nhận gợi ý từ ⇒ trọng số 2. Không bao giờ ở ô mật khẩu / `[app_modes]` off / chế độ English / terminal / trình soạn code / ô URL-email (cùng cổng văn bản tự động). Ngữ cảnh: ≤ 2 từ trước cùng câu, cách đúng một dấu cách. Xếp hạng (cùng hợp đồng iOS): cặp / bộ ba học được ≥ 2 lần mới gợi ý từ kế tiếp không có seed (`tên tôi` gõ 2 lần ⇒ `Tên ␣` → tôi); bộ ba học ≥ 2 lần dẫn trước trigram tĩnh; từ ngoài lexicon cần ≥ 3 lần; hoàn thành từ được cộng đếm cá nhân. Trần 3000 từ / 6000 cặp / 3000 bộ ba (đầy ⇒ chia đôi), decay 0,7 mỗi tuần. File `$XDG_DATA_HOME/viettelex/learned-words.bin` (mặc định `~/.local/share/viettelex/`), ghi nguyên tử 3 s sau lượt học cuối và khi process con thoát; hỏng ⇒ bắt đầu rỗng. Không mạng, không đồng bộ. App Cài đặt → "Xoá từ đã học…" ghi đè bằng kho rỗng (process con đang chạy thấy file đổi ⇒ nạp lại). Từ nhạy cảm vẫn được đếm, bị lọc lúc gợi ý theo `filter_sensitive`. Yêu cầu `predict` mang thêm trường `learn` (`1` = dùng dữ liệu học; thiếu ⇒ không nạp) |

Chung: không chạy trong terminal (`isTerminalApp`, ô Terminal, Direct), trình soạn code
(`autotext::isCodeEditorApp`: VS Code + họ, Zed, Sublime, JetBrains, Kate, Builder, Geany…), ô
URL / email, ô mật khẩu / nhạy cảm, khi đang English hoặc `[app_modes]` off.

Gợi ý từ — hiển thị: ô ứng viên gốc của khung (Fcitx5 `CommonCandidateList` ngang, nhãn rỗng,
ứng viên đầu được tô = Tab, aux "Tab"; IBus `IBusLookupTable` ngang, nhãn rỗng + aux "Tab";
click = `CandidateWord::select` / `candidate_clicked`). Preedit: từ đang gõ là preedit nên chọn
= commit từ + dấu cách (chạy cả ở Chrome/Firefox/Electron); Surrounding: thay đúng từ trên màn
hình (đọc lại trước khi xoá). Tính ở `viettelex-text-tool --serve` (lệnh `predict`,
`engine-capi/Sources/TextToolCLI/Predict.swift`: cùng mã xếp hạng iOS/macOS — VNSuggest,
SuggestRank, SyllableLM `vnlm.bin`, SeedData, DisplayCase, SensitiveWords, SwipeEnglish
`enlexicon.bin`); bộ gõ chỉ hẹn giờ (HintService chờ 0,3 s, phím mới = huỷ). Không biết chữ
trước đoạn đã gõ (vừa focus ở Chrome…) ⇒ từ đầu tiên được coi là đứng riêng.

## 8c. Tự sửa từ phía trước (`[typing] retroactive_english`, thử nghiệm, mặc định tắt)

Xem docs/DESIGN.md "Sửa ngược tiếng Anh". App cài đặt chỉ hiện công tắc ngay dưới "Quyết định
theo ngữ cảnh", và chỉ khi nó bật. Cờ `VT_FLAG_RETRO_ENGLISH` bật khi `contextual_english` bật
(tắt nó = không có gì). `Session` (`retro_english.h`) báo mọi ký tự ranh giới cho engine
(`vt_note_boundary`). Ở ranh giới gõ được (dấu cách, dấu câu), phép sửa chỉ được dùng khi Session
được phép sửa chữ đã chốt (`allowSurroundingEdits`; không ở terminal/Direct/passthrough/field bị
distrust) và surrounding text chứng minh các từ bị viết lại có đúng trên màn hình (host được phép
chậm đúng phần từ vừa commit trong phím này). Enter/Tab chỉ cắt mạch.
- Công tắc **bật**: áp bằng delete-surrounding + commit. ⌫ ngay sau đó khôi phục chữ cũ nếu text
  trước con trỏ vẫn kết thúc bằng phần vừa chèn.
- Công tắc **tắt**: MỜI bằng gợi ý cạnh con trỏ (aux text, `CaretSuggestion::Kind::Retro`):
  "His car is   Tab". Tab đọc lại text rồi áp đúng phép sửa đó; phím khác ẩn gợi ý và đi tiếp.
  Gợi ý này thắng mọi gợi ý khác cùng phím (trả lời của helper bị bỏ khi nó đang hiện).

### 8d. Đoán từ trùng theo tần suất (`[typing] english_by_frequency`, thử nghiệm, mặc định tắt)

App cài đặt hiện công tắc ngay dưới "Tự sửa từ phía trước", cùng điều kiện (`contextual_english`
bật). Cờ `VT_FLAG_ENGLISH_BY_FREQUENCY` chỉ bật cùng `VT_FLAG_RETRO_ENGLISH` (tắt = engine chỉ thử
một Bool mỗi lần chốt từ). Đầu cụm, từ vừa là tiếng Anh phổ biến vừa là âm tiết Việt hiếm (his →
hí) chốt thành tiếng Anh; từ kế cho thấy là tiếng Việt (cặp hay gặp "hí hửng", lặp "hí hí") thì
engine trả phép sửa có `flip_back = 1`. `Session::finishRetro` áp phép LẬT LẠI đó tự động qua đúng
đường xoá + chèn có kiểm surrounding text, kể cả khi công tắc "Tự sửa từ phía trước" tắt (chế độ
mời) và cả ở Enter / Tab / Esc — trước khi phím đi tiếp. Không có ⌫ hoàn tác sau Enter.

## 9. Thử nghiệm: không gạch chân ở Chromium/Electron (`[experimental] no_underline`)

`"off"` (mặc định; giá trị lạ cũng là off) hoặc `"forward-keys"`. App cài đặt: trang **Ứng dụng →
Hiển thị chữ đang gõ → Nâng cao → "Bỏ gạch chân trong Chrome/Electron (thử nghiệm)"** (ghi tại chỗ như mọi
key khác); áp dụng ngay (inotify). Đánh giá đầy đủ + kế hoạch kiểm thử:
`docs/NO-UNDERLINE-SPIKE.md`.

- `"forward-keys"`: app họ Chromium (`isChromiumApp`: Chrome/Chromium/Brave/Edge/Vivaldi/Opera/
  Cốc Cốc…, VS Code + Antigravity/Windsurf/Kiro…, Slack, Discord, Zalo, Obsidian…, PWA `crx_*` / `chrome-*-default`) gõ thẳng
  không gạch chân; sửa dấu bằng **phím BackSpace do bộ gõ forward** rồi commit chữ mới — không
  dùng `delete_surrounding_text` (Draft.js/Lexical ở Messenger không theo được). Chỉ khi:
  host giữ thứ tự phím forward với commit (`hostOrdersForwardedKeys`: IBus trên GNOME Wayland —
  client `gnome-shell`; Fcitx5 frontend `wayland` trên KWin; Fcitx5 frontend `ibus` trên GNOME
  Wayland, chỉ ngữ cảnh của chính gnome-shell — `program` `gnome-shell` hoặc id app `*.desktop` /
  `window:N` của Fcitx5 mới, trong phiên GNOME Wayland; client IBus X11/XWayland khác qua cùng
  frontend vẫn gạch chân) — **trừ GNOME 50** (mutter 50 bỏ phím forward, sửa ở 51:
  `gnome::mutterDeliversForwardedKeys`, NO-UNDERLINE-SPIKE §5.2), app id thật (không phải id chung),
  surrounding text đã chứng minh trong lần focus này, ô không phải URL / terminal / số / mật
  khẩu / nhạy cảm, và app không có mục `[app_modes]` (mục đó luôn thắng). Còn lại: như `"off"`.
- Ở chế độ này không re-edit, ⌫ không mở lại từ (chỉ sửa trong từ đang gõ, gõ tắt, tự khôi
  phục); vùng chọn ở con trỏ thì không gửi BackSpace.
- Mỗi lần sửa được **xác nhận** từ chữ app báo trước con trỏ ở các phím sau. Chữ khác điều
  VietTelex đã gửi (mất / thừa BackSpace, commit đôi…) hoặc quá 1 giây chưa thấy kết quả ⇒ ô đó
  về gạch chân tới lần focus sau. Không bao giờ chờ / ngủ trong đường phím.
- Chrome/Electron phải chạy IME Wayland gốc (text-input), không qua `--gtk-version=4` / XWayland.
  Chrome ≥ 140 và Electron ≥ 38 đã như vậy mặc định trên phiên Wayland (text-input-v3 mặc định
  từ Chromium 137, Wayland mặc định từ Chrome 140 / Electron 38). App cũ hơn cần cờ ⇒ app cài
  đặt tự làm, người dùng không chạy lệnh nào:

### 9.1 Lối tắt có cờ (`viettelex_settings/launchers.py`)

- Khi cờ bật **và** phiên Wayland trên GNOME (IBus/Fcitx5) hoặc KDE (Fcitx5): với mỗi app họ
  Chromium (tên file .desktop hoặc `StartupWMClass` khớp `isChromiumApp` — danh sách Python có
  test so khớp với `app.cpp`) tìm trong `XDG_DATA_DIRS` (+ export Flatpak, `/var/lib/snapd/desktop`),
  chép file sang `$XDG_DATA_HOME/applications/` (mặc định `~/.local/share/applications`, ưu
  tiên cao hơn theo XDG) và chèn `--enable-wayland-ime --wayland-text-input-version=3
  --ozone-platform-hint=auto` vào mọi `Exec=` (mục chính + Desktop Actions): ngay sau chương
  trình (trước tham số và `%U/%F`); `env A=1 /opt/x` ⇒ sau `/opt/x`; `flatpak run … <appid>` ⇒
  sau app id (trước `@@u`); `/snap/bin/x`, `snap run x` ⇒ sau đó. Cờ đã có thì không thêm
  (idempotent). KDE với KWin < 6.7 (còn text-input-v1): `=1`. Mọi key khác (`TryExec`, `Icon`,
  `StartupWMClass`, bản dịch, `X-Flatpak`…) giữ nguyên.
- Bỏ qua (báo trong dòng mô tả): Exec ép X11 (`--ozone-platform=x11`, `GDK_BACKEND=x11`,
  `ELECTRON_OZONE_PLATFORM_HINT=x11`, `--disable-wayland-ime`), wrapper không sửa an toàn
  (`sh -c`, `flatpak run --command=sh`, `gtk-launch`…), `DBusActivatable=true`; Chrome / Edge /
  Chromium (.deb, snap) có phiên bản ≥ 140 đọc được từ `/var/lib/dpkg/status` /
  `snap.yaml` (đã bật mặc định — trừ KDE cần `=1`).
- Sở hữu: file tạo ra có `X-VietTelex-Generated=<sha256(nguồn + cờ)[:16]>` và
  `X-VietTelex-Source=<đường dẫn nguồn>`. Chỉ file có dòng `X-VietTelex-Generated` mới bị sửa/xoá;
  file người dùng tự đặt cùng tên (hoặc symlink) không bao giờ bị ghi đè — chỉ báo lại. Muốn
  giữ file của ta làm của mình: xoá dòng `X-VietTelex-Generated`.
- Làm mới mỗi lần mở app cài đặt và khi bật/tắt: nguồn đổi (hash khác) ⇒ tạo lại; nguồn mất ⇒
  xoá; tắt ⇒ xoá mọi file của ta. Phiên X11 / desktop chưa hỗ trợ mà cờ đang bật: chỉ làm mới /
  xoá file đã có, không tạo mới. Có thay đổi ⇒ `update-desktop-database -q <dir>` nếu có (lỗi bỏ
  qua).
- App đang chạy mà tiến trình chính không mang `--enable-wayland-ime` (mở trước khi có lối tắt)
  ⇒ dòng mô tả + thông báo "thoát hẳn rồi mở lại …".
- Không dùng `~/.config/<app>-flags.conf`: chỉ wrapper của Arch đọc; wrapper của gói .deb Google
  Chrome (`chrome/installer/linux/common/wrapper`) chỉ `exec -a "$0" "$HERE/chrome" "$@"`.
