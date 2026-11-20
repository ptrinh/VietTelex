# VietTelex Windows — Spec

> Trạng thái: SPEC (26/09/2026). Nguồn sự thật hành vi gõ: `TelexCore/` (Swift, dùng chung
> macOS/iOS) + app macOS 1.7.12 (`App/Sources/`). Mục tiêu: **gõ y hệt macOS** (cùng engine,
> cùng tuỳ chọn, cùng mặc định), triết lý giữ nguyên: tối giản, nhanh, ổn định, không thu thập
> dữ liệu, mã nguồn mở (MIT, cùng repo public, thư mục `windows/`).

---

## 1. Nguyên tắc

- **Bộ gõ thật của hệ thống** — Text Services Framework (TSF) Text Input Processor (TIP), tương
  đương InputMethodKit bên macOS. **Không** dùng global keyboard hook + giả lập phím làm đường
  chính (kiểu UniKey/EVKey): hook dễ vỡ, bị anti-cheat/antivirus nghi ngờ, xung đột app khác.
  Hook chỉ là đường dự phòng theo từng app (§5.3).
- **Không gạch chân** từ đang gõ, con trỏ luôn ở cuối chữ, undo/autocomplete của app giữ nguyên.
- **Hiệu năng**: engine ≤ 200 ns/phím, xử lý một phím trong TIP (key event → text đã sửa) < 1 ms
  p99; DLL TIP < 1 MB mỗi kiến trúc; nạp vào process mới < 5 ms; 0% CPU khi không gõ
  (không timer, không polling).
- **Không mạng** trừ khi user bấm/bật *Kiểm tra cập nhật*. Không telemetry, không crash SDK.
- Mỗi bug sửa phải kèm regression test (quy ước dự án).

## 2. Kiến trúc

```
windows/
├── engine/          C++20 thư viện tĩnh, không phụ thuộc Win32 — port TelexCore 1:1
│   └── tests/       golden corpus chung (§3.2) + unit test (GoogleTest hoặc doctest)
├── tip/             VietTelexTIP.dll — COM in-process, TSF TIP (x86, x64, ARM64)
├── app/             VietTelex.exe — tray + cửa sổ Cài đặt + cập nhật + (tuỳ) hook dự phòng
├── installer/       WiX v4 → MSI per-machine, đăng ký COM + TSF profile
└── docs/
```

- **Ngôn ngữ**: C++20 (MSVC, `/permissive-`, không exception qua ranh giới COM, không RTTI trong
  TIP). Lý do: TIP là DLL được nạp vào **mọi** process có ô nhập — cần nhỏ, không runtime phụ,
  COM là C++ tự nhiên. (Phương án thay thế: Rust + `windows-rs` — xem §14.)
- **Engine port 1:1 từ `TelexCore/Sources/TelexCore/`** (`TelexEngine`, `SyllableValidator`,
  `Tables`, `EnglishCollisions`, `EnglishContextWords`). Không mang `InPlaceProbe`,
  `IMEActivation`, `ClientPolicy` (đặc sản macOS) — Windows có chính sách app riêng (§5).
- **Một nguồn settings** dùng chung TIP ↔ app (§9).

## 3. Engine

### 3.1 API (giữ tên Swift)
`feed(ch) → Action{Passthrough | Replace(backspaces, insert) | None}`, `backspace()`,
`commitBoundary(autoRestore)`, `peekCommitText()` (không đổi state), `composed`,
`rawKeystrokes`, `reset()`, `resetContext()`, `reopenLastCommit()` (gõ lại dấu cho từ trước con
trỏ). Cờ: `freeMarking, simpleTelex, liveSpellCheck, quickTelex, modernTone, teencode,
contextualEnglish, bracketVowels, vniMode, collisionPrefersVietnamese`.

Hiệu năng: bảng tra compile sẵn (constexpr / mảng tĩnh), buffer cố định trên stack
(`std::array<char16_t, 32>`), **0 cấp phát** ở phím không đổi màn hình; bộ từ Anh dạng
perfect-hash/trie nằm trong `.rdata` (không nạp file).

### 3.2 Golden corpus
Dùng lại target Swift `gen-golden` (`TelexCore/Sources/GenGolden`, đã có cho Android, ~358k ca):
sinh `golden.tsv.gz`, test C++ phải khớp **100%**. Mỗi lần sửa engine Swift: `swift run
gen-golden` → port → `ctest` xanh. CI chạy cả ba (Swift, Kotlin, C++).

