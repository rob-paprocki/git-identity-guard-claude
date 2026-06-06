# Publish checklist

Run every gate below from the repo root and confirm the expected output before
publishing. **Do not create the public GitHub repo, add a remote, or push until
the owner gives an explicit go-ahead** (see the final section). This tool locks
folders to GitHub identities; publishing it with a single real handle, path,
token, or numeric-ID email defeats its own purpose.

All commands use placeholders only (`account-a`, `/path/to/folder-a`,
`NNNN+account-a@users.noreply.github.com`). Replace nothing with real values.

---

## 1. Tests are green

```bash
bash test/run.sh
```

Expected: every suite passes and the run ends with `ALL SUITES PASSED`. The
individual suites print their own totals (resolve-account, identity-guard,
session-init, install). A non-zero exit, or any `FAILED SUITES:` line, blocks
publishing.

## 2. Leak gate is clean

```bash
bash scripts/leak-gate.sh
```

Expected: prints `clean` and exits 0. If it prints `LEAK:`, fix the offending
file (the gate echoes the matching line) before doing anything else.

Also exercise the gate's own self-test so a broken regex can't pass a dirty
tree silently:

```bash
bash scripts/leak-gate.sh --self-test
```

Expected: ends with `self-test: ok` (it confirms the gate catches a planted
bad path/token and allows the anonymized fixture forms).

## 3. History-wide leak scan

The gate in step 2 only scans the current tree. Before publishing, scan **every
commit** — a leaked identifier in an old commit is still public once pushed.

```bash
SHAPES='(/Users[/][^/ ]+|/home[/][^/ ]+|gh[oprs]_[A-Za-z0-9]{20,})'
ALLOW='users\.noreply\.github\.com'
git grep -InE "$SHAPES" $(git rev-list --all) -- . ':!docs/' | grep -vE "$ALLOW" \
  && echo LEAK || echo clean
```

Expected: prints `clean` (no matching lines in any commit). If it prints `LEAK`,
the history itself must be rewritten (or the repo re-created from a clean
squash) before publishing — a fresh push of dirty history cannot be undone.

> `docs/` is excluded because commit-author metadata there (repo owner) is
> intended and fine; this scan is about file *content*.

## 4. End-to-end dry-run on throwaway fixtures

Confirm the installer wires and the uninstaller fully reverses, entirely inside
a sandbox `HOME` with a **stubbed `gh`** on `PATH` and `mktemp` folders. **Never
run `install.sh` against your real locked folders or real `HOME` for this
check.** The `install` test suite already does this end-to-end cycle:

```bash
bash test/install.test.sh
```

Expected: ends with `... passed, 0 failed`. It asserts the four pinning layers
appear after install (gitconfig `includeIf`, per-account credential helper,
per-folder `settings.local.json` with the pinned token/env, global
`~/.claude/settings.json` hooks) and that `uninstall.sh` removes them again.

## 5. Plugin + config JSON validates

```bash
jq -e . plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json config.example.json
```

Expected: exits 0 (all three parse as valid JSON).

## 6. No generated/private files are tracked

The local config, per-folder `settings.local.json`, and the maintainer's
leak-gate denylist must never be committed.

```bash
git status --porcelain                 # working tree clean before publishing
git ls-files | grep -E 'folders\.json$|settings\.local\.json$|\.leak-denylist$' \
  && echo TRACKED || echo none
```

Expected: `git status --porcelain` prints nothing, and the second command
prints `none`. (`config.example.json` is the only committed JSON config and is
placeholders only — it is intentionally *not* matched above.)

## 7. Pre-commit hook is wired (recommended)

So the gate + tests run automatically on future commits:

```bash
git config core.hooksPath .githooks
```

---

## Publish — owner go-ahead required

**Stop here until the repo owner explicitly says to publish.** The build is
committed locally on purpose; creating the public repo and pushing are a
separate, owner-authorized step.

Only after the owner's explicit go-ahead, and only after steps 1–6 above all
pass:

1. Create the public GitHub repo under the owner's chosen account/handle.
2. Add it as `origin` and push the default branch.
3. Confirm CI (`.github/workflows/test.yml`) runs and is green on the first
   push.
4. Re-run step 3 (history-wide leak scan) against the pushed branch as a final
   confirmation.

Do **not** automate or pre-emptively perform repo creation, remote add, or push
as part of the build.
