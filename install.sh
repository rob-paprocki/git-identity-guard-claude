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

CONFIG_DIR="${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}"
CONFIG="${IDENTITY_LOCK_CONFIG:-$CONFIG_DIR/folders.json}"

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
  note "  locked $path -> $account"
done

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
note "(Task 4: config only. Run later install steps to wire git/credential/hook layers.)"