## 4. TIP (TSF)

### 4.1 Đăng ký
- CLSID riêng, profile **vi-VN (0x042A)**, tên hiển thị **"Tiếng Việt (VietTelex)"**, icon Vᴛ.
- Layout thay thế US (`SubstituteLayout = 0x04090409`), nhưng KHÔNG dựa hẳn vào nó (#121): phím
  TIP để app tự gõ (số, dấu câu, chế độ Anh, Direct) đi qua layout của thread; nếu đó là layout
  "Vietnamese" gốc (1→ă…) thì TIP nuốt phím và tự gõ ký tự US (SendInput Unicode) — chỉ phím
  layout gõ khác US, chỉ trong ô nhận chữ, không trong game/app "off"/secure desktop
  (`keymap.h` `shouldRetypeAsUs`, `TextService::retypeAsUs`).
- Category: `GUID_TFCAT_TIP_KEYBOARD`, `GUID_TFCAT_TIPCAP_UIELEMENTENABLED`,
  `GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT` (UWP/Store/Start/Search), `GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT`,
  `GUID_TFCAT_TIPCAP_SECUREMODE` (hộp thoại UAC/lock screen: chạy chế độ tối thiểu, không đọc
  settings/từ điển người dùng), `GUID_TFCAT_TIPCAP_COMLESS` (nếu áp dụng).
- DLL cài vào `%ProgramFiles%\VietTelex\` (x64/ARM64) và `%ProgramFiles(x86)%\VietTelex\` (x86);
  ACL đọc/thực thi cho `ALL APPLICATION PACKAGES` + `ALL RESTRICTED APPLICATION PACKAGES`
  để process AppContainer nạp được.

### 4.2 Luồng gõ
- `ITfKeyEventSink::OnTestKeyDown/OnKeyDown`: chỉ ăn phím chữ/số (VNI)/dấu Telex khi đang ở chế độ
  Việt và ô nhập không phải mật khẩu; Ctrl/Alt/Win + phím → passthrough + `reset()`.
- **Chế độ mặc định: composition không gạch chân.** Mở `ITfComposition` cho từ đang gõ, gán
  display attribute `TF_DISPLAYATTRIBUTE` với `lsStyle = TF_LS_NONE` (không gạch chân, không nền),
  mỗi phím `SetText` lại cả range bằng `composed`. Ranh giới từ (space, dấu câu, Enter, click,
  mũi tên) → `commitBoundary` → `EndComposition`. Ưu điểm: một nguồn sự thật, app nhận text cuối,
  autocomplete/undo không bị vỡ bởi backspace giả.
- **Chế độ in-place (theo app)**: không composition, sửa trực tiếp range trước con trỏ
  (`ITfRange::ShiftStart(-n)` + `SetText`) — dùng khi app vẽ composition xấu hoặc xử lý sai
  (tương đương đường replacementRange bên macOS). Học/ghi đè theo app (§5).
- **Gõ lại từ trước con trỏ** (`reEditWord`, mặc định bật): con trỏ đứng ngay sau một từ và gõ
  phím dấu → đọc lại từ qua `ITfRange::GetText`, `reopenLastCommit`/seed engine rồi áp dấu.
- Theo dõi con trỏ bằng `ITfTextEditSink::OnEndEdit` + `ITfThreadMgrEventSink`; selection đổi từ
  ngoài (click, phím điều hướng, app tự sửa) → `reset()` không chèn gì.
- Input scope `IS_PASSWORD / IS_PRIVATE / IS_NUMBER / IS_TELEPHONE_*` → passthrough (literal).
  `IS_EMAIL_*`, `IS_URL` → passthrough mặc định (như macOS với ô không autocorrect).

### 4.3 Chuyển Việt ↔ Anh
- Trong TIP: phím tắt chuyển mặc định **Ctrl+Shift** (giống thói quen UniKey), đổi được
  (Alt+Z, Ctrl+Space, Win+Space dành cho hệ thống). Đăng ký bằng
  `ITfKeystrokeMgr::PreserveKey`. Trạng thái lưu **theo từng app** (exe name), như macOS nhớ theo
  bundle ID.
- Chỉ báo: nút **Language Bar / system tray input indicator** (`ITfLangBarItemButton`) hiện **V**
  / **E** (hoặc icon Vᴛ / chữ E theo tuỳ chọn `menuIcon`), click = đổi, chuột phải = menu (Cài
  đặt, bảng mã, kiểu gõ Telex/VNI, Kiểm tra cập nhật, Thoát chế độ Việt).

## 5. Tương thích ứng dụng

### 5.1 Chính sách theo app (tương đương macOS `manualAppModes` / `fallbackApps`)
Mỗi exe có một mode: `composition` (mặc định) · `inPlace` · `hookFallback` · `off` (luôn Anh).
Bảng mặc định cài sẵn (JSON trong DLL) + user ghi đè trong Cài đặt → tab **Ứng dụng**.

### 5.2 Ma trận phải chạy (test tay mỗi release, §12)
Notepad (Win11), WordPad/Word, Excel (ô + thanh công thức), PowerPoint, Outlook (soạn + tìm),
OneNote, Chrome/Edge/Brave/Firefox (ô địa chỉ có autocomplete, form, Google Docs, Sheets),
Electron (VS Code, Slack, Discord, Teams mới, Zalo PC, Messenger, Notion, Obsidian), Telegram
Desktop, Windows Terminal (PowerShell, cmd, WSL bash — giữ autocomplete shell), conhost cũ,
Explorer (đổi tên, ô tìm), Start/Windows Search, Settings, UWP/WinUI (Mail, Sticky Notes),
app chạy quyền Admin, Remote Desktop / AnyDesk (client), JetBrains IDE (Java), Qt app,
game DirectX (nên tự `off`). Kiểm: không nhân đôi chữ, không mất dấu, backspace đúng,
auto-restore đúng, không gạch chân, undo một bước ra từ gốc.

### 5.3 Hook dự phòng (`hookFallback`)
Cho app không hỗ trợ TSF tử tế (một số app Java/Qt cũ, game, RDP client): `VietTelex.exe` bật
`WH_KEYBOARD_LL` **chỉ khi app đó ở foreground**, engine chạy trong process app, xuất bằng
`SendInput` (`KEYEVENTF_UNICODE`, backspace dùng VK_BACK), đánh dấu `dwExtraInfo` để bỏ qua
phím tự sinh, có breaker chống cascade (bài học macOS 1.2.1: synthetic-event cascade treo bàn
phím). Mặc định tắt; user bật theo app.

## 6. Bảng mã & đầu ra
- Mặc định **Unicode dựng sẵn (NFC)**. Tuỳ chọn: Unicode tổ hợp (NFD), **TCVN3 (ABC)**,
  **VNI Windows** — cho văn bản/phần mềm cũ ở VN (bên macOS không có; Windows cần vì còn phổ
  biến). Chuyển mã chỉ ở tầng xuất, engine luôn Unicode.

## 7. Tính năng (parity macOS 1.7.12, cùng mặc định)

| Nhóm | Tuỳ chọn (key) | Mặc định |
|---|---|---|
| Kiểu gõ | Telex / VNI (`vniMode`) | Telex |
| | Telex đơn giản — w đứng lẻ giữ w (`simpleTelex`) | tắt |
| | Bỏ dấu tự do (`freeMarking`) | bật |
| | Gõ nhanh cc→ch, nn→ng… (`quickTelex`) | tắt |
| | Bỏ dấu kiểu mới hoà/thuý (`modernOrthography`) | tắt |
| | `[` `]` → ơ ư (`bracketVowels`) | tắt |
| Chính tả | Tự khôi phục từ tiếng Anh (`autoRestore`) | bật |
| | Kiểm tra chính tả khi gõ (`liveSpellCheck`) | bật |
| | Quyết định theo ngữ cảnh (`contextualEnglish`) | bật |
| | Tự sửa từ phía trước, thử nghiệm (`retroactiveEnglish`; chỉ hiện khi `contextualEnglish` bật) | tắt |
| | Đoán từ trùng theo tần suất, thử nghiệm (`englishByFrequency`; chỉ hiện khi `contextualEnglish` bật; phép lật lại tự áp cả ở chế độ mời và trước Enter) | tắt |
| | Ưu tiên tiếng Việt khi trùng (`collisionPrefersVietnamese`) | bật |
| | Chính tả teencode (`teencode`) | tắt |
| | Gõ lại dấu cho từ trước con trỏ (`reEditWord`) | bật |
| Gõ tắt | Bảng gõ tắt (`shortcuts`), nhập/xuất file như macOS | rỗng |
| Chuyển | Phím tắt chuyển (`switchHotkey`), nhớ theo app | Ctrl+Shift |
| | Bắt đầu bằng tiếng Anh trong app mới (`startEnglish`; hồ sơ onboarding `en`) | tắt |
| Giao diện | Icon khay (`menuIcon`), ngôn ngữ UI vi/en (`uiLanguage`) | Vᴛ, vi |
| Hệ thống | Tự kiểm tra cập nhật (`autoUpdateCheck`), Debug log (`debugLogging`) | tắt / tắt |

Mặc định lấy từ `App/Sources/AppState.swift` (1.7.12); nếu macOS đổi mặc định thì Windows đổi theo.
Từ 05/11/2026 (docs/ONBOARDING-SPEC.md §4) Cài đặt gom `autoRestore`, `collisionPrefersVietnamese`,
`contextualEnglish`, `retroactiveEnglish`, `englishByFrequency`, `switchHotkey`, `startEnglish` vào
nhóm "Gõ lẫn tiếng Anh" (phần Nâng cao) và "Chuyển Việt/Anh" của trang Gõ phím (key không đổi; xem docs/SETTINGS-CLEANUP-SPEC.md).

## 8. App `VietTelex.exe`
- Win32 thuần + Common Controls v6, dark mode theo hệ thống (`DwmSetWindowAttribute`,
  `SetPreferredAppMode`), DPI-aware per-monitor v2. **Không** WinUI/WPF/.NET (runtime nặng).
  Tự khởi động (Run key HKCU) để giữ khay; tắt app vẫn gõ được (TIP độc lập).
- Cửa sổ Cài đặt, các tab giống macOS: **Kiểu gõ · Chính tả · Gõ tắt · Ứng dụng · Giới thiệu**
  (log gỡ lỗi: Giới thiệu → Chẩn đoán; chế độ in-place/hook theo app: tab Ứng dụng).
- Một instance (named mutex); lần mở thứ hai → đưa cửa sổ lên (nhường, không kill — như macOS
  `SingleInstance` "yield not kill").
- Cập nhật: đọc `https://viettelex.com/stable.json` (cùng định dạng `docs/stable.json`, thêm
  trường `windows`), tải MSI đã ký, kiểm tra chữ ký Authenticode trước khi chạy.

