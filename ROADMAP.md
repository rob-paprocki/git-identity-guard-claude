# Roadmap

This is an owner-curated, non-binding list of directions for
`git-identity-guard-claude` beyond v1. It exists so that parked ideas have a
durable home and contributors can see where the project is headed. Nothing here
is committed to a schedule, and the list is expected to grow and change.

The fixed v1 scope is: `install.sh` + `uninstall.sh` + the config-driven guard +
a parameterized test suite + README + `config.example.json` + a thin Claude Code
plugin + GitHub Actions CI + `CONTRIBUTING.md`. Everything below is explicitly
out of v1.

## Shipped since v1

- **Sub-directory launch support** — launching Claude inside a repo nested under a
  locked folder now pins `gh`/`git` (via the SessionStart env-file pin + a
  per-session pin file the guard verifies) and, opt-out, GitHub MCP (via a
  user-scoped `headersHelper` override that resolves the account by `cwd` at
  connect). Previously only `git` stayed pinned in sub-directories; `gh`/MCP
  fail-closed. The MCP override changes the GitHub MCP tool namespace machine-wide
  (`mcp__plugin_github_github__*` → `mcp__github__*`); `install.sh --no-mcp-override`
  skips it.

## Known bug (priority to patch)

- **A sub-directory launch can commit under the wrong author when the locked account's token is
  unavailable.** In `identity-session-init.sh`, the env-file lines that pin the git author/committer
  (the `printf 'export GIT_AUTHOR_…'` / `GIT_COMMITTER_…` block) sit INSIDE the
  `if [ -n "$tok" ] && [ -n "$CLAUDE_ENV_FILE" ]` guard, where `tok="$(gh auth token --user "$LOCKED")"`.
  If that token is empty (the locked account is not logged into `gh` in this session, or `gh` is
  unavailable), the whole block is skipped and the **author pin is never written** — even though it needs
  only the already-resolved `$NAME` / `$EMAIL`, not the token. The session then inherits the launching
  shell's author identity, so commits are authored under an ambient/foreign identity while *push* still
  succeeds (the credential helper is independent of commit author). Observed in the wild (2026-06): a
  worktree launch authored ~21 commits in a locked repo under an unrelated project's bot identity, which
  reached the remote looking otherwise normal and was invisible in the session transcript (ambient env,
  never a typed command). The sub-directory fallback note also wrongly says "commit author **still**
  [pinned]."
  **Fix:** decouple — when `CLAUDE_ENV_FILE` is set, ALWAYS write the author/committer exports from the
  resolved `$NAME` / `$EMAIL`; gate ONLY the token exports (`GH_TOKEN` /
  `GITHUB_PERSONAL_ACCESS_TOKEN`) on `$tok`. Add an `unset` of inherited author/committer vars as defense,
  correct the fallback note, and add a "no-token sub-dir launch still pins the commit author" test.

## Candidate future work

- **Mid-session `cd` re-pinning (CwdChanged)** — re-resolve and re-pin `gh`/MCP when
  the working directory moves *between* locked trees within a single session. Today
  a cross-tree `cd` is fail-closed (the guard denies it); the user relaunches Claude
  in the target tree. The env-file is re-sourced per Bash command, so a `CwdChanged`
  hook rewriting it is feasible — but it needs its own design + tests to avoid a
  stale-pin window.
- **Richer plugin UX** — a status dashboard, per-folder enable/disable, and a
  `doctor` command that diagnoses a misconfigured lock.
- **Multi-host / GitHub Enterprise support** — per-host credential helpers and
  `GH_HOST` handling so a folder can be locked to an account on a non-`github.com`
  host.
- **Optional OS-level isolation guidance** — documented patterns for per-identity
  user accounts or a container-per-folder, to push past the command-hook residual
  floor described in the README's threat model.
- **Additional guard hardening** — new deny rules as further bypass classes are
  identified.
- **`--dry-run` / audit mode** — report exactly what *would* be wired (and what
  is already wired) without changing anything.

## Suggesting ideas

Open an issue or a discussion describing the use case. Keep the project's
anonymization rule in mind: never include real GitHub handles, numeric-ID
emails, machine paths, or tokens in issues, PRs, or examples — use placeholders
(`account-a`, `/path/to/folder-a`,
`NNNN+account-a@users.noreply.github.com`). See `CONTRIBUTING.md`.
