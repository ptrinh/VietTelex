# VietTelex latency baseline — runbook

How to measure where VietTelex spends its per-keystroke time, and how to read
the numbers. Two complementary harnesses live in `scripts/`:

| Harness | Question it answers | What it measures |
| --- | --- | --- |
| **A1 — end-to-end** (`measure-e2e.sh` → `keystroke-photon.swift`) | "What does the user actually feel, per app?" | keystroke → pixel-change latency (the whole OS → IME → app → render → compositor pipeline), VietTelex vs ABC. |
| **A2 — signposts** (`measure-signposts.sh` → `analyze-signposts.py`) | "Inside our code, where do the ms go, per strategy?" | the `imk.handle` / `tap.handle` / `tap.emit` os_signpost intervals, aggregated to p50/p90/p99/max. |

Ground truth to keep in mind while reading any of this:

- The **engine itself is ~0.2 µs** per keystroke (see the keystroke-speed
  regression test). Parsing is not the cost.
- A **window-server / CGEvent round trip is ~milliseconds**. Every ms you see
  is IMKit dispatch, synthetic-event posting, and app+compositor render — not
  Telex logic. That is exactly why we measure the round trips, not the engine.
- So "good" = the VietTelex-minus-ABC **delta** is small (sub-ms to low
  single-digit ms) and does not blow up for a particular strategy. A strategy
  that is visibly slower than its peers is the signal the decision gates act on.

---

## Permissions (grant once, to the terminal you run these from)

System Settings → Privacy & Security →

- **Accessibility** — required by both harnesses to post key events.
- **Screen Recording** — required by A1 (keystroke-photon reads pixels via
  ScreenCaptureKit).
- Instruments (A2) will prompt once for permission to record; accept it.

If a run says it cannot read the screen or post events, it is almost always a
missing permission on *this* terminal app (not the target app).

---

## A1 — per-strategy end-to-end (the felt latency)

```
scripts/measure-e2e.sh [samples]      # default 20 samples/run
```

It walks the app matrix one strategy at a time. For each app it:

1. asks you to focus the field and give the caret's **X Y** screen coords
   (read them with the ⌘⇧4 crosshair, then Esc);
2. prompts you to select **VietTelex** as the input source, runs N samples;
3. prompts you to switch to **ABC** (Apple), runs N samples again;
4. prints the paired median and the **delta = IME cost**.

The app matrix (one row per handling strategy):

| App | Strategy | Notes |
| --- | --- | --- |
| TextEdit | `in-place` | plain NSTextView, the happy path |
| iTerm / Terminal | `tap-backspace` | CGEventTap emits synthetic Backspace+insert |
| Chrome address bar | `selection-replace` | Chromium omnibox path |
| Spotlight | `tap-selection` | selection-based replace |
| Microsoft Excel | `emptyReset` | auto-skipped if Excel is not installed |

### Results table to fill in

Record medians in ms; IME cost = VietTelex − ABC.

| App | Strategy | VietTelex (ms) | ABC (ms) | IME cost (ms) | Date / machine |
| --- | --- | --- | --- | --- | --- |
| TextEdit | in-place | | | | |
| iTerm/Terminal | tap-backspace | | | | |
| Chrome address bar | selection-replace | | | | |
| Spotlight | tap-selection | | | | |
| Excel | emptyReset | | | | |

### A2 baseline measured — 2026-07-20, v1.2.0 (installed release), M-series

Automated run: `stress-typing.swift` at 15 keys/s into a real focused app while
`measure-signposts.sh 25` recorded. Output text verified character-exact
(8 × "đây là tiếng việt rất hay", no lost/mis-toned chars).

| Interval · group | count | p50 | p90 | p99 | max |
| --- | --- | --- | --- | --- | --- |
| TextEdit — imk.handle (in-place) | 280 | 1.93 ms | 2.35 ms | 2.97 ms | 6.01 ms |
| Terminal — imk.handle (tap-defer) | 202 | 13.4 µs | 18.6 µs | 23.2 µs | 31.0 µs |
| Terminal — tap.handle | 273 | 18.2 µs | 84.5 µs | 318.9 µs | 457.1 µs |
| Terminal — tap.emit bs=1 | 56 | 55.4 µs | 78.5 µs | 410.7 µs | 434.0 µs |
| Terminal — tap.emit bs=2 | 7 | 62.5 µs | 74.1 µs | 80.0 µs | 80.7 µs |
| Terminal — tap.emit bs=3 | 8 | 80.7 µs | 110.9 µs | 118.9 µs | 119.8 µs |

Reading:

- **The IMKit in-place path is the expensive one inside our code**: ~1.9 ms
  p50 per keystroke, dominated by the synchronous `insertText`/`selectedRange`
  XPC to the client — not the engine (0.2 µs) and not the tap (≤ 0.1 ms).
- The tap path is cheap end-to-end in-process; `tap.emit` measures only the
  posting call, not the window-server round trip to pixels — A1
  (keystroke-photon) still needed for the felt latency per strategy.
- Strategy labels for `imk.handle`/`tap.handle` show `<private>` on the v1.2.0
  build; the `.public` fix is on main and will label the next release.
  `tap.emit`'s numeric `bs=` labels export fine even on 1.2.0.