## 9. Settings & dữ liệu
- `HKCU\Software\VietTelex` (DWORD/String; gõ tắt = REG_BINARY JSON). TIP đọc một lần khi kích
  hoạt + khi app phát sự kiện đổi (`RegNotifyChangeKeyValue` trên luồng riêng của TIP, không poll).
- Process AppContainer không đọc được HKCU thường → app ghi thêm bản sao **read-only** vào
  file `%LOCALAPPDATA%\VietTelex\settings.bin` có ACL cho `ALL APPLICATION PACKAGES`; TIP trong
  AppContainer đọc file đó (memory-mapped). Không bao giờ ghi từ TIP trong AppContainer.
- Không lưu nội dung gõ. Debug log (chỉ khi bật) **không ghi ký tự** ở bản Release.

## 10. Bảo mật & tin cậy
- Ký Authenticode (Azure Trusted Signing hoặc EV cert) cho DLL, EXE, MSI — không ký thì
  SmartScreen chặn và Defender dễ gắn cờ hook.
- TIP không mở mạng, không ghi file ngoài thư mục của mình, không tạo thread ở `DllMain`.
- Secure desktop (UAC, lock screen): chỉ Telex cơ bản, không đọc dữ liệu người dùng.

## 11. Cài đặt & phân phối
- **MSI per-machine** (WiX v4): cài 3 kiến trúc DLL, `regsvr32`-equivalent qua custom action
  (`ITfInputProcessorProfileMgr::RegisterProfile`), thêm VietTelex vào danh sách bàn phím của
  user hiện tại (`InstallLayoutOrTip`), gỡ sạch khi uninstall (unregister + xoá HKCU tuỳ chọn).
