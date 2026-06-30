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
# target fixed UPPERCASE variable names / fixed git flags. Common in-band obfuscations of a name that
# bash collapses back (quote-splitting `GH""_TOKEN`, backslash `GH\_TOKEN`, brace `GH{A,_}TOKEN`,
# `$`-expansion `${v}`) are EXPLICITLY caught (rules 1/1b/1d). A determined arbitrary-code interpreter can
# still build a name no command-string regex can see — that is the documented residual floor (see below).
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
  ($c | sub("/+$";"")) as $cc
  | .[] | (.path | ascii_downcase | sub("/+$";"")) as $p
  | select($cc == $p or ($cc | startswith($p + "/")))
  | (.path | sub("/+$";""))' "$IDLOCK_CFG" 2>/dev/null | head -1)"
ROOT_LC="$(printf '%s' "$ROOT" | tr '[:upper:]' '[:lower:]')"
# Regex-escape ROOT_LC before it is spliced into the -C in-tree exception grep (rule 4): an unescaped
# metacharacter in a configured lock path (a '.' in 'v1.2'/'.claude', '+', '[', '(', …) would widen the
# match so an outside sibling ('v1X2') is treated as in-tree — or, if unbalanced, break the ERE and
# wrongly DENY legit in-tree work. Escape every non-[alnum _ / -] char. (L1.)
ROOT_LC_RE="$(printf '%s' "$ROOT_LC" | sed 's/[^A-Za-z0-9_/-]/\\&/g')"

deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

# ===================== GitHub MCP tools =====================
case "$tool" in
  mcp__github__*|mcp__plugin_github_github__*|mcp__*github*__*)
    # The NAMESPACE determines where the connection token comes from, which determines how we verify it:
    #   override (mcp__github__*)        — supplied LIVE at connect by the headersHelper
    #                                      (gh auth token --user $LOCKED); the env var is NOT used.
    #   plugin   (mcp__plugin_github_github__*) — the static env GITHUB_PERSONAL_ACCESS_TOKEN.
    #   other    (any other mcp__…github…__) — a separately-configured github MCP server (Enterprise,
    #                                      copilot, …); token source unknown, so verify strictly (fail-closed).
    # Matching the broader 'other' namespace closes a fail-OPEN: previously such a server skipped the guard
    # entirely. (The hook MATCHER in settings must also be widened — install.sh does this; pre-existing
    # installs must re-run install.sh to guard non-standard github namespaces.)
    case "$tool" in
      mcp__github__*)               ns=override; action="${tool#mcp__github__}" ;;
      mcp__plugin_github_github__*) ns=plugin;   action="${tool#mcp__plugin_github_github__}" ;;
      *)                            ns=other;    action="${tool##*__}" ;;
    esac
    # READ-ALLOWLIST (default-deny): only get/list/search and the two *_read read tools are reads; EVERY
    # other tool name is treated as a WRITE and token-checked. The previous verb-allowlist let writes whose
    # verb wasn't enumerated (assign_/mark_/dismiss_/manage_/run_secret_scanning — even a future renamed
    # write) through as "reads". NOTE 'mark_all_notifications_read' is a WRITE despite the _read suffix, so
    # the read test anchors on issue_read/pull_request_read exactly, never a _read$ suffix.
    if ! printf '%s' "$action" | grep -Eq '^(get|list|search)|^(issue_read|pull_request_read)$'; then
      want="$(gh auth token --user "$LOCKED" 2>/dev/null)"
      [ -z "$want" ] && deny "Identity guard: GitHub MCP write '$tool' blocked — the $LOCKED account isn't available (run 'gh auth login --user $LOCKED')."
      have="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
      if [ -n "$have" ]; then
        [ "$have" = "$want" ] && exit 0
        # override namespace: the connection token is ALWAYS the live $LOCKED token from the headersHelper,
        # so a baked/rotated/foreign env GITHUB_PERSONAL_ACCESS_TOKEN is irrelevant — the write still acts
        # as $LOCKED. (Denying here was a false-positive DoS after a `gh auth refresh`/re-login.)
        [ "$ns" = override ] && exit 0
        deny "Identity guard: GitHub MCP write '$tool' would act as a non-$LOCKED account (MCP token != $LOCKED)."
      fi
      # Sub-directory launch: the MCP token is supplied at connect by the headersHelper override and is NOT
      # in this hook's env. Verify pinning via the session pin file.
      [ "$(session_pin)" = "$LOCKED" ] && exit 0
      deny "Identity guard: GitHub MCP write '$tool' is not provably pinned to $LOCKED (no session pin — a sub-directory launch without the MCP override, or a cross-tree cd). Relaunch Claude from $ROOT, or use the gh CLI."
    fi
    exit 0 ;;
