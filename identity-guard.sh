#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# identity-guard.sh — account-isolation guard (Claude Code PreToolUse hook)
# Matchers: Bash  and  mcp__plugin_github_github__.*
#
# Identity is PINNED at the environment + gitconfig level, not by parsing the
# command:
#   * settings.local.json env: GH_TOKEN (gh CLI), GITHUB_PERSONAL_ACCESS_TOKEN
#     (GitHub MCP), GIT_AUTHOR_*/GIT_COMMITTER_* (commit identity).
#   * per-folder gitconfig credential.https://github.com.helper -> the locked
#     account's token (git push over HTTPS).
# So however git/gh is invoked (wrappers, $(...), backticks, split keywords,
# `gi""t`), it uses the locked account by DEFAULT. This guard therefore does not
# try to detect invocations; it is a DENY-ONLY filter that blocks the bounded set
# of constructs that could OVERRIDE or STRIP the pinned identity. Those constructs
# target fixed UPPERCASE variable names / fixed git flags, which (unlike command
# names) cannot be obfuscated by quote-splitting — so detection is reliable.
#
# It also fail-closes GitHub MCP write tools unless the MCP token is the locked
# account's. No rewrite (no injection surface). Defensive: no set -e/pipefail.
#
# Residual (documented): a command with arbitrary code execution (eval is denied,
# but e.g. `curl … | sh`, a script, or a compiled binary) can do anything a shell
# can, including exfiltrate via non-git channels — a PreToolUse hook cannot sandbox
# that. The guarantee here is: no ACCIDENTAL or override-style cross-account git/gh
# action; the default identity for every command is the locked account.
#
# The locked account + the locked tree ROOT for this cwd are resolved from
# folders.json ($IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json)
# via lib/resolve-account.sh — nothing here is hardcoded to any account/path.
# ---------------------------------------------------------------------------
GUARD_VERSION=3

payload="$(cat)"
jqr() { printf '%s' "$payload" | jq -r "$1" 2>/dev/null; }
tool="$(jqr '.tool_name // empty')"
cwd="$(jqr '.cwd // empty')"; [ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
cwd_lc="$(printf '%s' "$cwd" | tr '[:upper:]' '[:lower:]')"

# Session pin: SessionStart records the locked ACCOUNT (no token) here after it has
# verifiably pinned this session's env-file. The guard can't see the env-file's
# GH_TOKEN/GITHUB_PERSONAL_ACCESS_TOKEN, so for sub-directory launches it confirms
# pinning by reading this file (keyed by session_id, present in every payload).
sid="$(jqr '.session_id // empty')"
SESS_DIR="${IDENTITY_LOCK_SESSIONS:-${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}/sessions}"
session_pin() { [ -n "$sid" ] && head -1 "$SESS_DIR/$sid" 2>/dev/null; }

# --- resolve the locked account for this cwd from folders.json ---
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/lib/resolve-account.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib/resolve-account.sh"
IFS=$'\t' read -r LOCKED EMAIL NAME < <(resolve_account "$cwd")
[ -z "${LOCKED:-}" ] && exit 0
# The locked tree ROOT (the matched folders.json .path) — the git -C/--git-dir/
# --work-tree in-tree exception below allows only paths under this root.
IDLOCK_CFG="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
ROOT="$(jq -r --arg c "$cwd_lc" '
  .[] | (.path | ascii_downcase) as $p
  | select($c == $p or ($c | startswith($p + "/")))
  | .path' "$IDLOCK_CFG" 2>/dev/null | head -1)"
ROOT_LC="$(printf '%s' "$ROOT" | tr '[:upper:]' '[:lower:]')"

deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

# ===================== GitHub MCP tools =====================
case "$tool" in
  mcp__plugin_github_github__*|mcp__github__*)
    # Strip BOTH possible prefixes — the plugin server (mcp__plugin_github_github__)
    # OR the user-scoped headersHelper override (mcp__github__) — so the write
    # classifier sees the bare action either way. Matching the new namespace in the
    # matcher WITHOUT also stripping it here would misclassify every override-
    # namespace write as a read and allow it (fail-open).
    action="$tool"; action="${action#mcp__plugin_github_github__}"; action="${action#mcp__github__}"
    if printf '%s' "$action" | grep -Eq '^(create|update|delete|merge|push|fork|add_|sub_|request_)|_write$'; then
      want="$(gh auth token --user "$LOCKED" 2>/dev/null)"
      [ -z "$want" ] && deny "Identity guard: GitHub MCP write '$tool' blocked — the $LOCKED account isn't available (run 'gh auth login --user $LOCKED')."
      have="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
      if [ -n "$have" ]; then
        [ "$have" = "$want" ] && exit 0
        deny "Identity guard: GitHub MCP write '$tool' would act as a non-$LOCKED account (MCP token != $LOCKED)."
      fi
      # Sub-directory launch: the MCP token is supplied at connect by the headersHelper
      # override and is NOT in this hook's env. Verify pinning via the session pin file.
      [ "$(session_pin)" = "$LOCKED" ] && exit 0
      deny "Identity guard: GitHub MCP write '$tool' is not provably pinned to $LOCKED (no session pin — a sub-directory launch without the MCP override, or a cross-tree cd). Relaunch Claude from $ROOT, or use the gh CLI."
    fi
    exit 0 ;;
