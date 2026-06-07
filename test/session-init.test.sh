#!/usr/bin/env bash
# Test harness for identity-session-init.sh (SessionStart reminder).
# The hook injects an additionalContext reminder when cwd is inside a locked
# folder, adds a SUB-DIRECTORY warning when cwd is a sub-dir (not the root), and
# emits nothing outside the tree.
#
# Parameterized: runs entirely against mktemp fixtures + a fixture folders.json.
# No real paths / handles / tokens / emails appear here. This hook never calls
# gh, so no stub is needed.
set -u
INIT="$(cd "$(dirname "$0")/.." && pwd)/identity-session-init.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A="$TMP/folder-a"; B="$TMP/folder-b"; C="$TMP/folder-c"; mkdir -p "$A" "$B" "$C"
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"},
  {"path":"$B","account":"account-b","name":"Account B","email":"b@users.noreply.github.com"},
  {"path":"$C","account":"account-c","name":"Account C","email":"c@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"

# The hook now resolves a token via `gh auth token --user <acct>` to write the
# per-session env-file pin. Stub gh: account-a/-b have tokens, account-c does NOT
# (simulates a locked account that isn't logged in -> no pin must be written).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  "auth token --user account-b") echo "TOKEN_B" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

# Session pin files (the guard reads these) live here in tests.
export IDENTITY_LOCK_SESSIONS="$TMP/sessions"

pass=0; fail=0
run() { jq -n --arg c "$1" '{cwd:$c}' | bash "$INIT" 2>/dev/null; }

# matches: name expr cwd  -> out must satisfy `jq -e <expr>`
matches() { local name="$1" expr="$2" cwd="$3" out
  out="$(run "$cwd")"
  if printf '%s' "$out" | jq -e "$expr" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: out=[%s]\n' "$name" "$out"
  fi
}
# empty: name cwd -> out must be empty
empty() { local name="$1" cwd="$2" out
  out="$(run "$cwd")"
  if [ -z "$out" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL  %s :: out=[%s]\n' "$name" "$out"; fi
}

ctx='.hookSpecificOutput.additionalContext'
matches "root: names account, no subdir warning" \
  "($ctx | test(\"account-a\")) and ($ctx | test(\"SUB-DIRECTORY\") | not)" "$A"
matches "subdir: names account AND subdir warning" \
  "($ctx | test(\"account-a\")) and ($ctx | test(\"SUB-DIRECTORY\"))" "$A/sub/deep"
matches "subdir warning references the locked root path" \
  "$ctx | test(\"$A\")" "$A/sub"
matches "second folder resolves to account-b" \
  "$ctx | test(\"account-b\")" "$B"
matches "hookEventName is SessionStart" \
  '.hookSpecificOutput.hookEventName=="SessionStart"' "$A"
empty "outside the tree -> empty" "$TMP/elsewhere"

# ---------------------------------------------------------------------------
# Per-session env-file pin (lets gh/git work from sub-directories) + the session
# pin file the guard reads. The hook appends exports to $CLAUDE_ENV_FILE and
# records the locked ACCOUNT (no token) in $IDENTITY_LOCK_SESSIONS/<session_id>
# — ONLY when the account's token is available AND the env-file append succeeded.
# ---------------------------------------------------------------------------
runp() { jq -n --arg c "$1" --arg s "$2" '{cwd:$c, session_id:$s}' \
  | CLAUDE_ENV_FILE="$3" bash "$INIT" >/dev/null 2>&1; }
t() { local name="$1"; shift; if "$@"; then pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL  %s\n' "$name"; fi; }

# (1) sub-dir launch in folder-a, token available -> env-file gets the pin exports.
EF1="$TMP/envfile1.sh"; : > "$EF1"
runp "$A/sub/deep" "sid-aaa" "$EF1"
t "env-file exports GH_TOKEN=TOKEN_A"             grep -q 'export GH_TOKEN=.*TOKEN_A' "$EF1"
t "env-file exports GITHUB_PERSONAL_ACCESS_TOKEN" grep -q 'export GITHUB_PERSONAL_ACCESS_TOKEN=.*TOKEN_A' "$EF1"
t "env-file exports GIT_AUTHOR_EMAIL"             grep -q 'export GIT_AUTHOR_EMAIL=' "$EF1"
t "env-file exports GIT_COMMITTER_NAME"           grep -q 'export GIT_COMMITTER_NAME=' "$EF1"
# (2) pin file records the account NAME only — never the token value.
t "pin file written with account name" test "$(cat "$IDENTITY_LOCK_SESSIONS/sid-aaa" 2>/dev/null)" = "account-a"
t "pin file does NOT contain the token" bash -c '! grep -q TOKEN_A "$1"' _ "$IDENTITY_LOCK_SESSIONS/sid-aaa"
# (3) idempotent: re-running on the same env-file does not duplicate the exports.
runp "$A/sub/deep" "sid-aaa" "$EF1"
t "env-file GH_TOKEN export appears exactly once" bash -c '[ "$(grep -c "export GH_TOKEN=" "$1")" = 1 ]' _ "$EF1"
# (4) locked account with NO available token (account-c) -> NO pin, NO export.
EF2="$TMP/envfile2.sh"; : > "$EF2"
runp "$C/repo" "sid-ccc" "$EF2"
t "no env pin when account token unavailable" bash -c '! grep -q "export GH_TOKEN=" "$1"' _ "$EF2"
t "no pin file when account token unavailable" bash -c '[ ! -f "$1" ]' _ "$IDENTITY_LOCK_SESSIONS/sid-ccc"
# (5) no CLAUDE_ENV_FILE (e.g. a resume path) -> no pin file (can't verify the pin).
jq -n --arg c "$A/sub" --arg s "sid-nofile" '{cwd:$c,session_id:$s}' | env -u CLAUDE_ENV_FILE bash "$INIT" >/dev/null 2>&1
t "no pin file when CLAUDE_ENV_FILE is absent" bash -c '[ ! -f "$1" ]' _ "$IDENTITY_LOCK_SESSIONS/sid-nofile"
# (6) the additionalContext for a pinned sub-dir reflects that gh/MCP are pinned here.
EF3="$TMP/envfile3.sh"; : > "$EF3"
ctxout="$(jq -n --arg c "$A/sub" --arg s "sid-ctx" '{cwd:$c,session_id:$s}' | CLAUDE_ENV_FILE="$EF3" bash "$INIT" 2>/dev/null)"
t "pinned sub-dir context still names the account" bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"account-a\")" >/dev/null' _ "$ctxout"

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