esac

# ===================== Bash =====================
[ "$tool" = "Bash" ] || exit 0
cmd="$(jqr '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0
# Collapse bash line-continuations (backslash immediately before a newline) into one logical line, so
# the line-oriented greps below see what bash will actually RUN. Otherwise a continuation splits tokens
# across grep lines while bash joins them — e.g. `git \<NL>-C /outside` or
# `git remote add origin \<NL>git@host:repo` would evade the segment-scoped rules. Bare newlines are
# LEFT intact: they are genuine command separators (like ';') and grep already treats them per-line.
nl=$'\n'
cmd="${cmd//\\$nl/}"
has()  { printf '%s' "$cmd" | grep -Eq  -- "$1"; }
hasi() { printf '%s' "$cmd" | grep -Eqi -- "$1"; }   # case-insensitive (git config keys / macOS paths)

# Pinned / sensitive variable names. Assignment or override of any of these could
# re-point identity (tokens, git author) or inject code (BASH_ENV, LD_PRELOAD, …).
PV='(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GH_HOST|GH_CONFIG_DIR|GITHUB_PERSONAL_ACCESS_TOKEN|GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|GIT_COMMITTER_NAME|GIT_COMMITTER_EMAIL|GIT_CONFIG[A-Z0-9_]*|GIT_SSH[A-Z0-9_]*|GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_PROXY_COMMAND|GIT_EXTERNAL_DIFF|HOME|XDG_CONFIG_HOME|BASH_ENV|PROMPT_COMMAND|PS4|LD_PRELOAD|DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH)'
# NOTE: the POSIX-sh startup var `ENV` was intentionally REMOVED from PV: as a bare 3-letter token it
# matched ubiquitous, identity-irrelevant build/CI invocations (`make ENV=prod`, `docker run -e ENV=…`,
# `terraform -var ENV=…`, `printenv ENV`) and wrongly DENIED them. BASH_ENV (the bash analog) stays.
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

# 1d) An assignment NAME built by ANY in-band obfuscation that bash collapses back into a pinned name —
#     brace expansion (`GH{A,_}TOKEN`), OR quote/backslash splitting that quote-removal rebuilds
#     (`GH""_TOKEN`, `GH''_TOKEN`, `GH\_TOKEN`, mid-name `GIT_AUTHOR""_NAME`) — sets the real variable with
#     NO literal substring and NO '$', so it evades rule 1 (literal name) AND rule 1b ('$'-built names).
#     Deny any export/declare/typeset/readonly/local/env whose name-token (the part BEFORE '=') contains a
#     '{', a quote, or a backslash. A brace/quote/backslash in the VALUE (after '=', e.g. `export P=/x/{a,b}`
#     or `export G="hi there"`) is NOT matched — the name-token class [^=…] stops at the '='. (The bare-prefix
#     form `GH""_TOKEN=v cmd` is not recognized as a bash assignment-prefix, so only these builtins set it.)
has '\b(export|declare|typeset|readonly|local)\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^=;|&[:space:]]*([{"'\'']|\\)' && \
  deny "Identity guard: refusing an obfuscated (brace/quote/backslash) variable-NAME assignment in the $LOCKED workspace — the name could rebuild a pinned identity variable. Use a literal NAME=value (non-identity)."
has '\benv\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^=;|&[:space:]]*([{"'\'']|\\)' && \
  deny "Identity guard: refusing 'env' with an obfuscated (brace/quote/backslash) variable name in the $LOCKED workspace."
# Same obfuscation in a printf -v / read / mapfile TARGET name (no '=' there). Require a WORD char
# immediately before the brace/quote/backslash so an embedded-name char (`read GH""_TOKEN`) is caught
# while a leading-quote ARGUMENT (a prompt: `read -p "Continue? " ans`) is not a false positive.
has '\b(printf[[:space:]]+-v|read|mapfile|readarray)\b[[:space:]]+(-[-A-Za-z]+[[:space:]]+)*[^;|&[:space:]]*[A-Za-z0-9_]([{"'\'']|\\)' && \
  deny "Identity guard: refusing an obfuscated (brace/quote/backslash) 'printf -v'/'read'/'mapfile' target name in the $LOCKED workspace."

