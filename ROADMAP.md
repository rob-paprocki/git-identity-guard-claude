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
  file together rather than trusting a stale account; account markers are matched **whole-line**
  (`grep -qxF`) so a prefix-named account can't substring-match a longer account's marker line), and the
  sub-directory note is honest in every path (push is only claimed pinned when the token the push
  credential helper needs is present; an unwritable env-file warns the ambient identity is still active).
  Regressions in `test/session-init.test.sh` (4b/4c/4d/4e/5b/5c); applied to the root scripts and the
  byte-identical `plugin/scripts/` copies.

- **Guard & resolver hardening — 3 HIGH pre-existing bugs fixed + deny-rule robustness (2026-06,
  four-round adversarial review).**
  (1) **`git -C` outside-tree escapes** — the outside-tree block now catches a leading `./` (`./../x`),
  mid-token `..` (`foo/../../x`), `~` home paths, and the two-space `--git-dir`/`--work-tree` form; it is
  **scoped to a git invocation in the same command segment** (so `make -C /x` / `tar -C /var/git/data`,
  or `git … && make -C /x`, are no longer wrongly denied). (2) **Trailing-slash fail-open** — a
  `folders.json` path written as `/foo/` made the lock inert and the guard fail-OPEN; `install.sh` now
  strips trailing slashes on input and `resolve_account` + both inline ROOT lookups normalize them on
  either side. (3) **SSH-remote setup** — `git remote add`/`set-url` to an SSH/scp remote (incl.
  dotless-host, IP, and absolute-path scp forms) is now denied; the detection is segment-scoped and never
  trips on `https://` (even with userinfo or `:port`). Plus: **bash line-continuations** (`\`+newline) are
  collapsed before the line-oriented greps so a continuation can't split a token across grep lines while
  bash joins it (`git \⏎-C /outside`). Regressions in `test/identity-guard.test.sh` and
  `test/resolve-account.test.sh`. **Residuals (accepted):** a repo *cloned* over SSH before the session
  still isn't push-pinned (a command-string hook can't bind the SSH transport — re-point such an `origin`
  to `https://`, see README "Threat model"); quoted/`$`-expanded/symlink `-C` paths and a literal `\`+LF
  inside quotes are the documented quote-blindness floor (the last errs toward over-blocking, never a
  bypass).

- **Red-team hardening pass (2026-06, second multi-agent review + hand-verification).** A multi-agent red
  team plus empirical re-verification (every finding run against the real guard, with paired controls) found
  and FIXED a batch of bypasses and false-positives. **HIGH:** (H1) the guard's own policy files
  (`~/.config/identity-lock/`, `~/.claude/hooks/`) were unprotected — `rm`/clobbering them fail-OPENed the
  whole guard; now write/delete-protected (rule 7b). (H2/H8) an assignment NAME obfuscated by brace
  expansion, quote-splitting, or backslash (`export GH{A,_}TOKEN=`, `GH""_TOKEN`, `GH\_TOKEN`,
  `GIT_AUTHOR""_NAME`, also `read`/`printf -v`/`mapfile` targets) rebuilt a pinned var with no literal
  substring and no `$` — now caught (rule 1d). (H5) the `gh api` Authorization-header deny was effectively
  case-sensitive and adjacency-bound (`-H 'AUTHORIZATION:'`, `gh --verbose api`) — now case-insensitive,
  flags allowed. (H6) `git send-pack` (push plumbing, no "push" word) bypassed all of rule 6 — now in scope.
  (H7) scp push to a dotless host / IP / 1-char TLD evaded the dotted-host regex — now uses the rule-6b
  detector. (H3/H4) session-init trusted marker PRESENCE as proof of pinning, so a forged marker comment, or
  an A→B→A account return-hop, left a foreign author winning while the pin file claimed the locked account —
  the env-file pin is now strip-then-reappend (current account always wins, state derived from the actual
  write, never a marker). **MEDIUM:** (M2) the MCP write-classifier was a verb-allowlist that missed
  `assign_/mark_/dismiss_/manage_/run_secret_scanning` writes — inverted to a read-allowlist (default-deny);
  (M3) a non-standard github MCP namespace (Enterprise/copilot) skipped the guard entirely — matcher + case
  widened to `mcp__…github…__*`; (M4) `command/builtin/time/VAR= source` evaded the source deny — anchored;
  (M6) `gh auth setup-git` (writes a credential helper) is denied, and `gh auth switch/refresh` fail-closed
  in an unpinned tree. **Fixed false-positives** that were pushing users to disable the guard: bare `ENV`
  over-blocked `make ENV=prod`/`docker -e ENV=` (M5, dropped from the var list); rule 6 wasn't segment-scoped
  so a `host:port` token in a later segment wrongly denied a legit push (L6); the `-C` in-tree exception
  spliced the lock ROOT into a regex unescaped, so a dotted lock path mis-matched a sibling (L1, now escaped);
  single-userinfo / uppercase-scheme push URLs (L4/L5); and a stale baked MCP token wrongly denied
  override-namespace writes after `gh auth refresh` (L3, the override connection uses the live headersHelper
  token). Regressions: `test/identity-guard.test.sh` (+62), `test/session-init.test.sh` (+10),
  `test/install.test.sh` (+1); independently re-verified via `verification/`. Applied to the root scripts and
  the byte-identical `plugin/scripts/` copies (+ `plugin/hooks/hooks.json` matcher). **Accepted residuals:**
  `cd <outside-tree> && git push` (a string hook can't pin an arbitrary outside repo — documented); `..`-path
  lexical over-pin in `resolve_account` (L2 — over-pin, not a bypass; cwd isn't agent-forgeable).

## Known issues (pre-existing — found in the 2026-06 adversarial review)

The three HIGH issues from that review are now fixed (see "Shipped since v1" above). These lower-severity
ones remain, independent of the author-pin fix:

- **(medium) Guard matcher only covers `Bash` + the github MCP tools.** Other *non-github* shell-exec MCP
  tools (e.g. a `*__execute_shell_command`, `osascript`) run git/gh unguarded and outside the env pin. Fix:
  widen the matcher or document the exposure. (The 2026-06 hardening DID widen the matcher to cover other
  *github* MCP namespaces — M3 — but a generic shell-exec MCP tool is a distinct, still-open exposure.)
- **(low, partially mitigated) Session pin file is an agent-writable trust anchor.** The 2026-06 rule 7b now
  blocks writes/deletes to `~/.config/identity-lock/` (incl. `sessions/<sid>`) and `~/.claude/hooks/` from a
  **Bash** command in a locked tree, so the common forge-via-Bash path is closed. It is NOT a hard boundary:
  a non-Bash channel (an unguarded MCP shell-exec tool, a compiled binary) could still write the file. Fix
  for full coverage: store it outside agent-writable space, sign it, or have the guard re-verify the token.
- **(nit) `$account` is interpolated unquoted into the generated credential-helper snippet** (`install.sh`)
  — a malformed/hostile account string becomes shell that git runs on every push. STILL OPEN. Fix: validate
  the handle shape and quote it. (Low risk: `$account` comes from the operator's own install input, not an
  agent; but worth hardening.)

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
