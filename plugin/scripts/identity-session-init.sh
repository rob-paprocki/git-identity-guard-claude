#!/usr/bin/env bash
# SessionStart hook — when a session starts anywhere under a locked workspace, inject a
# reminder of the account lock. This matters most for SUB-DIRECTORY sessions, where the
# folder's CLAUDE.md is not loaded and settings.local.json (the GH_TOKEN/MCP-token env pin)
# may not load — so the agent must be told to relaunch from the folder root for full pinning.
#
# The locked account + the locked tree ROOT for this cwd are resolved from folders.json
# ($IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json) via lib/resolve-account.sh
# — nothing here is hardcoded to any account/path. Defensive: never aborts the session.
payload="$(cat)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
cwd_lc="$(printf '%s' "$cwd" | tr '[:upper:]' '[:lower:]')"

# --- resolve the locked account for this cwd from folders.json ---
INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$INIT_DIR/lib/resolve-account.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib/resolve-account.sh"
IFS=$'\t' read -r LOCKED EMAIL NAME < <(resolve_account "$cwd")
[ -z "${LOCKED:-}" ] && exit 0
# The locked tree ROOT (the matched folders.json .path) — used to detect whether this
# session is at the folder root or in a sub-directory.
IDLOCK_CFG="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
ROOT="$(jq -r --arg c "$cwd_lc" '
  ($c | sub("/+$";"")) as $cc
  | .[] | (.path | ascii_downcase | sub("/+$";"")) as $p
  | select($cc == $p or ($cc | startswith($p + "/")))
  | (.path | sub("/+$";""))' "$IDLOCK_CFG" 2>/dev/null | head -1)"
ROOT_LC="$(printf '%s' "$ROOT" | tr '[:upper:]' '[:lower:]')"

# --- per-session identity pin: make gh / git / MCP work from SUB-DIRECTORIES ---
# Claude Code loads .claude/settings.local.json only from the launch directory, not
# ancestors, so a sub-directory launch never gets the folder-root env pin. Fix it
# here: resolve the locked account's token (same source as the git credential
# helper) and, if available, export it into this session's CLAUDE_ENV_FILE so every
# subsequent Bash command (gh/git) is pinned regardless of where Claude was
# launched. Record the locked ACCOUNT (never the token) in a session pin file the
# guard reads to verify pinning. The pin file is written ONLY after a verified
# env-file append — so "pin present" always implies "really pinned" (fail-closed):
# a resume/compact path with no writable CLAUDE_ENV_FILE writes no pin, and the
# guard then denies rather than letting gh fall back to the active account.
SESS_DIR="${IDENTITY_LOCK_SESSIONS:-${IDENTITY_LOCK_DIR:-$HOME/.config/identity-lock}/sessions}"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
pinned_ok=0
author_pinned=0
ambient_cleared=0
tok="$(gh auth token --user "$LOCKED" 2>/dev/null)"

# Markers are informational breadcrumbs only — they NO LONGER gate whether the pin is (re)written.
# (The old "skip if this account's marker is present" gate had two failures: (H4) the agent could
# pre-seed a forged marker COMMENT line — guard-invisible, no exports — to make the hook skip the
# unset+export so an inherited ambient/foreign identity survived while state was reported "pinned";
# and (H3) on an A->B->A return hop the account-a marker from fire 1 made fire 3 skip re-pinning, so
# account-b's fire-2 exports stayed LAST and won when sourced while the pin file said account-a.)
auth_marker="# identity-lock author pin OK $LOCKED"
tok_marker="# identity-lock pin OK $LOCKED"

# Every env-file line THIS hook manages (for ANY account/value). On each fire we STRIP all prior
# managed lines and re-append a FRESH block for the CURRENT account. That makes the current account's
# exports always LAST (so they win when the file is sourced — fixes H3), keeps exactly one copy
# (idempotent / bounded growth), forces the unset+export to run regardless of any pre-existing/forged
# marker (fixes H4), and lets us derive pin state from THIS fire's actual write, not a marker. It also
# strips any stray/forged ambient `export GIT_AUTHOR_*`/`export GH_TOKEN=` the agent wrote into the
# env-file, so such an override can't shadow the locked pin.
managed_re='^(unset GIT_AUTHOR_NAME |export (GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|GIT_COMMITTER_NAME|GIT_COMMITTER_EMAIL|GH_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN)=|# identity-lock (author )?pin OK )'

# --- strip prior managed lines (best-effort, atomic; NEVER corrupt the env-file on failure) ---
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
  tmp_ef="$CLAUDE_ENV_FILE.idlock.$$"
  grep -Ev "$managed_re" "$CLAUDE_ENV_FILE" > "$tmp_ef" 2>/dev/null
  # grep exit 0 = some lines kept, 1 = ALL lines were managed (kept none) — BOTH are success here;
  # only 2 = a real read error (e.g. unwritable/unreadable env-file), in which case leave it untouched.
  if [ "$?" -le 1 ]; then
    mv "$tmp_ef" "$CLAUDE_ENV_FILE" 2>/dev/null || rm -f "$tmp_ef" 2>/dev/null
  else
    rm -f "$tmp_ef" 2>/dev/null
  fi
fi

