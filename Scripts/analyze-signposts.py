#!/usr/bin/env python3
# analyze-signposts.py — aggregate os_signpost intervals exported from an
# Instruments .trace into a per-strategy latency table.
#
# Input: the XML produced by
#   xcrun xctrace export --input <trace> \
#     --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]'
# (measure-signposts.sh does the record+export and pipes the file here.)
#
# What it does:
#   - Parses each <row> POSITIONALLY (the schema fixes the column order:
#     0 start, 1 duration, 3 name, 5 subsystem, 11 start-msg, 12 end-msg).
#   - Resolves xctrace's id/ref de-duplication: a value appears once with an
#     `id`, and later rows reference it with `ref`. We build one id->value map
#     over the whole document, then resolve every cell (this is the #1 thing a
#     naive parser gets wrong — refs look like empty cells otherwise).
#   - Keeps only our subsystem (default com.viettelex.inputmethod.telex) so
#     Apple's own inputmethodkit-perf signposts don't pollute the numbers.
#   - Groups by (interval name, message-group) and reports count/p50/p90/p99/max.
#   - For tap.emit, ALSO buckets by backspace count (bs=0 / bs=1 / bs=2+),
#     the burst-size dependency B1/B2/B3 care about.
#
# Usage:
#   analyze-signposts.py <intervals.xml> [--subsystem <name>|--all] [--csv out.csv]
#
# Exits non-zero with a clear message if the file is missing/unparseable.
# An EMPTY result (no matching intervals) is NOT an error — it prints a clear
# "no intervals" notice and exits 0, because a valid recording in which nobody
# typed legitimately contains zero of our intervals.

import sys
import os
import re
import xml.etree.ElementTree as ET

OUR_SUBSYSTEM = "com.viettelex.inputmethod.telex"

# Positional column indices within a <row> (fixed by the os-signpost-interval schema).
COL_DURATION = 1      # engineering-type "duration", text is nanoseconds
COL_NAME = 3          # engineering-type "string" -> signpost name
COL_SUBSYSTEM = 5     # engineering-type "subsystem"
COL_START_MSG = 11    # os-log-metadata (beginInterval message)
COL_END_MSG = 12      # os-log-metadata (endInterval message) -> our strategy / bs=N


