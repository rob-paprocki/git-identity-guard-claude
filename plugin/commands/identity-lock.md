---
description: Manage git-identity-guard folder locks — add, remove, list, or check the status of a folder pinned to a GitHub account.
argument-hint: add|remove|list|status [path] [account]
---

# /identity-lock

Manage the folder→account locks enforced by **git-identity-guard**. Each lock
binds one local folder (and everything under it) to a single GitHub account by
pinning the commit author, the `gh`/GitHub-MCP account, and the push credential,
backed by a PreToolUse deny-guard.

The source of truth is the (gitignored, generated) config file:

- `${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}`

Each entry has the shape:

```json
{
  "path": "/path/to/folder-a",
  "account": "account-a",
  "name": "Account A",
  "email": "0000000+account-a@users.noreply.github.com"
}
```

The installer and uninstaller scripts (`install.sh`, `uninstall.sh`) live at the
**repository root** — they are *not* bundled inside the plugin (only the guard,
session-init, and resolver scripts are, under `"${CLAUDE_PLUGIN_ROOT}"`). Run
`install.sh` / `uninstall.sh` from your local checkout of the
git-identity-guard-claude repo; the examples below use `/path/to/install.sh` for
that absolute path.

## Subcommands

`$ARGUMENTS` selects the action. Parse the first word as the subcommand.

### `list`

Show every locked folder. Read the config and print one row per entry:

```bash
jq -r '.[] | "\(.path)\t\(.account)\t\(.email)"' \
  "${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
```

If the file is missing or empty, report that no folders are locked yet.

### `status [path]`

Report which account (if any) governs a folder. Default `path` to the current
working directory. Resolve it the same way the guard does — the lock whose
`.path` equals or is a parent of `path`, case-insensitively:

```bash
cwd="${1:-$PWD}"; lc="$(printf '%s' "$cwd" | tr '[:upper:]' '[:lower:]')"
jq -r --arg c "$lc" '
  .[] | (.path | ascii_downcase) as $p
  | select($c == $p or ($c | startswith($p + "/")))
  | "\(.account)\t\(.email)\t\(.name)"' \
  "${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}" | head -1
```

Empty output means the folder is outside every locked tree (the guard does not
fire there). Note whether the match was the folder itself or a parent
(sub-directory of a lock).

### `add [path] [account]`

Lock a new folder. This wires all four layers (gitconfig `includeIf`,
credential helper, per-folder `settings.local.json`, and the global hooks), so
it must run the installer rather than editing the config directly. Confirm the
GitHub account and the commit `name`/`email` with the user, then run the
installer in scripted mode — it reads four lines per folder (path, account,
name, email) and a blank line ends the loop:

```bash
printf '%s\n' \
  "/path/to/folder-a" \
  "account-a" \
  "Account A" \
  "0000000+account-a@users.noreply.github.com" \
  "" | bash /path/to/install.sh --non-interactive-from-stdin
```

`install.sh` is idempotent and merges by path, so re-adding an existing folder
safely refreshes it. Requires `gh` to be authenticated for the target account.

### `remove [path]`

Unlock folders. `uninstall.sh` reads `folders.json` and reverses every wiring
step for each recorded folder (drops the `includeIf` section, removes the
per-folder `settings.local.json`, and clears the global hook wiring), leaving
the per-account gitconfig in place unless `--purge` is given:

```bash
bash /path/to/uninstall.sh --non-interactive
# add --purge to also delete ~/.config/git/<account>.gitconfig
```

`uninstall.sh` removes all locked folders at once. To drop a single folder while
keeping the rest, first delete that one entry from `folders.json`, re-run the
remaining ones through `install.sh`, or have the user manage the single entry —
then re-run `/identity-lock list` to confirm the result.

## Safety

- Never write real GitHub handles, numeric-ID emails, or machine paths into the
  repo; the examples above use placeholders (`account-a`,
  `/path/to/folder-a`, `0000000+account-a@users.noreply.github.com`).
- `folders.json` and every `settings.local.json` are gitignored — they hold the
  real paths/accounts/tokens and must never be committed.
