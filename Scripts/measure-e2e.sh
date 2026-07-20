#!/usr/bin/env bash
# measure-e2e.sh — paired end-to-end (keystroke->pixel) latency runbook.
#
# This is the A1 orchestrator. It walks you through the app matrix one strategy
# at a time and, for each, runs keystroke-photon.swift twice:
#   (1) with VietTelex active   -> full pipeline incl. our IME
#   (2) with ABC (Apple) active -> same pipeline WITHOUT our IME
# The difference (VietTelex median - ABC median) is the IME's real cost for that
# app/strategy. The human does the focusing, input-source switching, and reads
# the on-screen caret coordinates — this script just sequences and tabulates.
#
# Usage:
#   scripts/measure-e2e.sh [samples]      (default 20 samples per run)
#
# Per app you'll be asked for the X Y screen coords of the caret (where the NEXT
# character will appear). Read them with the ⌘⇧4 crosshair (Esc to cancel), or
# any pixel ruler. You then focus the field during each 3s countdown.
#
# Requires: Accessibility + Screen Recording permission for THIS terminal
# (keystroke-photon.swift posts keys and reads pixels). Swift toolchain.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTON="$SCRIPT_DIR/keystroke-photon.swift"
SAMPLES="${1:-20}"

[[ -f "$PHOTON" ]] || { echo "measure-e2e: ERROR: keystroke-photon.swift not found at $PHOTON" >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "measure-e2e: ERROR: swift not found." >&2; exit 1; }

# App matrix: label | strategy | focusing instructions.
# (Excel row is skipped automatically if Microsoft Excel is not installed.)
MATRIX=(
  "TextEdit|in-place|Open TextEdit, new document, click into the body."
  "iTerm/Terminal (tap mode)|tap-backspace|Open iTerm or Terminal, click at the shell prompt."
  "Chrome address bar|selection-replace|Open Chrome, click the address bar, clear it."
  "Spotlight|tap-selection|Press Cmd-Space to open Spotlight, click the search field."
  "Excel|emptyReset|Open Microsoft Excel, click an empty cell and start editing (press = then delete, or double-click)."
)

echo "==================================================================="
echo " VietTelex end-to-end latency — paired runbook ($SAMPLES samples/run)"
echo "==================================================================="
echo "For EACH app you will: focus the field, give caret X Y, run VietTelex,"
echo "then switch to ABC and run again. Ctrl-C to abort at any prompt."
echo

# Parse the 'median=NN.N' token from keystroke-photon's summary line.
parse_median() {  # <logfile>
  grep -oE 'median=[0-9]+(\.[0-9]+)?' "$1" | tail -1 | cut -d= -f2
}

run_photon() {  # <x> <y> <logfile>  -> echoes median (ms) or empty
  local x="$1" y="$2" log="$3"
  # Show live output to the user AND capture it for parsing.
  swift "$PHOTON" "$x" "$y" "$SAMPLES" 2>&1 | tee "$log"
  parse_median "$log"
}

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
declare -a RESULTS=()

for entry in "${MATRIX[@]}"; do
  IFS='|' read -r label strategy instr <<<"$entry"

  if [[ "$label" == "Excel" ]] && [[ ! -d "/Applications/Microsoft Excel.app" ]]; then
    echo ">>> Skipping Excel ($strategy) — Microsoft Excel not installed."
    echo
    RESULTS+=("$label|$strategy|-|-|- (skipped: not installed)")
    continue
  fi

  echo "-------------------------------------------------------------------"
  echo ">>> $label   [strategy: $strategy]"
  echo "    $instr"
  echo "-------------------------------------------------------------------"
  read -r -p "Measure this app? [Y/n/s=skip] " ans
  case "${ans:-y}" in
    n|N) echo "Aborting."; exit 0 ;;
    s|S) RESULTS+=("$label|$strategy|-|-|- (skipped by user)"); echo; continue ;;
  esac

  read -r -p "  Caret X coordinate: " cx
  read -r -p "  Caret Y coordinate: " cy
  if ! [[ "$cx" =~ ^[0-9]+([.][0-9]+)?$ && "$cy" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "  Bad coordinates; skipping $label."
    RESULTS+=("$label|$strategy|-|-|- (bad coords)")
    echo; continue
  fi

  echo
  echo "  [1/2] Switch input source to *VietTelex* now, then focus the field."
  read -r -p "  Ready? press Enter to start the VietTelex run… " _
  vt_med="$(run_photon "$cx" "$cy" "$TMPDIR_RUN/vt.log")"

  echo
  echo "  [2/2] Switch input source to *ABC* (Apple) now, then focus the same field."
  read -r -p "  Ready? press Enter to start the ABC run… " _
  abc_med="$(run_photon "$cx" "$cy" "$TMPDIR_RUN/abc.log")"

  if [[ -n "$vt_med" && -n "$abc_med" ]]; then
    delta="$(awk -v a="$vt_med" -v b="$abc_med" 'BEGIN{printf "%.1f", a-b}')"
  else
    delta="?"
  fi
  RESULTS+=("$label|$strategy|${vt_med:-?}|${abc_med:-?}|${delta}")
  echo
  echo "  => $label: VietTelex=${vt_med:-?} ms  ABC=${abc_med:-?} ms  IME cost=${delta} ms"
  echo
done

echo
echo "==================================================================="
echo " PAIRED RESULTS  (median ms; IME cost = VietTelex - ABC)"
echo "==================================================================="
printf "%-26s %-16s %10s %10s %10s\n" "App" "Strategy" "VietTelex" "ABC" "IME cost"
printf "%-26s %-16s %10s %10s %10s\n" "---" "--------" "---------" "---" "--------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r label strategy vt abc delta <<<"$r"
  printf "%-26s %-16s %10s %10s %10s\n" "$label" "$strategy" "$vt" "$abc" "$delta"
done
echo
echo "Read: a small positive IME cost (sub-ms to low-ms) is expected — the"
echo "engine itself is ~0.2µs, so anything you see is IMKit/CGEvent round trips,"
echo "not parsing. A large or strategy-specific cost is what the decision gates"
echo "(D1, B3) in docs/latency-baseline.md act on."
