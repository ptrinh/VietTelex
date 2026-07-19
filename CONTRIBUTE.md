# Đóng góp cho VietTelex

Tài liệu kỹ thuật cho người muốn build từ source, sửa lỗi hoặc đóng góp.

## Build từ source

Yêu cầu macOS 14+, Xcode 26 / Swift 6.3, và [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
# Engine + validator: test không cần Xcode GUI
cd TelexCore && swift test

# Sinh Xcode project và build app
xcodegen generate
xcodebuild -project VietTelex.xcodeproj -scheme VietTelex -configuration Release build
```

macOS yêu cầu input method phải **notarized** mới đăng ký được — cài bản tự build
bằng `Scripts/notarize-install.sh` (cần Apple Developer ID; xem chi tiết trong
[`BUILD.md`](BUILD.md)).

## Cấu trúc

```
TelexCore/        Engine Telex + SyllableValidator (Swift package thuần, test độc lập)
App/Sources/      IMKit controller, CGEventTap (tap-mode), AppState, Settings UI
Scripts/          notarize-install, đo latency (keystroke-photon), stress test
```

## Tài liệu

- [`DESIGN.md`](DESIGN.md) — kiến trúc, 5 chiến lược gõ theo app, hot-path rules.
- [`BUILD.md`](BUILD.md) — build, ký, notarize, cài đặt, phân phối MAS.
- [`MACOS_IME_NOTES.md`](MACOS_IME_NOTES.md) — các bài học "xương máu" về đăng ký
  input method trên macOS (notarization, bundle id, marked text, event ordering…).
  Đọc TRƯỚC khi đụng vào signing / Info.plist / cơ chế gõ.
- [`BENCHMARKS.md`](BENCHMARKS.md) — số đo engine theo version + bộ công cụ đo
  end-to-end (os_signpost, keystroke-photon, stress-typing, zero-alloc invariant).
- [`checklist.md`](checklist.md) — ma trận test tương thích theo từng app.

## Test & benchmark

```bash
cd TelexCore
swift test                                          # 37 tests (golden + validator)
swift test -c release --filter Benchmark            # engine latency (ghi vào BENCHMARKS.md)
swift test -c release --filter ZeroAllocation       # invariant zero-alloc hot path
```

Quy ước khi sửa engine:
- Mọi hành vi mới phải có golden test trong `EngineTests.swift`.
- Chạy lại benchmark, ghi thêm dòng vào `BENCHMARKS.md` nếu số thay đổi đáng kể.
- Hot path không được cấp phát heap — test ZeroAllocation sẽ fail nếu vi phạm.
- Bảng luật (onsets/rimes/tone) là data trong `SyllableValidator` — thêm luật mới
  bằng cách sửa bảng, không thêm branch.

## Quy trình release

1. Test tay theo `checklist.md` (VS Code EditContext là blocker).
2. `Scripts/notarize-install.sh` → smoke test trên máy thật.
3. Zip app đã staple, tạo GitHub Release, đính kèm.
