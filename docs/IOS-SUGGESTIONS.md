# Hệ thống gợi ý của bàn phím iOS (suggestion bar)

Tài liệu thiết kế cho toàn bộ pipeline gợi ý trên `VietTelexKeyboard` (iOS
keyboard extension). Viết 2026-07-24, sau hai vòng research (thiết kế datastore
cá nhân hóa + thuật toán inline suggestion) — nguồn tham khảo chính: Gboard
federated n-gram, SwiftKey dynamic model, Grammarly personal LM blog, KenLM,
kinh nghiệm pinyin IME.

## Tổng quan

Thanh gợi ý (44pt, chỉ hiện khi bật toggle **Thanh gợi ý** trong app; bàn phím
cao 260pt khi bật, 216pt khi tắt) có **ba trạng thái** theo ngữ cảnh gõ:

| Trạng thái | Hiển thị | Nguồn dữ liệu |
|---|---|---|
| Field trống, chưa gõ | 3 từ user hay mở đầu nhất | `UserLangModel.topWords` |
| Vừa space sau một từ ("Anh ␣") | 3 từ **kế tiếp** dự đoán | `UserLangModel.nextWords` (trigram ⊕ bigram ⊕ seed) |
| Đang gõ dở một từ | `["nguyên văn"] \| ứng viên 1 \| ứng viên 2 (hoặc ≤3 emoji)` | `VNSuggest` (inline) + `EmojiSuggest` |

Rule ngữ cảnh cứng chạy trước cả ba: token trước con trỏ kết thúc bằng `@` →
gợi `gmail.com / yahoo.com / outlook.com`; kết thúc bằng `.` sau chữ/số → gợi
TLD `com / vn / net`. Các fragment này chèn không kèm space và không đi qua
datastore (token chứa `@`/`.` không phải "từ").

Hành vi bấm nhận: **nguyên văn** = giữ như đã gõ; **từ** = thay từ đang gõ +
space, đồng thời **học với weight 2**; **emoji** = thay từ bằng emoji (hành vi
QuickType). Tự tắt ở field từ chối gợi ý (`isSecureTextEntry`,
`autocorrectionType == .no`) — giống bàn phím stock.

## Các tầng dữ liệu

### 1. `VNSuggest` + `VNLexicon2Data` — inline suggestion (từ đang gõ dở)

- **Lexicon**: 7.184 âm tiết tiếng Việt (tập đóng, danh sách hieuthi) + tần
  suất văn nói OpenSubtitles, generate bởi `Scripts/gen-vnlexicon.py` thành
  blob tĩnh (~90KB) nằm thẳng trong binary — **zero cold-start**, quan trọng
  vì extension bị iOS kill/respawn liên tục.
- **Chuẩn hóa dấu kiểu cũ** lúc build: `hoà→hòa`, `thuý→thúy` — CHỈ với âm
  tiết mở (cặp oa/oe/uy ở cuối từ); có coda giữ nguyên (`toàn`, `thuyền`),
  sau `q` giữ nguyên (`quý` — u là glide).
- **Decompose**: mỗi ký tự → `(base, quality, tone)` pack 1 byte
  (`attr = quality<<3 | tone`; quality: 0 none / 1 â-ê-ô / 2 ơ-ư-ă / 3 đ;
  tone: 0-5 ngang sắc huyền hỏi ngã nặng). Bảng tra runtime ~190 ký tự, O(1)
  mỗi char, không allocation.
- **Lookup mỗi phím**: binary search range trên folded key (loại 99% lexicon)
  → post-filter **tương thích dấu** từng ký tự:
  - ký tự CHƯA bỏ dấu khớp mọi biến thể: gõ `to` → tôi, tớ, **toàn**…
  - quality đã chốt phải trùng: gõ `tô` → tôi, tối, tội… (**toàn** bị loại)
  - tone đã chốt phải trùng: gõ `tò` → tòa, tồi… (**tôi/tới** bị loại;
    `tồi` vẫn hợp lệ vì quality chưa chốt)
  - prefix 1 phím đi qua bucket **top-32 mỗi chữ cái** precomputed (hot path).