esac

# ===================== Bash =====================
[ "$tool" = "Bash" ] || exit 0
cmd="$(jqr '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0
has()  { printf '%s' "$cmd" | grep -Eq  -- "$1"; }
hasi() { printf '%s' "$cmd" | grep -Eqi -- "$1"; }   # case-insensitive (git config keys / macOS paths)

# Pinned / sensitive variable names. Assignment or override of any of these could
# re-point identity (tokens, git author) or inject code (BASH_ENV, LD_PRELOAD, …).
PV='(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GH_HOST|GH_CONFIG_DIR|GITHUB_PERSONAL_ACCESS_TOKEN|GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|GIT_COMMITTER_NAME|GIT_COMMITTER_EMAIL|GIT_CONFIG[A-Z0-9_]*|GIT_SSH[A-Z0-9_]*|GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_PROXY_COMMAND|GIT_EXTERNAL_DIFF|HOME|XDG_CONFIG_HOME|BASH_ENV|ENV|PROMPT_COMMAND|PS4|LD_PRELOAD|DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH)'
NR='[^A-Za-z0-9_${#!]'   # a char that is NOT part of a $NAME / ${NAME} / ${#NAME} / ${!NAME} read

# 1) Any NON-READ appearance of a pinned/sensitive name. Covers direct assignment
#    (GH_TOKEN=…), env-prefix, export/declare/readonly, unset, read, printf -v, GH_TOKEN+=…,
#    AND name-indirection where the literal name appears (`v=GH_TOKEN; export $v=…`,
#    `n=GH_TOKEN; env "$n"=…`). Plain reads `$NAME` / `${NAME}` are allowed.
has "(^|$NR)${PV}\\b" && \
  deny "Identity guard: refusing to set/override/redirect a pinned identity or code-injection variable in the $LOCKED workspace (identity is pinned automatically). Reading \$NAME is fine."

# 1b) Dynamically-named assignment (variable NAME built via expansion) — could set a pinned var
#     without the literal name ever appearing: `export $v=…`, `export ${p}_TOKEN=…`, `env "$n"=…`,
#     `printf -v "$n"`, `read $n`. (A `$` in the VALUE, e.g. `export PATH=$PATH`, is allowed.)
has '\b(export|declare|typeset|readonly|local)\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^=;|&[:space:]]*\$' && \
  deny "Identity guard: refusing a dynamically-named variable assignment in the $LOCKED workspace — the name is built by expansion and could target a pinned identity variable. Use a literal NAME=value (non-identity)."
has '\benv\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^=;|&[:space:]]*\$' && \
  deny "Identity guard: refusing 'env' with a dynamically-named assignment in the $LOCKED workspace."
has '\b(printf[[:space:]]+-v|read|mapfile|readarray)\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^;|&[:space:]]*\$' && \
  deny "Identity guard: refusing a dynamically-named 'printf -v'/'read' target in the $LOCKED workspace."

