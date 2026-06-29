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

- **Sub-directory author-pin leak fixed (priority patch, 2026-06).** A worktree / sub-directory
  launch in a locked repo used to commit under the wrong author when the locked account's token was
  unavailable: the git author/committer exports lived inside the
  `if [ -n "$tok" ] && [ -n "$CLAUDE_ENV_FILE" ]` token gate in `identity-session-init.sh`, so an
  empty `$tok` skipped the whole block and the session inherited the launching shell's ambient
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` — while push still worked (credential helper is independent of
  commit author). Observed in the wild: ~21 commits authored under an unrelated project's bot identity,
  invisible in the transcript (ambient env, never a typed command). **Fix:** the author/committer pin is
  written **unconditionally** (token-independent; needs only `$NAME`/`$EMAIL`) under its **own**
  idempotency marker, inherited ambient author/committer is `unset` first, the gh/MCP token pin **and**
  the session pin file stay gated on `$tok` (so the guard never green-lights unpinned gh/MCP), both
  markers are **account-scoped** (a re-fire resolving a different account re-pins author + token + pin
  file together rather than trusting a stale account), and the sub-directory note is honest in every path
  (push is only claimed pinned when the token the push credential helper needs is present). Regressions in
  `test/session-init.test.sh` (4b/4c/4d/5b); applied to the root scripts and the byte-identical
  `plugin/scripts/` copies.

## Candidate future work

- **Guard commit-author backstop.** The guard (`identity-guard.sh`) only fail-closes `gh`/MCP; it never
  gates `git commit` and assumes the includeIf `[user]` pin keeps the author correct. Git env vars
  (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`) override gitconfig `user.*`, so if the env-file author pin ever
  fails to apply, an ambient author silently wins and the guard provides no backstop (and its messages
  still say "commit author stays pinned"). Consider a deny rule / warning when committing in a locked
  tree without a verified locked author, and align the guard's reassurance messages with reality.
  (The env-file/pin-file markers are now account-scoped, but the guard still does not gate `git commit`.)
- **Most-specific nested-folder resolution.** `resolve_account` (and the ROOT lookups) take `head -1`
  over unordered `jq` output, so for nested locks a cwd can bind to whichever entry `folders.json` lists
  first rather than the deepest matching `.path`. Order matches by path-specificity (longest path wins).

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
