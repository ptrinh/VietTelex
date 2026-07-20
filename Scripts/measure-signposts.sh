#!/usr/bin/env bash
# measure-signposts.sh — record an Instruments trace while you type, then
# aggregate our os_signpost intervals into a per-strategy latency table.
#
# This is the A2 pipeline: it answers "where do the milliseconds go, per
# handling strategy?" using the imk.handle / tap.handle / tap.emit intervals
# already shipping in the app (see App/Sources/Instrumentation.swift).
#
# Usage:
#   scripts/measure-signposts.sh [seconds] [output.trace]
#     seconds       recording window (default 30). TYPE Vietnamese into a
#                   focused text field during this window — the intervals only
#                   fire on real keystrokes.
#     output.trace  where to save the .trace (default: build/traces/<ts>.trace)
#
#   Env overrides:
#     VT_SUBSYSTEM  subsystem to aggregate (default com.viettelex.inputmethod.telex)
#     VT_ALL=1      aggregate ALL subsystems (includes Apple's inputmethodkit)
#     VT_ATTACH=0   fall back to --all-processes instead of --attach VietTelex
#
# Requires: Xcode command-line tools (xctrace) and Python 3. The invoking
# terminal needs permission to record (Instruments will prompt once).
#
# Fails loudly with a clear message at every step — never silently produces
# an empty table without saying why.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANALYZER="$SCRIPT_DIR/analyze-signposts.py"

SECONDS_ARG="${1:-30}"
if ! [[ "$SECONDS_ARG" =~ ^[0-9]+$ ]]; then
  echo "measure-signposts: ERROR: seconds must be an integer, got '$SECONDS_ARG'" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
DEFAULT_TRACE="$REPO_DIR/build/traces/vt-$TS.trace"
TRACE="${2:-$DEFAULT_TRACE}"
mkdir -p "$(dirname "$TRACE")"

SUBSYSTEM="${VT_SUBSYSTEM:-com.viettelex.inputmethod.telex}"

command -v xcrun >/dev/null 2>&1 || { echo "measure-signposts: ERROR: xcrun not found (install Xcode CLT)." >&2; exit 1; }
[[ -f "$ANALYZER" ]] || { echo "measure-signposts: ERROR: analyzer missing: $ANALYZER" >&2; exit 1; }

# --- record ---------------------------------------------------------------
ATTACH_MODE="attach"
if [[ "${VT_ATTACH:-1}" == "1" ]] && pgrep -x VietTelex >/dev/null 2>&1; then
  echo "==> VietTelex is running (pid $(pgrep -x VietTelex | head -1)); attaching."
  RECORD_TARGET=(--attach VietTelex)
else
  ATTACH_MODE="all"
  if [[ "${VT_ATTACH:-1}" == "1" ]]; then
    echo "==> VietTelex not running; recording ALL processes instead."
    echo "    (Start VietTelex and set it as the active input method for real data.)"
  else
    echo "==> VT_ATTACH=0; recording ALL processes."
  fi
  RECORD_TARGET=(--all-processes)
fi

echo "==> Recording ${SECONDS_ARG}s to: $TRACE"
echo "    >>> NOW: focus a text field and TYPE VIETNAMESE (e.g. 'ddaay laf tieengs vieejt') <<<"
if ! xcrun xctrace record \
      --template 'Logging' \
      "${RECORD_TARGET[@]}" \
      --time-limit "${SECONDS_ARG}s" \
      --output "$TRACE" \
      --no-prompt; then
  echo "measure-signposts: ERROR: xctrace record failed." >&2
  if [[ "$ATTACH_MODE" == "attach" ]]; then
    echo "  Try again with VT_ATTACH=0 (records --all-processes), or grant the" >&2
    echo "  terminal permission to record in System Settings > Privacy." >&2
  fi
  exit 1
fi
[[ -d "$TRACE" ]] || { echo "measure-signposts: ERROR: trace not created: $TRACE" >&2; exit 1; }

# --- export ---------------------------------------------------------------
INTERVALS="${TRACE%.trace}.intervals.xml"
echo "==> Exporting os-signpost-interval table -> $INTERVALS"
# NB: export straight to --output; never pipe through head/tee (SIGPIPE truncates the XML).
if ! xcrun xctrace export \
      --input "$TRACE" \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]' \
      --output "$INTERVALS"; then
  echo "measure-signposts: ERROR: xctrace export failed." >&2
  echo "  Inspect available tables with:" >&2
  echo "    xcrun xctrace export --input '$TRACE' --toc" >&2
  exit 1
fi
[[ -s "$INTERVALS" ]] || { echo "measure-signposts: ERROR: export produced empty file: $INTERVALS" >&2; exit 1; }

# --- analyze --------------------------------------------------------------
echo "==> Aggregating"
echo
ANALYZE_ARGS=("$INTERVALS")
if [[ "${VT_ALL:-0}" == "1" ]]; then
  ANALYZE_ARGS+=(--all)
else
  ANALYZE_ARGS+=(--subsystem "$SUBSYSTEM")
fi
ANALYZE_ARGS+=(--csv "${TRACE%.trace}.summary.csv")
python3 "$ANALYZER" "${ANALYZE_ARGS[@]}"

echo
echo "Artifacts:"
echo "  trace:     $TRACE"
echo "  intervals: $INTERVALS"
echo "  csv:       ${TRACE%.trace}.summary.csv"