# 1c) source/. of a file can set identity overrides the guard can't inspect.
has '(^|[;&|({]|&&|\|\|)[[:space:]]*(source|\.)[[:space:]]' && \
  deny "Identity guard: 'source'/'.' of a file is blocked in the $LOCKED workspace (it could set identity overrides off-screen). Inline the commands instead."

# 2) Dynamic construction / env-stripping / elevation / remote shells.
has '\beval\b'  && deny "Identity guard: 'eval' is blocked in the $LOCKED workspace (it can construct identity overrides the guard can't inspect)."
has '\bsudo\b'  && deny "Identity guard: 'sudo' is blocked in the $LOCKED workspace (it strips the pinned identity environment)."
has '\bdoas\b'  && deny "Identity guard: 'doas' is blocked in the $LOCKED workspace (it strips the pinned identity environment)."
has '\benv[[:space:]]+(--ignore-environment\b|-[A-Za-z]*i\b|-[[:space:]]|--[[:space:]])' && \
  deny "Identity guard: 'env -i / env - / env --ignore-environment' is blocked in the $LOCKED workspace (it strips the pinned identity environment)."
if has '\bssh[[:space:]]' && has '\b(git|gh)\b'; then
  deny "Identity guard: refusing 'ssh … git/gh …' in the $LOCKED workspace — it would run git/gh on a remote host outside the pinned identity."
fi

# 3) git config WRITES of any kind (identity/credentials/url/http are pinned by the managed gitconfig).
if has '\bgit[[:space:]]+config\b' \
   && ! has '\bgit[[:space:]]+config\b[^;&|]*(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l\b|--show-origin|--show-scope)'; then
  deny "Identity guard: 'git config' writes are blocked in the $LOCKED workspace (identity, credential helper, url/http config are pinned by the managed gitconfig). Reads (--get/--list) are fine."
fi

# 4) git -c overrides and commit --author.
hasi '(^|[[:space:]])-c[[:space:]]+(user|credential|http|core|url|include)\.' && \
  deny "Identity guard: 'git -c' override of user/credential/http/core/url/include config is blocked in the $LOCKED workspace."
has '(^|[[:space:]])--config-env([ =])' && \
  deny "Identity guard: 'git --config-env' is blocked in the $LOCKED workspace (it sets config from an env var, bypassing the -c guard)."
if has '\b(commit|am|rebase|cherry-pick|revert)\b' && has '(^|[[:space:]])--author([ =])'; then
  deny "Identity guard: 'git --author' is blocked in the $LOCKED workspace; author/committer are pinned automatically."
fi
# author-forge: 'git am' (arbitrary From: header) and commit message/author reuse from another commit.
has '\bgit[[:space:]]+([^;&|]*[[:space:]])?am([[:space:]]|$)' && \
  deny "Identity guard: 'git am' is blocked in the $LOCKED workspace (a patch's From: header sets an arbitrary commit author the env pin can't override)."
if has '(^|[[:space:]])(--reuse-message|--reedit-message)([ =])' && ! has '\-\-reset-author'; then
  deny "Identity guard: 'git commit --reuse-message/--reedit-message' copies another commit's author; blocked in the $LOCKED workspace unless combined with --reset-author."
fi
# 'git -C' / --git-dir / --work-tree pointing OUTSIDE the locked tree: the includeIf identity and the
# credential-helper pin only apply under the locked folder ROOT, so an outside target acts as another account.
if has '(-C[[:space:]]+|--git-dir[ =]|--work-tree[ =])(\.\./|/)'; then
  printf '%s' "$cmd" | grep -Eqi -- "(-C[[:space:]]+|--git-dir[ =]|--work-tree[ =])${ROOT_LC}(/|[[:space:]]|\$)" \
    || deny "Identity guard: 'git -C/--git-dir/--work-tree' targeting a path outside the locked folder ($ROOT) is blocked (the identity pin only applies under that tree)."
fi

