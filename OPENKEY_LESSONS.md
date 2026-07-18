# Bài học từ OpenKey/EVKey — edge cases cho engine Telex

Chắt lọc từ commit history + CHANGELOG + issues của OpenKey (GPL — chỉ học **hành vi**,
không copy code) và EVKey, rồi **chạy engine hiện tại của VietTelex** đối chiếu. Mỗi
mục ghi trạng thái thực tế của mình để quyết định có đáng làm không.

Ký hiệu: ✅ đã đúng · 🔴 bug thật nên fix · 🟡 nên cân nhắc · ⚪ bỏ qua (không hợp Simple Telex).

> **Trạng thái (đã làm):** B1 (ươ) ✅ · B2 (coda-tone) ✅ · C1 (trailing d) ✅ ·
> C2 (w reach-back) ✅ · C3 (w-lẻ) ✅ · C4 (auto-restore) ✅ — đều có golden test
> trong `EngineTests.swift` (`testUowHornPropagation`, `testStopCodaToneConstraint`,
> `testTrailingDMakesDbar`, `testWReachesBackOverCoda`, `testStandaloneWBlocking`,
> `testAutoRestoreKeepsRareValidWords`). **Hết backlog OpenKey** (trừ C1/C2 hoãn ⚪).
> Ghi chú thực thi C3/C4: xem mục C3 & C4 bên dưới.

## Đã đúng — không cần làm gì ✅

| Input | Engine mình ra | Ghi chú |
|---|---|---|
| `hoaf` | hòa | tone trên nguyên âm đầu = **kiểu cũ**, đúng thiết kế (research dán nhãn "hoà" là kiểu mới) |
| `uys` / `thuyr` | úy / thủy | kiểu cũ, đúng |
| `nguyeenj` / `Nguyeejn` | nguyện / Nguyện | quy tắc "ê luôn nhận dấu" hoạt động; giữ hoa/thường |
| `quets` | quét | bỏ qua `u` của `qu` khi đặt dấu |
| `gif` / `ginf` | gì / gìn | xử lý `gi` onset |
| `huychj` / `tuyps` / `quyts` | huỵch / tuýp / quýt | bảng vần `uy`+coda đầy đủ |
| `ass` / `aaa` / `ddd` | as / aa / dd | double-key hủy dấu + latch |
| `DDA` | ĐA | case là cờ độc lập |
| `toans` | toán | đặt dấu lại khi có coda |
| `khuyar` | khuỷa | ok |

Engine mình đã cover phần lớn edge case cốt lõi của Telex — nền tảng tốt.

## Bug thật — nên fix 🔴

### B1. `ươ` không lan horn sang cả hai nguyên âm — CAO, phổ biến nhất
- Hiện tại: `uow` → **uơ** (chỉ horn `o`, `u` giữ nguyên). Đúng phải là **ươ**.
- Ảnh hưởng từ RẤT thường dùng: **được, người, trường, nước, thương, đường, hưởng…**
  - `truowngf` → mình ra "truờng" (thiếu ư), đúng phải **trường**.
  - `nguoiwf` → mình ra "nguoiừ" (hỏng hẳn), đúng **người**.
- Nguyên nhân: khi gõ `w` sau `uo`, chỉ horn nguyên âm ngay trước, không lan sang `u`.
  Telex chuẩn: một `w` sau cụm `uo` phải tạo cả `ư` lẫn `ơ`. (Hiện chỉ chạy nếu gõ `uwow`.)
- OpenKey ref: `handleModernMark` rule 3.1 / `handleOldMark` rule 3 xử lý `ươ` như một khối.
- **Đề xuất: FIX ngay** — đây là lỗi nặng nhất, chạm hầu hết văn bản tiếng Việt.

### B2. Chặn thanh không hợp lệ trên coda tắc `-c/-ch/-p/-t` — TRUNG BÌNH (đúng chính tả)
- Hiện tại: `batf` → **bàt** (sai — coda `-t` chỉ cho sắc/nặng, không huyền/hỏi/ngã).
- Đúng: `batf` nên để `f` thành ký tự thường (không áp huyền) → "bat" + phím f.
- Ảnh hưởng: hiếm khi user gõ nhầm kiểu này, nhưng là lỗi tính đúng đắn; cũng giúp
  validator/auto-restore chuẩn hơn.
- **Đề xuất: nên làm** (nhỏ, thêm ràng buộc coda→tone trong đặt dấu).

## Nên cân nhắc 🟡

### C1. `d` cuối từ chuyển `d` đầu thành `đ` (`duongd` → đương)
- Hiện tại: `duongd` → "duongd" (d cuối bị bỏ literal). OpenKey cho `d` cuối quét ngược
  về onset để tạo `đ`.
- Thực tế: đa số user gõ `dd` ngay đầu (`dduong`), nên đây là *tiện lợi* chứ không bắt buộc
  cho Simple Telex. Có thể gây bất ngờ (gõ "add" tiếng Anh…).
- **Đề xuất: hoãn / optional.**

