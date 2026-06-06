#!/usr/bin/env bash
# Test harness for identity-session-init.sh (SessionStart reminder).
# The hook injects an additionalContext reminder when cwd is inside a locked
# folder, adds a SUB-DIRECTORY warning when cwd is a sub-dir (not the root), and
# emits nothing outside the tree.
#
# Parameterized: runs entirely against mktemp fixtures + a fixture folders.json.
# No real paths / handles / tokens / emails appear here. This hook never calls
# gh, so no stub is needed.
set -u
INIT="$(cd "$(dirname "$0")/.." && pwd)/identity-session-init.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A="$TMP/folder-a"; B="$TMP/folder-b"; mkdir -p "$A" "$B"
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"},
  {"path":"$B","account":"account-b","name":"Account B","email":"b@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"

pass=0; fail=0
run() { jq -n --arg c "$1" '{cwd:$c}' | bash "$INIT" 2>/dev/null; }

# matches: name expr cwd  -> out must satisfy `jq -e <expr>`
matches() { local name="$1" expr="$2" cwd="$3" out
  out="$(run "$cwd")"
  if printf '%s' "$out" | jq -e "$expr" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s :: out=[%s]\n' "$name" "$out"
  fi
}
# empty: name cwd -> out must be empty
empty() { local name="$1" cwd="$2" out
  out="$(run "$cwd")"
  if [ -z "$out" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL  %s :: out=[%s]\n' "$name" "$out"; fi
}

ctx='.hookSpecificOutput.additionalContext'
matches "root: names account, no subdir warning" \
  "($ctx | test(\"account-a\")) and ($ctx | test(\"SUB-DIRECTORY\") | not)" "$A"
matches "subdir: names account AND subdir warning" \
  "($ctx | test(\"account-a\")) and ($ctx | test(\"SUB-DIRECTORY\"))" "$A/sub/deep"
matches "subdir warning references the locked root path" \
  "$ctx | test(\"$A\")" "$A/sub"
matches "second folder resolves to account-b" \
  "$ctx | test(\"account-b\")" "$B"
matches "hookEventName is SessionStart" \
  '.hookSpecificOutput.hookEventName=="SessionStart"' "$A"
empty "outside the tree -> empty" "$TMP/elsewhere"

echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
