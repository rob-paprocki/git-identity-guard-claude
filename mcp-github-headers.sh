#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# mcp-github-headers.sh — headersHelper for a user-scoped GitHub MCP override.
#
# Claude Code runs this at MCP connect time, in the directory Claude was launched
# from, and merges its stdout (a JSON object of header name->value) into the
# connection headers. We resolve the locked account for that launch directory and
# bind the Authorization header to THAT account's token — so GitHub MCP is
# identity-pinned even for a sub-directory launch, where settings.local.json (and
# thus GITHUB_PERSONAL_ACCESS_TOKEN) doesn't load. This is the MCP analog of what
# the includeIf gitconfig already does for git, and the env-file does for gh.
#
# Outside any locked tree it falls back to the ambient GITHUB_PERSONAL_ACCESS_TOKEN,
# so GitHub MCP keeps working exactly as the plugin's static config did (the
# override supersedes the plugin by endpoint, machine-wide).
#
# The token appears ONLY in the JSON written to stdout — never logged.
# ---------------------------------------------------------------------------
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HDIR/lib/resolve-account.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib/resolve-account.sh" 2>/dev/null

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
acct=""
if command -v resolve_account >/dev/null 2>&1; then
  IFS=$'\t' read -r acct _ _ < <(resolve_account "$cwd")
fi

if [ -n "$acct" ]; then
  tok="$(gh auth token --user "$acct" 2>/dev/null)"   # locked account for this tree
else
  tok="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"             # outside a locked tree: ambient
fi

jq -n --arg t "$tok" '{Authorization: ("Bearer " + $t)}'
