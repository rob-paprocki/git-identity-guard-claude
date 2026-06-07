#!/usr/bin/env bash
# install.sh — interactive installer for git-identity-guard.
#
# Task 4 scope: preflight (gh/jq/git present, gh authenticated) + a prompt loop
# that collects {path, account, name, email} for each folder to lock, then writes
# them to ~/.config/identity-lock/folders.json (idempotent/merged by path). The
# four-layer wiring (gitconfig includeIf, credential helper, per-folder
# settings.local.json, global hooks) is added in later tasks.
#
# Defensive bash: NO `set -e` — a failed `read` at EOF must end the loop cleanly,
# not abort the script. Supports a scripted stdin mode for tests:
#   printf '%s\n' PATH ACCOUNT NAME EMAIL "" | install.sh --non-interactive-from-stdin
# where a blank PATH (or EOF) terminates the loop.
set -u

# The installer's own directory — source of the hooks/lib we copy into ~/.claude.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}"
CONFIG="${IDENTITY_LOCK_CONFIG:-$CONFIG_DIR/folders.json}"
# Where the guard/session-init hooks + the resolve-account lib are installed.
HOOKS_DIR="$HOME/.claude/hooks"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
# User-scoped MCP config + the GitHub MCP endpoint we override (same URL = supersedes
# the plugin server by endpoint).
CLAUDE_JSON="$HOME/.claude.json"
GH_MCP_URL="https://api.githubcopilot.com/mcp/"

SCRIPTED=0
HARDEN=0   # --harden-keychain (or an interactive yes) forces osxkeychain hardening
MCP_OVERRIDE=1   # default ON; --no-mcp-override (or an interactive no) skips the MCP override
for arg in "$@"; do
  case "$arg" in
    --non-interactive-from-stdin) SCRIPTED=1 ;;
    --harden-keychain)            HARDEN=1 ;;
    --no-mcp-override)            MCP_OVERRIDE=0 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--non-interactive-from-stdin] [--harden-keychain] [--no-mcp-override]

Locks one or more local folders each to a specific GitHub account by recording
them in ~/.config/identity-lock/folders.json.

Interactive mode (default): prompts for folder path, GitHub account, git name,
and commit email, looping until you leave the path blank. Then offers to harden
git pushes to fail-closed (default no).

Scripted mode (--non-interactive-from-stdin): reads the same four answers per
folder from stdin (one per line); a blank path line or EOF ends the loop. Used
by the test suite.

--harden-keychain: erase any stored github.com credential from the macOS login
keychain so a push without a per-folder helper FAILS rather than falling back to
the wrong identity. Off by default; harmless on non-macOS (the erase is a no-op).

--no-mcp-override: skip the GitHub MCP override. By default install adds a
user-scoped `github` MCP server (same endpoint as the GitHub plugin) whose
headersHelper resolves the locked account by cwd, so GitHub MCP works from
sub-directory launches too. NOTE: enabling it changes the GitHub MCP tool
namespace machine-wide (mcp__plugin_github_github__* -> mcp__github__*).
USAGE
      exit 0 ;;
  esac
done

err()  { printf 'install: %s\n' "$*" >&2; }
note() { [ "$SCRIPTED" = 1 ] || printf '%s\n' "$*"; }
ask()  { # ask <var> <prompt> [default]; in scripted mode reads a bare line from stdin
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  if [ "$SCRIPTED" = 1 ]; then
    IFS= read -r __reply || __reply=""
  else
    if [ -n "$__default" ]; then
      IFS= read -r -p "$__prompt [$__default]: " __reply || __reply=""
      [ -z "$__reply" ] && __reply="$__default"
    else
      IFS= read -r -p "$__prompt: " __reply || __reply=""
    fi
  fi
  printf -v "$__var" '%s' "$__reply"
}

