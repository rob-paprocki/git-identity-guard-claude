#!/usr/bin/env bash
# resolve_account <cwd> -> prints "<account>\t<email>\t<name>" for the locked folder
# whose configured path equals or is a parent of <cwd> (case-insensitive); else nothing.
# Config: $IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json
resolve_account() {
  local cwd_lc cfg
  cwd_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  cfg="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
  [ -f "$cfg" ] || return 0
  # Normalize trailing slashes on BOTH sides: a folders.json path written as "/foo/" must still
  # match cwd "/foo" (and "/foo/sub") — otherwise the lock silently resolves to nothing and the
  # guard fail-OPENs (allows everything) for that tree.
  jq -r --arg c "$cwd_lc" '
    ($c | sub("/+$";"")) as $cc
    | .[] | (.path | ascii_downcase | sub("/+$";"")) as $p
    | select($cc == $p or ($cc | startswith($p + "/")))
    | [.account, .email, .name] | @tsv' "$cfg" 2>/dev/null | head -1
}
