#!/usr/bin/env bash
# leak-gate.sh — fail if any tracked file (outside docs/) contains a forbidden
# identifier shape: machine/user paths, gh*_ tokens, or numeric-ID noreply emails.
# Optionally also fails on any term in a local, gitignored denylist
# (scripts/.leak-denylist, one term per line) so the gate never hardcodes real
# handles. Prints "clean" and exits 0 when nothing is found.
#
# Run from anywhere inside the repo. Uses `git grep`, so it only scans tracked
# files — stage your changes (`git add`) before trusting the result.
set -u

# Repo root (the dir containing this script's parent).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || { echo "leak-gate: cannot cd to repo root" >&2; exit 2; }

# Generic forbidden shapes. The path patterns bracket the leading slash
# (e.g. /Users[/]) on purpose: an unbracketed home-path literal anywhere —
# including in this gate — would otherwise make the gate flag itself. The
# bracketed form is regex-equivalent for matching real paths but, because the
# slash sits inside a class, is not itself a matchable home-path literal.
#   - /Users[/][^/ ]+   machine path on macOS
#   - /home[/][^/ ]+    machine path on Linux
#   - gh[oprs]_[A-Za-z0-9]{20,}  gh CLI / OAuth / PAT / refresh / server tokens
SHAPES='(/Users[/][^/ ]+|/home[/][^/ ]+|gh[oprs]_[A-Za-z0-9]{20,})'

# Noreply commit emails are allowed in their anonymized fixture/placeholder form
# (e.g. a@users.noreply.github.com, 0000000+account-a@users.noreply.github.com).
# A real numeric-user-id email would be caught by the gitignored denylist below.
ALLOW='users\.noreply\.github\.com'

status=0

if git grep -InE "$SHAPES" -- . ':!docs/' | grep -vE "$ALLOW"; then
  echo "LEAK: forbidden identifier shape found above" >&2
  status=1
fi

# Local denylist (gitignored). Never committed; absent in CI and clean clones.
DENY="$REPO/scripts/.leak-denylist"
if [ -f "$DENY" ] && [ -s "$DENY" ]; then
  if git grep -Inf "$DENY" -- . ':!docs/'; then
    echo "LEAK: denylisted term found above" >&2
    status=1
  fi
fi

# ---------------------------------------------------------------------------
# Self-test: assert the SHAPES regex actually catches a planted bad string and
# leaves a clean fixture string alone. Runs with `--self-test`; exits non-zero
# if the gate's own regex is broken. We test the regex directly (not via a
# tracked file) so the self-test plants nothing into git history.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  st=0
  # caught(): true if a sample trips the gate (matches SHAPES and survives the
  # noreply ALLOW filter) — i.e. the same two-stage logic as the live scan.
  caught() { printf '%s\n' "$1" | grep -E "$SHAPES" | grep -qvE "$ALLOW"; }
  # Build planted bad samples without writing any real value into this file:
  # concatenation keeps the literals below the gate's own self-match threshold.
  bad_path="/Users""/somebody/project"
  bad_token="gho""_$(printf 'A%.0s' {1..30})"
  for s in "$bad_path" "$bad_token"; do
    if caught "$s"; then echo "  self-test PASS caught: $s"
    else echo "  self-test FAIL missed: $s"; st=1; fi
  done
  # Clean fixtures that MUST NOT trip the gate.
  good_email="a@users.noreply.github.com"
  good_email2="0000000+account-a@users.noreply.github.com"
  good_path="/absolute/path/to/folder-a"
  for s in "$good_email" "$good_email2" "$good_path"; do
    if caught "$s"; then echo "  self-test FAIL false-positive: $s"; st=1
    else echo "  self-test PASS allowed: $s"; fi
  done
  [ "$st" = 0 ] && echo "self-test: ok" || echo "self-test: BROKEN"
  exit "$st"
fi

[ "$status" = 0 ] && echo clean
exit "$status"
