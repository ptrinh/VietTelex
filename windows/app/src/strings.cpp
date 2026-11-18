#include "strings.h"

#include <cstddef>

namespace vtx::app {

namespace {
bool g_en = false;

struct Pair {
    const wchar_t* vi;
    const wchar_t* en;
};

// Order == enum S. Setting titles/descriptions follow macOS Localizable.strings.
const Pair kStrings[] = {
    {L"VietTelex", L"VietTelex"},
    {L"VietTelex — bộ gõ tiếng Việt", L"VietTelex — Vietnamese input"},
    {L"Cài đặt…", L"Settings…"},
    {L"Kiểm tra cập nhật", L"Check for updates"},
    {L"Giới thiệu", L"About"},
    {L"Ẩn biểu tượng khay", L"Hide tray icon"},

    {L"Gõ phím", L"Typing"},
    {L"Gợi ý & công cụ", L"Suggestions & tools"},
    {L"Gõ tắt", L"Shortcuts"},
    {L"Ứng dụng", L"Apps"},
    {L"Chung", L"General"},

    {L"Kiểu gõ", L"Input style"},
    {L"Chuyển Việt/Anh", L"Vietnamese/English switch"},
    {L"Giao diện", L"Appearance"},
    {L"Chính tả", L"Spelling"},
    {L"Bảng gõ tắt", L"Shortcut table"},
    {L"Chế độ theo ứng dụng", L"Per-app modes"},
    {L"Cập nhật", L"Updates"},
    {L"Nâng cao / Gỡ lỗi", L"Advanced / Debugging"},
    {L"Gỡ cài đặt", L"Uninstall"},

    {L"Kiểu gõ", L"Typing method"},
    {L"VNI — dấu bằng số: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 xoá dấu.",
     L"VNI — tones with digits: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 clears."},
    {L"Telex", L"Telex"},
    {L"VNI", L"VNI"},
    {L"Telex đơn giản", L"Simple Telex"},
    {L"w đứng riêng vẫn là w (gõ uw ra ư).", L"A lone w stays w (type uw for ư)."},
    {L"Bỏ dấu tự do", L"Free tone placement"},
    {L"Đặt dấu ở đâu trong từ cũng được (ama → âm). Tắt: chặt hơn, hợp gõ tiếng Anh/code.",
     L"Put the tone anywhere in the word (ama → âm). Off: stricter, better for English/code."},
    {L"Gõ tắt phụ âm nhanh (cc→ch, gg→gi…)", L"Quick consonants (cc→ch, gg→gi…)"},
    {L"Gõ đúp phụ âm đầu: kk → kh, nn → ng, pp → ph, tt → th…",
     L"Double the first consonant: kk → kh, nn → ng, pp → ph, tt → th…"},
    {L"Bỏ dấu kiểu mới (oà, uý)", L"Modern tone placement (oà, uý)"},
    {L"hoà, thuý, khoẻ thay vì hòa, thủy, khỏe.", L"hoà, thuý, khoẻ instead of hòa, thủy, khỏe."},
    {L"Phím ngoặc: [ ra ơ, ] ra ư", L"Bracket vowels: [ types ơ, ] types ư"},
    {L"[ ra ơ, ] ra ư (th[ → thơ). Nên tắt nếu bạn viết code.",
     L"[ types ơ, ] types ư (th[ → thơ). Leave off if you write code."},
    {L"Tự khôi phục từ tiếng Anh", L"Auto-restore English words"},
    {L"Từ không phải tiếng Việt trả về đúng như đã gõ (google, github; “tet” → “text”).",
     L"Words that aren’t Vietnamese go back to what you typed (google, github; “tet” → “text”)."},
    {L"Kiểm tra chính tả khi gõ", L"Live spell-check"},
    {L"Ngừng thêm dấu ngay khi từ không thể là tiếng Việt (google, github).",
     L"Stop adding tones once a word can’t be Vietnamese (google, github)."},
    {L"Quyết định theo ngữ cảnh", L"Context-based decision"},
    {L"Sau một từ tiếng Anh, từ kế giữ tiếng Anh: “he is”, không thành “he í”.",
     L"After an English word, the next stays English: “he is”, not “he í”."},
    {L"Khi từ vừa Anh vừa Việt: ưu tiên tiếng Việt", L"Word is both English and Vietnamese: prefer Vietnamese"},
    {L"Vd. list → lít. Muốn giữ tiếng Anh, gõ đúp phím dấu: lisst → list.",
     L"e.g. list → lít. To keep English, double the tone key: lisst → list."},
    {L"Chính tả teencode", L"Teencode spelling"},
    {L"Nhận kiểu viết chat: wá, zui zẻ, kó. Tắt: was, zoo giữ nguyên.",
     L"Accept chat spellings: wá, zui zẻ, kó. Off: was, zoo stay as typed."},
    {L"Sửa dấu từ đã gõ", L"Fix tones of typed words"},
    {L"Thêm dấu cho từ đã gõ: toan + s → toán.", L"Add a tone to a word already typed: toan + s → toán."},
    {L"Phím chuyển Việt/Anh", L"Switch hotkey"},
    {L"VietTelex nhớ Việt/Anh theo từng ứng dụng khi bạn chuyển bằng phím này.",
     L"VietTelex remembers Vietnamese/English per app when you switch with this key."},
    {L"Ctrl+Shift", L"Ctrl+Shift"},
    {L"Win+Space (của Windows)", L"Win+Space (Windows)"},
    {L"Alt+Z", L"Alt+Z"},
    {L"Tắt", L"Off"},
    {L"Biểu tượng bàn phím", L"Keyboard icon"},
    {L"Hiện trên thanh tác vụ và danh sách bàn phím (Win+Space). Đổi cần quyền quản trị.",
     L"Shown on the taskbar and in the keyboard list (Win+Space). Changing it needs admin rights."},
    {L"Vᴛ", L"Vᴛ"},
    {L"Ngôi sao", L"Star"},
    {L"Cờ Việt Nam", L"Vietnam flag"},
    {L"Logo", L"Logo"},
    {L"Chữ VI", L"VI text"},
    {L"Hiện biểu tượng ở khay hệ thống", L"Show icon in the notification area"},
    {L"V = tiếng Việt, E = tiếng Anh. Tắt thì mở Cài đặt từ VietTelex trong menu Start.",
     L"V = Vietnamese, E = English. When off, open Settings from VietTelex in the Start menu."},
    // Bilingual on purpose: findable whichever language the window is in.
    {L"Ngôn ngữ / Language", L"Ngôn ngữ / Language"},
    {L"Ngôn ngữ của cửa sổ này và menu khay. Mặc định tiếng Việt.",
     L"Language of this window and the tray menu. Vietnamese by default."},
    {L"Tự kiểm tra cập nhật", L"Check for updates automatically"},
    {L"Mỗi ngày một lần hỏi viettelex.com có bản mới không. Không gửi dữ liệu nào khác.",
     L"Asks viettelex.com once a day whether a new version exists. Nothing else is sent."},
    {L"Ghi nhật ký gỡ lỗi", L"Record debug log"},
    {L"Ghi vào %LOCALAPPDATA%\\VietTelex\\debug.log, không ghi chữ bạn gõ.",
     L"Writes %LOCALAPPDATA%\\VietTelex\\debug.log, never the text you type."},
    {L"Kiểm tra cập nhật", L"Check for updates"},
    {L"Chỉ kết nối mạng khi bạn bấm nút này hoặc bật tự kiểm tra.",
     L"VietTelex only goes online when you click this or enable automatic checks."},
    {L"Kiểm tra ngay", L"Check now"},
    {L"Gỡ cài đặt VietTelex", L"Uninstall VietTelex"},
    {L"Gỡ bộ gõ và ứng dụng khỏi máy. Cài đặt của bạn được xoá.",
     L"Removes the input method and the app from this PC. Your settings are deleted."},
    {L"Gỡ cài đặt…", L"Uninstall…"},
    {L"Gỡ VietTelex khỏi máy này? Bộ gõ, ứng dụng và cài đặt của bạn sẽ bị xoá.",
     L"Uninstall VietTelex from this PC? The input method, the app and your settings will be removed."},

    {L"Gõ viết tắt rồi dấu cách để bung ra (ko → không). Nhập/xuất YAML, JSON, văn bản.",
     L"Type an abbreviation, then space, to expand it (ko → không). Import/export YAML, JSON, text."},
    {L"Viết tắt", L"Abbreviation"},
    {L"Nội dung", L"Expands to"},
    {L"Thêm", L"Add"},
    {L"Xoá", L"Remove"},
    {L"Nhập…", L"Import…"},
    {L"Xuất…", L"Export…"},
    {L"App gõ sai hoặc bị gạch chân? Đổi cách gõ cho app đó — không chắc thì để Mặc định.",
     L"App types wrong or underlines? Change its mode — if unsure, leave it on Default."},
    {L"Tệp chạy (vd. notepad.exe)", L"Executable (e.g. notepad.exe)"},
    {L"Chế độ", L"Mode"},
    {L"Gạch chân chữ đang gõ", L"Underline while typing"},
    {L"Mặc định (sửa thẳng trong ô)", L"Default (edit in the field)"},
    {L"Gõ bằng phím thật (cần VietTelex đang chạy)", L"Real keystrokes (needs VietTelex running)"},
    {L"Luôn tiếng Anh", L"Always English"},
    {L"Gõ thẳng (không gạch chân)", L"Type directly (no underline)"},
    {L"Chưa có gõ tắt nào", L"No shortcuts yet"},
    {L"Chưa có ứng dụng nào", L"No apps yet"},

    {L"Bộ gõ tiếng Việt tối giản, nhanh, ổn định. Không thu thập dữ liệu. Mã nguồn mở (MIT).",
     L"A minimal, fast, stable Vietnamese input method. No data collection. Open source (MIT)."},
    {L"Phiên bản", L"Version"},
    {L"viettelex.com", L"viettelex.com"},
    {L"Mã nguồn trên GitHub", L"Source on GitHub"},
    {L"Học gõ Telex", L"Learn Telex typing"},
    {L"Bật", L"On"},
    {L"Tắt", L"Off"},

    {L"Bạn đang dùng bản mới nhất.", L"You are up to date."},
    {L"Có bản mới %s. Tải và cài đặt?", L"Version %s is available. Download and install?"},
    {L"Không kiểm tra được cập nhật.", L"Could not check for updates."},
    {L"Tệp cài đặt tải về không có chữ ký hợp lệ — đã huỷ.", L"The downloaded installer is not validly signed — cancelled."},
    {L"Không tải được bản cập nhật. Mở trang tải về để tải bằng tay?",
     L"Could not download the update. Open the download page to get it yourself?"},
    {L"Không kiểm tra được chữ ký của bản cập nhật (có thể do mất mạng hoặc proxy chặn) — chưa cài gì. Mở trang tải "
     L"về để tải bằng tay?",
     L"Could not check the update's signature (maybe offline, or a proxy blocks the check) — nothing was installed. "
     L"Open the download page to get it yourself?"},
    {L"Đang tải bản cập nhật, vui lòng chờ.", L"The update is downloading, please wait."},
    {L"Không đọc được tệp gõ tắt.", L"Could not read the shortcut file."},
    {L"Ứng dụng này chạy với quyền quản trị: cách gõ bằng phím thật không gõ vào được. Chạy VietTelex bằng quyền quản trị hoặc đổi cách gõ của ứng dụng.",
     L"This app runs as administrator: real keystrokes cannot type into it. Run VietTelex as administrator or change the app's mode."},
    {L"Bạn chuyển bằng bộ gõ Windows (VietTelex ↔ ENG); Windows nhớ riêng cho từng cửa sổ.",
     L"You switch via the Windows input method (VietTelex ↔ ENG); Windows remembers it per window."},
    {L"Bạn chuyển bằng bộ gõ Windows (VietTelex ↔ ENG); đổi ở một app là đổi mọi app.",
     L"You switch via the Windows input method (VietTelex ↔ ENG); a change applies to every app."},
    {L"Bạn chuyển bằng bộ gõ Windows (VietTelex ↔ ENG); nhớ theo app hay không: tuỳ chọn bên dưới.",
     L"You switch via the Windows input method (VietTelex ↔ ENG); per-app memory: the option below."},
    {L"Nhớ bộ gõ theo từng ứng dụng (Windows)", L"Input method per app window (Windows)"},
    {L"Đang bật: mỗi cửa sổ ứng dụng giữ bộ gõ riêng (VietTelex hoặc ENG).",
     L"On: each app window keeps its own input method (VietTelex or ENG)."},
    {L"Đang tắt: đổi bộ gõ ở một app sẽ đổi cho mọi app.",
     L"Off: changing the input method in one app changes it everywhere."},
    {L"Không đọc được. Xem ở Cài đặt → Nhập liệu → Cài đặt bàn phím nâng cao.",
     L"Couldn’t read it. Check Settings → Typing → Advanced keyboard settings."},
    {L"Bật", L"Turn on"},
    {L"Mở cài đặt", L"Open Settings"},

    {L"Công cụ văn bản", L"Text tools"},
    {L"Hiện công cụ văn bản trong menu", L"Show text tools in the menu"},
    {L"Chọn chữ, bấm chuột phải biểu tượng khay → Công cụ văn bản: thêm dấu, hoa/thường, xoá dấu.",
     L"Select text, right-click the tray icon → Text tools: add tones, change case, remove tones."},
    {L"Phím tắt Thêm dấu", L"Add-tones hotkey"},
    {L"Thêm dấu cho vùng chọn ở mọi ứng dụng; clipboard được giữ. Không chạy ở ô mật khẩu.",
     L"Adds tones to the selection in any app; clipboard is kept. Never in password fields."},
    {L"Công cụ văn bản", L"Text tools"},
    {L"Thêm dấu cho vùng chọn", L"Add tones to selection"},
    {L"HOA", L"UPPERCASE"},
    {L"thường", L"lowercase"},
    {L"Hoa Đầu Từ", L"Title Case"},
    {L"Hoa đầu câu", L"Sentence case"},
    {L"Xoá dấu", L"Remove tones"},
    {L"Thêm dấu, HOA/thường, xoá dấu cho vùng chọn: menu khay, phím tắt Thêm dấu…",
     L"Add tones, UPPER/lowercase, remove tones on the selection: tray menu, add-tones hotkey…"},
    {L"Hiện kết quả phép tính", L"Show maths results"},
    {L"Gõ phép tính kết thúc bằng = (12*3=); kết quả hiện cạnh con trỏ, Tab để chèn.",
     L"Type a sum ending in = (12*3=); the result shows by the cursor, Tab inserts it."},
    {L"Gợi ý số tiền", L"Suggest money amounts"},
    {L"Gõ 1tr2 + dấu cách → 1.200.000 ₫ hiện cạnh con trỏ; Tab để thay.",
     L"Type 1tr2 + space → 1.200.000 ₫ shows by the cursor; Tab replaces."},
    {L"Gợi ý sửa lỗi gõ sai", L"Suggest typo fixes"},
    {L"Sau từ gõ nhầm (tpoi), từ đúng (tôi) hiện cạnh con trỏ; Tab để thay, Esc để bỏ qua.",
     L"After a typo (tpoi), the fix (tôi) shows by the cursor; Tab replaces, Esc ignores."},
    {L"Gợi ý thêm dấu cho câu không dấu", L"Suggest tones for unaccented sentences"},
    {L"Sau 3+ âm tiết không dấu, toi di hoc → tôi đi học hiện cạnh con trỏ; Tab để thay.",
     L"After 3+ unaccented syllables, toi di hoc → tôi đi học shows by the cursor; Tab replaces."},
    {L"Gợi ý ngày giờ", L"Suggest dates and times"},
    {L"Gõ hôm nay (hoặc today) + dấu cách → ngày (28/09/2026) hiện ra; Tab để thay.",
     L"Type hôm nay (or today) + space → the date (28/09/2026) shows; Tab replaces."},
    {L"Lọc từ nhạy cảm", L"Filter sensitive words"},
    {L"Gợi ý không bao giờ đưa ra từ tục; tự gõ thì vẫn bình thường.",
     L"Suggestions never offer swear words; typing them yourself still works."},
    {L"Gạch đỏ âm tiết sai chính tả khi gõ", L"Underline misspelled syllables while typing"},
    {L"Gạch đỏ chữ đang gõ không thể thành âm tiết Việt (đc, tòc). Chỉ khi chữ có gạch chân.",
     L"Red squiggle when the word can’t become Vietnamese (đc, tòc). Only with underlined typing."},

    // Games / fullscreen
    {L"Chơi game / toàn màn hình", L"Games / fullscreen"},
    {L"Tự tắt tiếng Việt khi chơi game toàn màn hình", L"Turn Vietnamese off in fullscreen games"},
    {L"Khi game toàn màn hình ở phía trước, không giữ phím nào (WASD không thành ư/ă).",
     L"While a fullscreen game is in front, no key is held (WASD never turns into ư/ă)."},
    {L"Chế độ game", L"Game mode"},
    {L"Mọi phím đi thẳng tới ứng dụng cho tới khi tắt; tự tắt khi VietTelex khởi động lại.",
     L"Every key goes straight to the app until turned off; resets when VietTelex restarts."},
    {L"Phím tắt Chế độ game", L"Game mode hotkey"},
    {L"Bật/tắt Chế độ game ở mọi nơi. Phím tắt này sẽ không tới ứng dụng khác nữa.",
     L"Turns Game mode on/off anywhere. That hotkey then no longer reaches other apps."},
    {L"Hiện V/E khi chuyển Việt/Anh", L"Show V/E when switching"},
    {L"Chữ V/E nhỏ hiện ~1 giây cạnh con trỏ khi chuyển. Tự động: chỉ khi ẩn biểu tượng khay.",
     L"A small V/E shows ~1 s by the cursor when you switch. Automatic: only if the tray is hidden."},
    {L"Tự động", L"Automatic"},
    {L"Game: bật", L"Game: on"},
    {L"Game: tắt", L"Game: off"},

    // Other Vietnamese input methods
    {L"Có bộ gõ tiếng Việt khác", L"Another Vietnamese input method is active"},
    {L"Hai bộ gõ cùng lúc sẽ bỏ dấu hai lần (vieejt → viêệt). Hãy thoát bộ gõ kia.",
     L"Two input methods at once add tones twice (vieejt → viêệt). Quit the other one."},
    {L"Xử lý…", L"Resolve…"},
    {L"VietTelex sẽ không tự tắt hay gỡ phần mềm khác. Chọn việc cần làm:",
     L"VietTelex never quits or uninstalls other software by itself. Choose what to do:"},
    {L"Mở thư mục của %s", L"Open the folder of %s"},
    {L"Cách thoát %s", L"How to quit %s"},
    {L"Bấm chuột phải vào biểu tượng %s ở khay hệ thống (góc phải thanh tác vụ, có thể trong mũi tên ^) rồi chọn "
     L"Thoát / Kết thúc. Để nó không tự chạy cùng Windows: bỏ “Khởi động cùng Windows” trong %s, hoặc tắt nó ở "
     L"Trình quản lý tác vụ → Ứng dụng khởi động.",
     L"Right-click the %s icon in the notification area (right end of the taskbar, maybe under the ^ arrow) and "
     L"choose Exit. To stop it starting with Windows: turn off its “Run at startup” option in %s, or disable it in "
     L"Task Manager → Startup apps."},
    {L"Gỡ bàn phím tiếng Việt có sẵn của Windows", L"Remove Windows' built-in Vietnamese keyboard"},
    {L"Chỉ bỏ khỏi danh sách bàn phím của bạn và đặt VietTelex làm mặc định. Windows vẫn giữ bàn phím đó, thêm "
     L"lại được trong Cài đặt.",
     L"Only takes it off your keyboard list and makes VietTelex the default. Windows keeps that keyboard; you can "
     L"add it back in Settings."},
    {L"Mở Cài đặt ngôn ngữ của Windows", L"Open Windows language settings"},
    {L"Đã gỡ khỏi danh sách. Từ giờ Windows gõ tiếng Việt bằng VietTelex.",
     L"Removed from the list. From now on Windows types Vietnamese with VietTelex."},
    {L"Không gỡ được tự động. Cài đặt ngôn ngữ của Windows sẽ mở ra: Tiếng Việt → Tuỳ chọn → Bàn phím → Gỡ.",
     L"Could not remove it automatically. Windows language settings will open: Vietnamese → Options → Keyboards → "
     L"Remove."},
    {L"Không thấy bộ gõ tiếng Việt nào khác.", L"No other Vietnamese input method found."},

    // Welcome
    {L"Chào mừng đến với VietTelex", L"Welcome to VietTelex"},
    {L"VietTelex đã được thêm vào bàn phím của bạn. Chọn vài thứ để bắt đầu — đổi lại lúc nào cũng được trong "
     L"Cài đặt.",
     L"VietTelex has been added to your keyboards. Pick a few things to start — you can change them any time in "
     L"Settings."},
    {L"Kiểu gõ", L"Typing method"},
    {L"Phím chuyển Việt/Anh", L"Vietnamese/English switch key"},
    {L"Hiện biểu tượng V/E ở khay hệ thống", L"Show a V/E icon in the notification area"},
    {L"V đỏ = tiếng Việt, E xanh = tiếng Anh. Windows 11 có thể giấu nó dưới mũi tên ^ cạnh đồng hồ: kéo nó ra "
     L"thanh tác vụ. Không bật thì chỉ có chữ V/E nhỏ hiện thoáng qua khi chuyển.",
     L"Red V = Vietnamese, blue E = English. Windows 11 may hide it under the ^ arrow next to the clock: drag it "
     L"onto the taskbar. Without it, only a brief V/E shows when you switch."},
    {L"Chuyển gõ tắt từ bộ gõ khác…", L"Bring shortcuts from another input method…"},
    {L"Bắt đầu gõ", L"Start typing"},
    {L"Mở Cài đặt…", L"Open Settings…"},

    // Import result
    {L"Đã nhập %d gõ tắt (%s).", L"Imported %d shortcuts (%s)."},
    {L"%d dòng bị bỏ qua (viết tắt có dấu cách, rỗng hoặc dài quá 64 ký tự).",
     L"%d lines skipped (abbreviation with a space, empty or longer than 64 characters)."},
    {L"Tệp gõ tắt kiểu cũ (mã VIQR, không có dòng “version=1”): chữ có dấu chưa được chuyển, ví dụ “Vie^.t”. "
     L"Mở tệp bằng bộ gõ đã tạo ra nó rồi lưu lại để có bản UTF-8.",
     L"An old shortcut file (VIQR encoding, no “version=1” line): accented letters were not converted, e.g. "
     L"“Vie^.t”. Open it in the input method that made it and save it again to get a UTF-8 file."},

    // Default input method
    {L"Bộ gõ mặc định của Windows", L"Windows default input method"},
    {L"Windows mở app mới bằng bàn phím khác. Đặt VietTelex làm mặc định để gõ được ngay.",
     L"Windows opens new apps with another keyboard. Make VietTelex the default to type right away."},
    {L"Đặt làm mặc định", L"Make default"},

    // Spelling page: caret hints; Text tools without the tray icon
    {L"Gợi ý cạnh con trỏ", L"Suggestions next to the cursor"},
    {L"Biểu tượng khay đang ẩn: dùng phím tắt Thêm dấu, hoặc bật biểu tượng khay ở Chung.",
     L"Tray icon hidden: use the add-tones hotkey, or turn the tray icon on in General."},
    // Tray menu
    {L"Chế độ game", L"Game mode"},
    // Học từ bạn gõ
    {L"Học từ bạn gõ", L"Learn from your typing"},
    {L"Học từ bạn hay gõ, chỉ lưu trên máy này. Cần bật gợi ý văn bản của Windows.",
     L"Learns words you type often; stays on this PC. Needs Windows text suggestions on."},
    {L"Xoá từ đã học", L"Clear learned words"},
    {L"Quên mọi từ đã học trên máy này.", L"Forgets every word learned on this PC."},
    {L"Xoá…", L"Clear…"},
    {L"Xoá mọi từ đã học? Không hoàn tác được.", L"Clear all learned words? This cannot be undone."},
    // Gợi ý chữ khi gõ
    {L"Gợi ý chữ khi gõ", L"Word suggestions while typing"},
    {L"Đang bật.", L"On."},
    {L"Đang tắt — bật trong Cài đặt Windows.", L"Off — turn it on in Windows Settings."},
    {L"VietTelex làm theo cài đặt này của Windows.", L"VietTelex follows Windows’ physical keyboard suggestions."},
    {L"Mở cài đặt Gõ phím của Windows…", L"Open Windows Typing settings…"},
    // Tray icon style
    {L"Kiểu biểu tượng khay", L"Tray icon style"},
    {L"Chữ V/E: V đỏ = tiếng Việt, E xanh = tiếng Anh. Windows 11 có thể giấu dưới mũi tên ^.",
     L"V/E letter: red V = Vietnamese, blue E = English. Windows 11 may hide it under the ^ arrow."},
    {L"Chữ V/E", L"V/E letter"},
    {L"Biểu tượng bàn phím", L"Keyboard icon"},
    {L"Tiếng Việt (V)", L"Vietnamese (V)"},
    {L"Tiếng Anh (E)", L"English (E)"},
    // Welcome: how to start, default input method
    {L"Để gõ: trên thanh tác vụ (góc phải, chữ ENG/VIE) hoặc bằng Win+Space, chọn bàn phím VietTelex. Sau đó "
     L"phím chuyển bên dưới đổi Việt/Anh. Hãy thoát bộ gõ tiếng Việt khác nếu đang chạy.",
     L"To type: pick the VietTelex keyboard on the taskbar (ENG/VIE, bottom right) or with Win+Space. Then the "
     L"switch key below toggles Vietnamese/English. Quit any other Vietnamese input method that is running."},
    {L"Đặt VietTelex làm bàn phím mặc định (ứng dụng mở ra là gõ được ngay)",
     L"Make VietTelex the default keyboard (apps are ready to type when they open)"},
    // Windows' own Ctrl+Shift hotkey (input_switch.h winHotkeyClash)
    {L"Phím Ctrl+Shift của Windows", L"Windows' Ctrl+Shift hotkey"},
    {L"Windows cũng đổi bàn phím bằng Ctrl+Shift, nên có lúc hiện VIE mà vẫn gõ tiếng Anh.",
     L"Windows also switches keyboards on Ctrl+Shift, so it may show VIE while typing English."},
    {L"Bỏ Ctrl+Shift khỏi phím tắt của Windows", L"Take Ctrl+Shift off Windows' hotkeys"},
    {L"Đổi phím chuyển ngôn ngữ của Windows sang Alt+Shift trái (mặc định của Windows) và bỏ phím đổi bố cục. "
     L"Đổi lại được trong Cài đặt → Gõ phím → Cài đặt bàn phím nâng cao → Phím nóng ngôn ngữ nhập.",
     L"Sets Windows' input-language hotkey to Left Alt+Shift (the Windows default) and removes the layout hotkey. "
     L"You can change it back in Settings → Typing → Advanced keyboard settings → Input language hot keys."},
    {L"Đã đổi. Từ giờ Ctrl+Shift chỉ đổi Việt/Anh của VietTelex.",
     L"Done. Ctrl+Shift now only switches VietTelex between Vietnamese and English."},
    {L"Không đổi được tự động. Cài đặt Gõ phím của Windows sẽ mở ra: Cài đặt bàn phím nâng cao → Phím nóng "
     L"ngôn ngữ nhập.",
     L"Could not change it automatically. Windows Typing settings will open: Advanced keyboard settings → Input "
     L"language hot keys."},
    {L"Tự sửa từ phía trước (thử nghiệm)", L"Fix earlier words (experimental)"},
    {L"Sửa từ bị bỏ dấu nhầm khi câu hoá ra tiếng Anh: “Hí cả í” → “His car is”.",
     L"Fixes mis-toned words once the sentence turns out English: “Hí cả í” → “His car is”."},
    {L"Đoán từ trùng theo tần suất (thử nghiệm)", L"Guess colliding words by frequency (experimental)"},
    {L"Đầu câu, “his” giữ tiếng Anh thay vì “hí”; tự đổi lại nếu câu là tiếng Việt.",
     L"At the start, “his” stays English, not “hí”; switches back if the sentence is Vietnamese."},
    // Onboarding
    {L"Tiếp", L"Next"},
    {L"Bỏ qua", L"Skip"},
    {L"Bạn thường gõ thế nào?", L"How do you usually type?"},
    {L"Chọn cách gần nhất — lựa chọn chỉ bật/tắt vài công tắc, đổi lại lúc nào cũng được trong Cài đặt → Gõ phím "
     L"→ Gõ lẫn tiếng Anh.",
     L"Pick the closest one — it only sets a few switches, which you can change any time in Settings → Typing → "
     L"Mixed Vietnamese/English typing."},
    {L"Chủ yếu tiếng Việt", L"Mostly Vietnamese"},
    {L"“Chiều nay mình đi cà phê nhé”", L"“Chiều nay mình đi cà phê nhé”"},
    {L"Việt + Anh nhiều", L"Lots of Vietnamese + English"},
    {L"“Chiều nay họp team, nhớ check mail nha”", L"“Chiều nay họp team, nhớ check mail nha”"},
    {L"Chủ yếu tiếng Anh", L"Mostly English"},
    {L"“See you at the meeting, nhớ mang laptop nhé”", L"“See you at the meeting, nhớ mang laptop nhé”"},
    {L"Gõ thử", L"Try typing"},
    {L"Gõ thử một câu dưới đây vào ô bên dưới, bằng VietTelex như khi gõ trong mọi ứng dụng khác:",
     L"Type one of these sentences in the box below, using VietTelex as you would in any app:"},
    {L"• Chiều nay mình đi cà phê nhé\r\n• Cảm ơn bạn đã giúp đỡ hôm qua",
     L"• Chiều nay mình đi cà phê nhé\r\n• Cảm ơn bạn đã giúp đỡ hôm qua"},
    {L"• Mai họp team lúc 9h, nhớ confirm nhé\r\n• Chiều nay họp team, nhớ check mail nha\r\n• File design gửi "
     L"qua email rồi đó",
     L"• Mai họp team lúc 9h, nhớ confirm nhé\r\n• Chiều nay họp team, nhớ check mail nha\r\n• File design gửi "
     L"qua email rồi đó"},
    {L"• See you at the meeting, nhớ mang laptop nhé\r\n• Please review the report trước thứ Sáu\r\n• Mai họp "
     L"team lúc 9h, nhớ confirm nhé",
     L"• See you at the meeting, nhớ mang laptop nhé\r\n• Please review the report trước thứ Sáu\r\n• Mai họp "
     L"team lúc 9h, nhớ confirm nhé"},
    {L"Đã bật cho bạn — bỏ chọn mục nào bạn không muốn:", L"Turned on for you — untick anything you don’t want:"},
    {L"Ô này đang ở tiếng Anh? Đổi Việt/Anh bằng phím chuyển (mặc định Ctrl+Shift).",
     L"Is this box in English? Switch Vietnamese/English with the switch key (Ctrl+Shift by default)."},
    {L"Gõ lẫn tiếng Anh", L"Mixed Vietnamese/English typing"},
    {L"Bắt đầu bằng tiếng Anh trong app mới", L"Start new apps in English"},
    {L"App chưa từng chuyển bắt đầu ở tiếng Anh; app đã chuyển vẫn nhớ như cũ.",
     L"Apps you never switched start in English; apps you switched keep what they remember."},
    {L"Bạn hay gõ trộn Anh/Việt?", L"Do you often mix English into Vietnamese?"},
    {L"Nhóm Gõ lẫn tiếng Anh mới ở ngay dưới: chọn cách bạn gõ; công tắc chi tiết ở Nâng cao.",
     L"New Mixed Vietnamese/English typing section below: pick how you type; details under Advanced."},
    {L"Xem", L"Show me"},
    // Quick profile picker (ONBOARDING-SPEC §4)
    {L"Bạn thường gõ thế nào? Chọn một — các công tắc bên dưới sẽ tự đặt theo.",
     L"How do you usually type? Pick one — the switches below are set to match."},
    {L"Tuỳ chỉnh", L"Custom"},
    {L"Bạn đã tự chỉnh các công tắc bên dưới.", L"You changed the switches below yourself."},
    {L"✓ Đang dùng", L"✓ In use"},
    {L"Chọn", L"Use"},
    {L"Áp dụng “%s”?", L"Apply “%s”?"},
    {L"Các công tắc bạn đã tự chỉnh sẽ đổi:", L"Switches you changed yourself will change:"},
    // Settings cleanup (docs/SETTINGS-CLEANUP-SPEC.md): expanders, import labels
    {L"Nâng cao", L"Advanced"},
    {L"Telex đơn giản, bỏ dấu tự do, gõ tắt phụ âm, dấu kiểu mới, teencode, phím ngoặc, sửa dấu",
     L"Simple Telex, free tones, quick consonants, modern tones, teencode, brackets, fix typed words"},
    {L"Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…",
     L"English auto-restore, context, colliding words, fixing earlier words…"},
    {L"Nhớ theo ứng dụng, app mới bắt đầu bằng tiếng Anh, bộ gõ mặc định, báo V/E khi chuyển",
     L"Per-app memory, new apps start in English, default input method, V/E when switching"},
    {L"Tự tắt tiếng Việt khi chơi game toàn màn hình, Chế độ game",
     L"Vietnamese off in fullscreen games, Game mode"},
    {L"Biểu tượng bàn phím, biểu tượng khay", L"Keyboard icon, tray icon"},
    {L"Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này.",
     L"VNI leaves English words as typed, so there is nothing to set here."},
    {L"Tệp gõ tắt", L"Shortcut files"},
    {L"tệp gõ tắt của bộ gõ khác", L"another input method’s shortcut file"},
    {L"VietTelex / văn bản", L"VietTelex / text"},
    // App feel (docs/WINDOWS-APP-FEEL-SPEC.md)
    {L"Thoát VietTelex", L"Quit VietTelex"},
    {L"Khởi động cùng Windows", L"Start with Windows"},
    {L"VietTelex đang tắt (đang chọn bàn phím khác) — bấm để bật",
     L"VietTelex is off (another keyboard is selected) — click to turn it on"},
    {L"Đang dùng bàn phím tiếng Việt khác — bấm để VietTelex gõ",
     L"Another Vietnamese keyboard is in use — click to type with VietTelex"},
    {L"VietTelex portable", L"VietTelex portable"},
    {L"Đã sẵn sàng — gõ thử ở đây", L"Ready — try typing here"},
    {L"Đổi Việt/Anh: Ctrl+Shift hoặc bấm biểu tượng V/E ở khay.",
     L"Switch Vietnamese/English: Ctrl+Shift, or click the V/E icon in the notification area."},
    {L"Bản portable không gõ được vào ứng dụng chạy quyền quản trị.",
     L"The portable version cannot type into apps running as administrator."},
    {L"Một bộ gõ tiếng Việt khác đang chạy: hai bộ gõ cùng lúc sẽ bỏ dấu hai lần.",
     L"Another Vietnamese input method is running: two at once add every tone twice."},
    {L"Danh sách bàn phím còn bàn phím tiếng Việt có sẵn của Windows (không phải VietTelex), nó có thể giành "
     L"chỗ mặc định. Bấm Gỡ để chỉ dùng VietTelex — thêm lại được bất cứ lúc nào.",
     L"Your keyboard list also has Windows' built-in Vietnamese keyboard (not VietTelex), which can take over as "
     L"the default. Click Remove to use only VietTelex — you can add it back anytime."},
    {L"VietTelex bản cài đang chạy trên máy này nên bản portable sẽ thoát (hai bộ gõ cùng lúc sẽ bỏ dấu hai "
     L"lần).\n\nBạn vẫn gõ tiếng Việt bằng bản cài như thường: Ctrl+Shift hoặc bấm biểu tượng V/E ở khay.\n\n"
     L"Muốn dùng bản portable: bấm chuột phải biểu tượng VietTelex ở khay → Thoát VietTelex, rồi mở lại "
     L"VietTelex.exe trong thư mục portable. Bản portable không có trong danh sách bàn phím của Windows "
     L"(Win+Space) — bật/tắt tiếng Việt bằng Ctrl+Shift hoặc biểu tượng ở khay.",
     L"The installed VietTelex is running on this PC, so the portable copy will quit (two at once would add every "
     L"tone twice).\n\nYou can keep typing Vietnamese with the installed version: Ctrl+Shift or a click on the V/E "
     L"icon in the notification area.\n\nTo use the portable copy: right-click the VietTelex icon in the "
     L"notification area → Quit VietTelex, then open VietTelex.exe in the portable folder again. The portable copy "
     L"is not in Windows' keyboard list (Win+Space) — switch Vietnamese on/off with Ctrl+Shift or its tray icon."},
    {L"Đã có VietTelex %s. Mở trang tải để lấy bản portable mới?",
     L"VietTelex %s is available. Open the download page for the new portable version?"},
    {L"Bản portable không có gợi ý từ — dùng bản cài để có gợi ý.",
     L"The portable version has no suggestions — use the installed version for them."},
    {L"Xoá lùi về từ vừa gõ rồi thêm dấu: “toan ” + Backspace + s → toán.",
     L"Backspace into the word you just typed to add a tone: “toan ” + Backspace + s → toán."},
    // One-click removal of Windows' built-in Vietnamese keyboard (welcome row)
    {L"Gỡ", L"Remove"},
    {L"Đã gỡ — giờ chỉ còn VietTelex, và VietTelex là bàn phím mặc định.",
     L"Removed — only VietTelex is left, and it is the default keyboard."},
    // Portable (báo lỗi 1.3.17)
    {L"VietTelex đang được chạy thẳng từ trong file zip nên không chạy được.\n\nBấm chuột phải file zip → "
     L"Giải nén tất cả (Extract All), rồi mở VietTelex.exe trong thư mục vừa giải nén (cần có file "
     L"portable.ini nằm cạnh).",
     L"VietTelex was started from inside the zip file, so it cannot run.\n\nRight-click the zip → Extract All, "
     L"then open VietTelex.exe in the extracted folder (portable.ini must be next to it)."},
    {L"Cửa sổ này đang dùng bàn phím tiếng Việt (VietTelex bản cài hoặc bàn phím có sẵn của Windows) nên bản "
     L"portable nhường, và danh sách bàn phím không có bàn phím nào khác để đổi sang.\n\nThêm bàn phím tiếng Anh "
     L"(US) trong Cài đặt Windows → Thời gian & ngôn ngữ → Ngôn ngữ & khu vực, rồi bấm Win+Space chọn nó: bản portable "
     L"sẽ gõ tiếng Việt ở đó.",
     L"This window uses a Vietnamese keyboard (the installed VietTelex or Windows' built-in one), so the portable "
     L"copy steps aside, and the keyboard list has no other keyboard to switch to.\n\nAdd an English (US) keyboard "
     L"in Windows Settings → Time & language → Language & region, then pick it with Win+Space: the portable copy types "
     L"Vietnamese there."},
    {L"Mở app không hiện cửa sổ Cài đặt", L"Start without the Settings window"},
    {L"Mở VietTelex thì chỉ chạy nền. Mở lần nữa khi đang chạy để hiện Cài đặt.",
     L"Opening VietTelex only runs it in the background. Open it again to show Settings."},
    {L"Phát tiếng khi đổi Việt/Anh", L"Play a sound when switching Việt/Anh"},
    {L"Tiếng đi lên là tiếng Việt, đi xuống là tiếng Anh. Chỉ khi bạn tự đổi.",
     L"A rising tone means Vietnamese, a falling one English. Only when you switch."},
    {L"Tự thêm dấu mũ", L"Auto-add circumflex"},
    {L"Gõ vietj ra việt, benhj ra bệnh khi vần không mũ không tồn tại.",
     L"Type vietj for việt when the plain vowel isn't a valid syllable."},
};
static_assert(sizeof(kStrings) / sizeof(kStrings[0]) == static_cast<size_t>(S::Count), "string table size");
}  // namespace

const wchar_t* tr(S id) {
    const Pair& p = kStrings[static_cast<size_t>(id)];
    return g_en ? p.en : p.vi;
}

void setEnglish(bool en) { g_en = en; }

S textPredictionState(bool on) { return on ? S::TextPredictionOn : S::TextPredictionOff; }

std::wstring textPredictionDesc(bool on) {
    return std::wstring(tr(textPredictionState(on))) + L" " + tr(S::TextPredictionCaption);
}

}  // namespace vtx::app
