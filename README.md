# git-identity-guard-claude

Lock any number of local folders, each to a specific GitHub account, so that an
AI coding agent (Claude Code) — and plain `git`/`gh` — only ever act as that
folder's account. It prevents accidental or prompt-injection-driven
cross-account commits, pushes, PRs/issues, and GitHub-MCP writes when several
GitHub identities share one machine.

> **No real identifiers anywhere.** This repo uses placeholders only
> (`account-a`, `/path/to/folder-a`, `NNNN+account-a@users.noreply.github.com`).
> A leak gate (`scripts/leak-gate.sh`) and CI keep it that way. Your real
> accounts/paths/tokens live only in a gitignored, locally generated config.

## Why

If you maintain repos under more than one GitHub identity on the same machine
(for example, a personal account and a work account), it is easy to commit or
push as the wrong one. The active `gh` account, the macOS keychain, and your
global git config are all shared, mutable, global state — and a single mistaken
default can leak one identity into another's history.

This tool pins identity **by default, per folder**, without mutating any of that
global state. It leaves the globals untouched and simply **outranks** them with
scoped, declarative mechanisms, then adds a Claude Code deny-guard on top that
fails closed when a session is not pinned.

## How it pins identity: the layers

Identity is pinned by default through scoped, declarative mechanisms — never by
mutating-and-restoring global state. Each layer works on its own; together they
are defense-in-depth.

| Layer | Surface | Mechanism |
|-------|---------|-----------|
| L1 | commit author/committer | gitconfig `includeIf "gitdir:<folder>/"` + `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env |
| L2 | `gh` CLI | per-folder `GH_TOKEN` env outranks the active `gh` account |
| L3 | `git push` (HTTPS) | per-folder gitconfig `credential.https://github.com.helper` returning `gh auth token --user <acct>` (overrides the OS keychain) |
| L4 | GitHub MCP | per-folder `GITHUB_PERSONAL_ACCESS_TOKEN` env + a fail-closed write guard |
| L5 | override defense | a PreToolUse **deny-only** guard; fail-closed for unpinned `gh`/MCP |

The relevant globals (active `gh` account, OS keychain, global git config) are
left as-is and simply outranked by the per-folder configuration.

## Requirements

- `bash`, `jq`, `git`, and the GitHub CLI (`gh`), authenticated for each account
  you want to lock (`gh auth login`).
- Claude Code (for L4/L5; L1 and L3 work with plain `git`/`gh` even without it).

## Quickstart

```bash
# 1. Authenticate gh for every account you intend to lock:
gh auth login   # repeat per account

# 2. Run the interactive installer and answer the prompts (one folder at a time):
./install.sh
```

For each folder you will be asked for its absolute path, the GitHub account it
should be locked to, and the commit `name`/`email` to use. The installer:

1. Appends an entry to `~/.config/identity-lock/folders.json` (generated,
   gitignored).
2. Adds an `includeIf "gitdir/i:<path>/"` to `~/.gitconfig` pointing at a
   per-account gitconfig that sets `user.name`/`user.email` and the push
   credential helper.
3. Writes `<path>/.claude/settings.local.json` with the per-folder hooks and
   `env` (tokens from `gh auth token --user <acct>`, plus `GIT_AUTHOR_*` /
   `GIT_COMMITTER_*`). This file is gitignored — it holds real tokens.
4. Merges the global hook wiring into `~/.claude/settings.json` (idempotent).
5. Installs the guard + session-init hooks into `~/.claude/hooks/`.

The installer is idempotent and merges by path, so re-running it safely
refreshes an existing lock. The config schema is documented in
`config.example.json`.

### Optional: fail-closed pushes

By default the per-folder credential helper outranks the OS keychain, but a
keychain entry for `github.com` still exists as a fallback. Pass
`--harden-keychain` (or answer the interactive prompt) to erase the `github.com`
keychain entry so that a push outside a locked folder has **no** ambient
credential to fall back on — it fails closed instead of silently using whatever
the keychain holds. This is opt-in and off by default.

## How the deny-guard works

`identity-guard.sh` is a Claude Code **PreToolUse** hook. For each tool call it:

1. Resolves the locked account for the command's `cwd` by matching it against
   `folders.json` (the folder itself or any parent, case-insensitively). If the
   `cwd` is outside every locked tree, the guard does nothing and exits.