# 1c) source/. of a file can set identity overrides the guard can't inspect. The plain form is anchored
#     to a segment start; the second check also catches a leading 'command'/'builtin'/'time' or a
#     VAR=value assignment-prefix (`command source x`, `builtin . x`, `time source x`, `FOO=1 source x`),
#     all of which run the source/. builtin in the CURRENT shell just like a bare `source`.
has '(^|[;&|({]|&&|\|\|)[[:space:]]*(source|\.)[[:space:]]' && \
  deny "Identity guard: 'source'/'.' of a file is blocked in the $LOCKED workspace (it could set identity overrides off-screen). Inline the commands instead."
has '(^|[;&|({]|&&|\|\|)[[:space:]]*(command|builtin|time|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*)[[:space:]]+(source|\.)[[:space:]]' && \
  deny "Identity guard: 'source'/'.' (via command/builtin/time/assignment-prefix) is blocked in the $LOCKED workspace (it could set identity overrides off-screen). Inline the commands instead."

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
# credential-helper pin only apply under the locked folder ROOT, so an outside target acts as another
# account. --git-dir/--work-tree are git-ONLY flags (enforced anywhere); -C is SHARED (make/tar use it),
# so the -C form is enforced only when 'git' precedes it in the SAME command segment ([^;&|]*) — a plain
# 'make -C /x', a 'tar -C /var/git/data', or a 'git …' chained with an unrelated 'make -C /x' is NOT
# denied. Trigger on an absolute (/) or home (~) path, OR ANY '..' path component (leading or mid-token,
# so ./../x, foo/../../x, ../x all count); an in-tree relative path (sub, ./sub, sub/dir) has none and
# stays allowed. Separators accept '=' or one-or-more spaces (a two-space form can't slip past). Quoted,
# $-expanded, or symlink paths are the documented quote-splitting / dynamic-construction residual.
if has '\bgit\b[^;&|]*-C[[:space:]]+(/|~)' \
   || has '\bgit\b[^;&|]*-C[[:space:]]+([^[:space:]]*/)?\.\.(/|[[:space:]]|$)' \
   || has '(--git-dir|--work-tree)[[:space:]=]+(/|~)' \
   || has '(--git-dir|--work-tree)[[:space:]=]+([^[:space:]]*/)?\.\.(/|[[:space:]]|$)'; then
  printf '%s' "$cmd" | grep -Eqi -- "(-C[[:space:]]+|--git-dir[[:space:]=]+|--work-tree[[:space:]=]+)${ROOT_LC_RE}(/|[[:space:]]|\$)" \
    || deny "Identity guard: 'git -C/--git-dir/--work-tree' targeting a path outside the locked folder ($ROOT), or any path with a '..' component, is blocked (the identity pin only applies under that tree)."
fi

# 5) gh: explicit auth-header / hostname override, token login, logout.
# Header NAMES are case-insensitive (HTTP), so match 'authorization' case-insensitively (an UPPERCASE
# or mixed-case header evades a first-letter-only [Aa] match). Allow global flags between 'gh' and 'api'
# (`gh --verbose api …`) so adjacency can't be used to dodge the rule.
if has '\bgh[[:space:]]+(-[^[:space:]]*[[:space:]]+)*api\b' && has '(-H|--header)' && hasi 'authorization'; then
  deny "Identity guard: 'gh api' with an explicit Authorization header is blocked in the $LOCKED workspace (it would act as another account)."
fi
has '\bgh[[:space:]]+api\b[^;&|]*--hostname' && \
  deny "Identity guard: 'gh api --hostname' is blocked in the $LOCKED workspace."
has '\bgh[[:space:]]+auth[[:space:]]+login\b[^;&|]*--with-token' && \
  deny "Identity guard: 'gh auth login --with-token' is blocked in the $LOCKED workspace."
has '\bgh[[:space:]]+auth[[:space:]]+logout\b' && \
  deny "Identity guard: 'gh auth logout' is blocked in the $LOCKED workspace (it would break the pinned git credential helper)."
has '\bgh[[:space:]]+auth[[:space:]]+setup-git\b' && \
  deny "Identity guard: 'gh auth setup-git' writes a git credential helper into your gitconfig (it can shadow the per-folder pinned helper); blocked in the $LOCKED workspace — push is already pinned."

