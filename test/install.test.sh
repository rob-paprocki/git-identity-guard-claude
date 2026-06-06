#!/usr/bin/env bash
# Test harness for install.sh — preflight + folder/account prompt loop (Task 4).
#
# Runs entirely against a sandbox HOME + a STUBBED gh on PATH, and drives the
# installer's scripted stdin mode (--non-interactive-from-stdin). No real paths /
# handles / tokens / emails appear here, and the user's real gh keyring / HOME is
# never touched.
#
# This task only covers building ~/.config/identity-lock/folders.json from the
# scripted answers (preflight + prompt loop + idempotent merge by path). The
# four-layer wiring is covered by later tasks.
set -u
INSTALL="$(cd "$(dirname "$0")/.." && pwd)/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"

# Stub gh so preflight (auth status) succeeds and defaults resolve without the
# real keyring. Exit 0 for auth status; echo placeholders for the rest.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  "auth token --user account-b") echo "TOKEN_B" ;;
  "auth status"*)                 exit 0 ;;
  "api user"*)                    echo "account-a" ;;
  *)                              exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/folder-a" "$TMP/folder-b"
CFG="$TMP/.config/identity-lock/folders.json"

pass=0; fail=0
# check <name> <jq-expr> [path]: path (if given) is bound to $p inside the filter,
# so we never interpolate a real path into jq source (exact-match safe).
check() { local name="$1" expr="$2" p="${3:-}"
  if jq -e --arg p "$p" "$expr" "$CFG" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: cfg=[%s]\n' "$name" "$(cat "$CFG" 2>/dev/null)"
  fi
}

# --- one folder via scripted stdin (blank path terminates the loop) ---
printf '%s\n' "$TMP/folder-a" "account-a" "Account A" "a@users.noreply.github.com" "" \
  | bash "$INSTALL" --non-interactive-from-stdin >/dev/null 2>&1

check "folders.json created with the scripted entry" \
  '.[0].path==$p and .[0].account=="account-a" and .[0].name=="Account A" and .[0].email=="a@users.noreply.github.com"' \
  "$TMP/folder-a"
check "exactly one entry" 'length==1'

# --- second run adds a different folder, keeps the first (merge) ---
printf '%s\n' "$TMP/folder-b" "account-b" "Account B" "b@users.noreply.github.com" "" \
  | bash "$INSTALL" --non-interactive-from-stdin >/dev/null 2>&1

check "merge: still has folder-a after second run" \
  'any(.[]; .path==$p)' "$TMP/folder-a"
check "merge: now also has folder-b" \
  'any(.[]; .path==$p and .account=="account-b")' "$TMP/folder-b"
check "merge: two entries total" 'length==2'

# --- re-adding folder-a with changed metadata replaces (idempotent by path) ---
printf '%s\n' "$TMP/folder-a" "account-a" "Account A2" "a2@users.noreply.github.com" "" \
  | bash "$INSTALL" --non-interactive-from-stdin >/dev/null 2>&1

check "idempotent: folder-a still appears exactly once" \
  '[.[] | select(.path==$p)] | length==1' "$TMP/folder-a"
check "idempotent: folder-a metadata updated in place" \
  'any(.[]; .path==$p and .name=="Account A2")' "$TMP/folder-a"
check "idempotent: still two entries total" 'length==2'

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