def die(msg, code=1):
    print(f"analyze-signposts: ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def build_id_map(root):
    """Map every id -> its fmt (fall back to text) across the whole doc, so
    `ref` cells can be resolved back to their value."""
    idmap = {}
    for el in root.iter():
        i = el.get("id")
        if i is not None:
            idmap[i] = el.get("fmt") if el.get("fmt") is not None else (el.text or "")
    return idmap


def cell(el, idmap):
    """Resolve one row cell to its display value, following ref de-dup."""
    ref = el.get("ref")
    if ref is not None:
        return idmap.get(ref, "")
    if el.get("fmt") is not None:
        return el.get("fmt")
    return el.text or ""


def cell_ns(el, idmap):
    """Resolve a duration cell to integer nanoseconds (text is ns; ref points
    at the element whose text is ns)."""
    ref = el.get("ref")
    if ref is not None:
        # Need the text (ns), not fmt ("1.42 ms"); look it up by id.
        return _ns_by_id.get(ref, 0)
    try:
        return int((el.text or "0").strip())
    except ValueError:
        return 0


_ns_by_id = {}


def build_ns_map(root):
    for el in root.iter():
        i = el.get("id")
        if i is not None and el.text is not None:
            t = el.text.strip()
            if t.isdigit():
                _ns_by_id[i] = int(t)


def msg_group(name, end_msg):
    """Collapse a raw end message into a stable group label.
    - imk.handle / tap.handle: the message IS the strategy/mode -> use as-is.
    - tap.emit: message is 'bs=N ins=M' -> group is the whole thing here; the
      backspace bucketing is done separately below.
    """
    m = (end_msg or "").strip()
    if not m or m == "IGNORED":
        return "(none)"
    return m


def bs_bucket(end_msg):
    """For tap.emit 'bs=N ins=M' -> 'bs=0' / 'bs=1' / 'bs=2+'."""
    mo = re.search(r"bs=(\d+)", end_msg or "")
    if not mo:
        return None
    n = int(mo.group(1))
    return "bs=0" if n == 0 else "bs=1" if n == 1 else "bs=2+"


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = k - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def fmt_us(ns):
    us = ns / 1000.0
    if us >= 1000:
        return f"{us/1000:.2f} ms"
    return f"{us:.2f} µs"


def summarize(label, vals):
    s = sorted(vals)
    return {
        "label": label,
        "count": len(s),
        "p50": pct(s, 50),
        "p90": pct(s, 90),
        "p99": pct(s, 99),
        "max": s[-1] if s else 0,
    }


def main():
    args = sys.argv[1:]
    if not args:
        die("usage: analyze-signposts.py <intervals.xml> [--subsystem <name>|--all] [--csv out.csv]")
    path = args[0]
    subsystem = OUR_SUBSYSTEM
    want_all = False
    csv_out = None
    i = 1
    while i < len(args):
        if args[i] == "--all":
            want_all = True
        elif args[i] == "--subsystem" and i + 1 < len(args):
            subsystem = args[i + 1]
            i += 1
        elif args[i] == "--csv" and i + 1 < len(args):
            csv_out = args[i + 1]
            i += 1
        else:
            die(f"unknown argument: {args[i]}")
        i += 1

    if not os.path.exists(path):
        die(f"intervals file not found: {path}")
    if os.path.getsize(path) == 0:
        die(f"intervals file is empty (0 bytes): {path} — did the export step fail?")

    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        die(f"could not parse XML ({e}). If this file came from a `| head`/`| tee` "
            f"pipeline it may be truncated (SIGPIPE) — export with xctrace --output instead.")
    root = tree.getroot()
    build_ns_map(root)
    idmap = build_id_map(root)

    rows = root.findall(".//row")
    # Per (name, group) -> list of ns; and tap.emit bs buckets.
    groups = {}
    emit_bs = {}
    total_kept = 0
    seen_subsystems = set()

    for row in rows:
        kids = list(row)
        if len(kids) <= COL_END_MSG:
            continue
        name = cell(kids[COL_NAME], idmap).strip()
        sub = cell(kids[COL_SUBSYSTEM], idmap).strip()
        seen_subsystems.add(sub)
        if not want_all and sub != subsystem:
            continue
        ns = cell_ns(kids[COL_DURATION], idmap)
        end_msg = cell(kids[COL_END_MSG], idmap).strip()
        total_kept += 1

        g = msg_group(name, end_msg)
        groups.setdefault((name, g), []).append(ns)

        if name == "tap.emit":
            b = bs_bucket(end_msg)
            if b:
                emit_bs.setdefault(b, []).append(ns)

    # ---- Report ----
    scope = "ALL subsystems" if want_all else subsystem
    print(f"# signpost analysis  ({os.path.basename(path)})")
    print(f"# scope: {scope}")
    print(f"# rows in table: {len(rows)}   matched intervals: {total_kept}")
    print()

    if total_kept == 0:
        print("No matching intervals in this trace.")
        print("This is EXPECTED for a recording in which no Vietnamese text was typed")
        print("(our imk.handle/tap.handle/tap.emit intervals fire only on keystrokes).")
        print()
        others = sorted(s for s in seen_subsystems if s)
        if others:
            print("Subsystems that WERE present (for sanity):")
            for s in others:
                print(f"  - {s}")
            print()
            print("Re-run with --all to inspect every subsystem, or type Vietnamese")
            print("into a focused field during the recording window to capture ours.")
        # Empty is not a failure: the pipeline worked, there was just nothing to aggregate.
        return

    header = f"{'interval / group':<34}{'count':>7}{'p50':>12}{'p90':>12}{'p99':>12}{'max':>12}"
    print(header)
    print("-" * len(header))
    for (name, g) in sorted(groups.keys()):
        s = summarize(f"{name} · {g}", groups[(name, g)])
        print(f"{s['label']:<34}{s['count']:>7}{fmt_us(s['p50']):>12}"
              f"{fmt_us(s['p90']):>12}{fmt_us(s['p99']):>12}{fmt_us(s['max']):>12}")

    # Warn when the strategy/bs labels are redacted (the common stock-machine case).
    private_groups = [g for (n, g) in groups.keys() if g == "<private>"]
    if private_groups:
        print()
        print("NOTE: end messages show as '<private>' — os_signpost redacts dynamic string")
        print("      interpolations by default, so per-strategy and bs=N breakdown is hidden.")
        print("      Fix (either one):")
        print("        1. code: annotate the endInterval message .public, e.g.")
        print("           endInterval(\"imk.handle\", st, \"\\(spMode, privacy: .public)\")")
        print("           (strategy/bs labels carry no user text — safe to make public).")
        print("        2. system: enable signpost private data, then re-record:")
        print("           sudo log config --mode 'private_data:on'   (revert with :off)")

    if emit_bs:
        print()
        print("tap.emit by backspace-burst size (the B1/B2/B3 dependency):")
        print("-" * len(header))
        for b in ("bs=0", "bs=1", "bs=2+"):
            if b in emit_bs:
                s = summarize(f"tap.emit · {b}", emit_bs[b])
                print(f"{s['label']:<34}{s['count']:>7}{fmt_us(s['p50']):>12}"
                      f"{fmt_us(s['p90']):>12}{fmt_us(s['p99']):>12}{fmt_us(s['max']):>12}")

    if csv_out:
        with open(csv_out, "w") as f:
            f.write("interval,group,count,p50_ns,p90_ns,p99_ns,max_ns\n")
            for (name, g) in sorted(groups.keys()):
                s = summarize("", groups[(name, g)])
                f.write(f"{name},{g},{s['count']},{s['p50']:.0f},{s['p90']:.0f},{s['p99']:.0f},{s['max']:.0f}\n")
            for b in ("bs=0", "bs=1", "bs=2+"):
                if b in emit_bs:
                    s = summarize("", emit_bs[b])
                    f.write(f"tap.emit,{b},{s['count']},{s['p50']:.0f},{s['p90']:.0f},{s['p99']:.0f},{s['max']:.0f}\n")
        print(f"\nCSV written: {csv_out}")


if __name__ == "__main__":
    main()