# 6) push (or 'send-pack', the push plumbing that carries no 'push' word) over SSH/scp, or with an
# embedded-credential URL. Each check is SEGMENT-SCOPED to the push/send-pack command ([^;&|]*) so a
# host:port token in an unrelated later segment (a comment, an echo) is NOT a false positive. The scp
# host detector mirrors rule 6b: a dotless alias, an IP, or a 1-char TLD all count (the old
# '\.[A-Za-z]{2,}:' required a dotted host and let `server:` / `10.0.0.1:` / `h.x:` slip). https:// never
# matches it (its ':' is followed by '//', and the host after '//' is not space-anchored). The
# embedded-credential check matches ANY userinfo (`//token@` with no colon, as well as `//user:pass@`)
# and is case-insensitive (a `HTTPS://` scheme evaded the lowercase-only form).
if has '\b(push|send-pack)\b'; then
  hasi '\b(push|send-pack)\b[^;&|]*(git@|ssh://)' && \
    deny "Identity guard: SSH-remote push can't be identity-pinned to $LOCKED. Use an https:// remote."
  has '\b(push|send-pack)\b[^;&|]*[[:space:]]([A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+:/?[^/[:space:]]' && \
    deny "Identity guard: scp-style remote push can't be identity-pinned to $LOCKED. Use an https:// remote."
  hasi '\b(push|send-pack)\b[^;&|]*https?://[^/[:space:]]*@' && \
    deny "Identity guard: refusing a push URL with embedded credentials in the $LOCKED workspace."
fi

# 6b) git remote add / set-url to an SSH/scp remote. The credential-helper pin is HTTPS-only, so a push
# over an SSH remote authenticates with the loaded SSH key, NOT the locked account. Refuse to CREATE such
# a remote. Gate tightly on the 'remote add' / 'remote set-url' SUBCOMMAND (not a stray 'add' word in,
# say, a commit message). Detect ssh:// or a scp-style host:path token. Note an scp token (host:path,
# host:/path, user@host:path, dotless alias, or IP) has NO '://' — so https remotes, including
# https://user@host and https://host:443, never match (the ':' there is followed by '//'). A repo CLONED
# over SSH before the session keeps an SSH origin the guard cannot pin — see README "Threat model".
if has '\bgit\b[^;&|]*\bremote[[:space:]]+(add|set-url)\b'; then
  # Detect the ssh:// or scp-style URL only within the SAME segment as the subcommand ([^;&|]*), so a
  # chained 'remote add … https://… && npm run build:prod' isn't tripped by the later 'build:prod'.
  { has 'remote[[:space:]]+(add|set-url)[^;&|]*ssh://' \
    || has 'remote[[:space:]]+(add|set-url)[^;&|]*[[:space:]]([A-Za-z0-9_.-]+@)?[A-Za-z0-9_.-]+:/?[^/[:space:]]'; } && \
    deny "Identity guard: setting an SSH/scp git remote is blocked in the $LOCKED workspace — SSH pushes can't be identity-pinned to $LOCKED. Use an https:// remote."
fi

# 7) Direct writes to a git config file (redirection / tee / sed -i / cp / mv …) — bypasses 'git config'.
if hasi '(\.git/config\b|/gitconfig\b|\.gitconfig\b|/\.config/git/)'; then
  has '(>|[[:space:]]tee\b|sed[[:space:]]+-i|\b(cp|mv|ln|dd|install|truncate)\b)' && \
    deny "Identity guard: writing/replacing a git config file is blocked in the $LOCKED workspace."
fi

# 7b) Direct writes/deletes to the guard's OWN trust anchors — the lock config dir
# (~/.config/identity-lock/, incl. folders.json and the session pin files) and the installed hook scripts
# (~/.claude/hooks/, incl. identity-guard.sh / identity-session-init.sh / lib/resolve-account.sh /
# mcp-github-headers.sh). Removing or corrupting folders.json makes resolve_account return empty and the
# guard fail-OPEN (exit 0) for every subsequent command; clobbering a hook script disables enforcement
# outright. Rule 7 covered git-config files but not these. Reads (cat/grep/ls) stay allowed — only
# mutating verbs are blocked. (Exotic deletions — xargs rm, find -delete — are a documented residual.)
if hasi '(/\.config/identity-lock|/\.claude/hooks)'; then
  { has '(^|[;&|]|&&|\|\|)[[:space:]]*(rm|unlink|shred)\b' \
    || has '(>|[[:space:]]tee\b|sed[[:space:]]+-i|\b(cp|mv|ln|dd|install|truncate|chmod|chown)\b)'; } && \
    deny "Identity guard: modifying or deleting the guard's own policy files / hook scripts is blocked in the $LOCKED workspace."
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
  # 'gh auth switch'/'refresh' MUTATE which account gh acts as — NOT read-exempt. In an unpinned tree
  # (no GH_TOKEN, no session pin) they must fail-closed like any other real gh write. (setup-git is denied
  # outright above; at a pinned root these are harmless because GH_TOKEN overrides the active account.)
  has '\bgh[[:space:]]+auth[[:space:]]+(switch|refresh)\b' && gh_real=1
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