2. Inside a locked tree, it runs a set of **deny-only** rules against the
   command string. It never rewrites or "fixes" a command — it only allows or
   blocks. Blocked forms include the override/sabotage shapes a confused agent
   or naive prompt-injection would use, for example:
   - inline token or identity overrides on `gh`/`git` invocations;
   - `git config`, `git -c`, or `--config-env` attempts to change identity or
     the credential helper;
   - `gh api` calls that inject their own auth header;
   - `source`/`eval`/`sudo`/`env -i` wrappers used to launder the environment;
   - SSH/scp-based pushes that sidestep the HTTPS credential helper;
   - writes to identity-bearing config files;
   - out-of-tree `git -C <other path>` operations;
   - `git am` / author-reuse that would carry a foreign identity.
3. For GitHub-MCP writes and for `gh`/MCP commands that are not pinned to the
   locked account, it **fails closed** (blocks) rather than letting an unpinned
   identity through.

`identity-session-init.sh` is a **SessionStart** hook that injects a reminder of
which account governs the current folder, and warns when the session starts in a
sub-directory of a locked folder.

## Plain `git` / `gh` (without Claude Code)

Even if you never use Claude Code, two layers still protect you because they live
in your git/gh configuration, not in the agent:

- **L1 (commit author)** — the `includeIf` in `~/.gitconfig` sets the right
  `user.name`/`user.email` for any git command run inside the locked folder.
- **L3 (push credentials)** — the per-folder credential helper returns the
  locked account's token for `git push` over HTTPS.

The deny-guard and the fail-closed MCP checks (L4/L5) only run under Claude
Code; outside it, you rely on L1/L3 plus your own discipline with `gh`.

## Threat model & residual limits

Be honest about what this does and does not do.

The **default** identity for every command is the locked account, and the deny
filter blocks the override/sabotage forms a confused agent or naive
prompt-injection would use; unpinned `gh`/MCP fail closed. That covers the
realistic, common failure modes.

It is **not a sandbox.** A command that already has arbitrary code execution can
still defeat pinning, because there is an irreducible floor a command-string hook
cannot reach:

- **shell quote-splitting** of a command or flag, so the literal substring the
  guard scans for never appears (e.g. splitting `git`, `--author`, or
  `credential.helper` across quotes);
- an **interpreter building a flag or variable name** dynamically, with no
  literal substring to match;
- writing a **persistent shell-startup file** that re-points identity for future
  shells.

These bypasses are described abstractly here on purpose. A PreToolUse hook
inspects a command string; it cannot defeat an executor that constructs the
forbidden form at runtime. True isolation against that level would require
**OS-level separation** — a per-identity user account, or a container per folder.

An actor with arbitrary code execution can also exfiltrate data over non-git
channels entirely. So treat this tool as **hardening that makes the common
mistakes impossible and the deliberate bypasses obvious**, not as a jail.

### Override / strip attacks the guard targets (by name)

The guard's deny rules exist specifically to block these classes, while
acknowledging the residual floor above:

- **HOME-redirect** — running git/gh with `HOME` (or `XDG_CONFIG_HOME`) pointed
  at a different config tree to dodge the `includeIf`.
- **GIT_DIR / out-of-tree operations** — using `GIT_DIR` or `git -C` to act on a
  repository outside the locked folder.
- **`git -c` / `--config-env`** — inline config overrides of `user.*` or the
  credential helper.
- **env-token injection** — supplying `GH_TOKEN` /
  `GITHUB_PERSONAL_ACCESS_TOKEN` (or an inline auth header) to act as a
  different account.

## Uninstall

```bash
./uninstall.sh
# add --purge to also delete the per-account ~/.config/git/<account>.gitconfig
```

`uninstall.sh` reverses every wiring step recorded in `folders.json`: it drops
the `includeIf` sections, removes the per-folder `settings.local.json`, and
clears the global hook wiring. It leaves the per-account gitconfig in place
unless `--purge` is given. It is idempotent.

## Development

- Run the full test suite: `bash test/run.sh`
- Run the leak gate: `bash scripts/leak-gate.sh` (must print `clean`)
- Enable the pre-commit hook (leak gate + tests) once per clone:
  `git config core.hooksPath .githooks`

Tests run entirely against `mktemp` fixtures, a fixture `folders.json`, and a
stubbed `gh` on `PATH` — never your real paths or your real `gh` keyring. See
`CONTRIBUTING.md`.

## License

MIT — see [`LICENSE`](LICENSE).
