#!/usr/bin/env bash
# SessionStart hook — when a session starts anywhere under a locked workspace, inject a
# reminder of the account lock. This matters most for SUB-DIRECTORY sessions, where the
# folder's CLAUDE.md is not loaded and settings.local.json (the GH_TOKEN/MCP-token env pin)
# may not load — so the agent must be told to relaunch from the folder root for full pinning.
#
# The locked account + the locked tree ROOT for this cwd are resolved from folders.json
# ($IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json) via lib/resolve-account.sh
# — nothing here is hardcoded to any account/path. Defensive: never aborts the session.
payload="$(cat)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
cwd_lc="$(printf '%s' "$cwd" | tr '[:upper:]' '[:lower:]')"

# --- resolve the locked account for this cwd from folders.json ---
INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$INIT_DIR/lib/resolve-account.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib/resolve-account.sh"
IFS=$'\t' read -r LOCKED EMAIL NAME < <(resolve_account "$cwd")
[ -z "${LOCKED:-}" ] && exit 0
# The locked tree ROOT (the matched folders.json .path) — used to detect whether this
# session is at the folder root or in a sub-directory.
IDLOCK_CFG="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
ROOT="$(jq -r --arg c "$cwd_lc" '
  .[] | (.path | ascii_downcase) as $p
  | select($c == $p or ($c | startswith($p + "/")))
  | .path' "$IDLOCK_CFG" 2>/dev/null | head -1)"
ROOT_LC="$(printf '%s' "$ROOT" | tr '[:upper:]' '[:lower:]')"

# --- per-session identity pin: make gh / git / MCP work from SUB-DIRECTORIES ---
# Claude Code loads .claude/settings.local.json only from the launch directory, not
# ancestors, so a sub-directory launch never gets the folder-root env pin. Fix it
# here: resolve the locked account's token (same source as the git credential
# helper) and, if available, export it into this session's CLAUDE_ENV_FILE so every
# subsequent Bash command (gh/git) is pinned regardless of where Claude was
# launched. Record the locked ACCOUNT (never the token) in a session pin file the
# guard reads to verify pinning. The pin file is written ONLY after a verified
# env-file append — so "pin present" always implies "really pinned" (fail-closed):
# a resume/compact path with no writable CLAUDE_ENV_FILE writes no pin, and the
# guard then denies rather than letting gh fall back to the active account.
SESS_DIR="${IDENTITY_LOCK_SESSIONS:-${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}/sessions}"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
pinned_ok=0
tok="$(gh auth token --user "$LOCKED" 2>/dev/null)"
if [ -n "$tok" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if ! grep -q 'identity-lock pin OK' "$CLAUDE_ENV_FILE" 2>/dev/null; then
    {
      printf 'export GH_TOKEN=%q\n'                     "$tok"
      printf 'export GITHUB_PERSONAL_ACCESS_TOKEN=%q\n' "$tok"
      printf 'export GIT_AUTHOR_NAME=%q\n'              "$NAME"
      printf 'export GIT_AUTHOR_EMAIL=%q\n'             "$EMAIL"
      printf 'export GIT_COMMITTER_NAME=%q\n'           "$NAME"
      printf 'export GIT_COMMITTER_EMAIL=%q\n'          "$EMAIL"
      printf '# identity-lock pin OK %s\n'              "$LOCKED"   # marker written LAST
    } >> "$CLAUDE_ENV_FILE" 2>/dev/null
  fi
  if [ -n "$sid" ] && grep -q 'identity-lock pin OK' "$CLAUDE_ENV_FILE" 2>/dev/null; then
    if mkdir -p "$SESS_DIR" 2>/dev/null && printf '%s\n' "$LOCKED" > "$SESS_DIR/$sid" 2>/dev/null; then
      chmod 600 "$SESS_DIR/$sid" 2>/dev/null; pinned_ok=1
    fi
    find "$SESS_DIR" -type f -mtime +7 -delete 2>/dev/null   # prune stale pins (best-effort)
  fi
fi

subdir_note=""
if [ "$cwd_lc" != "$ROOT_LC" ]; then
  if [ "$pinned_ok" = 1 ]; then
    subdir_note=" SUB-DIRECTORY launch: gh + GitHub-MCP are session-pinned to $LOCKED here (git push and commit author too), so you can work normally. Do NOT 'cd' into a DIFFERENT locked tree mid-session — that stays blocked; relaunch Claude there instead."
  else
    subdir_note=" This session is a SUB-DIRECTORY launch and the $LOCKED account could not be pinned for gh/MCP (its token was unavailable). git push and commit author still are. Relaunch Claude from $ROOT, or run 'gh auth login --user $LOCKED', for full coverage."
  fi
fi

jq -n --arg a "$LOCKED" --arg n "$subdir_note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("GitHub identity for this workspace is LOCKED to \($a). Every git / gh / GitHub-MCP action MUST be performed as \($a). Identity is pinned by default (settings env GH_TOKEN + GIT_AUTHOR_*, the per-folder git credential helper, and the MCP token) and a deny-only PreToolUse guard blocks attempts to override it. Do NOT switch accounts, set/override GH_TOKEN or GIT_AUTHOR_*, or rewrite git credential config." + $n)
  }
}' 2>/dev/null