# 5) gh: explicit auth-header / hostname override, token login, logout.
if has '\bgh[[:space:]]+api\b' && has '(-H|--header)' && has '[Aa]uthorization'; then
  deny "Identity guard: 'gh api' with an explicit Authorization header is blocked in the $LOCKED workspace (it would act as another account)."
fi
has '\bgh[[:space:]]+api\b[^;&|]*--hostname' && \
  deny "Identity guard: 'gh api --hostname' is blocked in the $LOCKED workspace."
has '\bgh[[:space:]]+auth[[:space:]]+login\b[^;&|]*--with-token' && \
  deny "Identity guard: 'gh auth login --with-token' is blocked in the $LOCKED workspace."
has '\bgh[[:space:]]+auth[[:space:]]+logout\b' && \
  deny "Identity guard: 'gh auth logout' is blocked in the $LOCKED workspace (it would break the pinned git credential helper)."

# 6) SSH / scp-style remote push, or a push URL with embedded credentials.
if has '\bpush\b'; then
  has '(git@|ssh://)' && deny "Identity guard: SSH-remote push can't be identity-pinned to $LOCKED. Use an https:// remote."
  has '(^|[[:space:]])([A-Za-z0-9_.-]+@)?[A-Za-z0-9.-]+\.[A-Za-z]{2,}:[^/[:space:]]' && \
    deny "Identity guard: scp-style remote push can't be identity-pinned to $LOCKED. Use an https:// remote."
  has 'https?://[^/[:space:]]*:[^/@[:space:]]*@' && \
    deny "Identity guard: refusing a push URL with embedded credentials in the $LOCKED workspace."
fi

# 7) Direct writes to a git config file (redirection / tee / sed -i / cp / mv …) — bypasses 'git config'.
if hasi '(\.git/config\b|/gitconfig\b|\.gitconfig\b|/\.config/git/)'; then
  has '(>|[[:space:]]tee\b|sed[[:space:]]+-i|\b(cp|mv|ln|dd|install|truncate)\b)' && \
    deny "Identity guard: writing/replacing a git config file is blocked in the $LOCKED workspace."
fi

# 8) FAIL CLOSED if this session is not actually token-pinned to $LOCKED. The settings env GH_TOKEN
#    is injected into every command (verified), so a missing/wrong GH_TOKEN means the session wasn't
#    launched at the folder root (e.g. a sub-directory) and a 'gh' command would act as the active
#    account. git push (gitconfig credential helper) and commit author (includeIf) stay pinned, so
#    only 'gh' (non-auth) needs this. gh-auth-only commands are exempt.
gh_real=0
if has '\bgh\b'; then
  printf '%s' "$cmd" | grep -oE '\bgh[[:space:]]+[a-z][a-z-]*' | grep -qvE '[[:space:]]auth$' && gh_real=1
  printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+[a-z]' || gh_real=1
fi
if [ "$gh_real" = 1 ]; then
  want="$(gh auth token --user "$LOCKED" 2>/dev/null)"
  if [ -z "$want" ]; then
    # The locked account isn't in gh's keyring — can't pin gh to it. Fail closed
    # (matches the MCP section), rather than letting gh use the active account.
    deny "Identity guard: 'gh' blocked — the $LOCKED account isn't available (gh auth token --user $LOCKED is empty). Run 'gh auth login --user $LOCKED'."
  elif [ -n "${GH_TOKEN:-}" ]; then
    # Root launch: settings.local.json injected GH_TOKEN into this session's env.
    [ "${GH_TOKEN}" = "$want" ] || \
      deny "Identity guard: GH_TOKEN isn't the $LOCKED token; 'gh' would act as another account in the $LOCKED workspace."
  else
    # Sub-directory launch: GH_TOKEN is set via the session env-file by SessionStart
    # (not visible to this hook). Confirm pinning via the session pin file instead.
    [ "$(session_pin)" = "$LOCKED" ] || \
      deny "Identity guard: this session is not token-pinned to $LOCKED (no session pin — a sub-directory launch SessionStart couldn't pin, or a cross-tree cd). Relaunch Claude from $ROOT, or use 'git' (push/commit stay pinned)."
  fi
fi

exit 0
