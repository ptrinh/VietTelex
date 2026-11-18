"""Ngôn ngữ giao diện (vi | en) — cùng cách làm với iOS/Shared/L10n.swift.

Chữ gốc tiếng Việt CHÍNH LÀ khoá: `_("Gõ tắt")` trả "Gõ tắt" (mặc định) hoặc "Shortcuts" khi
người dùng chọn English (config.toml [general] ui_language = "en"). Mặc định LUÔN "vi" —
KHÔNG nhìn locale của máy (LANG/LC_*), quy ước chung mọi bản VietTelex.

Thêm chuỗi mới: bọc `_("…")` (hoặc `N_("…")` cho hằng cấp module, dịch lúc hiển thị bằng
`_(x)`) và thêm bản dịch vào `EN` — tests/test_i18n.py quét mã nguồn, thiếu là đỏ. Tham số
`%s` / `%d` phải giữ đúng số lượng và thứ tự. Tên riêng (VietTelex, Fcitx5, IBus, Telex,
VNI…) giữ nguyên.

Module thuần Python (không GTK) để test chạy được ở mọi máy.
"""

SUPPORTED = ("vi", "en")

_lang = "vi"


def normalized(value):
    """Giá trị đã lưu → "vi" | "en"; thiếu/lạ ⇒ "vi"."""
    return "en" if value == "en" else "vi"


def set_language(value):
    global _lang
    _lang = normalized(value)


def language():
    return _lang


def _(vi):
    if _lang != "en":
        return vi
    return EN.get(vi, vi)


def N_(vi):
    """Đánh dấu để dịch (hằng cấp module) — trả nguyên chuỗi, dịch lúc hiển thị bằng `_`."""
    return vi


def C_(context, vi):
    """Như `_` nhưng có ngữ cảnh — cùng chữ Việt, nghĩa tiếng Anh khác (vd. "Tuỳ chỉnh" là tab
    "Options" nhưng ở bộ chọn hồ sơ là "Custom"). Khoá EN: "<context>\x04<chữ Việt>"."""
    if _lang != "en":
        return vi
    return EN.get(context + "\x04" + vi, vi)


