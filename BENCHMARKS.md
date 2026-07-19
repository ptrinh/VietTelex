# VietTelex — Benchmark theo version

Đo engine latency bằng benchmark test trong `TelexCore` (release build):

```bash
cd TelexCore && swift test -c release --filter Benchmark
```

Ghi lại mỗi version một dòng để so sánh regression qua thời gian.
Budget: **< 50µs p99 / keystroke** (xem DESIGN.md).

## Corpus

Từ 2026-07-19, cả 3 case đo trên cùng một đoạn văn thực tế (đoạn giới thiệu Phil
Trịnh — có từ viết hoa, tên riêng nước ngoài, số, dấu câu; xem `corpusText` trong
`BenchmarkTests.swift`), được sinh tự động thành 3 luồng phím:

1. **Vietnamese (Telex)** — mỗi từ chuyển thành chuỗi phím Telex tạo ra nó
   (sáng → `sangs`, điều → `ddieeuf`, thương → `thuwowng`). Full engine:
   parse + render + diff + validator. Có sanity test round-trip.
2. **English mode (folded)** — cùng các từ đó bỏ dấu (sáng → `sang`): engine vẫn
   re-parse mỗi phím nhưng (gần như) không transform. Chi phí khi gõ tiếng Anh.
3. **Passthrough (non-letters)** — các phím không phải chữ cái trong đoạn văn
   (space, dấu câu, số): engine trả về ngay, không đụng buffer. Sàn overhead.

## Kết quả

| Ngày | Version | Máy | Vietnamese | English mode | Passthrough | Ghi chú |
|---|---|---|---|---|---|---|
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | 0.27 | — | — | corpus cũ (15 từ), baseline đầu tiên |
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | 0.211 | 0.2355 | 0.0076 | corpus cũ, sau đợt zero-alloc scratch buffers |
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | **0.262** | **0.291** | **0.0078** | **corpus mới (đoạn văn thực tế)** — không so trực tiếp với 2 dòng trên |
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | **0.135** | **0.147** | **0.0080** | rules→data: trie phẳng + tone bitmask, incremental parse, SIMD diff, zero-alloc validate |
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | **0.129** | **0.159** | **0.0079** | sau khi thêm os_signpost (app layer) — engine không đổi, dao động run-to-run |

Đơn vị: µs/keystroke, release build.

**Ghi chú tối ưu (2026-07-19):** profiling cho thấy chi phí KHÔNG nằm ở vòng parse
(đã rẻ) mà ở boundary validation (`isValidSyllable` build String + hash
`Set<String>` mỗi từ) và các String tạm. Đợt tối ưu "rules→data" compile toàn bộ
bảng luật (onsets, rimes, luật thanh-coda) thành 2 trie phẳng trên bảng chữ nén
33 class (1 byte/chữ), luật "coda tắc chỉ nhận sắc/nặng" nén thành bitmask 6-bit
trên node kết thúc rime. Kèm: incremental parse (mỗi phím 1 bước fold, không
re-parse cả từ), SIMD8 cho diff/LCP, bitmask phân loại nguyên âm. Kết quả ~2×.

## Đo end-to-end (nơi milliseconds thật sự sống)

Engine chỉ chiếm ~0.1µs trong tổng keystroke latency 30–60ms; các công cụ sau đo
phần còn lại:

- **os_signpost** (`Instrumentation.swift`): mỗi keystroke phát interval
  `imk.handle` / `tap.handle` / `tap.emit` kèm tên chiến lược (in-place / marked /
  tap-defer / selection / emptyReset). Xem bằng Instruments → os_signpost, filter
  subsystem `com.viettelex.inputmethod.telex`. Gần như miễn phí khi không ghi.
- **`Scripts/keystroke-photon.swift <x> <y>`**: đo keystroke→pixel toàn pipeline
  (phương pháp typometer — bơm phím thật, poll 8×8 pixel qua ScreenCaptureKit).
  Chạy 2 lần (VietTelex vs ABC) để tách phần đóng góp thật của IME per app.
- **`Scripts/stress-typing.swift [rate] [repeats]`**: bơm 500 phím/s bắt race /
  corruption — bài test đúng đắn, không phải đo tốc độ (checklist 11.8).
- **Zero-alloc invariant**: `swift test -c release --filter ZeroAllocation` —
  fail nếu hot path bắt đầu cấp phát heap (thay cho `@_noAllocation`, vốn không
  thỏa được với buffer Array CoW trên target macOS 14; xem comment trong test).

**Đọc số liệu:**
- Gõ tiếng Anh tốn ngang (thậm chí nhỉnh hơn) gõ tiếng Việt vì engine re-parse cả
  từ mỗi phím bất kể có dấu hay không — chi phí nằm ở parse, không phải transform.
  Corpus mới có từ dài hơn ("programming"-class: SenPrints, Singapore) nên English
  mode nhỉnh hơn một chút.
- Passthrough gần như miễn phí (~8ns/phím).
- Mọi case đều dưới budget 50µs trên dưới ~200 lần.

## Chống hồi quy tốc độ (regression gate)

`KeystrokePerfTests` (release-only) canh cho **các bản sau không được chậm hơn bản
trước**. Vì runner CI khác phần cứng máy dev, không so µs tuyệt đối mà so **tỷ lệ
chuẩn hoá**: (ns mỗi keystroke tiếng Việt) ÷ (ns mỗi đơn vị workload tham chiếu đo
cùng máy, cùng tiến trình). Tỷ lệ này không phụ thuộc CPU nên so được giữa máy local
và CI.

- **Baseline: 90** (đo 2026-07-20, Apple Silicon, release; giá trị điển hình 87–90).
- **Ngưỡng fail: baseline × 1.40 = 126** — dư cho nhiễu CI, vẫn bắt được hồi quy thật (>1.4×).
- Lấy min của 5 lần đo để loại nhiễu.
- Khi tối ưu engine nhanh hơn thật: chạy test, đọc dòng `KeystrokePerf: ratio=…`,
  hạ `baseline` trong `KeystrokePerfTests.swift` xuống để khoá thành tựu.
- Chạy CI cùng nhóm: `swift test -c release --filter 'Benchmark|ZeroAllocation|KeystrokePerf'`.
