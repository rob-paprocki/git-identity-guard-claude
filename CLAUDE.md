# git-identity-guard-claude — project memory

Pins every git / gh / GitHub-MCP action under a locked folder to a configured account, via layered
env + gitconfig + credential-helper pins and a deny-only PreToolUse guard. See `README.md`, `ROADMAP.md`,
`identity-guard.sh`, `identity-session-init.sh`, `install.sh`.

> **Anonymization rule (binding for all committed files):** never put real GitHub handles, numeric-ID
> emails, machine paths, or tokens in tracked files — use placeholders (`account-a`,
> `/path/to/folder-a`, `NNNN+account-a@users.noreply.github.com`). See `CONTRIBUTING.md`. This file obeys it.

## ⚠️ PRIORITY PATCH — open bug: a sub-directory launch can commit under the WRONG author

**Patch this first thing next time you launch here.** A real cross-project author leak happened
(2026-06): a worktree / sub-directory Claude launch in a locked repo authored ~21 commits under an
**unrelated ambient identity** — the git author/committer values inherited from the launching shell
(another project's bot, exported in that shell). The wrong author still reached the remote because
**push auth (credential helper) is independent of commit author**, and it was invisible in the session
transcript because the identity was ambient env, never a typed command.

**Root cause — `identity-session-init.sh` (the SessionStart pin):** the env-file lines that pin the git
author/committer (the `printf 'export GIT_AUTHOR_…'` / `GIT_COMMITTER_…` block) live INSIDE the block
guarded by `if [ -n "$tok" ] && [ -n "$CLAUDE_ENV_FILE" ]`, where `tok="$(gh auth token --user "$LOCKED")"`.
If the locked account is not logged into `gh` in that session (or the token is otherwise unavailable),
`tok` is empty → the **entire block is skipped** → the author/committer pin is **never written** — even
though it needs only the already-resolved `$NAME` / `$EMAIL`, not the token. The session then inherits the
launching shell's author identity. Worse, the sub-directory fallback note still tells the agent
"git push and commit author **still** [pinned]" — false in this path.

**The fix:**
1. **Decouple the author/committer pin from the token gate.** When `CLAUDE_ENV_FILE` is set, ALWAYS write
   the author/committer exports from the resolved `$NAME` / `$EMAIL` (token-independent). Gate ONLY the
   token exports (`GH_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN`) on `$tok`.
2. Add an `unset` of any inherited author/committer vars (or unconditional overwrite-export) as defense
   against an ambient identity, and correct the fallback note so it never claims author pinning that did
   not happen.
3. **Test:** a sub-directory launch with NO available account token must STILL pin the commit author.
4. (Belt-and-suspenders) optionally also pin the locked author at the repo-local `[user]` level — but note
   env overrides config, so #1 is the real fix.

Full write-up: `ROADMAP.md` → "Known bug (priority to patch)".

## Conventions
- Identity here is itself locked to the owner account — commit only as the pinned account.
- Keep `README.md` / `ROADMAP.md` / threat-model claims in sync when you touch the pin mechanism.
