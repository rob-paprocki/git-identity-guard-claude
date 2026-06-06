#!/usr/bin/env bash
# resolve_account <cwd> -> prints "<account>\t<email>\t<name>" for the locked folder
# whose configured path equals or is a parent of <cwd> (case-insensitive); else nothing.
# Config: $IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json
resolve_account() {
  local cwd_lc cfg
  cwd_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  cfg="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
  [ -f "$cfg" ] || return 0
  jq -r --arg c "$cwd_lc" '
    .[] | (.path | ascii_downcase) as $p
    | select($c == $p or ($c | startswith($p + "/")))
    | [.account, .email, .name] | @tsv' "$cfg" 2>/dev/null | head -1
}