- Chi phí: **<50µs/phím** (budget 1-2ms). Trie/DAWG bị bác có chủ ý: ở scale
  7-15k entries chúng không thắng gì mà trả giá effort + cold-start.
- `VNSuggest.contains(word)` (binary search, zero RAM phụ) là nguồn
  "từ-trong-từ-điển" cho ngưỡng học của UserLangModel.

### 2. `UserLangModel` — datastore cá nhân hóa

- **Cấu trúc**: `uni [từ: count]`, `bi [prev → next → count]`,
  `tri ["p2␁p1" → next → count]` (nested dict → lookup O(1), không scan).
  Cap 3000/6000/3000, quá trần thì chia đôi mọi count (từ hiếm rơi về 0).
- **Học**: mỗi từ commit (+1; suggestion được bấm nhận +2 — tín hiệu mạnh
  hơn). Trigram chỉ ghi khi nền bigram (p2,p1) đã đạt count ≥2 — chống noise.
  Chống học typo: chỉ chữ cái thuần ≤12 ký tự, loại chuỗi lặp ≥3 ("heeeyyy");
  **learning-vs-suggesting** (pattern Grammarly): từ NGOÀI lexicon phải đạt
  count ≥3 mới được *xuất hiện* trong gợi ý (vẫn *đếm* từ lần đầu).
- **Ranking next-word**: linear interpolation với Bayesian shrinkage —
  `λ_tri = n/(n+2)`, `λ_bi = n/(n+4)`:
  `score = λ_tri·P_tri + λ_bi·P_bi + 0.1·P_uni + (1−λ_bi)·0.9·P_seed`
  (seed rank i → 0.5^i). Prev mới gặp 1-2 lần → tin seed; gặp nhiều → tin dữ
  liệu cá nhân. Một lần gõ nhầm không đè nổi seed curated (có golden test).
- **Decay**: mỗi ≥7 ngày, mọi count ×0.7^tuần lúc load (một timestamp toàn
  cục duy nhất — không lưu thời gian per-từ). Hồ sơ phản ánh thói quen gần đây.
- **Persistence**: binary plist `App Group/userlm.plist`, ghi atomic,
  coalesce 5s sau phím cuối + khi bàn phím đóng; có migrate từ format v1.
  SQLite trong App Group bị bác có chủ ý (anti-pattern iOS — corruption khi
  extension bị suspend).
- **Ranking inline**: điểm ứng viên khi đang gõ dở =
  `log(staticFreq+1) + 2.5·log(personalCount+1) + 4·[có trong nextWords ngữ cảnh] + 1.5·[chỉ-còn-thiếu-dấu]`.

### 3. `SeedData` — mồi ban đầu

Inject qua `seedIfEmpty()` khi datastore trống (cài mới / sau nút **Xóa từ đã
học**). ~700 unigram + ~470 bigram:

- Lõi hội thoại từ **OpenSubtitles2018 tiếng Việt** (lọc bias phim ảnh) + lớp
  chat/teencode curated (ko, đc, nhé, nha, haha…), weight log-scale **max 50**.
- ~112 từ tiếng Anh hay pha trong chat Việt (ok, thanks, meeting…), cap ≤18.
- Proper noun (weight 3-15, dưới lớp hội thoại): địa danh VN/quốc tế, thương
  hiệu (SenPrints, FPT, VinFast…), tech (GitHub, Claude, ChatGPT…), OS, crypto,
  họ/đệm/tên VN với **chuỗi bigram họ→đệm→tên** (Nguyễn␣ → văn/thị → hùng/lan).
- Cụm đa âm tiết luôn tách thành **bigram nối** (`hồ→chí` + `chí→minh`) để gợi
  ý trôi liên tiếp cả chuỗi.
- **Hợp đồng weight**: gõ thật +1/lần vượt seed sau 2-3 ngày; decay tuần làm
  seed mờ dần — seed chỉ là bệ đỡ ngày đầu.

### 4. `EmojiSuggest` — emoji theo nghĩa từ

