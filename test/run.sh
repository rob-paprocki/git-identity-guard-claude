#!/usr/bin/env bash
# run.sh — run every test suite; exit non-zero if any suite fails.
# Used by CI (.github/workflows/test.yml) and the pre-commit hook.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITES=(
  "resolve-account.test.sh"
  "identity-guard.test.sh"
  "session-init.test.sh"
  "install.test.sh"
)

rc=0
failed=()
for s in "${SUITES[@]}"; do
  echo "=== $s ==="
  if bash "$HERE/$s"; then
    :
  else
    rc=1
    failed+=("$s")
  fi
  echo
done

if [ "$rc" = 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "FAILED SUITES: ${failed[*]}"
fi
exit "$rc"
