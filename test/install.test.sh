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

# ===========================================================================
# Task 5: the four-layer wiring. After the three install runs above, folder-a
# was wired twice and folder-b once — so every assertion below must hold under
# repeated wiring (idempotency), which is why the global-settings checks count
# entries rather than merely asserting presence.
# ===========================================================================

# jqf <name> <file> <jq-expr> [path->$p]: run `jq -e` against an arbitrary file.
jqf() { local name="$1" file="$2" expr="$3" p="${4:-}"
  if jq -e --arg p "$p" "$expr" "$file" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: file=[%s] body=[%s]\n' "$name" "$file" "$(cat "$file" 2>/dev/null)"
  fi
}
# grepf <name> <file> <ERE>: fixed-by-regex presence check for a plain-text file.
grepf() { local name="$1" file="$2" re="$3"
  if grep -Eq -- "$re" "$file" 2>/dev/null; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: file=[%s] body=[%s]\n' "$name" "$file" "$(cat "$file" 2>/dev/null)"
  fi
}
# countf <name> <file> <ERE> <want>: assert the line-count of matches equals want.
countf() { local name="$1" file="$2" re="$3" want="$4" got
  got="$(grep -Ec -- "$re" "$file" 2>/dev/null || echo 0)"
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: want=%s got=%s file=[%s]\n' "$name" "$want" "$got" "$file"
  fi
}

GC="$TMP/.config/git/account-a.gitconfig"
GITCONFIG="$TMP/.gitconfig"
SL="$TMP/folder-a/.claude/settings.local.json"
GS="$TMP/.claude/settings.json"

# (a) ~/.gitconfig has an includeIf "gitdir/i:<path>/" pointing at folder-a,
#     exactly once despite folder-a being wired twice.
grepf "(a) ~/.gitconfig has includeIf gitdir/i for folder-a" \
  "$GITCONFIG" "includeIf .gitdir/i:$TMP/folder-a/."
countf "(a) includeIf for folder-a appears exactly once (idempotent)" \
  "$GITCONFIG" "gitdir/i:$TMP/folder-a/" 1

# (b) ~/.config/git/account-a.gitconfig sets user.email + a credential helper
#     referencing 'gh auth token --user account-a'.
grepf "(b) per-account gitconfig sets user.email" \
  "$GC" "email = a2?@users\.noreply\.github\.com"
grepf "(b) per-account gitconfig credential helper calls gh auth token --user account-a" \
  "$GC" "gh auth token --user account-a"
# Idempotency: the real helper line must appear exactly once (not duplicated by
# re-wiring). The helper is reset+re-added each run, so exactly one non-empty line.
countf "(b) credential helper appears exactly once (idempotent)" \
  "$GC" "gh auth token --user account-a" 1

# (c) folder-a/.claude/settings.local.json: the Bash|mcp PreToolUse hook +
#     env.GH_TOKEN==TOKEN_A (from the stubbed gh keyring).
jqf "(c) settings.local.json has Bash|mcp PreToolUse matcher" \
  "$SL" '.hooks.PreToolUse[0].matcher | test("Bash") and test("mcp__plugin_github_github__")'
jqf "(c) settings.local.json PreToolUse runs the guard" \
  "$SL" '.hooks.PreToolUse[0].hooks[0].command | test("identity-guard.sh")'
jqf "(c) settings.local.json env.GH_TOKEN == TOKEN_A" \
  "$SL" '.env.GH_TOKEN=="TOKEN_A"'
jqf "(c) settings.local.json env.GITHUB_PERSONAL_ACCESS_TOKEN == TOKEN_A" \
  "$SL" '.env.GITHUB_PERSONAL_ACCESS_TOKEN=="TOKEN_A"'
jqf "(c) settings.local.json env pins GIT_AUTHOR_NAME/EMAIL (latest metadata)" \
  "$SL" '.env.GIT_AUTHOR_NAME=="Account A2" and .env.GIT_AUTHOR_EMAIL=="a2@users.noreply.github.com"'
jqf "(c) settings.local.json env pins GIT_COMMITTER_NAME/EMAIL" \
  "$SL" '.env.GIT_COMMITTER_NAME=="Account A2" and .env.GIT_COMMITTER_EMAIL=="a2@users.noreply.github.com"'

# (d) ~/.claude/settings.json has the SessionStart + PreToolUse wiring, merged
#     idempotently — exactly one of each despite three install runs.
jqf "(d) global settings.json SessionStart runs session-init" \
  "$GS" '.hooks.SessionStart[0].hooks[0].command | test("identity-session-init.sh")'
jqf "(d) global SessionStart has exactly one entry (idempotent merge)" \
  "$GS" '.hooks.SessionStart | length == 1'
jqf "(d) global settings.json PreToolUse has the Bash|mcp guard matcher" \
  "$GS" 'any(.hooks.PreToolUse[]; .matcher | test("Bash") and test("mcp__plugin_github_github__"))'
jqf "(d) global PreToolUse guard matcher appears exactly once (idempotent merge)" \
  "$GS" '[.hooks.PreToolUse[] | select(.hooks[0].command | test("identity-guard.sh"))] | length == 1'

# (e) hooks (+ the resolve-account lib) copied into ~/.claude/hooks/.
[ -x "$TMP/.claude/hooks/identity-guard.sh" ] \
  && { pass=$((pass+1)); echo "  PASS  (e) identity-guard.sh installed + executable"; } \
  || { fail=$((fail+1)); echo "  FAIL  (e) identity-guard.sh missing/non-exec in ~/.claude/hooks/"; }
[ -x "$TMP/.claude/hooks/identity-session-init.sh" ] \
  && { pass=$((pass+1)); echo "  PASS  (e) identity-session-init.sh installed + executable"; } \
  || { fail=$((fail+1)); echo "  FAIL  (e) identity-session-init.sh missing/non-exec in ~/.claude/hooks/"; }
[ -f "$TMP/.claude/hooks/lib/resolve-account.sh" ] \
  && { pass=$((pass+1)); echo "  PASS  (e) lib/resolve-account.sh installed"; } \
  || { fail=$((fail+1)); echo "  FAIL  (e) lib/resolve-account.sh missing in ~/.claude/hooks/lib/"; }

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