### C2. Modifier `w` gõ sau coda / sau nguyên âm vẫn quét ngược đúng target
- `w` quét ngược qua coda về a/o/u gần nhất (`quatw`→quăt, `moiw`→mơi, `nguoiwf`→người).
- **✅ ĐÃ LÀM (đặt dấu tự do như OpenKey).** Thêm luật cụm `ua`: khi target là `a`
  chưa dấu mà ngay trước là `u` thật (không phải glide `qu`), horn cái `u` → `ưa`
  (vì `uă` không phải nguyên âm hợp lệ). Nhờ vậy `w` gõ **sau** `a` vẫn đúng:
  `nuawx`→nữa (bằng `nuwax`), `muaw`→mưa, `chuaw`→chưa, `buawx`→bữa, `tuawj`→tựa.
  Vẫn giữ: `hoaw`→hoă (trước a là `o`, không phải u), `quatw`→quăt (glide qu).
  Test: `testUaNucleusHornsU`.

### C3. `w` đứng một mình → `ư` sau vài phụ âm nên chặn (`kw`→kw, không phải kư)
- Hiện tại: mọi `w` lẻ → `ư` (kể cả `kw`→kư). OpenKey có bảng `_standaloneWbad`
  ({w,e,y,f,j,k,z}) và `_doubleWAllowed` ({tr,th,ch,nh,ng,kh,gi,ph,gh}).
- Ảnh hưởng: từ tiếng Anh bắt đầu `w`/`kw` bị biến dạng khi gõ (dù auto-restore sẽ khôi phục
  ở cuối từ nếu bật). Liên quan chặt tới chất lượng auto-restore.
- **✅ ĐÃ LÀM.** Thay vì blocklist ad-hoc của OpenKey, dùng nguyên tắc dựa trên bảng
  onset: `w`-lẻ (không có a/o/u để horn/breve) chỉ thành `ư` khi các chữ đã gõ tạo
  thành onset hợp lệ đứng trước `ư` (`onsetsAllowingStandaloneU` trong `TelexEngine`:
  cư/thư/giữ/ngư…). Sau `k/q/gh/ngh/p`, sau `qu`, hay sau nguyên âm khác → giữ `w`
  literal (`kw`→kw). Test: `testStandaloneWBlocking`.
- **Bổ sung: từ bắt đầu bằng `w` = tiếng Anh.** Tiếng Việt gần như không có âm tiết
  mở đầu bằng `w`, nên `w` là **phím đầu** của từ → cả từ để literal, không bỏ dấu
  (`w`→w, `was`→was, `write`→write). Muốn `ư` ở đầu thì gõ `uw`. Short-circuit ngay
  đầu `parse()`, áp cả 2 chế độ. (Trước đây `w` lẻ empty-onset → ư; nay → w.)

### C4. Auto-restore: tránh false-positive trên từ hợp lệ hiếm
- OpenKey từng sửa: `quét`, `quởn` bị auto-restore nhầm; tắt spell-check khi dùng `[ ] { }`.
- Engine mình có validator; cần đảm bảo các từ hiếm nhưng hợp lệ (quởn, uơ-words) không bị
  khôi phục nhầm.
- **✅ ĐÃ LÀM.** (1) Golden test `testAutoRestoreKeepsRareValidWords` khoá các từ hiếm
  hợp lệ (sư, thư, cư, quởn, giữ, ư) — validator trả valid nên auto-restore không đụng.
  (2) Tắt spell-check (auto-restore) khi ký tự ranh giới là ngoặc `[ ] { } ( )` — ngữ
  cảnh code: `TelexInputController.boundary(suppressAutoRestore:)` + `isBracket()`.
  (3) **Auto-restore giờ mặc định BẬT** (`AppState.autoRestore` default true): âm tiết
  không hợp lệ ở ranh giới từ → khôi phục raw keystrokes (`retore`→retỏe→**retore**,
  `user`→ủe→user). Validator `SyllableValidator` rule-based (onset+rime+ràng buộc
  thanh/coda, ~180 rime, không từ điển, O(1), zero RAM). Kiểm định: 28/28 từ Việt thật
  pass; hạn chế cố hữu — English trùng âm tiết Việt hợp lệ (`test`→tét, `list`→lít) KHÔNG
  khôi phục được (cần từ điển/tần suất). Test `testAutoRestoreRevertsInvalidWords`.

### C5. "Bỏ dấu tự do" toggle (OpenKey issue #224 / Minimal Telex)
- OpenKey mặc định "bỏ dấu tự do": modifier (mũ `aa/ee/oo`, breve/horn `w`) đặt dấu
  tự do → quét ngược **qua phụ âm** tới nguyên âm đích (`ama`→âm, `trangw`→trăng).
  Tiện tiếng Việt nhưng nuốt nhiều từ English (`data`→dâta).