EN = {
    # --- chế độ theo app / hộp thoại chung
    "Tự động": "Automatic",
    "Gõ thẳng, sửa bằng Backspace": "Type directly, fix with Backspace",
    "Tắt tiếng Việt": "Vietnamese off",
    "Huỷ": "Cancel",
    "Lưu file": "Save file",
    "Mở file": "Open file",
    "Lưu": "Save",
    "Mở": "Open",
    "VietTelex — Cài đặt": "VietTelex — Settings",
    "Đang kiểm tra…": "Checking…",

    # --- Gõ phím
    "Kiểu gõ": "Typing method",
    "Bộ gõ": "Input method",
    "Hướng dẫn bật bộ gõ…": "Setup guide…",
    "Gõ dấu bằng chữ số": "Tones with number keys",
    "Dấu bằng số: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 xoá dấu.":
        "Tones with digits: 1–5 acute/grave/hook/tilde/dot, 6 â/ê/ô, 7 ơ ư, 8 ă, 9 đ, 0 clears.",
    "Telex đơn giản": "Simple Telex",
    "w đứng riêng vẫn là w (gõ uw ra ư).":
        "A lone w stays w (type uw for ư).",
    "Chính tả teencode": "Teencode spelling",
    "Nhận kiểu viết chat: wá, zui zẻ, kó. Tắt: was, zoo giữ nguyên.":
        "Accept chat spellings: wá, zui zẻ, kó. Off: was, zoo stay as typed.",
    "Tự thêm dấu mũ": "Auto-add circumflex",
    "Gõ vietj ra việt, benhj ra bệnh khi vần không mũ không tồn tại.":
        "Type vietj for việt when the plain vowel isn’t a valid syllable.",
    "Gõ đúp phụ âm đầu: kk → kh, nn → ng, pp → ph, tt → th…":
        "Double the first consonant: kk → kh, nn → ng, pp → ph, tt → th…",
    "Bỏ dấu tự do": "Free tone placement",
    "Đặt dấu ở đâu trong từ cũng được (ama → âm). Tắt: chặt hơn, hợp gõ tiếng Anh/code.":
        "Put the tone anywhere in the word (ama → âm). Off: stricter, better for English/code.",
    "Phím ngoặc: [ ra ơ, ] ra ư": "Bracket keys: [ types ơ, ] types ư",
    "Bỏ dấu kiểu mới (oà, uý)": "Modern tone placement (oà, uý)",
    "hoà, thuý, khoẻ thay vì hòa, thủy, khỏe.":
        "hoà, thuý, khoẻ instead of hòa, thủy, khỏe.",
    "VietTelex đang hoạt động": "VietTelex is running",
    "Bộ khung gõ: %s. Chuyển Việt/Anh bằng %s.": "Framework: %s. Switch Vietnamese/English with %s.",
    "menu bộ gõ": "the input method menu",
    "Chưa có bộ khung gõ Fcitx5 hoặc IBus": "No Fcitx5 or IBus framework found",
    "Cài gói viettelex-fcitx5 (khuyên dùng) hoặc viettelex-ibus, rồi làm theo hướng dẫn.":
        "Install viettelex-fcitx5 (recommended) or viettelex-ibus, then follow the guide.",
    "VietTelex chưa được bật trong %s": "VietTelex is not enabled in %s",
    "Bấm “Hướng dẫn bật bộ gõ…” để làm từng bước.": "Click “Setup guide…” for step-by-step help.",

    # --- Gợi ý & công cụ
    "Chính tả": "Spelling",
    "Kiểm tra chính tả khi gõ": "Spell-check while typing",
    "Ngừng thêm dấu ngay khi từ không thể là tiếng Việt (google, github).":
        "Stop adding tones once a word can’t be Vietnamese (google, github).",
    "Quyết định theo ngữ cảnh": "Decide by context",
    "Sau một từ tiếng Anh, từ kế giữ tiếng Anh: “he is”, không thành “he í”.":
        "After an English word, the next stays English: “he is”, not “he í”.",
    "Tự sửa từ phía trước (thử nghiệm)": "Fix earlier words (experimental)",
    "Sửa từ bị bỏ dấu nhầm khi câu hoá ra tiếng Anh: “Hí cả í” → “His car is”.":
        "Fixes mis-toned words once the sentence turns out English: “Hí cả í” → “His car is”.",
    "Đoán từ trùng theo tần suất (thử nghiệm)": "Guess colliding words by frequency (experimental)",
    "Thêm dấu cho từ đã gõ: toan + s → toán.":
        "Add a mark to a word already typed: toan + s → toán.",
    "Gạch đỏ âm tiết sai chính tả khi gõ": "Underline misspelled syllables while typing",
    "Ưu tiên tiếng Việt": "Prefer Vietnamese",
    "Ưu tiên tiếng Anh": "Prefer English",
    "Hiển thị chữ đang gõ": "Word being typed",
    "Soạn từ rồi chèn": "Compose the word, then insert",
    "Tắt: chữ đang gõ trông như chữ thường (GTK, Qt, VTE X11). Chrome/Electron vẫn tự gạch.":
        "Off: the word being typed looks like normal text (GTK, Qt, X11 VTE). Chrome still underlines.",
    "Terminal: gõ thẳng, sửa dấu bằng Backspace": "Terminals: type directly, fix marks with Backspace",
    "Bỏ gạch chân trong Chrome/Electron (thử nghiệm)":
        "No underline in Chrome/Electron (experimental)",
    "Chrome, VS Code, Slack… gõ thẳng, sửa bằng Backspace. Chỉ GNOME/KDE Wayland; mở lại app.":
        "Chrome, VS Code, Slack… type directly, fix with Backspace. GNOME/KDE Wayland only; reopen apps.",
    "Trạng thái: đang có hiệu lực trong phiên này.": "Status: active in this session.",
    "Trạng thái: đã bật nhưng không có hiệu lực trong phiên này.":
        "Status: on, but not active in this session.",
    "Phiên này là X11: không áp dụng, Chrome/Electron vẫn gạch chân.":
        "This is an X11 session: not applicable, Chrome/Electron keep the underline.",
    "GNOME 50 làm mất phím Backspace của bộ gõ (sửa ở 51): tạm giữ gạch chân ở Chrome/Electron.":
        "GNOME 50 drops the input method’s Backspace (fixed in 51): Chrome/Electron keep the underline.",
    "KDE cần Fcitx5; IBus trên KDE chưa hỗ trợ.": "KDE needs Fcitx5; IBus on KDE is not supported.",
    "Desktop này (%s) chưa hỗ trợ — chỉ GNOME và KDE Plasma.":
        "This desktop (%s) is not supported — GNOME and KDE Plasma only.",
    "Đã thêm cờ cho: %s.": "Flags added for: %s.",
    "Đã bật sẵn, không cần cờ: %s.": "Already on by default, no flags needed: %s.",
    "Đang chạy bản cũ — thoát hẳn rồi mở lại: %s.": "Running without the flags — quit fully and reopen: %s.",
    "Lối tắt bạn tự sửa (đã có cờ): %s.": "Launchers you edited yourself (flags present): %s.",
    "Không sửa lối tắt bạn tự tạo: %s — tự thêm %s vào dòng Exec=.":
        "Not touching launchers you created: %s — add %s to the Exec= line yourself.",
    "Đang ép chạy X11, giữ nguyên (vẫn gạch chân): %s.":
        "Forced to X11, left as is (keeps the underline): %s.",
    "Không tự thêm cờ được: %s.": "Could not add the flags automatically: %s.",
    "Chưa thấy app Chrome/Electron nào cài trên máy.": "No Chrome/Electron apps found on this computer.",
    "Lỗi khi ghi lối tắt: %s": "Error writing launchers: %s",
    "Đã tắt — Chrome/Electron về gạch chân như cũ.": "Off — Chrome/Electron go back to the underline.",
    "Đã bật, nhưng máy này chưa áp dụng được (xem dòng mô tả).":
        "On, but it does not apply on this computer (see the description).",
    "Thoát hẳn rồi mở lại %s để bỏ gạch chân.": "Quit fully and reopen %s to drop the underline.",
    "Đã bật. Mở lại Chrome/Electron để bỏ gạch chân.": "On. Reopen Chrome/Electron to drop the underline.",
    "Công cụ văn bản": "Text tools",
    "Chọn chữ ở app bất kỳ → menu bộ gõ → Công cụ…: thêm dấu, hoa/thường, xoá dấu.":
        "Select text in any app → input method menu → Tools…: add marks, change case, remove marks.",
    "Hiện công cụ văn bản trong menu": "Show text tools in the menu",
    "Menu “Công cụ…” của bộ gõ (khay Fcitx5 / menu IBus) liệt kê 6 công cụ trên.":
        "The input method’s “Tools…” menu (Fcitx5 tray / IBus menu) lists the 6 tools above.",
    "Chưa cài gói viettelex-text-tools": "viettelex-text-tools is not installed",
    "Cần cho gợi ý và công cụ văn bản. Cài bằng lệnh dưới đây rồi khởi động lại bộ gõ.":
        "Needed for suggestions and text tools. Run the command below, then restart the input method.",
    "Gợi ý cạnh con trỏ": "Suggestions next to the caret",
    "Chỉ Tab mới áp dụng, Esc bỏ; không bao giờ tự thay. Cần gói viettelex-text-tools.":
        "Only Tab applies it, Esc dismisses; never replaces by itself. Needs viettelex-text-tools.",
    "Hiện kết quả phép tính": "Show math results",
    "Gõ phép tính kết thúc bằng = (12*3=); kết quả hiện cạnh con trỏ, Tab để chèn.":
        "Type a sum ending in = (12*3=); the result shows by the cursor, Tab inserts it.",
    "50k, 1tr2, 2 tỷ + dấu cách → 1.200.000 ₫ cạnh con trỏ; Tab để thay.":
        "50k, 1tr2, 2 tỷ + space → 1.200.000 ₫ next to the caret; Tab replaces.",
    "Gợi ý sửa lỗi gõ sai": "Typo fix suggestions",
    "Sau từ gõ nhầm (tpoi), từ đúng (tôi) hiện cạnh con trỏ; Tab để thay, Esc để bỏ qua.":
        "After a typo (tpoi), the fix (tôi) shows by the cursor; Tab replaces, Esc ignores.",
    "Gợi ý thêm dấu cho câu không dấu": "Add tones to unaccented sentences",
    "Sau 3+ âm tiết không dấu, toi di hoc → tôi đi học hiện cạnh con trỏ; Tab để thay.":
        "After 3+ unaccented syllables, toi di hoc → tôi đi học shows by the cursor; Tab replaces.",
    "Gợi ý ngày giờ": "Date and time suggestions",
    "Gõ hôm nay (hoặc today) + dấu cách → ngày (28/09/2026) hiện ra; Tab để thay.":
        "Type hôm nay (or today) + space → the date (28/09/2026) shows; Tab replaces.",
    # --- Văn bản tự động
    "Văn bản tự động": "Automatic text",
    "Thêm dấu chấm khi gõ hai dấu cách": "Add period with double-space",
    "Gõ hai dấu cách sau một chữ → “. ”. Chỉ ở app cho bộ gõ đọc chữ quanh con trỏ.":
        "Two spaces after a word → “. ”. Only in apps that let the input method read nearby text.",
    "Tự viết hoa đầu câu": "Capitalize sentences automatically",
    "Tự viết hoa chữ đầu câu (sau . ? ! hoặc xuống dòng): dduwowcj → Được. Bỏ qua email, web.":
        "Capitalizes the start of a sentence (after . ? ! or a new line): dduwowcj → Được.",
    "Ngoặc kép cong và gạch dài": "Smart quotes and dashes",
    "\" ' → ngoặc cong theo ngữ cảnh (don't → don’t); -- → — (gõ thêm - thì thành ---).":
        "\" ' → curly quotes by context (don't → don’t); -- → — (one more - gives ---).",
    "Gợi ý từ": "Word suggestions",
    "Dừng gõ → gợi ý từ (keyb → keyboard, cảm → ơn); Tab để chọn. Cần gói viettelex-text-tools.":
        "Pause → a word suggestion (keyb → keyboard, cảm → ơn); Tab picks. Needs viettelex-text-tools.",
    "Lọc từ nhạy cảm": "Filter sensitive words",
    "Học từ bạn gõ": "Learn from your typing",
    "Xoá từ đã học": "Clear learned words",
    "Gợi ý từ quên mọi từ và cặp từ đã học từ những gì bạn gõ trên máy này.":
        "Word suggestions forget every word and word pair learned from your typing on this computer.",
    "Xoá…": "Clear…",
    "Xoá": "Clear",
    "Đã xoá từ đã học.": "Learned words cleared.",
    "Xoá từ đã học?": "Clear learned words?",
    "Gợi ý từ sẽ quên mọi từ và cặp từ đã học. Không hoàn tác được.":
        "Word suggestions forget every learned word and word pair. This cannot be undone.",
    "Gợi ý không bao giờ đưa ra từ tục; tự gõ thì vẫn bình thường.":
        "Suggestions never offer swear words; typing them yourself still works.",
    "Kiểu ngoặc kép": "Quote style",
    "“ ” ‘ ’ (mặc định)": "“ ” ‘ ’ (default)",
    "Phím tắt Thêm dấu": "Add tones hotkey",
    "Thêm dấu cho đoạn không dấu đang bôi đen (toi di hoc → tôi đi học). Mặc định tắt.":
        "Add tones to the selected unaccented text (toi di hoc → tôi đi học). Off by default.",
    "Tắt phím tắt": "Turn hotkey off",
    "Phím chuyển Việt/Anh": "Vietnamese/English hotkey",
    "Mặc định Ctrl+Space. Không dùng Super+Space (GNOME dùng để đổi nguồn nhập).":
        "Default Ctrl+Space. Super+Space is not allowed (GNOME uses it to switch input sources).",
    "Về mặc định (Ctrl+Space)": "Reset to default (Ctrl+Space)",
    "Tắt": "Off",
    "Nhớ Việt/Anh theo từng app": "Remember Vietnamese/English per app",
    "Phát tiếng khi đổi Việt/Anh": "Play a sound when switching Vietnamese/English",
    "Tiếng đi lên là tiếng Việt, đi xuống là tiếng Anh. Chỉ khi bạn tự đổi.":
        "A rising tone means Vietnamese, a falling one English. Only when you switch.",
    "Mỗi app giữ Việt/Anh riêng: gõ tiếng Anh ở terminal không làm mất tiếng Việt ở app khác.":
        "Each app keeps its own Vietnamese/English: English in a terminal, Vietnamese elsewhere.",
    "App mới mở bắt đầu bằng tiếng Việt": "New apps start in Vietnamese",
    "Tắt = app lần đầu gặp bắt đầu ở chế độ tiếng Anh.": "Off = apps seen for the first time start in English.",
    "Quên trạng thái Việt/Anh đã nhớ": "Forget remembered Vietnamese/English states",
    "Xoá trạng thái đã nhớ của mọi app; lần sau mỗi app bắt đầu theo mặc định.":
        "Clear the remembered state of every app; each app starts with the default next time.",
    "Quên tất cả": "Forget all",
    "Nhấn tổ hợp phím mới…": "Press the new key combination…",
    "Cần ít nhất một phím Ctrl/Alt/Shift/Super.": "Needs at least one of Ctrl/Alt/Shift/Super.",
    "Cần ít nhất một phím Ctrl/Alt/Super.": "Needs at least one of Ctrl/Alt/Super.",
    "Esc = huỷ · Backspace = tắt phím chuyển.": "Esc = cancel · Backspace = no switch hotkey.",
    "Esc = huỷ · Backspace = tắt phím tắt.": "Esc = cancel · Backspace = turn the hotkey off.",
    "Cần thêm Ctrl, Alt, Shift hoặc Super": "Add Ctrl, Alt, Shift or Super",
    "Cần thêm Ctrl, Alt hoặc Super": "Add Ctrl, Alt or Super",
    "Không dùng được %s — chọn tổ hợp khác": "%s can’t be used — pick another combination",
    "%s đang là phím chuyển Việt/Anh — chọn tổ hợp khác":
        "%s is the Vietnamese/English hotkey — pick another combination",
    "%s đang là phím tắt Thêm dấu — chọn tổ hợp khác":
        "%s is the Add tones hotkey — pick another combination",
    "Trùng phím tắt GNOME: %s — hãy chọn tổ hợp khác.":
        "Conflicts with the GNOME shortcut %s — please pick another combination.",
    "Không xoá được %s": "Couldn’t delete %s",
    "Đã quên trạng thái Việt/Anh của mọi app.": "Forgot the Vietnamese/English state of every app.",
    "Quên trạng thái Việt/Anh?": "Forget Vietnamese/English states?",
    "Mọi app sẽ bắt đầu lại theo mặc định.": "Every app will start again with the default.",

    # --- Gõ tắt
    "Gõ tắt": "Shortcuts",
    "Bật gõ tắt": "Enable shortcuts",
    "Gõ từ tắt rồi dấu cách/dấu câu để bung ra cụm đầy đủ (ko → không).":
        "Type a shortcut, then space or punctuation, to expand it (ko → không).",
    "Thêm / sửa gõ tắt": "Add / edit shortcut",
    "Bấm một dòng để sửa.": "Click a row to edit it.",
    "gõ": "type",
    "thành": "becomes",
    "Thêm": "Add",
    "Nhập…": "Import…",
    "Xuất ra YAML…": "Export to YAML…",
    "Bảng gõ tắt": "Shortcut list",
    "Chưa có gõ tắt nào": "No shortcuts yet",
    "Xoá gõ tắt này": "Delete this shortcut",
    "Từ gõ tắt không được trống hay chứa dấu cách (tối đa 64 ký tự).":
        "A shortcut can’t be empty or contain spaces (up to 64 characters).",
    "Nhập cụm từ sẽ thay thế.": "Enter the text to expand to.",
    "Không đọc được file. Định dạng hỗ trợ: JSON, YAML, hoặc mỗi dòng một cặp key:value.":
        "Couldn’t read the file. Supported formats: JSON, YAML, or one key:value pair per line.",
    "Đã nhập %d gõ tắt — gộp vào bảng hiện có (mục trùng lấy giá trị mới).":
        "Imported %d shortcuts — merged into the current list (duplicates take the new value).",
    "Đã lưu %s": "Saved %s",
    "Không lưu được file.": "Couldn’t save the file.",

    # --- Ứng dụng: cách gõ theo từng app
    "Tên app (vd: org.gnome.texteditor, kitty, code)": "App name (e.g. org.gnome.texteditor, kitty, code)",
    "App đã chỉnh": "Customized apps",
    "Tên app: Fcitx5 dùng tên chương trình; IBus dùng app-id Wayland hoặc WM_CLASS (chữ thường).":
        "App name: Fcitx5 uses the program name; IBus uses the Wayland app-id or WM_CLASS "
        "(lowercase).",
    "Chưa có app nào": "No apps yet",
    "Mọi app đang dùng chế độ Tự động.": "Every app uses Automatic mode.",
    "Bỏ ghi đè cho app này": "Remove the override for this app",
    "Nhập tên app (không chứa dấu cách).": "Enter an app name (no spaces).",
    "Đã nhập %d chế độ app. Mục có chế độ không hợp lệ bị bỏ qua.":
        "Imported %d app modes. Entries with an invalid mode were skipped.",

    # --- Ứng dụng: tương thích
    "Tương thích ứng dụng": "App compatibility",
    "Chỉ liệt kê lưu ý khớp với máy này.": "Only issues that apply to this computer are listed.",
    "Không phát hiện vấn đề nào với các ứng dụng đã cài.": "No issues found with the installed apps.",
    "Dò lại": "Check again",
    "Chép lệnh": "Copy command",
    "Đã chép lệnh.": "Command copied.",
    "%s: cần cờ bật bộ gõ trên Wayland": "%s: needs a flag to enable the input method on Wayland",
    "Chrome/Electron trên Wayland: bản mới (Chrome ≥ 137) tự nhận bộ gõ; bản cũ hơn hoặc app "
    "Electron chưa cập nhật cần cờ %s.":
        "Chrome/Electron on Wayland: recent versions (Chrome ≥ 137) pick up the input method on "
        "their own; older ones or outdated Electron apps need the flag %s.",
    " Cờ này chạy tốt với GNOME + IBus.": " This flag works well with GNOME + IBus.",
    " Cách khác: %s (chạy qua XWayland).": " Alternatively: %s (runs through XWayland).",
    "# Chạy thử một lần:": "# Try it once:",
    "# Cố định — sửa dòng Exec của file .desktop:":
        "# Make it permanent — edit the Exec line of the .desktop file:",
    "# %s (snap/flatpak): thêm cờ trên vào dòng Exec= của file .desktop":
        "# %s (snap/flatpak): add the flags above to the Exec= line of the .desktop file",
    "# Hoặc chạy qua XWayland (chắc ăn nhất):  … %s": "# Or run through XWayland (most reliable):  … %s",
    "kitty: cần GLFW_IM_MODULE=ibus": "kitty: needs GLFW_IM_MODULE=ibus",
    "Trên X11, kitty chỉ nhận bộ gõ khi có biến này (dùng cho cả IBus lẫn Fcitx5). Đăng nhập "
    "lại sau khi thêm.":
        "On X11, kitty only uses the input method with this variable (for both IBus and "
        "Fcitx5). Log in again after adding it.",
    "JetBrains IDE: thêm tuỳ chọn JVM": "JetBrains IDEs: add a JVM option",
    "Trên X11, IntelliJ/PyCharm… có thể mất bộ gõ sau khi đổi cửa sổ. Help → Edit Custom VM "
    "Options…, thêm dòng dưới rồi khởi động lại IDE.":
        "On X11, IntelliJ/PyCharm… can lose the input method after switching windows. Help → "
        "Edit Custom VM Options…, add the line below, then restart the IDE.",
    "rofi không hỗ trợ bộ gõ": "rofi doesn’t support input methods",
    "rofi không gõ được tiếng Việt có dấu. Dùng Ulauncher hoặc KRunner (KDE) nếu cần tìm bằng "
    "tiếng Việt.":
        "rofi can’t type accented Vietnamese. Use Ulauncher or KRunner (KDE) to search in "
        "Vietnamese.",
    "Ô tìm kiếm Tổng quan GNOME có thể mất chữ đầu": "GNOME overview search may drop the first letter",
    "Gõ ngay khi vừa mở Tổng quan, chữ đầu tiên có thể bị rơi (lỗi IBus upstream ibus#2246). "
    "Mở Tổng quan, chờ một nhịp rồi gõ.":
        "Typing right as the overview opens can drop the first letter (upstream IBus bug "
        "ibus#2246). Open the overview, pause briefly, then type.",
    "App Snap + Fcitx5 trên Ubuntu 22.04": "Snap apps + Fcitx5 on Ubuntu 22.04",
    "Trên 22.04, app dạng Snap (Firefox, Chromium…) thường không nhận Fcitx5. Dùng IBus "
    "(viettelex-ibus), hoặc cài bản .deb/Flatpak của app.":
        "On 22.04, Snap apps (Firefox, Chromium…) often ignore Fcitx5. Use IBus "
        "(viettelex-ibus), or install the app’s .deb/Flatpak version.",
    "im-config đang để tự động: IBus sẽ thắng Fcitx5": "im-config is on auto: IBus wins over Fcitx5",
    "Máy có cả IBus lẫn Fcitx5; ngoài GNOME, im-config chế độ auto chọn IBus. Muốn dùng "
    "VietTelex qua Fcitx5 thì chọn hẳn Fcitx5 rồi đăng nhập lại.":
        "Both IBus and Fcitx5 are installed; outside GNOME, im-config auto mode picks IBus. To "
        "use VietTelex through Fcitx5, select Fcitx5 explicitly and log in again.",
    "App Qt5 trên Wayland: thiếu QT_IM_MODULE": "Qt5 apps on Wayland: QT_IM_MODULE missing",
    "App Qt5 chạy Wayland gốc không có bộ gõ nếu thiếu QT_IM_MODULE. Qt ≥ 6.8.2 đọc "
    "QT_IM_MODULES (danh sách thử lần lượt). Đăng nhập lại sau khi thêm.":
        "Native Wayland Qt5 apps have no input method without QT_IM_MODULE. Qt ≥ 6.8.2 reads "
        "QT_IM_MODULES (a list tried in order). Log in again after adding it.",

    # --- Chung
    "Phiên bản %s · Linux": "Version %s · Linux",
    "Học gõ Telex": "Learn Telex",
    "Câu hỏi thường gặp": "FAQ",
    "Hướng dẫn báo lỗi": "How to report a bug",
    "Kiểm tra cập nhật": "Check for updates",
    "Chỉ kết nối mạng khi bạn bấm nút này.": "Only goes online when you click this button.",
    "Kiểm tra": "Check",
    "Mã nguồn mở (MIT) · không thu thập dữ liệu · chạy hoàn toàn trên máy":
        "Open source (MIT) · no data collection · runs entirely on your computer",
    "Không kết nối được máy chủ cập nhật.": "Couldn’t reach the update server.",
    "Mở trang tải": "Open download page",
    "Chưa có thông tin bản Linux trên kênh ổn định — xem trang phát hành.":
        "No Linux release info on the stable channel yet — see the releases page.",
    "Có bản mới: %s": "New version available: %s",
    "Bạn đang dùng bản mới nhất (%s).": "You’re on the latest version (%s).",
    "Cập nhật lên %s": "Update to %s",
    "Đang chuẩn bị cập nhật…": "Preparing the update…",
    "Khởi động lại bộ gõ": "Restart input method",
    "Thử lại": "Try again",
    "Không thấy gói VietTelex nào được cài bằng dpkg/apt.":
        "No VietTelex package installed through dpkg/apt was found.",
    "Chưa có bản cho kiến trúc %s.": "No build for the %s architecture yet.",
    "Chưa có bản cho %s (hỗ trợ: %s).": "No build for %s yet (supported: %s).",
    "hệ điều hành này": "this system",
    "Địa chỉ tải không hợp lệ trong stable.json.": "Invalid download address in stable.json.",
    "Thiếu mã kiểm tra SHA256 cho %s.": "Missing SHA256 checksum for %s.",
    "Đã cập nhật lên %s. Khởi động lại bộ gõ và mở lại ứng dụng này để dùng bản mới.":
        "Updated to %s. Restart the input method and reopen this app to use the new version.",
    "Đã huỷ — chưa cập nhật (cần mật khẩu quản trị).":
        "Cancelled — not updated (an administrator password is required).",
    "Trình quản lý gói đang bận (Software Updater/apt khác đang chạy). Đợi xong rồi thử lại.":
        "The package manager is busy (Software Updater or another apt is running). "
        "Wait for it to finish, then try again.",
    "Cập nhật lỗi (mã %d):\n%s": "Update failed (code %d):\n%s",
    "không có thông báo": "no message",
    "Máy này không dùng dpkg/apt — cập nhật theo cách bạn đã cài.":
        "This system doesn’t use dpkg/apt — update the way you installed it.",
    "Thiếu pkexec hoặc helper cập nhật — cài gói pkexec (22.04: policykit-1) hoặc cập nhật bằng apt.":
        "pkexec or the update helper is missing — install the pkexec package (22.04: "
        "policykit-1) or update with apt.",
    "Địa chỉ tải không hợp lệ: %s": "Invalid download address: %s",
    "VietTelex được cài bằng dnf — cập nhật: sudo dnf upgrade --refresh 'viettelex*' (hoặc Phần "
    "mềm / Discover).":
        "VietTelex was installed with dnf — update with: sudo dnf upgrade --refresh 'viettelex*' "
        "(or GNOME Software / Discover).",
    "Fedora Atomic: VietTelex cập nhật cùng hệ thống — rpm-ostree upgrade rồi khởi động lại "
    "(Bazzite/Bluefin/Aurora tự cập nhật).":
        "Fedora Atomic: VietTelex updates with the system — run rpm-ostree upgrade, then reboot "
        "(Bazzite/Bluefin/Aurora update automatically).",
    "VietTelex được cài bằng pacman — cập nhật: sudo pacman -Syu.":
        "VietTelex was installed with pacman — update with: sudo pacman -Syu.",
    "Đang tải %d/%d: %s": "Downloading %d/%d: %s",
    "Không tải được %s — kiểm tra mạng rồi thử lại.":
        "Couldn’t download %s — check your connection and try again.",
    "Sai mã SHA256 của %s — đã huỷ, không cài.": "SHA256 mismatch for %s — cancelled, nothing installed.",
    "Không xác minh được gói tải về với bản phát hành chính thức — đã huỷ, không cài.":
        "Couldn’t verify the downloaded packages against the official release — cancelled, nothing installed.",
    "Đang cài (cần mật khẩu quản trị)…": "Installing (administrator password required)…",
    "Không chạy được pkexec: %s": "Couldn’t run pkexec: %s",

    # --- Hướng dẫn bật bộ gõ (onboarding)
    "Bật bộ gõ VietTelex": "Set up VietTelex",
    "Kiểm tra lại": "Check again",
    "Bộ khung gõ": "Input method framework",
    "VietTelex là một input method của Fcitx5 (khuyên dùng — độ trễ thấp nhất, hợp KDE) hoặc "
    "IBus (mặc định của Ubuntu/GNOME).":
        "VietTelex is an input method for Fcitx5 (recommended — lowest latency, suits KDE) or "
        "IBus (the Ubuntu/GNOME default).",
    "Chưa thấy Fcitx5 hay IBus": "Neither Fcitx5 nor IBus found",
    "Cài một trong hai gói: %s (hoặc viettelex-ibus), rồi mở lại hướng dẫn này.":
        "Install one of the packages: %s (or viettelex-ibus), then open this guide again.",
    "Đang dùng %s": "Using %s",
    "Theo tiến trình đang chạy và biến môi trường của phiên đăng nhập này.":
        "Based on the running processes and the environment of this login session.",
    "Bấm “Dùng Fcitx5” ở trên rồi đăng xuất/đăng nhập lại.":
        "Click “Use Fcitx5” above, then log out and back in.",
    "Fcitx5 thay IBus trên GNOME": "Fcitx5 instead of IBus on GNOME",
    "Đã đặt Fcitx5 chạy thay IBus": "Fcitx5 is set to replace IBus",
    "Đang có hiệu lực.": "In effect.",
    "Chưa có hiệu lực — đăng xuất rồi đăng nhập lại.": "Not in effect yet — log out and back in.",
    "Quay về IBus": "Back to IBus",
    "Dùng Fcitx5 thay IBus": "Use Fcitx5 instead of IBus",
    "Cài gói trước: %s": "Install the package first: %s",
    "Fcitx5 tự chạy khi đăng nhập, app GTK nhận chữ thẳng từ Fcitx5. Đăng xuất/đăng nhập lại một lần.":
        "Fcitx5 starts at login and GTK apps get text straight from Fcitx5. Log out and back in once.",
    "Dùng Fcitx5": "Use Fcitx5",
    "Không ghi được cấu hình trong ~/.config.": "Couldn’t write the configuration in ~/.config.",
    "Xong — đăng xuất rồi đăng nhập lại để dùng Fcitx5.": "Done — log out and back in to use Fcitx5.",
    "Xong — đăng xuất rồi đăng nhập lại để quay về IBus.": "Done — log out and back in to go back to IBus.",
    "Các bước": "Steps",
    "1. Cài gói %s": "1. Install the %s package",
    "Đã cài.": "Installed.",
    "%s (hoặc cài gói tải từ trang phát hành).": "%s (or install the package from the releases page).",
    "2. Fcitx5 đang chạy": "2. Fcitx5 is running",
    "Đang chạy.": "Running.",
    "Khởi động Fcitx5. Nếu mỗi lần đăng nhập đều phải bật tay: chạy im-config -n fcitx5 rồi "
    "đăng nhập lại.":
        "Start Fcitx5. If you have to start it by hand at every login: run im-config -n fcitx5 "
        "and log in again.",
    "Khởi động Fcitx5": "Start Fcitx5",
    "3. Thêm VietTelex vào nhóm bộ gõ": "3. Add VietTelex to the input method group",
    "Đã có trong nhóm bộ gõ Fcitx5.": "Already in the Fcitx5 input method group.",
    "Thêm “Tiếng Việt (VietTelex)” vào nhóm hiện tại. Không cần đăng xuất.":
        "Add “Tiếng Việt (VietTelex)” to the current group. No need to log out.",
    "Cấu hình Fcitx5…": "Configure Fcitx5…",
    "Đổi thứ tự bộ gõ, phím chuyển giữa các bộ gõ.": "Reorder input methods, change the switch key.",
    "2. IBus đang chạy": "2. IBus is running",
    "Đang chạy. Vừa cài gói xong thì bấm “Khởi động lại IBus” để IBus thấy VietTelex.":
        "Running. If you just installed the package, click “Restart IBus” so IBus sees VietTelex.",
    "Khởi động IBus.": "Start IBus.",
    "Khởi động IBus": "Start IBus",
    "3. Thêm VietTelex vào nguồn nhập": "3. Add VietTelex to input sources",
    "Đã có trong nguồn nhập.": "Already in input sources.",
    "Cài đặt → Bàn phím → Nguồn nhập → + → Tiếng Việt → VietTelex. Hoặc bấm Thêm để làm hộ.":
        "Settings → Keyboard → Input Sources → + → Vietnamese → VietTelex. Or click Add to do "
        "it for you.",
    "Mở IBus Preferences → Input Method → Add → Vietnamese → VietTelex.":
        "Open IBus Preferences → Input Method → Add → Vietnamese → VietTelex.",
    "Khởi động lại IBus": "Restart IBus",
    "IBus chưa nạp VietTelex — đang tự khởi động lại IBus…":
        "IBus hasn’t loaded VietTelex yet — restarting IBus…",
    "IBus chưa nạp VietTelex — bấm “ibus restart” bên dưới.":
        "IBus hasn’t loaded VietTelex yet — click “ibus restart” below.",
    "IBus vẫn chưa nạp VietTelex — bấm “ibus restart” bên dưới, hoặc đăng xuất rồi đăng nhập lại.":
        "IBus still hasn’t loaded VietTelex — click “ibus restart” below, or log out and back in.",
    "Cần sau khi cài/cập nhật gói viettelex-ibus.": "Needed after installing/updating viettelex-ibus.",
    "Mở Cài đặt Bàn phím…": "Open Keyboard Settings…",
    "Nơi thêm/bớt và sắp xếp nguồn nhập của GNOME.": "Where GNOME input sources are added, removed and ordered.",
    "Lưu ý": "Notes",
    "Có bộ gõ tiếng Việt khác: %s": "Another Vietnamese input method is present: %s",
    "Bật cùng lúc hai bộ gõ Việt dễ bị gõ đúp dấu. Chỉ để một bộ trong danh sách nguồn nhập "
    "(hoặc gỡ gói kia).":
        "Two Vietnamese input methods at once easily double the marks. Keep only one in the "
        "input source list (or remove the other package).",
    "Fcitx5 và IBus cùng chạy": "Fcitx5 and IBus are both running",
    "Nên chỉ dùng một bộ khung gõ: im-config -n fcitx5 (hoặc ibus) rồi đăng nhập lại.":
        "Use only one framework: im-config -n fcitx5 (or ibus), then log in again.",
    "Phiên Wayland: Chrome/Electron (VS Code, Slack…)": "Wayland session: Chrome/Electron (VS Code, Slack…)",
    "Thử gõ": "Try it",
    "Bật VietTelex (%s) rồi gõ: vieejt → việt": "Turn VietTelex on (%s), then type: vieejt → việt",
    "Thử gõ tại đây…": "Type here to try…",
    "Không chạy được %s": "Couldn’t run %s",
    "Đã khởi động Fcitx5.": "Fcitx5 started.",
    "Đã khởi động IBus.": "IBus started.",
    "Đã khởi động lại IBus.": "IBus restarted.",
    "VietTelex đã có trong nhóm bộ gõ.": "VietTelex is already in the input method group.",
    "Đã thêm VietTelex vào nhóm “%s”.": "Added VietTelex to the “%s” group.",
    "Không thêm tự động được — hãy thêm “VietTelex” trong cửa sổ cấu hình.":
        "Couldn’t add it automatically — add “VietTelex” in the configuration window.",
    "Không kết nối được Fcitx5 — hãy khởi động Fcitx5 trước.":
        "Couldn’t connect to Fcitx5 — start Fcitx5 first.",
    "Đã thêm VietTelex vào nguồn nhập — chuyển bằng Super+Space.":
        "Added VietTelex to input sources — switch with Super+Space.",
    "Đã thêm VietTelex vào IBus.": "Added VietTelex to IBus.",
    "Không tìm thấy cấu hình IBus.": "IBus configuration not found.",
    "Không thêm được — hãy thêm tay trong Cài đặt → Bàn phím.":
        "Couldn’t add it — add it by hand in Settings → Keyboard.",

    # --- dòng lệnh
    "Mở hướng dẫn bật bộ gõ": "Open the setup guide",
    "Không tự mở hướng dẫn khi bộ gõ chưa bật": "Don’t open the setup guide automatically",

    # --- onboarding người dùng mới + nhóm "Gõ lẫn tiếng Anh" (docs/ONBOARDING-SPEC.md)
    "Bạn hay gõ trộn Anh/Việt?": "Do you mix English and Vietnamese?",
    "Xem": "Show me",
    "Đóng": "Close",
    "Nhận diện tiếng Anh khi gõ lẫn Việt–Anh.": "English detection when you mix Vietnamese and English.",
    "Chào mừng đến với VietTelex": "Welcome to VietTelex",
    "Tiếp": "Next",
    "Bỏ qua": "Skip",
    "Xong": "Done",
    "Bạn thường gõ thế nào?": "How do you usually type?",
    "Chủ yếu tiếng Việt": "Mostly Vietnamese",
    "Việt + Anh nhiều": "Lots of Vietnamese + English",
    "Chủ yếu tiếng Anh": "Mostly English",
    "Gõ thử": "Try typing",
    "Gõ thử các câu dưới đây bằng VietTelex. Chuyển Việt/Anh bằng %s.":
        "Type the sentences below with VietTelex. Switch Vietnamese/English with %s.",
    "Vừa bật": "Just turned on",
    "Tắt ngay nếu không cần.": "Turn off anything you don’t need.",
    "Bắt đầu bằng tiếng Anh": "Start in English",
    # Bộ chọn nhanh hồ sơ ở đầu nhóm Gõ lẫn tiếng Anh (ONBOARDING-SPEC §4)
    "profile\x04Tuỳ chỉnh": "Custom",
    "Áp dụng “%s”?": "Apply “%s”?",
    "Áp dụng": "Apply",
    "Các công tắc bạn đã tự chỉnh sẽ đổi:": "Switches you changed yourself will change:",
    "bật": "on",
    "tắt": "off",

    # --- thu gọn cài đặt (docs/SETTINGS-CLEANUP-SPEC.md)
    'Sửa thẳng trong ô':
        'Edit right in the field',
    'Gợi ý số tiền':
        'Money amount suggestions',
    "Học từ bạn hay gõ, chỉ lưu trên máy này; không học ở ô mật khẩu, terminal.":
        "Learns words you type often; stays on this computer, never in password fields or terminals.",
    "Không chạy ở terminal, trình soạn code, ô web/email, ô mật khẩu và khi gõ English.":
        "Not in terminals, code editors, web/email fields, password fields, or while typing English.",
    'Telex đơn giản, bỏ dấu tự do, gõ tắt phụ âm, dấu kiểu mới, teencode, phím ngoặc':
        'Simple Telex, free tone placement, consonant shortcuts, modern tones, teencode, bracket keys',
    "Nhóm Gõ lẫn tiếng Anh mới ở ngay dưới: chọn cách bạn gõ; công tắc chi tiết ở Nâng cao.":
        "New Mixed Vietnamese/English typing group below: pick how you type; details under Advanced.",
    'Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…':
        'Restore English words, context, ambiguous words, fixing earlier words…',
    'Tự khôi phục từ tiếng Anh':
        'Restore English words automatically',
    "Từ không phải tiếng Việt trả về đúng như đã gõ (google, github).":
        "Words that aren’t Vietnamese go back to what you typed (google, github).",
    'Khi từ vừa Anh vừa Việt':
        'When a word is both English and Vietnamese',
    'Nhớ theo từng app, app mới bắt đầu bằng…, quên trạng thái đã nhớ':
        'Remember per app, what new apps start in, forget remembered states',
    'Sửa dấu từ đã gõ':
        'Fix marks on a typed word',
    "Gạch đỏ chữ đang gõ không thể thành âm tiết Việt (đc, tòc). Chỉ khi chữ có gạch chân.":
        "Marks the word being typed when it can’t be Vietnamese (đc, tòc). Only with underlined typing.",
    'Bạn thường gõ thế nào? Chọn một — các công tắc trong Nâng cao sẽ tự đặt theo.':
        'How do you usually type? Pick one — the switches under Advanced are set to match.',
    'Cách hiện chữ đang gõ, gạch chân, terminal, Chrome/Electron':
        'How the word being typed is shown, underline, terminals, Chrome/Electron',
    'Cách hiện chữ đang gõ':
        'How the word being typed is shown',
    'Hiện gạch chân chữ đang gõ':
        'Underline the word being typed',
    "Không gạch chân ở gnome-terminal, konsole… (IBus GTK3/Fcitx5). GTK4 và GNOME Wayland vẫn gạch.":
        "No underline in gnome-terminal, konsole… (IBus GTK3/Fcitx5). GTK4 and GNOME Wayland still do.",
    'Mở trang: typing|suggestions|shortcuts|apps|general':
        'Open page: typing|suggestions|shortcuts|apps|general',
    'Nâng cao':
        'Advanced',
    'Gõ phím':
        'Typing',
    'Gõ tắt phụ âm nhanh (cc→ch, gg→gi…)':
        'Quick consonants (cc→ch, gg→gi…)',
    "[ ra ơ, ] ra ư (th[ → thơ). Nên tắt nếu bạn viết code.":
        "[ types ơ, ] types ư (th[ → thơ). Leave off if you write code.",
    'Gõ lẫn tiếng Anh':
        'Mixed Vietnamese/English typing',
    "Vd. list → lít. Muốn giữ tiếng Anh, gõ đúp phím dấu: lisst → list.":
        "e.g. list → lít. To keep English, double the mark key: lisst → list.",
    "Vd. list giữ nguyên. Muốn ra tiếng Việt, gõ dấu cuối từ: lits → lít.":
        "e.g. list stays list. For Vietnamese, type the mark last: lits → lít.",
    "Đầu câu, “his” giữ tiếng Anh thay vì “hí”; tự đổi lại nếu câu là tiếng Việt.":
        "At the start, “his” stays English, not “hí”; switches back if the sentence is Vietnamese.",
    'Chuyển Việt/Anh':
        'Switching Vietnamese/English',
    'Bạn đã tự chỉnh các công tắc trong Nâng cao.':
        'You changed the switches under Advanced yourself.',
    'Gợi ý & công cụ':
        'Suggestions & tools',
    "Thêm ở trên, hoặc Nhập… file YAML/JSON/TXT (mỗi dòng một cặp key: value).":
        "Add one above, or Import… a YAML/JSON/TXT file (one key: value per line).",
    'Ứng dụng':
        'Apps',
    'Cách gõ theo từng app':
        'Typing mode per app',
    "Soạn từ rồi chèn: đúng chữ ở mọi app. Sửa thẳng trong ô: như macOS, chỉ ở app hỗ trợ.":
        "Compose, then insert: right in every app. Edit right in the field: like macOS, some apps.",
    'Chung':
        'General',
    'Với Fcitx5, app GTK (Firefox, Terminal, Text Editor…) không gạch chân chữ đang gõ và thanh trên cùng hiện icon VietTelex. Chrome/Electron vẫn có thể gạch chân (xem trang Ứng dụng → Tương thích ứng dụng).':
        'With Fcitx5, GTK apps (Firefox, Terminal, Text Editor…) don’t underline the text being typed and the top bar shows the VietTelex icon. Chrome/Electron may still underline (see Apps → App compatibility).',
    'Một bộ gõ tiếng Việt khác đang gửi phím Backspace thật':
        'Another Vietnamese input method is sending real Backspace keys',
    'VietTelex bật sẵn các tính năng hợp với cách bạn gõ. Đổi lại lúc nào cũng được ở trang Gõ phím → Gõ lẫn tiếng Anh.':
        'VietTelex turns on the features that fit how you type. Change them any time in Typing → Mixed Vietnamese/English typing.',
    "App gõ sai hoặc bị gạch chân? Đổi cách gõ cho app đó — không chắc thì để Tự động.":
        "App types wrong or underlines? Change its mode — if unsure, leave it on Automatic.",
    'Bộ gõ đó sửa chữ bằng phím Backspace giả lập: đổi bộ gõ hay cửa sổ giữa chừng một từ có thể xoá thừa chữ khi gõ bằng VietTelex. Nên chỉ giữ một bộ gõ tiếng Việt; nếu vẫn dùng bộ gõ đó, chuyển nó sang chế độ gạch chân chữ đang gõ hoặc tắt dịch vụ của nó: %s':
        'That input method fixes text with simulated Backspace keys: switching input method or window in the middle of a word can delete extra characters while typing with VietTelex. Keep only one Vietnamese input method; if you keep that one, switch it to underlining the word being typed or stop its service: %s',
    'Nếu không gõ được tiếng Việt trong Chrome hay app Electron, chạy app với %s (hoặc %s). Lệnh copy sẵn ở trang Ứng dụng → Tương thích ứng dụng.':
        'If you can’t type Vietnamese in Chrome or Electron apps, launch them with %s (or %s). Ready-to-copy commands are in Apps → App compatibility.',
    'Mặc định tắt.':
        'Off by default.',
    'Terminal: gõ thẳng khi được, còn lại gạch chân chữ đang gõ':
        'Terminals: type directly when possible, otherwise underline the word being typed',
    'Terminal nhận phím qua IBus GTK3 hoặc Fcitx5 (fcitx5-gtk3, fcitx5-qt) — gnome-terminal, tilix, konsole… trên X11 — được gõ thẳng (sửa dấu bằng Backspace, không gạch chân). Terminal GTK4 (Ptyxis, Console), phiên Wayland GNOME, kitty/alacritty/foot và terminal của VS Code gạch chân chữ đang gõ: ở đó Backspace gửi đi không chắc đến trước chữ mới.':
        'Terminals that get keys through IBus GTK3 or Fcitx5 (fcitx5-gtk3, fcitx5-qt) — gnome-terminal, tilix, konsole… on X11 — type directly (marks fixed with Backspace, no underline). GTK4 terminals (Ptyxis, Console), GNOME Wayland sessions, kitty/alacritty/foot and the VS Code terminal underline the word being typed: there a sent Backspace isn’t guaranteed to arrive before the new text.',
    'Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này.':
        'VNI leaves English words as typed, so there is nothing to set here.',
}
