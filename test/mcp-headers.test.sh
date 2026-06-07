#!/usr/bin/env bash
# Test harness for mcp-github-headers.sh — the headersHelper for the user-scoped
# GitHub MCP override. It runs at MCP connect time IN the launch directory, resolves
# the locked account for that cwd, and prints a JSON header object binding the
# Authorization header to that account's token. Outside a locked tree it falls back
# to the ambient GITHUB_PERSONAL_ACCESS_TOKEN (no behavior change).
#
# Runs entirely against mktemp fixtures + a STUBBED gh on PATH. No real paths /
# handles / tokens / emails appear here.
set -u
HELPER="$(cd "$(dirname "$0")/.." && pwd)/mcp-github-headers.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A="$TMP/folder-a"; OUT="$TMP/elsewhere"; mkdir -p "$A/sub" "$OUT"
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

pass=0; fail=0
t() { local name="$1"; shift; if "$@"; then pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL  %s\n' "$name"; fi; }

# (1) inside a locked tree (sub-dir) -> Authorization bound to that account's token.
out="$( cd "$A/sub" && bash "$HELPER" 2>/dev/null )"
t "valid JSON output"               bash -c 'printf "%s" "$1" | jq -e . >/dev/null' _ "$out"
t "Authorization = Bearer TOKEN_A"  bash -c 'printf "%s" "$1" | jq -e ".Authorization==\"Bearer TOKEN_A\"" >/dev/null' _ "$out"

# (2) outside any locked tree -> falls back to the ambient GITHUB_PERSONAL_ACCESS_TOKEN.
out="$( cd "$OUT" && GITHUB_PERSONAL_ACCESS_TOKEN=AMBIENT bash "$HELPER" 2>/dev/null )"
t "fallback uses ambient token"     bash -c 'printf "%s" "$1" | jq -e ".Authorization==\"Bearer AMBIENT\"" >/dev/null' _ "$out"

# (3) the token is emitted ONLY in stdout JSON — nothing leaks to stderr.
errout="$( cd "$A/sub" && bash "$HELPER" 2>&1 >/dev/null )"
t "no token / noise on stderr"      bash -c '[ -z "$1" ]' _ "$errout"

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