# --- (a) commit author/committer pin — TOKEN-INDEPENDENT (needs only $NAME/$EMAIL) ---
# Appended UNCONDITIONALLY (no marker gate): clears any inherited ambient GIT_AUTHOR_*/GIT_COMMITTER_*
# first (env beats the per-folder gitconfig [user] pin, so an ambient identity would otherwise author
# commits under a FOREIGN account while push still succeeds), then exports the locked author. State is
# set from whether THIS append succeeded — a failed append leaves author_pinned=0 (honest note).
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if {
       printf 'unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL\n'
       if [ -n "$NAME" ] && [ -n "$EMAIL" ]; then
         printf 'export GIT_AUTHOR_NAME=%q\n'     "$NAME"
         printf 'export GIT_AUTHOR_EMAIL=%q\n'    "$EMAIL"
         printf 'export GIT_COMMITTER_NAME=%q\n'  "$NAME"
         printf 'export GIT_COMMITTER_EMAIL=%q\n' "$EMAIL"
       fi
       printf '%s\n' "$auth_marker"
     } >> "$CLAUDE_ENV_FILE" 2>/dev/null; then
    ambient_cleared=1
    [ -n "$NAME" ] && [ -n "$EMAIL" ] && author_pinned=1
  fi
fi

# --- (b) gh / GitHub-MCP token pin — TOKEN-DEPENDENT ---
# Appended AFTER (a), only when the locked account's token is available. The session pin file the guard
# trusts is written ONLY when the token export was durably appended THIS fire (so "pin present" implies
# "really pinned to THIS account"). Both exports + pin file move to the current account together.
if [ -n "$tok" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if {
       printf 'export GH_TOKEN=%q\n'                     "$tok"
       printf 'export GITHUB_PERSONAL_ACCESS_TOKEN=%q\n' "$tok"
       printf '%s\n' "$tok_marker"
     } >> "$CLAUDE_ENV_FILE" 2>/dev/null; then
    if [ -n "$sid" ] && mkdir -p "$SESS_DIR" 2>/dev/null && printf '%s\n' "$LOCKED" > "$SESS_DIR/$sid" 2>/dev/null; then
      chmod 600 "$SESS_DIR/$sid" 2>/dev/null; pinned_ok=1
    fi
    find "$SESS_DIR" -type f -mtime +7 -delete 2>/dev/null   # prune stale pins (best-effort)
  fi
fi

subdir_note=""
if [ "$cwd_lc" != "$ROOT_LC" ]; then
  if [ "$author_pinned" = 1 ]; then author_txt="commit author is pinned to $LOCKED"
  else                              author_txt="commit author is NOT pinned here"; fi
  if [ "$pinned_ok" = 1 ]; then
    # token present => the push credential helper (which calls gh auth token --user $LOCKED)
    # resolves too, so push is pinned here as well.
    subdir_note=" SUB-DIRECTORY launch: gh + GitHub-MCP + git push are session-pinned to $LOCKED here, and $author_txt — so you can work normally. Do NOT 'cd' into a DIFFERENT locked tree mid-session — that stays blocked; relaunch Claude there instead."
  elif [ "$author_pinned" = 1 ]; then
    # No token => gh, MCP AND git push are all unpinned (the push credential helper needs the
    # same token). Only the commit author is pinned (it is token-independent).
    subdir_note=" SUB-DIRECTORY launch: $author_txt, but the $LOCKED token is unavailable, so gh, GitHub-MCP and git push are NOT pinned here (the push credential helper needs that token). Commits stay correctly authored; run 'gh auth login --user $LOCKED' (or relaunch Claude from $ROOT) before pushing."
  elif [ "$ambient_cleared" = 1 ]; then
    # Author block ran (ambient cleared) but no locked name/email to export: git falls back to
    # the per-folder gitconfig [user] pin rather than any inherited foreign identity.
    subdir_note=" SUB-DIRECTORY launch: this lock has no name/email configured, so commit author is NOT pinned here — the inherited ambient identity was cleared and git falls back to the gitconfig [user] pin. gh/MCP/push are not pinned. Relaunch Claude from $ROOT, or add name/email to this lock's folders.json entry."
  else
    # No writable session env-file (absent OR unwritable): nothing was cleared, so any inherited
    # ambient identity is STILL ACTIVE and would author commits. Fail loud — do not commit.
    subdir_note=" SUB-DIRECTORY launch: identity could NOT be session-pinned here (no writable session env-file), so commit author is NOT guaranteed and any inherited ambient identity is STILL ACTIVE — do NOT commit. Relaunch Claude from $ROOT, or run 'gh auth login --user $LOCKED', for full coverage."
  fi
fi

jq -n --arg a "$LOCKED" --arg n "$subdir_note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("GitHub identity for this workspace is LOCKED to \($a). Every git / gh / GitHub-MCP action MUST be performed as \($a). Identity is pinned by default (settings env GH_TOKEN + GIT_AUTHOR_*, the per-folder git credential helper, and the MCP token) and a deny-only PreToolUse guard blocks attempts to override it. Do NOT switch accounts, set/override GH_TOKEN or GIT_AUTHOR_*, or rewrite git credential config." + $n)
  }
}' 2>/dev/null