# The PreToolUse matcher used by both the per-folder and the global wiring. Covers
# the GitHub plugin's MCP namespace AND the user-scoped override's (mcp__github__*),
# so the guard fires regardless of whether the MCP override is enabled.
GUARD_MATCHER='Bash|mcp__plugin_github_github__.*|mcp__github__.*'

# Opt-in osxkeychain hardening. We erase any stored github.com credential so a
# push from a locked folder cannot silently fall back to a cached (wrong-account)
# password — it fails closed, forcing the per-folder `gh auth token` helper.
#
# The command is overridable via $IDENTITY_OSXKEYCHAIN_CMD ONLY for the test seam;
# the default is byte-for-byte `git credential-osxkeychain`. We deliberately do NOT
# stub this via a PATH shim: git resolves `credential-osxkeychain` from its own
# exec-path, so a PATH stub would be shadowed on macOS yet honored on Linux CI —
# i.e. it could erase the tester's real credential locally while passing in CI.
harden_keychain() {
  local cmd="${IDENTITY_OSXKEYCHAIN_CMD:-git credential-osxkeychain}"
  # Unquoted on purpose so the default splits into `git` + `credential-osxkeychain`.
  printf 'protocol=https\nhost=github.com\n' | $cmd erase 2>/dev/null
  note "  hardened: erased stored github.com credential (pushes now fail-closed)"
}

