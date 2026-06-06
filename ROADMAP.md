# Roadmap

This is an owner-curated, non-binding list of directions for
`git-identity-guard-claude` beyond v1. It exists so that parked ideas have a
durable home and contributors can see where the project is headed. Nothing here
is committed to a schedule, and the list is expected to grow and change.

The fixed v1 scope is: `install.sh` + `uninstall.sh` + the config-driven guard +
a parameterized test suite + README + `config.example.json` + a thin Claude Code
plugin + GitHub Actions CI + `CONTRIBUTING.md`. Everything below is explicitly
out of v1.

## Candidate future work

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
