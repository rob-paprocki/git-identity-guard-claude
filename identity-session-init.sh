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
author_pinned=0
ambient_cleared=0
tok="$(gh auth token --user "$LOCKED" 2>/dev/null)"

# Markers are matched WHOLE-LINE (grep -qxF) against the exact written marker, NOT as a
# substring: a substring match (grep -qF "...OK $LOCKED") would let a prefix-named account
# (e.g. "acme" vs "acme-bot", "rob" vs "rob-paprocki") false-match a longer account's marker
# LINE on a reused env-file and silently skip its own re-pin. -x requires the full line.
auth_marker="# identity-lock author pin OK $LOCKED"
tok_marker="# identity-lock pin OK $LOCKED"

# --- (a) commit author/committer pin — TOKEN-INDEPENDENT (priority patch, 2026-06) ---
# Pin the locked author/committer into this session's env-file ALWAYS, whether or not the
# locked account's gh token is available: it needs only the already-resolved $NAME/$EMAIL,
# not the token. This is the pin that stops a SUB-DIRECTORY / worktree launch from silently
# inheriting the launching shell's ambient GIT_AUTHOR_*/GIT_COMMITTER_* — env beats the
# per-folder gitconfig [user] pin, so an ambient identity would otherwise author commits
# under a FOREIGN account while push (credential helper) still succeeds. These exports used
# to live inside the token gate below, so a no-token launch skipped them and leaked. The
# idempotency marker is ACCOUNT-SCOPED (includes $LOCKED) and independent of the token
# marker: a re-fire resolving a DIFFERENT account re-pins (appends fresh exports that win
# when the env-file is sourced) rather than leaving the previous account's author in place.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if ! grep -qxF "$auth_marker" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    {
      # Clear any inherited ambient author/committer first, so even a name/email-less
      # (misconfigured) lock cannot leave a foreign identity in place.
      printf 'unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL\n'
      if [ -n "$NAME" ] && [ -n "$EMAIL" ]; then
        printf 'export GIT_AUTHOR_NAME=%q\n'     "$NAME"
        printf 'export GIT_AUTHOR_EMAIL=%q\n'    "$EMAIL"
        printf 'export GIT_COMMITTER_NAME=%q\n'  "$NAME"
        printf 'export GIT_COMMITTER_EMAIL=%q\n' "$EMAIL"
      fi
      printf '%s\n' "$auth_marker"   # marker written LAST
    } >> "$CLAUDE_ENV_FILE" 2>/dev/null
  fi
  # The marker is present ONLY if the author block was durably written this session (a failed
  # append leaves no marker). So: marker present => ambient was cleared; marker present AND
  # name/email set => the locked author identity is actually exported.
  if grep -qxF "$auth_marker" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    ambient_cleared=1
    [ -n "$NAME" ] && [ -n "$EMAIL" ] && author_pinned=1
  fi
fi

# --- (b) gh / GitHub-MCP token pin — TOKEN-DEPENDENT ---
# Only when the locked account's token is available. Backs the gh/MCP "pinned_ok" state and
# the session pin file the guard reads as proof of pinning. Marker AND pin-file gate are
# ACCOUNT-SCOPED so a different-account re-fire re-pins the token and rewrites the pin file
# together (never pin-file=account-B while the env-file still exports account-A's token).
# The pin file is written ONLY here, gated on the token marker — never the author one.
if [ -n "$tok" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if ! grep -qxF "$tok_marker" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    {
      printf 'export GH_TOKEN=%q\n'                     "$tok"
      printf 'export GITHUB_PERSONAL_ACCESS_TOKEN=%q\n' "$tok"
      printf '%s\n' "$tok_marker"   # marker written LAST
    } >> "$CLAUDE_ENV_FILE" 2>/dev/null
  fi
  if [ -n "$sid" ] && grep -qxF "$tok_marker" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    if mkdir -p "$SESS_DIR" 2>/dev/null && printf '%s\n' "$LOCKED" > "$SESS_DIR/$sid" 2>/dev/null; then
      chmod 600 "$SESS_DIR/$sid" 2>/dev/null; pinned_ok=1
    fi
    find "$SESS_DIR" -type f -mtime +7 -delete 2>/dev/null   # prune stale pins (best-effort)
  fi
fi

subdir_note=""
if [ "$cwd_lc" != "$ROOT_LC" ]; then
  if [ "$author_pinned" = 1 ]; then author_txt="commit author is pinned to $LOCKED"
  else                              author_txt="commit author is NOT pinned here"; fi
  if [ "$pinned_ok" = 1 ]; then
    # token present => the push credential helper (which calls gh auth token --user $LOCKED)
    # resolves too, so push is pinned here as well.
    subdir_note=" SUB-DIRECTORY launch: gh + GitHub-MCP + git push are session-pinned to $LOCKED here, and $author_txt — so you can work normally. Do NOT 'cd' into a DIFFERENT locked tree mid-session — that stays blocked; relaunch Claude there instead."
  elif [ "$author_pinned" = 1 ]; then
    # No token => gh, MCP AND git push are all unpinned (the push credential helper needs the
    # same token). Only the commit author is pinned (it is token-independent).
    subdir_note=" SUB-DIRECTORY launch: $author_txt, but the $LOCKED token is unavailable, so gh, GitHub-MCP and git push are NOT pinned here (the push credential helper needs that token). Commits stay correctly authored; run 'gh auth login --user $LOCKED' (or relaunch Claude from $ROOT) before pushing."
  elif [ "$ambient_cleared" = 1 ]; then
    # Author block ran (ambient cleared) but no locked name/email to export: git falls back to
    # the per-folder gitconfig [user] pin rather than any inherited foreign identity.
    subdir_note=" SUB-DIRECTORY launch: this lock has no name/email configured, so commit author is NOT pinned here — the inherited ambient identity was cleared and git falls back to the gitconfig [user] pin. gh/MCP/push are not pinned. Relaunch Claude from $ROOT, or add name/email to this lock's folders.json entry."
  else
    # No writable session env-file (absent OR unwritable): nothing was cleared, so any inherited
    # ambient identity is STILL ACTIVE and would author commits. Fail loud — do not commit.
    subdir_note=" SUB-DIRECTORY launch: identity could NOT be session-pinned here (no writable session env-file), so commit author is NOT guaranteed and any inherited ambient identity is STILL ACTIVE — do NOT commit. Relaunch Claude from $ROOT, or run 'gh auth login --user $LOCKED', for full coverage."
  fi
fi

jq -n --arg a "$LOCKED" --arg n "$subdir_note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("GitHub identity for this workspace is LOCKED to \($a). Every git / gh / GitHub-MCP action MUST be performed as \($a). Identity is pinned by default (settings env GH_TOKEN + GIT_AUTHOR_*, the per-folder git credential helper, and the MCP token) and a deny-only PreToolUse guard blocks attempts to override it. Do NOT switch accounts, set/override GH_TOKEN or GIT_AUTHOR_*, or rewrite git credential config." + $n)
  }
}' 2>/dev/null
