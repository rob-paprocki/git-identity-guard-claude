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

SCRIPTED=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive-from-stdin) SCRIPTED=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--non-interactive-from-stdin]

Locks one or more local folders each to a specific GitHub account by recording
them in ~/.config/identity-lock/folders.json.

Interactive mode (default): prompts for folder path, GitHub account, git name,
and commit email, looping until you leave the path blank.

Scripted mode (--non-interactive-from-stdin): reads the same four answers per
folder from stdin (one per line); a blank path line or EOF ends the loop. Used
by the test suite.
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

# The PreToolUse matcher used by both the per-folder and the global wiring.
GUARD_MATCHER='Bash|mcp__plugin_github_github__.*'

# install_hooks: copy the guard, session-init, and resolve-account lib into
# ~/.claude/hooks/ (+ lib/), then merge the global SessionStart + PreToolUse
# wiring into ~/.claude/settings.json. Idempotent: re-running adds no duplicates.
install_hooks() {
  mkdir -p "$HOOKS_DIR/lib"
  install -m 755 "$SCRIPT_DIR/identity-guard.sh"        "$HOOKS_DIR/" 2>/dev/null
  install -m 755 "$SCRIPT_DIR/identity-session-init.sh" "$HOOKS_DIR/" 2>/dev/null
  install -m 644 "$SCRIPT_DIR/lib/resolve-account.sh"   "$HOOKS_DIR/lib/" 2>/dev/null

  local guard="bash $HOOKS_DIR/identity-guard.sh"
  local init="bash $HOOKS_DIR/identity-session-init.sh"

  mkdir -p "$(dirname "$GLOBAL_SETTINGS")"
  local cur="{}"
  if [ -f "$GLOBAL_SETTINGS" ]; then
    cur="$(jq '.' "$GLOBAL_SETTINGS" 2>/dev/null)" || cur="{}"
    [ -z "$cur" ] && cur="{}"
  fi

  # Add the SessionStart hook only if no existing SessionStart entry already runs
  # identity-session-init.sh; likewise the PreToolUse guard only if absent. Match
  # on the command substring so re-runs (and pre-existing user wiring) don't dupe.
  local merged
  merged="$(printf '%s' "$cur" | jq \
    --arg guard "$guard" --arg init "$init" --arg matcher "$GUARD_MATCHER" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = (.hooks.SessionStart // [])
    | .hooks.PreToolUse   = (.hooks.PreToolUse   // [])
    | (if any(.hooks.SessionStart[]?; (.hooks // [])[]?.command | . == $init)
       then .
       else .hooks.SessionStart += [ {hooks:[ {type:"command", command:$init, timeout:10} ]} ]
       end)
    | (if any(.hooks.PreToolUse[]?; (.hooks // [])[]?.command | . == $guard)
       then .
       else .hooks.PreToolUse += [ {matcher:$matcher, hooks:[ {type:"command", command:$guard, timeout:15} ]} ]
       end)')"

  if [ -n "$merged" ]; then
    printf '%s\n' "$merged" > "$GLOBAL_SETTINGS"
  fi
}

# wire_folder <path> <account> <name> <email>: wire the four pinning layers for
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
  local tok; tok="$(gh auth token --user "$account" 2>/dev/null)"
  local sl="$path/.claude/settings.local.json"
  mkdir -p "$(dirname "$sl")"
  jq -n --arg g "bash $HOOKS_DIR/identity-guard.sh" --arg m "$GUARD_MATCHER" \
        --arg t "$tok" --arg n "$name" --arg e "$email" '{
    hooks: { PreToolUse: [ {matcher:$m, hooks:[ {type:"command", command:$g, timeout:15} ]} ] },
    env: {
      GH_TOKEN: $t,
      GITHUB_PERSONAL_ACCESS_TOKEN: $t,
      GIT_AUTHOR_NAME: $n,    GIT_AUTHOR_EMAIL: $e,
      GIT_COMMITTER_NAME: $n, GIT_COMMITTER_EMAIL: $e
    }
  }' > "$sl"
  chmod 600 "$sl" 2>/dev/null || true
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

note ""
note "Wrote $collected folder lock(s) to $CONFIG"
note "Wired: per-account gitconfig + includeIf, credential helper, per-folder"
note "settings.local.json (env + guard), and global ~/.claude hooks."
