# git-identity-guard-claude — project memory

Pins every git / gh / GitHub-MCP action under a locked folder to a configured account, via layered
env + gitconfig + credential-helper pins and a deny-only PreToolUse guard. See `README.md`, `ROADMAP.md`,
`identity-guard.sh`, `identity-session-init.sh`, `install.sh`.

> **Anonymization rule (binding for all committed files):** never put real GitHub handles, numeric-ID
> emails, machine paths, or tokens in tracked files — use placeholders (`account-a`,
> `/path/to/folder-a`, `NNNN+account-a@users.noreply.github.com`). See `CONTRIBUTING.md`. This file obeys it.

## ✅ FIXED: sub-directory author-pin leak (priority patch, 2026-06)

A real cross-project author leak (2026-06): a worktree / sub-directory launch in a locked repo authored
~21 commits under an **unrelated ambient identity** — `identity-session-init.sh` kept the git
author/committer pin INSIDE the `if [ -n "$tok" ] && [ -n "$CLAUDE_ENV_FILE" ]` token gate, so when the
locked account wasn't logged into `gh` the **whole block (author pin included) was skipped**, the session
inherited the launching shell's `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, and the wrong author still reached the
remote because **push auth (credential helper) is independent of commit author**. Invisible in the
transcript (ambient env, never a typed command).

**Fix (shipped):** the author/committer pin is now written **unconditionally** when `CLAUDE_ENV_FILE` is
set (token-independent — needs only `$NAME`/`$EMAIL`), with its **own** idempotency marker separate from
the token marker; any inherited ambient author/committer is `unset` first; the gh/MCP token pin **and**
the session pin file the guard trusts stay gated on `$tok` (so the guard never green-lights gh/MCP that
was never pinned); both markers are **account-scoped**, so a resume/re-fire resolving a *different*
locked account on a reused env-file re-pins (author + token + pin file together) instead of trusting a
stale account; and the sub-directory note is now honest in every path (push is only claimed pinned when
the token — which the push credential helper also needs — is present; otherwise "NOT guaranteed — do NOT
commit"). Regressions: `test/session-init.test.sh` (4b/4c/4d/5b). Applies to both the root scripts and
the byte-identical `plugin/scripts/` copies.

**Related hardening (surfaced during the fix, parked — see `ROADMAP.md` → "Candidate future work"):**
the guard has no hard `git commit` author backstop (only fail-closes `gh`, so an ambient author still
slips through if the env-file pin can't be written); nested locked folders resolve via `head -1` instead
of most-specific path. Neither is the leak above — that one, and the cross-account re-pin gap, are fixed.

## Conventions
- Identity here is itself locked to the owner account — commit only as the pinned account.
- Keep `README.md` / `ROADMAP.md` / threat-model claims in sync when you touch the pin mechanism.
