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

subdir_note=""
[ "$cwd_lc" != "$ROOT_LC" ] && \
  subdir_note=" This session looks like a SUB-DIRECTORY of the workspace: gh/MCP may NOT be token-pinned here (git push and commit author still are). Relaunch Claude from $ROOT for full coverage."

jq -n --arg a "$LOCKED" --arg n "$subdir_note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("GitHub identity for this workspace is LOCKED to \($a). Every git / gh / GitHub-MCP action MUST be performed as \($a). Identity is pinned by default (settings env GH_TOKEN + GIT_AUTHOR_*, the per-folder git credential helper, and the MCP token) and a deny-only PreToolUse guard blocks attempts to override it. Do NOT switch accounts, set/override GH_TOKEN or GIT_AUTHOR_*, or rewrite git credential config." + $n)
  }
}' 2>/dev/null
