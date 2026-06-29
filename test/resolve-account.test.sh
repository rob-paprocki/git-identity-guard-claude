#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib/resolve-account.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/folders.json" <<EOF
[ {"path":"$tmp/folder-a","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"},
  {"path":"$tmp/folder-b","account":"account-b","name":"Account B","email":"b@users.noreply.github.com"},
  {"path":"$tmp/folder-c/","account":"account-c","name":"Account C","email":"c@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$tmp/folders.json"
pass=0; fail=0
check(){ local got; got="$(resolve_account "$1")"; [ "$got" = "$2" ] && { pass=$((pass+1)); echo "  PASS $3"; } || { fail=$((fail+1)); echo "  FAIL $3 :: got=[$got] want=[$2]"; }; }
check "$tmp/folder-a"            $'account-a\ta@users.noreply.github.com\tAccount A' "exact path"
check "$tmp/folder-a/sub/deep"   $'account-a\ta@users.noreply.github.com\tAccount A' "subdir"
check "$(echo "$tmp/folder-a" | tr a-z A-Z)" $'account-a\ta@users.noreply.github.com\tAccount A' "case-insensitive"
check "$tmp/folder-b"            $'account-b\tb@users.noreply.github.com\tAccount B' "second folder"
check "$tmp/elsewhere"           ""                                                  "outside -> empty"
# A folders.json path with a TRAILING SLASH must still resolve (else the lock fail-OPENs).
check "$tmp/folder-c"            $'account-c\tc@users.noreply.github.com\tAccount C'  "trailing-slash path: exact"
check "$tmp/folder-c/sub/deep"   $'account-c\tc@users.noreply.github.com\tAccount C'  "trailing-slash path: subdir"
echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
