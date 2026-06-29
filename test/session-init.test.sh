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
A="$TMP/folder-a"; B="$TMP/folder-b"; C="$TMP/folder-c"; D="$TMP/folder-d"; mkdir -p "$A" "$B" "$C" "$D"
# account-a-extra is a PREFIX-superstring of account-a (login "account-a" is a substring of
# "account-a-extra") — used to prove the markers are matched whole-line, not as substrings.
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"},
  {"path":"$B","account":"account-b","name":"Account B","email":"b@users.noreply.github.com"},
  {"path":"$C","account":"account-c","name":"Account C","email":"c@users.noreply.github.com"},
  {"path":"$D","account":"account-a-extra","name":"Account A Extra","email":"ax@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"

# The hook now resolves a token via `gh auth token --user <acct>` to write the
# per-session env-file pin. Stub gh: account-a/-b/-a-extra have tokens, account-c does NOT
# (simulates a locked account that isn't logged in -> no pin must be written).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  "auth token --user account-b") echo "TOKEN_B" ;;
  "auth token --user account-a-extra") echo "TOKEN_AX" ;;
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
# (4b) PRIORITY-PATCH regression (2026-06): a no-token sub-dir launch (account-c) MUST STILL
# pin the commit author/committer — that pin is token-INDEPENDENT. Before the fix the author
# exports lived inside the token gate, so this path inherited the launching shell's ambient
# GIT_AUTHOR_* and authored commits under a FOREIGN identity while push still worked. ($EF2
# was written by the account-c run above.)
t "no-token launch STILL pins author email"           grep -q '^export GIT_AUTHOR_EMAIL=' "$EF2"
t "no-token launch STILL pins author name"            grep -q '^export GIT_AUTHOR_NAME='  "$EF2"
t "no-token launch STILL pins committer name"         grep -q '^export GIT_COMMITTER_NAME=' "$EF2"
t "no-token launch STILL pins committer email"        grep -q '^export GIT_COMMITTER_EMAIL=' "$EF2"
t "no-token launch clears ambient author first"       grep -q '^unset GIT_AUTHOR_NAME ' "$EF2"
t "no-token author pin uses the LOCKED account email" grep -q 'export GIT_AUTHOR_EMAIL=.*c@users[.]noreply' "$EF2"
# idempotent: re-running the no-token launch does not duplicate the author exports.
runp "$C/repo" "sid-ccc" "$EF2"
t "no-token author email pinned exactly once" bash -c '[ "$(grep -c "^export GIT_AUTHOR_EMAIL=" "$1")" = 1 ]' _ "$EF2"
# the sub-dir note for this path must say commit author IS pinned, but crucially must NOT claim
# push is pinned (the old note lumped author+push together, yet push needs the same token).
ctxC="$(jq -n --arg c "$C/repo" --arg s "sid-ccc2" '{cwd:$c,session_id:$s}' | CLAUDE_ENV_FILE="$TMP/envfileC.sh" bash "$INIT" 2>/dev/null)"
t "no-token note: commit author IS pinned to the account" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"commit author is pinned to account-c\")" >/dev/null' _ "$ctxC"
t "no-token note: git push is NOT claimed pinned" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"git push are NOT pinned\")" >/dev/null' _ "$ctxC"

# (4c) Two INDEPENDENT markers (guards the split-marker regression): an env-file that already
# carries ONLY the author marker (a prior no-token fire) must NOT suppress the gh token pin on
# a later token-available fire, and must not re-run the author block.
EF4="$TMP/envfile4.sh"
printf '# identity-lock author pin OK account-a\n' > "$EF4"   # simulate a prior author-only pin
runp "$A/sub/deep" "sid-trans" "$EF4"
t "author marker present does NOT suppress the gh token pin" grep -q 'export GH_TOKEN=.*TOKEN_A' "$EF4"
t "author block idempotent (marker not duplicated)" bash -c '[ "$(grep -c "identity-lock author pin OK" "$1")" = 1 ]' _ "$EF4"

# (4d) Cross-account re-fire on a REUSED env-file: a resume that resolves a DIFFERENT locked
# account must RE-PIN author + token + pin file to the NEW account (account-scoped markers),
# never leave the previous account's identity in place. Fails on account-agnostic markers.
EF5="$TMP/envfile5.sh"; : > "$EF5"
runp "$A/sub" "sid-xacct" "$EF5"     # first fire: pin account-a
runp "$B/sub" "sid-xacct" "$EF5"     # re-fire resolves account-b on the SAME env-file
t "x-account: env-file re-pins author to account-b" grep -q 'export GIT_AUTHOR_EMAIL=.*b@users' "$EF5"
t "x-account: env-file re-pins token to TOKEN_B"     grep -q 'export GH_TOKEN=.*TOKEN_B' "$EF5"
t "x-account: pin file now reads account-b"          bash -c '[ "$(cat "$1" 2>/dev/null)" = account-b ]' _ "$IDENTITY_LOCK_SESSIONS/sid-xacct"
# sourced top-to-bottom, the LAST (account-b) writes must win for BOTH author and token:
t "x-account: sourced env-file authors as account-b" \
  bash -c 'e="$(. "$1" >/dev/null 2>&1; printf "%s" "$GIT_AUTHOR_EMAIL")"; case "$e" in b@*) exit 0;; *) exit 1;; esac' _ "$EF5"