- Kênh: GitHub Releases (cùng repo), **winget** (`ptrinh.VietTelex`), Microsoft Store
  (MSIX có khai báo TSF — giai đoạn sau, tuỳ §14).
- Yêu cầu: Windows 10 1903+ và Windows 11, x64 + ARM64 (kèm DLL x86 cho app 32-bit).

## 12. Kiểm thử
- **Unit/golden**: engine C++ khớp 100% golden; test chuyển mã (NFC/NFD/TCVN3/VNI).
- **TIP tự động**: host test dùng `ITfThreadMgr` + text store giả (ITextStoreACP) để chạy
  chuỗi phím và so văn bản cuối với golden; chạy trên CI `windows-latest` (x64) + ARM64 runner.
- **UI Automation smoke**: script mở Notepad/Edge/Windows Terminal, gõ bằng `SendInput`, đọc lại
  qua UIA — chạy trước mỗi release.
- **Ma trận tay** §5.2 + máy thật: Win10 22H2, Win11 24H2/25H2, một máy ARM64 (Snapdragon X).
- **Đo**: ns/phím (engine), ms/phím p50/p99 (TIP, ETW), thời gian nạp DLL, RAM thêm mỗi process.

## 13. Milestones

| M | Nội dung | Ước lượng |
|---|---|---|
| W0 | Repo/CMake, engine C++ 100% golden, CI | 3–4 ngày |
| W1 | TIP tối thiểu: đăng ký, composition không gạch chân, Việt/Anh, Notepad/Word | 3 ngày |
| W2 | Input scope, per-app state, reEditWord, in-place mode, Terminal/Chrome/Electron | 4 ngày |
| W3 | App tray + Cài đặt đủ tab, settings AppContainer, gõ tắt, bảng mã | 4 ngày |
| W4 | Hook dự phòng, secure mode, ARM64/x86, ma trận §5.2 | 4 ngày |
| W5 | MSI ký số, winget, updater, docs, beta với tester | ~1 tuần |