- **✅ ĐÃ LÀM.** Thêm cờ `TelexEngine.freeMarking` + setting `AppState.freeMarking`
  (persist), toggle ở menu "Bỏ dấu tự do" và trong Cài đặt. **Mặc định TẮT**
  (= Minimal Telex / nghiêm ngặt) theo yêu cầu: modifier chỉ nhận khi kề nguyên âm
  (được phép quét qua **nguyên âm** offglide — `nguoiwf`→người vẫn chạy — nhưng
  KHÔNG qua phụ âm), nên English/code gõ thẳng: `ama`→ama, `trangw`→trangw, `data`→
  data. Muốn dấu thì gõ sát: `aam`→âm, `trawng`→trăng, `coot`→côt. Bật cờ lên thì
  lại quét-ngược-qua-phụ-âm như OpenKey. Test: `testFreeMarkingToggle`. Phím **thanh**
  (s/f/r/x/j) vẫn áp cuối từ ở cả 2 chế độ (Telex lõi) — English do auto-restore lo.

### C6. Parity audit với OpenKey (đọc toàn bộ Engine.cpp) — G1 & G2
Sau khi kiểm kê toàn bộ engine OpenKey, 2 gap đáng đóng đã làm:
- **G1 — Modern orthography (oà/uý).** `TelexEngine.modernTone` + `AppState.modernOrthography`
  (mặc định TẮT = kiểu cũ), toggle menu + Cài đặt. Chỉ đổi ở nhân **mở** glide-đầu
  oa/oe/uy → hoà/khoẻ/thuý; ua/ưa/ia và mọi trường hợp có coda / ê-ơ-magnet giữ
  nguyên. Test `testModernOrthography`.
- **G2 — Live spell-check (OpenKey `tempDisableKey`).** `TelexEngine.liveSpellCheck` +
  `AppState.liveSpellCheck` (**mặc định BẬT**), toggle menu + Cài đặt. Khi từ đang gõ
  không còn là prefix hợp lệ (`SyllableValidator.isValidPrefix`) → đóng băng biến đổi,
  phím sau literal (google → gôgle rồi dừng, không nuốt tiếp). Ranh giới vẫn auto-restore
  về raw. `isValidPrefix` **fold nguyên âm về gốc** (ô/ơ→o, ư→u, ê→e, ă/â→a) nên trạng
  thái trung gian Telex (uo→ươ, ie→iê, uoi→ươi) luôn được chấp nhận — KHÔNG phá từ Việt
  đang gõ dở. Test `testLiveSpellCheckKeepsValidWords` (corpus 40+ từ) + `…StopsForeignWords`.
- Còn khác OpenKey (chấp nhận): default reach-back của mình là strict (do Minimal Telex),
  OpenKey reach-back qua coda mặc định. G2 giảm mangle nhưng **không** vá bug Chrome
  omnibox duplication (đó là lỗi client insertText, vẫn theo plan Shift+← riêng).
- Chưa làm (thấp): phím ngoặc [→ơ ]→ư, quick-start/end consonant (f→ph, w→qu, g→ng),
  oo-loanword (xoong), macro auto-caps, auto-hoa đầu câu. VNI/VIQR/SimpleTelex/QuickTelex
  = ⚪ ngoài phạm vi.

## Bỏ qua ⚪ (không hợp Simple Telex strict / ngoài phạm vi)

- `oo`→literal cho **xoong, boong, coóc** (từ mượn hiếm): mình luôn `oo`→ô. Chấp nhận.
- Toàn bộ VNI (phím 6/7/8/9), Quick Telex (cc=ch, gg=gi), macro/gõ tắt engine-level,
  auto viết hoa đầu câu, smart switch EN/VI, Dvorak layout, Windows/Linux.
  - **Simple Telex: ĐÃ LÀM** (toggle `simpleTelex`, mặc định BẬT). OpenKey #223: Simple
    Telex khác Telex thường ĐÚNG 2 điểm — (1) `w`-lẻ không thành `ư` (gõ `uw`); (2) ngoặc
    `[ ]` literal. Engine mình vốn đã literal ngoặc, nên chỉ thêm gate cho (1). Test
    `testSimpleTelex`.
- Các bug client/OS (Chrome omnibox, VS Code EditContext, Terminal, RDP, Spotlight…):
  đã nằm ở `checklist.md`, thuộc tầng IMKit chứ không phải engine.

---

## Kết luận & đề xuất thứ tự

1. **B1 (ươ horn propagation)** — làm ngay, đây là lỗi nặng và phổ biến nhất.
2. **B2 (chặn thanh trên coda tắc)** — làm cùng đợt, nhỏ và đúng chính tả.
3. **C3 + C4 (w-lẻ + auto-restore)** — làm khi hoàn thiện auto-restore.
4. **C1, C2** — hoãn, tiện lợi nhỏ, dễ gây bất ngờ.
5. Phần ⚪ — không làm.

Toàn bộ hành vi trên đọc từ mô tả commit/changelog + logic; **không copy code GPL** —
implement lại độc lập. Có thể thêm các vector trên vào `EngineTests.swift` làm golden test.
