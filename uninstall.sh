#!/usr/bin/env bash
# uninstall.sh — reverse what install.sh wired, idempotently.
#
# Reads ~/.config/identity-lock/folders.json FIRST (it's the record of every path
# and account we touched), then for each locked folder undoes the four pinning
# layers and finally the global ~/.claude wiring + the config itself:
#   1. ~/.gitconfig          : drop the `includeIf.gitdir/i:<path>/` section
#   2. <path>/.claude/settings.local.json : remove (install owns the whole file)
#   3. ~/.claude/settings.json: filter out our SessionStart + PreToolUse hooks
#   4. folders.json          : remove the entries (file emptied/removed)
# Per-account gitconfig files (~/.config/git/<account>.gitconfig) are LEFT IN PLACE
# by default — they hold the user's identity + helper and may predate us. Pass
# --purge to also delete them.
#
# Defensive bash: NO `set -e` — a missing config or already-clean state must exit
# 0, not abort. Idempotent: a second run with the config gone is a clean no-op.
set -u

CONFIG_DIR="${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}"
CONFIG="${IDENTITY_LOCK_CONFIG:-$CONFIG_DIR/folders.json}"
HOOKS_DIR="$HOME/.claude/hooks"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
GITCONFIG="$HOME/.gitconfig"

SCRIPTED=0   # accepted for symmetry with install.sh; uninstall takes no stdin
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive|--non-interactive-from-stdin) SCRIPTED=1 ;;
    --purge) PURGE=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: uninstall.sh [--non-interactive] [--purge]

Reverses install.sh: removes the ~/.gitconfig includeIf lines, each locked
folder's .claude/settings.local.json, the global ~/.claude/settings.json hook
wiring, and the entries in ~/.config/identity-lock/folders.json.

By default the per-account gitconfig files (~/.config/git/<account>.gitconfig)
are left untouched. Pass --purge to delete them too.
USAGE
      exit 0 ;;
  esac
done

err()  { printf 'uninstall: %s\n' "$*" >&2; }
note() { [ "$SCRIPTED" = 1 ] || printf '%s\n' "$*"; }

# unwire_global: strip our SessionStart + PreToolUse hooks from the global
# ~/.claude/settings.json, leaving any unrelated user hooks intact. Idempotent —
# a no-op when the file is absent or already clean. Removes empty hook arrays so a
# fully-cleaned file ends up as `{}` (or just `{"hooks":{}}`).
unwire_global() {
  [ -f "$GLOBAL_SETTINGS" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local merged
  # Use `any(...)` so an entry is tested once as a whole — a pre-existing user
  # entry with multiple hooks is preserved (not duplicated) when only some match.
  merged="$(jq '
    if .hooks then
      .hooks.SessionStart = [ (.hooks.SessionStart // [])[]
        | select(any((.hooks // [])[]?.command // ""; test("identity-session-init.sh")) | not) ]
      | .hooks.PreToolUse = [ (.hooks.PreToolUse // [])[]
        | select(any((.hooks // [])[]?.command // ""; test("identity-guard.sh")) | not) ]
      | (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end)
      | (if (.hooks.PreToolUse   | length) == 0 then del(.hooks.PreToolUse)   else . end)
    else . end' "$GLOBAL_SETTINGS" 2>/dev/null)"
  [ -n "$merged" ] && printf '%s\n' "$merged" > "$GLOBAL_SETTINGS"
}

# Nothing to do if the config is absent: clean no-op (idempotent second run).
if [ ! -f "$CONFIG" ]; then
  note "No config at $CONFIG; nothing to uninstall."
  # Still scrub the global hook wiring in case the config was removed manually.
  unwire_global
  exit 0
fi

# --- read the config first (paths + accounts we wired) -------------------------
# Newline-separated "<path>\t<account>" rows; tolerate a malformed/empty file.
rows=""
if command -v jq >/dev/null 2>&1; then
  rows="$(jq -r '.[]? | [.path, .account] | @tsv' "$CONFIG" 2>/dev/null)"
fi

removed=0
while IFS=$'\t' read -r path account; do
  [ -z "${path:-}" ] && continue

  # 1. ~/.gitconfig includeIf section (exact key install wrote: gitdir/i:<path>/).
  if [ -f "$GITCONFIG" ]; then
    git config -f "$GITCONFIG" --remove-section "includeIf.gitdir/i:$path/" 2>/dev/null
  fi

  # 2. per-folder settings.local.json — install owns the whole file, so remove it
  #    (and prune an empty .claude dir we may have created).
  sl="$path/.claude/settings.local.json"
  if [ -f "$sl" ]; then
    rm -f "$sl"
    rmdir "$path/.claude" 2>/dev/null || true
  fi

  # 3. --purge: drop the per-account gitconfig too (default: keep it).
  if [ "$PURGE" = 1 ] && [ -n "${account:-}" ]; then
    rm -f "$HOME/.config/git/$account.gitconfig" 2>/dev/null
  fi

  removed=$((removed+1))
  note "  unlocked $path${account:+ ($account)}"
done <<EOF
$rows
EOF

# 4. global ~/.claude/settings.json hook wiring (guard + session-init).
unwire_global

# 5. clear folders.json (remove the file so a second run is a clean no-op).
rm -f "$CONFIG" 2>/dev/null

note ""
note "=== git-identity-guard: uninstall summary ==="
note "Unlocked $removed folder(s); removed $CONFIG"
note "Removed: ~/.gitconfig includeIf lines, per-folder settings.local.json,"
note "global ~/.claude hook wiring."
if [ "$PURGE" = 1 ]; then
  note "Purged : per-account ~/.config/git/<account>.gitconfig files."
else
  note "Kept   : per-account ~/.config/git/<account>.gitconfig files (use --purge to drop)."
fi
note "Note   : the copied hook scripts under ~/.claude/hooks/ are left in place;"
note "         delete them by hand if no other tool uses them."