## 14. Quyết định còn mở
1. **C++ hay Rust** cho engine + TIP. Spec chọn C++ (nhỏ, COM tự nhiên). Rust chỉ đáng nếu muốn
   dần dùng một engine Rust chung cho cả macOS/iOS/Android.
2. **Phím tắt chuyển mặc định**: Ctrl+Shift (quen với người dùng UniKey) hay để Win+Space của hệ
   thống làm chính.
3. **Bảng mã cũ** (TCVN3, VNI Windows): đưa vào bản đầu hay để sau.
4. **Microsoft Store (MSIX)** ngay từ đầu hay chỉ MSI + winget.
5. **Chứng chỉ ký**: Azure Trusted Signing (rẻ, cần tổ chức/xác minh) hay EV cert.

## Quyết định đã chốt (26/09/2026)
1. Engine + TSF viết bằng **C++**.
2. Phím chuyển Việt/Anh: **cho người dùng chọn** trong Cài đặt (Ctrl+Shift kiểu UniKey hoặc Win+Space của hệ thống).
3. Bảng mã cũ (TCVN3, VNI Windows): **không làm** — chỉ Unicode.
4. **Microsoft Store: có** ngay từ đầu (song song MSI + winget).
5. Ký số: **Azure Trusted Signing**.
6. **ARM64 hỗ trợ ngay từ v1**: bản MSI ARM64 cài `VietTelexTIP.dll` dạng ARM64X pure forwarder (đăng ký COM) chuyển tiếp sang `VietTelexTIP_arm64.dll` (app ARM64 gốc) và `VietTelexTIP_x64.dll` (app x64 giả lập); build tự động bằng `link /MACHINE:ARM64X` trong CMake, không relink tay.
7. **Microsoft Store qua đường "MSI or EXE app"** của Partner Center (không dùng MSIX): MSI đã ký, URL tải HTTPS có phiên bản và bất biến, cài im lặng `/qn`; checklist tại `windows/installer/STORE.md`. MSIX chỉ còn là template tuỳ chọn cho app đồng hành.
8. **Chế độ mặc định: sửa trực tiếp (in-place)** cho mọi ứng dụng (từ 1.0.9, sau khi thử trên Windows thật): sửa đoạn chữ trước con trỏ có đối chiếu; composition không gạch chân là lựa chọn theo từng app trong tab Ứng dụng. Ô mật khẩu/PIN/số vẫn gõ thẳng. Nếu một ô không đọc/đối chiếu được chữ quanh con trỏ thì ô đó tự chuyển sang composition (có ghi log). Vùng chọn phía sau con trỏ (gợi ý autocomplete của thanh địa chỉ Chrome/Edge) là của ứng dụng: chỉ sửa chữ trước con trỏ, không xoá gợi ý. Lựa chọn composition đã đặt trước đó được giữ nguyên. (Ghi chú này thay cho mục "Chế độ mặc định: composition" ở §4.2.)
9. **Thanh địa chỉ Chromium (Edge/Chrome/Brave/Cốc Cốc…) gõ bằng composition** (10/2026, báo lỗi Edge "theêz"): omnibox gốc (views::Textfield) chọn gợi ý inline autocomplete theo chiều NGƯỢC, và TSFTextStore đổi SetText in-place thành `ExtendSelectionAndDelete(n,0)` + `InsertText` → phần xoá rơi vào trong gợi ý, chữ cũ còn lại. Ô có input scope `IS_URL` trong các exe này dùng composition ngay từ chữ đầu (không gạch chân; omnibox tự đưa gợi ý ra ngoài văn bản khi IME đang soạn). Thêm lưới an toàn chung: app nào "nuốt" phần xoá của một lần thay in-place (màn hình = từ cũ + chữ chèn) thì ô đó chuyển composition — không bao giờ chuyển sang hook (backspace-retype đua với autocomplete). **Cập nhật #173 (11/2026):** chính thanh địa chỉ vẫn vẽ gạch chân dưới mọi composition, nên ô đó giao cho hook (Direct): mỗi lần thay = U+202F (huỷ gợi ý) + Backspace × (N + 1) + chữ, trong một lô SendInput (như macOS `.emptyReset`); xoá thuần và ⌫ của người dùng không dùng U+202F. Composition chỉ còn là đường lui (không có VietTelex.exe, UIPI, NoDirect do SendInput bị từ chối, hook không ack trong 500 ms). Ô này KHÔNG được kiểm tra lại sau khi sửa: không gọi UI Automation vào trình duyệt (có thể bật chế độ trợ năng cho cả trình duyệt, tốn CPU/RAM), coi như ô không đọc được — hook vẫn gõ.
10. **Ctrl+Shift khi đang ở bàn phím khác** (10/2026): phím chuyển nằm trong TIP nên vô tác dụng khi cửa sổ đang dùng ENG. VietTelex.exe giữ một hook bàn phím chỉ-quan-sát khi phím chuyển là Ctrl+Shift; hợp âm hoàn tất mà cửa sổ trước mặt không có TIP (không có `VietTelex.Lang`, layout ≠ vi-VN) → lưu Việt cho app và gửi `WM_INPUTLANGCHANGEREQUEST` (HKL vi-VN) cho cửa sổ đang focus. Kèm thẻ "Bộ gõ mặc định của Windows" ở trang Kiểu gõ (chỉ khi người dùng bấm): `SetDefaultLayoutOrTip("0x042A:{CLSID}{PROFILE}")` để app mới mở ra bằng VietTelex.
11. **Ô web trong Chromium/Electron/WebView2 = kho chữ bất đồng bộ** (10/2026, báo lỗi Messenger/Facebook "ại chương tình ọc AI ừ óp 1" — mất chữ): TSFTextStore chỉ cập nhật bộ đệm khi renderer báo lại, nên chữ TIP đọc có thể trễ vài phím (thậm chí cũ hơn lần sửa của chính mình), còn lệnh sửa in-place lại áp vào con trỏ THẬT của trang. Context transitory đọc được (Chromium & co) được đánh dấu `asyncStore`: thấy bộ đệm lệch thì không sửa theo nó (phím đi thẳng vào trang, ô đó chuyển composition từ từ sau), phím chỉ nối thêm chữ vẫn giữ từ; báo trễ trong OnEndEdit không xoá từ; không bật sửa lại từ cũ (re-edit) ở đó; và không bao giờ giao ô web cho hook Direct (backspace-retype mù vào editor web là lớp lỗi mất chữ kiểu UniKey). Phiên edit async (kết thúc/flush composition) chỉ tác động lên đúng composition đã yêu cầu. Mô hình kiểm thử: `windows/ime/tests/chromium_store.h`. **Chốt theo app (11/2026, #139 Canva trong Brave, "OOngs" ra "OOngs"/"Ôngs")**: editor web hay focus lại ô nhập (OnSetFocus → resetContext) nên trước đây mỗi lần focus lại trả thêm một từ mất dấu; nay khi kho chữ async của app đã trễ một lần, mọi ô web sau đó trong app gõ composition ngay từ chữ đầu (chốt giữ qua resetContext, không áp cho kho đồng bộ).