# install_hooks: copy the guard, session-init, and resolve-account lib into
# ~/.claude/hooks/ (+ lib/), then merge the global SessionStart + PreToolUse
# wiring into ~/.claude/settings.json. Idempotent: re-running adds no duplicates.
install_hooks() {
  mkdir -p "$HOOKS_DIR/lib"
  install -m 755 "$SCRIPT_DIR/identity-guard.sh"        "$HOOKS_DIR/" 2>/dev/null
  install -m 755 "$SCRIPT_DIR/identity-session-init.sh" "$HOOKS_DIR/" 2>/dev/null
  install -m 755 "$SCRIPT_DIR/mcp-github-headers.sh"    "$HOOKS_DIR/" 2>/dev/null
  install -m 644 "$SCRIPT_DIR/lib/resolve-account.sh"   "$HOOKS_DIR/lib/" 2>/dev/null

  local guard="bash $HOOKS_DIR/identity-guard.sh"
  local init="bash $HOOKS_DIR/identity-session-init.sh"

  mkdir -p "$(dirname "$GLOBAL_SETTINGS")"
  local cur="{}"
  if [ -f "$GLOBAL_SETTINGS" ]; then
    cur="$(jq '.' "$GLOBAL_SETTINGS" 2>/dev/null)" || cur="{}"
    [ -z "$cur" ] && cur="{}"
  fi

  # Filter out any existing entry that runs OUR session-init/guard, then append a
  # fresh one. This dedups re-runs AND refreshes the entry (e.g. upgrading from an
  # older install whose PreToolUse matcher predates the mcp__github__ namespace) —
  # an add-only merge would leave a stale matcher and silently un-guard the override
  # namespace. Unrelated user hooks (entries not running our scripts) are preserved.
  local merged
  merged="$(printf '%s' "$cur" | jq \
    --arg guard "$guard" --arg init "$init" --arg matcher "$GUARD_MATCHER" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = ([ (.hooks.SessionStart // [])[]
        | select(((.hooks // [])[]?.command // "") | test("identity-session-init.sh") | not) ]
        + [ {hooks:[ {type:"command", command:$init, timeout:10} ]} ])
    | .hooks.PreToolUse = ([ (.hooks.PreToolUse // [])[]
        | select(((.hooks // [])[]?.command // "") | test("identity-guard.sh") | not) ]
        + [ {matcher:$matcher, hooks:[ {type:"command", command:$guard, timeout:15} ]} ])')"

  if [ -n "$merged" ]; then
    printf '%s\n' "$merged" > "$GLOBAL_SETTINGS"
  fi
}

# wire_mcp_override: add a USER-scoped `github` MCP server (same endpoint as the
# GitHub plugin) to ~/.claude.json, whose headersHelper resolves the locked account
# by cwd at connect. User scope supersedes the plugin by endpoint AND loads in every
# session, so GitHub MCP is identity-pinned even for a sub-directory launch. NOTE:
# this changes the GitHub MCP tool namespace machine-wide (mcp__plugin_github_github__*
# -> mcp__github__*). Idempotent; writes atomically and only if the result is valid,
# non-empty JSON (never corrupts ~/.claude.json).
wire_mcp_override() {
  local helper="bash $HOOKS_DIR/mcp-github-headers.sh"
  local cur="{}"
  if [ -f "$CLAUDE_JSON" ]; then
    cur="$(jq '.' "$CLAUDE_JSON" 2>/dev/null)" || cur="{}"
    [ -z "$cur" ] && cur="{}"
  fi
  local merged
  merged="$(printf '%s' "$cur" | jq --arg url "$GH_MCP_URL" --arg h "$helper" '
    .mcpServers = (.mcpServers // {})
    | .mcpServers.github = {type:"http", url:$url, headersHelper:$h}' 2>/dev/null)"
  if [ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$merged" > "$CLAUDE_JSON.idlock.tmp" && mv "$CLAUDE_JSON.idlock.tmp" "$CLAUDE_JSON"
  fi
}

# write_claude_md <path> <account>: generate the canonical per-folder identity contract
# CLAUDE.md from one template (the only per-account difference is the handle). It carries a
# 'managed by git-identity-guard' marker; we write/refresh it only when the file is absent or
# already carries that marker, so a hand-customized CLAUDE.md is never clobbered. The commit
# email is referenced generically (not hardcoded) so no account's address is baked into docs.
write_claude_md() {
  local path="$1" account="$2" cm="$path/CLAUDE.md"
  if [ -f "$cm" ] && ! grep -q 'managed by git-identity-guard' "$cm" 2>/dev/null; then
    return 0   # a hand-written CLAUDE.md — leave it alone
  fi
  local tmpl
  tmpl="$(cat <<'TEMPLATE'
<!-- managed by git-identity-guard — regenerated by install.sh; hand edits may be overwritten. -->
# Identity contract for this folder — __ACCT__ ONLY

Everything under this folder (it **and every repo cloned inside it**) MUST use the
**__ACCT__** GitHub identity. Using any other account to commit, push, open or comment
on issues/PRs, or otherwise act on GitHub here is a hard violation of the user's
identity-integrity requirement.

## Required identity
- GitHub account / login: **`__ACCT__`**
- Commit author / email: pinned automatically to the `__ACCT__` account by the per-folder
  gitconfig (`includeIf` → `~/.config/git/__ACCT__.gitconfig`) and the `GIT_AUTHOR_*` /
  `GIT_COMMITTER_*` env — you never set it by hand.

## How this is enforced (don't fight it)
Identity is pinned by **default** at the environment + git-config level, so every
git / gh / GitHub-MCP operation uses `__ACCT__` no matter how the command is written:
- **gh CLI** — `GH_TOKEN` is the `__ACCT__` token (per-folder `settings.local.json` `env` at
  the folder root, and the session env-file for sub-directory launches), so `gh` acts as
  `__ACCT__` regardless of the active `gh` account.
- **GitHub MCP** — `GITHUB_PERSONAL_ACCESS_TOKEN` is the `__ACCT__` token at the folder root;
  with the MCP override installed, a user-scoped `headersHelper` pins it by cwd for
  sub-directory launches too (this moves the GitHub MCP tool namespace to `mcp__github__*`).
  MCP writes are additionally hard-blocked unless provably `__ACCT__`.
- **git push (HTTPS)** — the per-folder gitconfig sets a `credential.https://github.com.helper`
  returning the `__ACCT__` token, overriding the OS keychain.
- **commit author/committer** — `~/.gitconfig` `includeIf` → `__ACCT__.gitconfig` **and**
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*` in `env`.

On top of that default, a **PreToolUse deny-filter** (`~/.claude/hooks/identity-guard.sh`)
blocks attempts to *override* the pinned identity: setting/unsetting `GH_TOKEN` / `GIT_AUTHOR_*`
(incl. name-indirection), `git config` writes, `git -c` / `--author`, `gh api` with an
`Authorization` header, `gh auth login --with-token` / `logout`, `eval` / `sudo` / `env -i`,
SSH/scp pushes, and direct git-config file writes.

## Sub-directory launches
Launching Claude in a repo nested under this folder is fully supported: the SessionStart hook
pins `gh` (via the session env-file) and GitHub MCP (via the `headersHelper` override), and
`git push` / commit author stay pinned via gitconfig — so you can work normally from any
sub-directory. The guard confirms pinning from a per-session pin file: a mid-session `cd` into a
**different** locked tree, or a locked account not logged in to `gh`, **fails closed** (denied)
rather than acting as the wrong account — relaunch Claude in the correct tree, or run
`gh auth login --user __ACCT__`.

## Threat model & residual limits
The **default** identity for every command is `__ACCT__`, and the override forms a confused agent
or naive prompt-injection would use are blocked. It is **not** a sandbox: a command with arbitrary
code execution can still defeat pinning by sufficiently obfuscated means (an interpreter building a
variable name with no literal substring, or writing a persistent shell-startup file), and can
exfiltrate over non-git channels — a command-string hook can't make that airtight. Treat this as
hardening that makes the common mistakes impossible and the deliberate bypasses obvious, not a jail.

## Rules for all agents (main thread and subagents)
- Prefer the **`gh` CLI** for issues / PRs / repo writes — it is identity-pinned here (and works
  from sub-directory launches).
- Do **not** run `gh auth switch` / `gh auth logout` to another account, pass another account's
  token, or set a different git `user.email` while working here.
- If the identity guard **blocks** an action, do **not** route around it. Surface the block to the
  user; if the `__ACCT__` account isn't logged in, ask them to run `gh auth login --user __ACCT__`,
  or — if you've `cd`'d into a different locked tree — relaunch Claude in the correct one.
TEMPLATE
)"
  printf '%s\n' "${tmpl//__ACCT__/$account}" > "$cm"
}

# wire_folder <path> <account> <name> <email>: wire the pinning layers for
# one locked folder. Idempotent — safe to re-run for the same path/account.
wire_folder() {
  local path="$1" account="$2" name="$3" email="$4"

  # --- L1/L3: per-account gitconfig (identity + credential helper) -------------
  local gc="$HOME/.config/git/$account.gitconfig"
  mkdir -p "$(dirname "$gc")"
  git config -f "$gc" user.name  "$name"
  git config -f "$gc" user.email "$email"
  # Reset the (possibly multivalued) helper to a single empty value, then add the
  # real helper. --replace-all collapses any prior duplicates so re-running yields
  # exactly ['', '<helper>'] every time (idempotent; defeats osxkeychain by order).
  git config -f "$gc" --replace-all 'credential.https://github.com.helper' '' 2>/dev/null
  git config -f "$gc" --add 'credential.https://github.com.helper' \
    "!f() { test \"\$1\" = get && echo username=x-access-token && echo \"password=\$(gh auth token --user $account)\"; }; f"

  # --- L1: ~/.gitconfig includeIf -> the per-account gitconfig (idempotent) -----
  local gitconfig="$HOME/.gitconfig"
  if ! grep -qF "gitdir/i:$path/" "$gitconfig" 2>/dev/null; then
    git config -f "$gitconfig" "includeIf.gitdir/i:$path/.path" "$gc"
  fi

  # --- L2/L4: per-folder settings.local.json (env pins + PreToolUse guard) ------
  # Token from the locked account's keyring entry. This file is gitignored.
  # MERGE into any existing file rather than overwriting it, so a re-run never
  # clobbers the user's other keys (e.g. a permissions allowlist or unrelated
  # hooks): preserve everything, and refresh only our guard entry + env pins.
  local tok; tok="$(gh auth token --user "$account" 2>/dev/null)"
  local sl="$path/.claude/settings.local.json"
  mkdir -p "$(dirname "$sl")"
  local cur="{}"
  if [ -f "$sl" ]; then cur="$(jq '.' "$sl" 2>/dev/null)" || cur="{}"; [ -z "$cur" ] && cur="{}"; fi
  local merged
  merged="$(printf '%s' "$cur" | jq \
        --arg g "bash $HOOKS_DIR/identity-guard.sh" --arg m "$GUARD_MATCHER" \
        --arg t "$tok" --arg n "$name" --arg e "$email" '
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = ([ (.hooks.PreToolUse // [])[]
        | select(((.hooks // [])[]?.command // "") | test("identity-guard.sh") | not) ]
        + [ {matcher:$m, hooks:[ {type:"command", command:$g, timeout:15} ]} ])
    | .env = ((.env // {}) + {
        GH_TOKEN: $t, GITHUB_PERSONAL_ACCESS_TOKEN: $t,
        GIT_AUTHOR_NAME: $n, GIT_AUTHOR_EMAIL: $e,
        GIT_COMMITTER_NAME: $n, GIT_COMMITTER_EMAIL: $e
      })')"
  if [ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$merged" > "$sl.tmp" && mv "$sl.tmp" "$sl"
  fi
  chmod 600 "$sl" 2>/dev/null || true

  # --- generate the canonical per-folder identity contract (non-destructive) -----
  write_claude_md "$path" "$account"
}

# --- preflight: required tools -------------------------------------------------
missing=""
for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  err "missing required tool(s):$missing"
  err "install them and re-run (gh: https://cli.github.com, jq: https://jqlang.github.io)."
  exit 1
fi

# --- preflight: gh must be authenticated (check exit code, not output) ---------
if ! gh auth status >/dev/null 2>&1; then
  err "gh is not authenticated. Run 'gh auth login' first."
  exit 1
fi

# A newline-separated default list of authenticated accounts (best-effort).
gh_accounts="$(gh auth status 2>/dev/null | grep -oE 'account [^ ]+' | awk '{print $2}' | sort -u | paste -sd, -)"

note "git-identity-guard installer"
note "Lock one or more local folders, each to a specific GitHub account."
note "Leave the folder path blank to finish."
note ""

# --- prompt loop: collect entries ---------------------------------------------
entries="[]"   # in-memory JSON array, appended as we go
collected=0
while :; do
  path=""
  ask path "Folder to lock (absolute path)"
  # Trim only trailing whitespace/newline; do NOT canonicalize (exact-match config).
  path="${path%"${path##*[![:space:]]}"}"
  [ -z "$path" ] && break

  account=""; name=""; email=""
  ask account "GitHub account/handle to lock it to${gh_accounts:+ (known: $gh_accounts)}"
  account="${account%"${account##*[![:space:]]}"}"

  # Email default from the locked account's gh profile (best-effort, scripted skips).
  email_default=""
  if [ "$SCRIPTED" != 1 ] && [ -n "$account" ]; then
    email_default="$(gh api user --jq '.email // empty' 2>/dev/null)"
  fi

  ask name  "Git author name"
  name="${name%"${name##*[![:space:]]}"}"
  ask email "Commit email" "$email_default"
  email="${email%"${email##*[![:space:]]}"}"

  if [ -z "$account" ]; then
    err "skipping '$path': no account given."
    continue
  fi

  # Append, replacing any existing entry for the same path (idempotent by path).
  entries="$(printf '%s' "$entries" | jq \
    --arg path "$path" --arg account "$account" --arg name "$name" --arg email "$email" '
      [ .[] | select(.path != $path) ]
      + [ {path:$path, account:$account, name:$name, email:$email} ]')"
  collected=$((collected+1))

  # --- wire the four pinning layers for this folder (idempotent) ---
  wire_folder "$path" "$account" "$name" "$email"
  note "  locked $path -> $account (wired)"
done

# Install/refresh the global hooks + settings.json wiring once (idempotent).
[ "$collected" != 0 ] && install_hooks

# MCP override (default ON). Interactive runs confirm (default keep); --no-mcp-override
# or an interactive "no" skips it. Scripted runs honor the flag without prompting.
if [ "$SCRIPTED" != 1 ] && [ "$MCP_OVERRIDE" = 1 ] && [ "$collected" != 0 ]; then
  reply=""
  IFS= read -r -p "Enable the GitHub MCP override so MCP works from sub-directories? It changes the GitHub MCP tool namespace machine-wide (mcp__plugin_github_github__* -> mcp__github__*). [Y/n]: " reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in [nN]|[nN][oO]) MCP_OVERRIDE=0 ;; esac
fi
[ "$collected" != 0 ] && [ "$MCP_OVERRIDE" = 1 ] && wire_mcp_override

if [ "$collected" = 0 ]; then
  note "No folders given; nothing to do."
  exit 0
fi

# --- merge into the on-disk config (idempotent by path) ------------------------
mkdir -p "$(dirname "$CONFIG")"
existing="[]"
if [ -f "$CONFIG" ]; then
  existing="$(jq '.' "$CONFIG" 2>/dev/null)" || existing="[]"
  [ -z "$existing" ] && existing="[]"
fi

# New entries win on path collisions: drop existing entries whose path is being
# (re)written, then concatenate the freshly collected ones.
merged="$(jq -n --argjson existing "$existing" --argjson new "$entries" '
  ($new | map(.path)) as $paths
  | [ $existing[] | select(.path as $p | $paths | index($p) | not) ] + $new')"

printf '%s\n' "$merged" > "$CONFIG"
chmod 600 "$CONFIG" 2>/dev/null || true

# --- opt-in: harden pushes to fail-closed (osxkeychain erase) -------------------
# Interactive runs ask (default NO); scripted runs never prompt — the loop already
# consumed every stdin line, so prompting here would desync. --harden-keychain
# forces it on in either mode.
if [ "$HARDEN" != 1 ] && [ "$SCRIPTED" != 1 ]; then
  reply=""
  IFS= read -r -p "Harden pushes to fail-closed? (erase stored github.com credential) [y/N]: " reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in [yY]|[yY][eE][sS]) HARDEN=1 ;; esac
fi
[ "$HARDEN" = 1 ] && harden_keychain

note ""
note "=== git-identity-guard: install summary ==="
note "Locked $collected folder(s); config: $CONFIG"
note "Wired per locked folder:"
note "  L1 identity   : ~/.config/git/<account>.gitconfig + ~/.gitconfig includeIf"
note "  L3 git push   : credential helper -> gh auth token --user <account>"
note "  L2/L4 CC + MCP: <folder>/.claude/settings.local.json (env pins + guard)"
note "Wired globally  : ~/.claude hooks + settings.json (SessionStart + PreToolUse)"
note "Subdir support  : SessionStart pins gh/git via the session env-file (works from"
note "                  any sub-directory of a locked folder)."
note "Identity contract: a managed CLAUDE.md written into each locked folder (a"
note "                  hand-customized CLAUDE.md without our marker is left untouched)."
if [ "$MCP_OVERRIDE" = 1 ]; then
  note "MCP override    : ON  (user-scoped github MCP -> headersHelper; MCP works in subdirs)."
  note "                  Changes GitHub MCP tool namespace machine-wide -> mcp__github__*."
else
  note "MCP override    : off (gh works in subdirs; GitHub MCP needs a folder-root launch)."
fi
if [ "$HARDEN" = 1 ]; then
  note "Keychain harden : ON  (stored github.com credential erased; pushes fail-closed)"
else
  note "Keychain harden : off (re-run with --harden-keychain to enable)"
fi
note "Uninstall with  : ./uninstall.sh   (add --purge to also drop per-account gitconfig)"
