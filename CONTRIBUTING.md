# Contributing

Thanks for your interest in `git-identity-guard-claude`. This is a small,
defensive shell project; contributions are welcome. Please read the
anonymization rule below carefully — it is the one hard line.

## Anonymization: never commit real identifiers

Public git history is permanent. A real identifier in any commit survives later
deletion, so we keep the repo clean from the very first commit.

**Never commit** real GitHub handles, emails containing numeric user-IDs,
machine/user paths, or tokens — in code, tests, examples, README, or any other
file. Use placeholders instead:

- accounts: `account-a`, `account-b` (or `your-gh-handle` for the maintainer)
- paths: `/path/to/folder-a` (in docs) or `/absolute/path/to/folder-a` (in the
  example config) — never a real machine path
- emails: `a@users.noreply.github.com` or
  `NNNN+account-a@users.noreply.github.com`
- tokens: an elided form like `ghp_xxxx` or `gh*_…` — never a full,
  token-shaped string

Tests must run against `mktemp` fixtures, a fixture `folders.json`, and a
**stubbed `gh`** on `PATH`. Never read real paths or the real `gh` keyring from
a test.

### The leak gate

`scripts/leak-gate.sh` scans tracked files (outside `docs/`) for forbidden
identifier shapes — machine paths, `gh*_` tokens, and numeric-ID noreply emails
— and prints `clean` when nothing is found. Run it before every commit:

```bash
git add -A
bash scripts/leak-gate.sh   # must print: clean
```

It only scans tracked content, so stage your changes first. CI runs the same
gate, so a leak will fail the build. The maintainer also keeps a private,
gitignored `scripts/.leak-denylist` (one term per line) so the gate can match
real handles without ever hardcoding them in the repo.

## Run the tests

```bash
bash test/run.sh            # runs every suite; non-zero on any failure
```

Individual suites live under `test/` (`resolve-account.test.sh`,
`identity-guard.test.sh`, `session-init.test.sh`, `install.test.sh`). They are
self-contained and create their own fixtures.

## Pre-commit hook

Enable the bundled hook once per clone so the leak gate and tests run
automatically before each commit:

```bash
git config core.hooksPath .githooks
```

## Test-driven development

This project is built TDD-first, and changes should follow the same loop:

1. Write (or port) a **failing test** that captures the new behavior.
2. Run it and watch it fail for the expected reason.
3. Implement the smallest change that makes it pass.
4. Run the suite and watch it pass.
5. Run the leak gate, then commit.

When you add a deny rule to the guard, add a test case that the new rule blocks
the bad form **and** a case that it still allows the legitimate form — over-broad
rules that block normal work are bugs too.

## Style

- Match the prototype's defensive bash style. The guard does **not** use
  `set -e`; it must keep running and fail closed deliberately, not abort.
- Keep files focused and small.
- Use conventional commit messages (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`).

## License

By contributing, you agree that your contributions are licensed under the
project's MIT License (see [`LICENSE`](LICENSE)).