t "x-account: sourced env-file token is account-b" \
  bash -c 'k="$(. "$1" >/dev/null 2>&1; printf "%s" "$GH_TOKEN")"; [ "$k" = TOKEN_B ]' _ "$EF5"

# (4e) PREFIX-COLLISION regression: account-a-extra's login is a superstring of account-a's, so
# a SUBSTRING marker match (grep -qF) would let account-a false-match account-a-extra's marker
# line. Pin the SUPERSTRING first, then re-fire the PREFIX account on the same env-file: the
# prefix account must FULLY re-pin (token + author + pin file), not inherit the superstring's
# identity. Whole-line (grep -qxF) markers make this pass; substring markers fail it.
EF6="$TMP/envfile6.sh"; : > "$EF6"
runp "$D/sub" "sid-prefix" "$EF6"    # superstring account-a-extra pins first
runp "$A/sub" "sid-prefix" "$EF6"    # prefix account-a re-fires on the SAME env-file
t "prefix: sourced token is account-a's (not account-a-extra's)" \
  bash -c 'k="$(. "$1" >/dev/null 2>&1; printf "%s" "$GH_TOKEN")"; [ "$k" = TOKEN_A ]' _ "$EF6"
t "prefix: sourced author is account-a (not account-a-extra)" \
  bash -c 'e="$(. "$1" >/dev/null 2>&1; printf "%s" "$GIT_AUTHOR_EMAIL")"; case "$e" in a@*) exit 0;; *) exit 1;; esac' _ "$EF6"
t "prefix: pin file reads account-a (not account-a-extra)" \
  bash -c '[ "$(cat "$1" 2>/dev/null)" = account-a ]' _ "$IDENTITY_LOCK_SESSIONS/sid-prefix"

# (5) no CLAUDE_ENV_FILE (e.g. a resume path) -> no pin file (can't verify the pin).
jq -n --arg c "$A/sub" --arg s "sid-nofile" '{cwd:$c,session_id:$s}' | env -u CLAUDE_ENV_FILE bash "$INIT" >/dev/null 2>&1
t "no pin file when CLAUDE_ENV_FILE is absent" bash -c '[ ! -f "$1" ]' _ "$IDENTITY_LOCK_SESSIONS/sid-nofile"
# (5b) ...and with no writable env-file the author pin cannot be applied, so the sub-dir note
# must HONESTLY warn that commit author is NOT guaranteed (not claim it is still pinned).
ctxNF="$(jq -n --arg c "$A/sub" --arg s "sid-nofile2" '{cwd:$c,session_id:$s}' | env -u CLAUDE_ENV_FILE bash "$INIT" 2>/dev/null)"
t "no-env-file sub-dir note warns commit author NOT guaranteed" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"NOT guaranteed\")" >/dev/null' _ "$ctxNF"
# (5c) a WRITABLE-path-but-UNWRITABLE CLAUDE_ENV_FILE: the append fails silently, nothing is
# cleared, so any inherited ambient author is STILL live. The note must say so (do NOT commit) —
# NOT falsely claim "ambient cleared / falls back to gitconfig".
EFRO="$TMP/envfile-ro.sh"; : > "$EFRO"; chmod 000 "$EFRO"
ctxRO="$(jq -n --arg c "$A/sub" --arg s "sid-ro" '{cwd:$c,session_id:$s}' | CLAUDE_ENV_FILE="$EFRO" bash "$INIT" 2>/dev/null)"
chmod 644 "$EFRO"
t "unwritable env-file: nothing was written" bash -c '[ ! -s "$1" ]' _ "$EFRO"
t "unwritable env-file note warns ambient STILL ACTIVE" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"STILL ACTIVE\")" >/dev/null' _ "$ctxRO"
# (6) the additionalContext for a pinned sub-dir reflects that gh/MCP/push + author are pinned.
EF3="$TMP/envfile3.sh"; : > "$EF3"
ctxout="$(jq -n --arg c "$A/sub" --arg s "sid-ctx" '{cwd:$c,session_id:$s}' | CLAUDE_ENV_FILE="$EF3" bash "$INIT" 2>/dev/null)"
t "pinned sub-dir context still names the account" bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"account-a\")" >/dev/null' _ "$ctxout"
t "pinned sub-dir note claims git push pinned to the account" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"git push are session-pinned to account-a\")" >/dev/null' _ "$ctxout"
t "pinned sub-dir note claims commit author pinned to the account" \
  bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"commit author is pinned to account-a\")" >/dev/null' _ "$ctxout"

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
