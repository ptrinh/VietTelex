# VietTelex — Benchmark theo version

Đo engine latency bằng benchmark test trong `TelexCore` (release build):

```bash
cd TelexCore && swift test -c release --filter Benchmark
```

Ghi lại mỗi version một dòng để so sánh regression qua thời gian.
Budget: **< 50µs p99 / keystroke** (xem DESIGN.md).

| Ngày | Version | Máy | µs/keystroke (release) | Ghi chú |
|---|---|---|---|---|
| 2026-07-19 | 1.0 | Apple Silicon (darwin 25.5) | **0.27** | baseline đầu tiên |