Notes on reading A1:

- The sampler prints its own capture resolution (~ms/capture). Treat the
  measurement error as ≈ ±1 capture + 1 screen frame; don't over-interpret
  sub-ms differences between VietTelex and ABC.
- Do several runs; medians are stable, single samples are not.

---

## A2 — signpost analysis (where the ms go inside our code)

```
scripts/measure-signposts.sh [seconds] [output.trace]
```

Records for `seconds` (default 30) while **you type Vietnamese into a focused
field**, then exports the `os-signpost-interval` table and aggregates it. The
intervals only fire on real keystrokes, so *type during the window* — e.g.
`ddaay laf tieengs vieejt raats hay` repeatedly. It attaches to the running
`VietTelex` process automatically (falls back to `--all-processes` if it isn't
running or `VT_ATTACH=0`).

Output is a table per `(interval, message-group)` with count / p50 / p90 / p99 /
max, plus — for `tap.emit` — a breakdown by backspace-burst size
(`bs=0` / `bs=1` / `bs=2+`), which is the dependency B1/B2/B3 care about.

Intervals (from `App/Sources/Instrumentation.swift`):

- `imk.handle` — one IMKit keystroke; message = strategy
  (`in-place`, `in-place-per-op`, `marked`, `tap-defer`, `passthrough`).
- `tap.handle` — one CGEventTap keystroke; message = emit mode
  (`backspace`, `selection`, `emptyReset`).
- `tap.emit` — one synthesized edit burst; message = `bs=N ins=M`.

Env overrides: `VT_ALL=1` (aggregate every subsystem, incl. Apple's
`inputmethodkit-perf`), `VT_SUBSYSTEM=<name>`, `VT_ATTACH=0` (record all
processes).

### Known quirk — messages show as `<private>`

On a stock machine the strategy / `bs=N` labels come through **redacted**:

```
imk.handle · <private>   32   3.99 ms ...
```

`os_signpost` redacts dynamic string interpolations by default, so the
per-strategy and per-burst breakdown collapses into one `<private>` group.
Two ways to reveal them:

1. **Code (preferred, clean):** annotate the `endInterval` messages
   `.public` in `App/Sources/*` — these labels (`in-place`, `bs=2`, …) carry
   **no user text**, so making them public is safe. E.g.
   `endInterval("imk.handle", st, "\(spMode, privacy: .public)")` and likewise
   for `tap.handle` / `tap.emit`. (Left to whoever owns App/Sources.)
2. **System (no rebuild):** `sudo log config --mode 'private_data:on'`, record,
   then `sudo log config --mode 'private_data:off'`.

Until one of those is done, A2 still gives you real **per-interval** timings
(imk.handle vs tap.handle vs tap.emit) — you just can't split by strategy.

### Verified on this machine

- macOS 26.5.2 (build 25F84), `xctrace version 16.0`.
- Schema is `os-signpost-interval`; export XPath:
  `/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]`.
- xctrace quirks worth knowing:
  - Columns are **positional** (the analyzer reads by index; duration text is
    in **nanoseconds**, `fmt` is the human string).
  - xctrace **de-duplicates repeated values** with `id`/`ref` — a value appears
    once with an `id`, later rows carry only `ref="id"`. The analyzer resolves
    these; a naive parser would see empty cells.
  - **Never pipe the export through `head`/`tee`** — SIGPIPE truncates the XML
    and it won't parse. Always export with `--output`.
- An **empty result is not a failure**: a recording in which nobody typed
  Vietnamese legitimately contains zero of our intervals. Both scripts say so
  clearly and exit 0.

---

## Decision gates (already agreed)

These are the actions the baseline is meant to trigger — do **not** implement
them pre-emptively; only if the numbers say so.

- **D1 — AX selection-replace for Chrome / Spotlight.** Switch those apps to an
  Accessibility-based selection-replace path **only if** their A1 rows
  (Chrome address bar `selection-replace`, Spotlight `tap-selection`) stay
  *visibly slow* relative to the in-place/tap rows. If they're already low, skip
  the added complexity.
- **B3 — `postToPid` targeting.** Post synthetic events directly to the target
  pid **only if** `tap.emit` (A2) remains the bottleneck *after* B1/B2 land.
  Watch `tap.emit` p90/p99 and especially the `bs=2+` bucket — if that is where
  the time concentrates, B3 is justified; otherwise it isn't.

---

## Full baseline session — exact commands

```bash
# 0. Make sure VietTelex is running and selected as an input source.
pgrep -x VietTelex || open -a VietTelex        # (or your dev-install build)

# 1. A2 — signpost breakdown. Type Vietnamese into any field during the 30s.
scripts/measure-signposts.sh 30
#    -> prints the per-interval table; artifacts saved under build/traces/.
#    (VT_ALL=1 scripts/measure-signposts.sh 30  to include Apple's subsystems.)

# 2. A1 — per-app felt latency. Follow the prompts; have ⌘⇧4 ready for coords.
scripts/measure-e2e.sh 20
#    -> paired VietTelex-vs-ABC medians + IME-cost delta per app.

# 3. Record the A1 medians in the results table above; compare tap.emit's
#    bs=2+ bucket (A2) and the Chrome/Spotlight rows (A1) against gates D1/B3.
```
