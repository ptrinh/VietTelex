#!/bin/zsh
# After typing Vietnamese in a few apps, run this to see which apps the in-place
# insertText(replacementRange:) path could NOT edit (selectedRange = NSNotFound).
# Those apps need a per-app strategy. Empty output = all tested apps work.
mins="${1:-15}"
echo "Apps with unusable selectedRange in the last ${mins} min:"
log show --last "${mins}m" \
  --predicate 'subsystem == "com.viettelex.inputmethod.telex" AND composedMessage CONTAINS "unusable"' \
  --style compact 2>/dev/null \
  | grep -oE 'app=[^ ]+' | sort -u
echo "— (nothing above = every app you tested works)"
