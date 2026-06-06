# git-identity-guard-claude — Design Spec

Status: **approved (design)**, build paused at user request.
Date: 2026-06-06

> Anonymization note: this document and the entire repo use **placeholders only**
> (`account-a`, `/path/to/folder-a`, `…noreply…`). No real account handles, emails,
> numeric user-IDs, machine paths, or tokens appear anywhere. See "Anonymization &
> publish safety" — it is a first-class requirement, enforced by a pre-push grep gate.

## 1. Purpose

Lock any number of local folders, each to a specific GitHub account, so that an AI
coding agent (Claude Code) — and plain `git`/`gh` — only ever act as that folder's
account. Prevents accidental or prompt-injection-driven cross-account commits, pushes,
PRs/issues, and GitHub-MCP writes when several GitHub identities share one machine.

## 2. Design principle: default-correct pinning, not global mutation

Identity is pinned **by default** through scoped, declarative mechanisms — never by
mutating-and-restoring global state. The relevant globals (active `gh` account, macOS
keychain, global git config) are left untouched and simply **outranked**. A Claude Code
hook adds a deny filter on top and fails closed when a session isn't pinned.

Layers (each works on its own; together they're defense-in-depth):

| Layer | Surface | Mechanism |
|------|---------|-----------|
| L1 | commit author/committer | gitconfig `includeIf "gitdir:<folder>/"` + `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env |
| L2 | `gh` CLI | `GH_TOKEN` env (per-folder) outranks the active gh account |
| L3 | `git push` (HTTPS) | per-folder gitconfig `credential.https://github.com.helper` returning `gh auth token --user <acct>` (overrides osxkeychain) |
| L4 | GitHub MCP | `GITHUB_PERSONAL_ACCESS_TOKEN` env + fail-closed write guard |
| L5 | override defense | PreToolUse **deny-only** guard; fail-closed for unpinned `gh`/MCP |

## 3. Components & boundaries

1. **`identity-guard.sh`** — config-driven PreToolUse hook. Derives the locked account
   for a command by matching its `cwd` against the configured folder map; then runs the
   account-agnostic deny rules (token/identity overrides, `git config`/`-c`/`--config-env`,
   `gh api` auth headers, `source`/`eval`/`sudo`/`env -i`, SSH/scp push, config-file
   writes, out-of-tree `git -C`, `git am`/author-reuse) and the fail-closed checks.
   *Only change vs. the working prototype: replace the hardcoded account table with a
   `folders.json` lookup.*
2. **`identity-session-init.sh`** — config-driven SessionStart hook; injects the lock
   reminder and a sub-directory warning.
3. **`install.sh`** — interactive, idempotent. Preflight (`gh`/`jq`/`git`), list accounts
   from `gh auth status`, loop over folder↔account pairs, and wire all layers (below).
   Opt-in osxkeychain "fail-closed push" prompt (default off). Self-verifies by running
   the test suite against fixtures.
4. **`uninstall.sh`** — reverses hook wiring + config; optionally leaves gitconfig.
5. **`identity-guard.test.sh`** — the full guard test suite, **parameterized against a
   fixture `folders.json` + `mktemp` fixture dirs** (never real paths). CI-safe.
6. **`plugin/`** — thin Claude Code plugin: ships the guard hook globally + a
   `/identity-lock add|remove|list|status` command that calls the install logic.
7. **`README.md`, CI, `CONTRIBUTING.md`** — README carries an honest **threat model &
   residual limits** section; GitHub Actions runs the test suite on push.

## 4. Config schema — `~/.config/identity-lock/folders.json` (gitignored, generated)

```json
[
  { "path": "/path/to/folder-a", "account": "account-a", "name": "Account A",
    "email": "<id>+account-a@users.noreply.github.com" }
]
```

The repo commits only `config.example.json` with placeholders. The guard reads the real
file from the user's machine; it never lives in the repo.

## 5. `install.sh` flow (per folder)

1. Append a `folders.json` entry.
2. Add `~/.gitconfig` `includeIf "gitdir/i:<path>/"` → `~/.config/git/<account>.gitconfig`
   (identity `name`/`email` + the credential helper).
3. Write `<path>/.claude/settings.local.json`: PreToolUse+SessionStart hooks and `env`
   (`GH_TOKEN`/`GITHUB_PERSONAL_ACCESS_TOKEN` from `gh auth token --user <acct>`,
   `GIT_AUTHOR_*`/`GIT_COMMITTER_*` from the config) — ensure it is gitignored.
4. Merge global `~/.claude/settings.json` hook wiring via `jq` (idempotent).
5. Install guard + session-init into `~/.claude/hooks/`.

## 6. Anonymization & publish safety (first-class)

Leak surface to scrub everywhere (guard, tests, examples, README, this spec): account
handles, emails with numeric user-IDs, machine/user paths, and any `gh*_`-style tokens.

- Everything is config-driven / fixture-based; **nothing real is committed**.
- **Pre-push grep gate** (must return empty) over the whole tree *and* history; verified
  clean from the **first commit** — public git history is permanent, so a value in commit
  1 survives later deletion. Publishing is gated on an explicit user go.
- `.gitignore` excludes any generated local config.
- During development, `install.sh`/tests touch **throwaway fixture targets only**, never
  the real locked folders.

## 7. Threat model & residual limits (honest README framing)

The default identity for every command is the locked account, and the deny filter blocks
the override/sabotage forms a confused agent or naive prompt-injection would use; unpinned
`gh`/MCP fail closed. It is **not** a sandbox. A command with arbitrary code execution can
still defeat pinning via the irreducible floor: shell quote-splitting of a command/flag
(`gi""t`, `--aut""hor`, `-c "cred""ential.helper"`), an interpreter building a variable
name with no literal substring, or writing a persistent shell-startup file. A
command-string PreToolUse hook cannot reach these; true isolation against that level would
require OS-level separation (per-identity user accounts or a container per folder). Such an
actor can also exfiltrate via non-git channels, so the hook is hardening, not a jail.

## 8. Scope (full polish)

`install.sh` + `uninstall.sh` + config-driven guard + parameterized test suite + README +
`config.example.json` + thin plugin + GitHub Actions CI + `CONTRIBUTING.md` + a short demo
(asciinema/gif) + `/identity-lock add|remove|list|status`.

## 9. Deferred (user intends to expand later)

Out of scope for v1, captured for later: richer plugin UX, multi-host/GitHub-Enterprise
support, optional OS-level isolation guidance, and any additional hardening the user wants
to pursue.