721 khóa generate từ `kid-words.json` + bản dịch EN của learn-site + bảng
"emoji họ hàng" curated: từ Việt, dạng KHÔNG DẤU và từ Anh cùng nghĩa trả về
cùng bộ ≤3 ứng viên (`yêu ≡ yeu ≡ love → ❤️ 💕 💗`).

### 5. `DisplayCase` — case chuẩn khi hiển thị

Datastore case-fold toàn bộ; bảng `DisplayCase` map dạng thường → dạng chuẩn
lúc HIỂN THỊ và chèn (`senprints → SenPrints`, `iphone → iPhone`,
`macos → macOS`, `nguyễn → Nguyễn`). Nguyên tắc: **chỉ token không nhập
nhằng** — vũ/đỗ/ngô/trang/nội/quốc bị loại có chủ ý (thà hiện thường còn hơn
hoa sai giữa câu). Học vẫn đếm dưới khóa thường.

### 6. `SensitiveWords` — lọc từ nhạy cảm

Chuẩn ngành (Gboard/SwiftKey): từ tục **vẫn nằm trong datastore và vẫn được
học**, nhưng toggle **Lọc từ nhạy cảm khỏi gợi ý** (mặc định BẬT — cân nhắc
App Store review) giấu chúng khỏi thanh. Phân tầng: chỉ token thô (lồn, địt,
đcm, vcl, tml, sml, fuck…) bị lọc; insult chuẩn mực (khốn nạn, ngu si) và từ
đời thường (cướp, giết, đánh rắm, mày/má) KHÔNG lọc. Khi lọc, over-fetch 6
lấy top-3 nên slot luôn được lấp.

## Settings (App Group `group.com.viettelex`)

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `showSuggestions` | true | Bật thanh gợi ý (bàn phím 260pt ↔ 216pt) |
| `learnWords` | true | Cho phép học từ hay dùng |
| `filterSensitive` | true | Lọc từ tục khỏi gợi ý |
| nút **Xóa từ đã học** | — | Xóa `userlm.plist`; lần mở sau seed lại |

## Privacy

- Chỉ đếm **tần suất** từ đơn + cặp/bộ-ba từ — không lưu câu, không thứ tự gõ,
  không timestamp per-từ. Ô mật khẩu không bao giờ đi qua pipeline.
- Toàn bộ dữ liệu nằm trong App Group container trên máy; không Full Access,
  không network.

## Bản đồ file

| File | Vai trò |
|---|---|
| `ios/Keyboard/VNSuggest.swift` | Engine inline suggestion (lookup + compat filter) |
| `ios/Keyboard/VNLexicon2.swift` | GENERATED — lexicon 7.184 âm tiết (blob) |
| `Scripts/gen-vnlexicon.py` | Script tái lập lexicon (nguồn hieuthi + OpenSubtitles) |
| `ios/Keyboard/UserLangModel.swift` | Datastore cá nhân hóa n-gram |
| `ios/Keyboard/SeedData.swift` | GENERATED + curated — seed ban đầu |
| `ios/Keyboard/EmojiSuggest.swift` | GENERATED — emoji theo nghĩa |
| `ios/Keyboard/DisplayCase.swift` | Case chuẩn proper noun |
| `ios/Keyboard/SensitiveWords.swift` | Bộ lọc từ nhạy cảm |
| `ios/Keyboard/KeyboardViewController.swift` | Điều phối: context, học, build SuggestionSet |
| `ios/Keyboard/KeyboardView.swift` | UI thanh gợi ý (SuggestionSet → slots) |

Tests: `ios/KeyboardTests/EngineBridgeTests.swift` — goldens cho compat-match
("tô" ⊅ toàn), shrinkage (1 lần gõ nhầm không đè seed), trigram gating,
ngưỡng học từ lạ, seed contract (max weight ≤50), filter tiers, display-case.

## Đường nâng cấp đã vạch (chưa làm)

- Personal model >50k entries → binary sorted array + mmap.
- Lexicon tĩnh >100k mục (lên tầng từ ghép/cụm) → double-array trie / marisa,
  bài học pinyin IME.
- Học case từ chính user (hiện DisplayCase là bảng tĩnh).
- Gợi ý viết hoa theo ngữ cảnh câu (auto-shift-aware).
