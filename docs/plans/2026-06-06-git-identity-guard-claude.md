# git-identity-guard-claude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish an account-agnostic, config-driven tool that locks any number of local folders each to a specific GitHub account (gh, git push, commit author, GitHub-MCP), with a Claude Code deny-guard, an interactive installer, a thin plugin, tests, CI, and honest docs — with zero real identifiers committed.

**Architecture:** Port the verified working prototype into a config-driven form: the guard resolves the locked account by matching `cwd` against `~/.config/identity-lock/folders.json` instead of a hardcoded table; everything else (deny rules, fail-closed, MCP guard) is already account-agnostic. An `install.sh` generates that config + wires the four pinning layers from the user's gh keyring. A thin CC plugin ships the guard hook + an `/identity-lock` command. Tests run against `mktemp` fixtures + a fixture config, so they pass in CI and contain no real paths.

**Tech Stack:** POSIX-ish bash, `jq`, `gh` CLI, git `includeIf` + credential helper, Claude Code hooks (PreToolUse/SessionStart), GitHub Actions, `bats`-free shell test harness (the existing custom harness).

**Repo (`$REPO`):** the project root, developed under the owner's locked GitHub-account folder so commits are authored as the repo owner via `includeIf`.

**Source of truth for porting:** the verified prototype lives at `~/.claude/hooks/identity-guard.sh` and `~/.claude/hooks/identity-guard.test.sh` (133 passing cases). It is account-agnostic **except** the `case "$cwd_lc" in …` resolution block near the top and the test harness's hardcoded folder-path constants / account-derived variable names — those are the only things this plan changes/anonymizes.

**LEAK GATE (run before EVERY commit, enforced by `scripts/leak-gate.sh` in Task 8).** It scans
tracked content for *generic* secret/path shapes plus any term in a local, gitignored denylist —
so the gate itself never hardcodes real handles:
```bash
# generic shapes
git -C "$REPO" grep -InE '(/Users/[^/ ]+|/home/[^/ ]+|gh[oprs]_[A-Za-z0-9]{20,})' -- . ':!docs/' \
  | grep -vE 'users\.noreply\.github\.com' && { echo LEAK; exit 1; }
# plus the maintainer's own account handles, kept ONLY in scripts/.leak-denylist (gitignored, one/line)
[ -f "$REPO/scripts/.leak-denylist" ] && git -C "$REPO" grep -Inf "$REPO/scripts/.leak-denylist" -- . ':!docs/' \
  && { echo LEAK; exit 1; }
echo clean
```
(Commit author metadata = repo owner is fine and intended; this gate is about file *content*.)

---

## File Structure

```
git-identity-guard-claude/
├── identity-guard.sh            # config-driven PreToolUse guard
├── identity-session-init.sh     # config-driven SessionStart reminder
├── lib/resolve-account.sh       # cwd -> {account,email,name} lookup (sourced by both hooks)
├── install.sh                   # interactive wiring
├── uninstall.sh                 # reverse wiring
├── config.example.json          # placeholder folder↔account map
├── test/identity-guard.test.sh  # parameterized guard suite (fixtures)
├── test/install.test.sh         # installer wiring tests (sandbox HOME)
├── test/run.sh                  # runs all tests; used by CI
├── scripts/leak-gate.sh         # forbidden-identifier scan
├── plugin/
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── commands/identity-lock.md
├── .github/workflows/test.yml
├── .githooks/pre-commit         # runs leak-gate + tests
├── README.md  ROADMAP.md  CONTRIBUTING.md  LICENSE  .gitignore
└── docs/specs/…  docs/plans/…   (already present)
```

---

## Task 1: Account-resolution library (the core generalization)

**Files:**
- Create: `lib/resolve-account.sh`
- Create: `config.example.json`
- Test: `test/resolve-account.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
# test/resolve-account.test.sh
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib/resolve-account.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/folders.json" <<EOF
[ {"path":"$tmp/folder-a","account":"account-a","name":"Account A","email":"a@users.noreply.github.com"},
  {"path":"$tmp/folder-b","account":"account-b","name":"Account B","email":"b@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$tmp/folders.json"
pass=0; fail=0
check(){ local got; got="$(resolve_account "$1")"; [ "$got" = "$2" ] && { pass=$((pass+1)); echo "  PASS $3"; } || { fail=$((fail+1)); echo "  FAIL $3 :: got=[$got] want=[$2]"; }; }
check "$tmp/folder-a"            $'account-a\ta@users.noreply.github.com\tAccount A' "exact path"
check "$tmp/folder-a/sub/deep"   $'account-a\ta@users.noreply.github.com\tAccount A' "subdir"
check "$(echo "$tmp/folder-a" | tr a-z A-Z)" $'account-a\ta@users.noreply.github.com\tAccount A' "case-insensitive"
check "$tmp/folder-b"            $'account-b\tb@users.noreply.github.com\tAccount B' "second folder"
check "$tmp/elsewhere"           ""                                                  "outside -> empty"
echo "=== $pass passed, $fail failed ==="; [ "$fail" = 0 ]
```

- [ ] **Step 2: Run it, verify it fails** — `bash test/resolve-account.test.sh` → FAIL (`resolve_account: command not found`).

- [ ] **Step 3: Implement `lib/resolve-account.sh`**

```bash
#!/usr/bin/env bash
# resolve_account <cwd> -> prints "<account>\t<email>\t<name>" for the locked folder
# whose configured path equals or is a parent of <cwd> (case-insensitive); else nothing.
# Config: $IDENTITY_LOCK_CONFIG or ~/.config/identity-lock/folders.json
resolve_account() {
  local cwd_lc cfg
  cwd_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  cfg="${IDENTITY_LOCK_CONFIG:-$HOME/.config/identity-lock/folders.json}"
  [ -f "$cfg" ] || return 0
  jq -r --arg c "$cwd_lc" '
    .[] | (.path | ascii_downcase) as $p
    | select($c == $p or ($c | startswith($p + "/")))
    | [.account, .email, .name] | @tsv' "$cfg" 2>/dev/null | head -1
}
```

- [ ] **Step 4: Run test, verify pass** — `bash test/resolve-account.test.sh` → `5 passed, 0 failed`.

- [ ] **Step 5: Write `config.example.json`** (placeholders only)

```json
[
  {
    "path": "/absolute/path/to/folder-a",
    "account": "your-gh-handle-a",
    "name": "Your Name A",
    "email": "0000000+your-gh-handle-a@users.noreply.github.com"
  }
]
```

- [ ] **Step 6: Commit**

```bash
cd "$REPO"; bash scripts/leak-gate.sh 2>/dev/null || true   # (gate added in Task 11; ok to skip now)
git add lib/resolve-account.sh config.example.json test/resolve-account.test.sh
git commit -m "feat: config-driven account resolution (folders.json lookup)"
```

---

## Task 2: Port the guard to use the lookup

**Files:**
- Create: `identity-guard.sh` (ported from `~/.claude/hooks/identity-guard.sh`)
- Test: `test/identity-guard.test.sh` (ported + parameterized)

- [ ] **Step 1: Copy the prototype, then replace ONLY the resolution block.** Copy `~/.claude/hooks/identity-guard.sh` → `identity-guard.sh`. Delete the hardcoded `LOCKED="" … case "$cwd_lc" in … *) exit 0 ; esac` block and replace with:

```bash
# --- resolve the locked account for this cwd from folders.json ---
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/lib/resolve-account.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib/resolve-account.sh"
IFS=$'\t' read -r LOCKED EMAIL NAME < <(resolve_account "$cwd")
[ -z "${LOCKED:-}" ] && exit 0
```

  Everything below (the `deny()`, MCP block, `has()/hasi()`, PV list, all rules 1–8, fail-closed) is **already account-agnostic** — port it **verbatim**. The credential-helper account references inside the guard are all `$LOCKED`, so nothing else changes.

- [ ] **Step 2: Port + parameterize the test harness.** Copy `~/.claude/hooks/identity-guard.test.sh` → `test/identity-guard.test.sh`. Replace the hardcoded path/token preamble with fixtures:

```bash
GUARD="$(cd "$(dirname "$0")/.." && pwd)/identity-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A="$TMP/folder-a"; B="$TMP/folder-b"; mkdir -p "$A" "$B"
RE="0000000+account-a@users.noreply.github.com"            # fixture "locked email"
cat > "$TMP/folders.json" <<EOF
[ {"path":"$A","account":"account-a","name":"Account A","email":"$RE"},
  {"path":"$B","account":"account-b","name":"Account B","email":"0001+account-b@users.noreply.github.com"} ]
EOF
export IDENTITY_LOCK_CONFIG="$TMP/folders.json"
# Ported per-folder test groups now reference the neutral fixtures $A and $B.
```

  The prototype test defines three real folder-path constants, a real locked-email literal, and account-derived variable names. Replace **all** of them with the fixtures: point the two fixture dirs `$A`/`$B` at the prototype's per-folder test groups, swap the email literal for `$RE`, and rename any account-derived variables to neutral ones (`A`, `B`). For the MCP/fail-closed tests that call `gh auth token --user …`, **mock gh** by prepending a stub to PATH:

```bash
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token --user account-a") echo "TOKEN_A" ;;
  "auth token --user account-b") echo "TOKEN_B" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"
```

  Update the fail-closed/MCP tests to use `TOKEN_A`/`TOKEN_B` instead of real `gh auth token` output, and `GH_TOKEN="$ROBTOK"` → `GH_TOKEN=TOKEN_A`.

- [ ] **Step 3: Run, verify the full suite passes** — `bash test/identity-guard.test.sh` → `N passed, 0 failed` (N≈133). Fix any path/token literal the port missed.

- [ ] **Step 4: Leak-check the two new files** — `grep -nE '(/Users/|/home/|gh[oprs]_[A-Za-z0-9]{20,})' identity-guard.sh test/identity-guard.test.sh` and a check against `scripts/.leak-denylist` → both empty (the resolution table and every path/email/token literal are gone).

- [ ] **Step 5: Commit** — `git add identity-guard.sh test/identity-guard.test.sh && git commit -m "feat: config-driven guard + parameterized test suite"`

---

## Task 3: Config-driven SessionStart hook

**Files:** Create `identity-session-init.sh`; Test `test/session-init.test.sh`

- [ ] **Step 1: Failing test** — assert that for a cwd under `folder-a` it emits `additionalContext` containing the account, and that a sub-dir cwd adds the "SUB-DIRECTORY" warning; outside the tree emits nothing.

```bash
. ; out="$(printf '%s' "$(jq -n --arg c "$A/sub" '{cwd:$c}')" | bash "$INIT")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("account-a") and test("SUB-DIRECTORY")'
```

- [ ] **Step 2: Verify fail** (`$INIT` missing).
- [ ] **Step 3: Implement** — port `~/.claude/hooks/identity-session-init.sh`; replace the hardcoded `case` with `resolve_account "$cwd"`; derive `ROOT` from the matched `.path` in `folders.json`; keep the subdir-detection and message text (anonymized).
- [ ] **Step 4: Verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat: config-driven SessionStart reminder"`

---

## Task 4: Installer — preflight + prompt loop

**Files:** Create `install.sh`; Test `test/install.test.sh` (runs against a sandbox `HOME`)

- [ ] **Step 1: Failing test** — sandbox HOME + stubbed gh; feed scripted answers; assert `folders.json` is created with the expected entry.

```bash
TMP="$(mktemp -d)"; export HOME="$TMP"; mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"
printf '#!/usr/bin/env bash\ncase "$*" in "auth token --user account-a") echo TOKEN_A;; "api user*") echo account-a;; "auth status*") echo "account-a";; *) exit 0;; esac\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
mkdir -p "$TMP/folder-a"
printf '%s\n' "$TMP/folder-a" "account-a" "Account A" "a@users.noreply.github.com" "" | bash "$REPO/install.sh" --non-interactive-from-stdin
jq -e --arg p "$TMP/folder-a" '.[0].path==$p and .[0].account=="account-a"' "$TMP/.config/identity-lock/folders.json"
```

- [ ] **Step 2: Verify fail.**
- [ ] **Step 3: Implement preflight + loop** — `install.sh`: check `command -v gh jq git`; `gh auth status` must succeed; loop prompting `path`, `account` (default-list from gh), `name`, `email` (default from `gh api user`); append validated entries to an in-memory array; support a stdin-scripted mode for tests. Write `~/.config/identity-lock/folders.json` (merge/idempotent by path).
- [ ] **Step 4: Verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat: installer preflight + folder/account prompt loop"`

---

## Task 5: Installer — wire the four layers

**Files:** Modify `install.sh`; Test `test/install.test.sh` (extend)

- [ ] **Step 1: Failing tests** (extend) — after install, assert: (a) `~/.gitconfig` contains an `includeIf "gitdir/i:<path>/"`; (b) `~/.config/git/<account>.gitconfig` has `user.email` + a `credential.https://github.com.helper` referencing `gh auth token --user <account>`; (c) `<path>/.claude/settings.local.json` has the Bash|mcp matcher hook and `env.GH_TOKEN==TOKEN_A`; (d) `~/.claude/settings.json` has the SessionStart+PreToolUse wiring; (e) hooks copied to `~/.claude/hooks/`.

- [ ] **Step 2: Verify fail.**
- [ ] **Step 3: Implement `wire_folder()`** with these exact pieces (per entry):

```bash
# gitconfig includeIf (idempotent)
gc="$HOME/.config/git/$account.gitconfig"; mkdir -p "$(dirname "$gc")"
git config -f "$gc" user.name "$name"; git config -f "$gc" user.email "$email"
git config -f "$gc" 'credential.https://github.com.helper' ''
git config -f "$gc" --add 'credential.https://github.com.helper' \
  "!f() { test \"\$1\" = get && echo username=x-access-token && echo \"password=\$(gh auth token --user $account)\"; }; f"
grep -qF "gitdir/i:$path/" "$HOME/.gitconfig" 2>/dev/null || \
  git config -f "$HOME/.gitconfig" "includeIf.gitdir/i:$path/.path" "$gc"
# per-folder settings.local.json (env + hooks) — token pulled from keyring, file gitignored
tok="$(gh auth token --user "$account")"
sl="$path/.claude/settings.local.json"; mkdir -p "$(dirname "$sl")"
jq -n --arg g "bash $HOME/.claude/hooks/identity-guard.sh" --arg t "$tok" \
      --arg n "$name" --arg e "$email" '{hooks:{PreToolUse:[{matcher:"Bash|mcp__plugin_github_github__.*",hooks:[{type:"command",command:$g,timeout:15}]}]},env:{GH_TOKEN:$t,GITHUB_PERSONAL_ACCESS_TOKEN:$t,GIT_AUTHOR_NAME:$n,GIT_AUTHOR_EMAIL:$e,GIT_COMMITTER_NAME:$n,GIT_COMMITTER_EMAIL:$e}}' > "$sl"
# global settings.json: SessionStart + PreToolUse (merge, idempotent)
install -m 755 "$REPO/identity-guard.sh" "$REPO/identity-session-init.sh" "$HOME/.claude/hooks/"
mkdir -p "$HOME/.claude/hooks/lib"; install -m 644 "$REPO/lib/resolve-account.sh" "$HOME/.claude/hooks/lib/"
# (jq-merge SessionStart+PreToolUse arrays into ~/.claude/settings.json without dupes)
```

  Provide the full jq merge for `~/.claude/settings.json` that adds the SessionStart hook and the `Bash|mcp__plugin_github_github__.*` PreToolUse hook only if absent.

- [ ] **Step 4: Verify pass** (all extended assertions).
- [ ] **Step 5: Commit** — `git commit -m "feat: installer wires gitconfig, credential helper, settings env, and hooks"`

---

## Task 6: Installer — osxkeychain opt-in + summary; `uninstall.sh`

**Files:** Modify `install.sh`; Create `uninstall.sh`; Test extend

- [ ] **Step 1: Failing test** — `--harden-keychain` flag triggers a (stubbed) `git credential-osxkeychain erase` for github.com; default run does NOT. `uninstall.sh` removes the includeIf lines, the per-folder hooks block, the global wiring, and the folders.json entries (leaves per-account gitconfig unless `--purge`).
- [ ] **Step 2: Verify fail.**
- [ ] **Step 3: Implement** — add an interactive `Harden pushes to fail-closed? [y/N]` (and `--harden-keychain` flag) that runs `printf 'protocol=https\nhost=github.com\n' | git credential-osxkeychain erase`; print a final summary of what was wired. Write `uninstall.sh` (reverse each wiring step; idempotent).
- [ ] **Step 4: Verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat: opt-in keychain hardening + uninstall"`

---

## Task 7: Claude Code plugin wrapper

**Files:** Create `plugin/.claude-plugin/plugin.json`, `plugin/hooks/hooks.json`, `plugin/commands/identity-lock.md`

- [ ] **Step 1: Implement `plugin.json`** (name, version, description, author=repo owner placeholder).
- [ ] **Step 2: Implement `hooks/hooks.json`** wiring the global guard + session-init (same matchers as the installer's global wiring), pathed to the plugin's bundled copies.
- [ ] **Step 3: Implement `commands/identity-lock.md`** — a slash command documenting `add|remove|list|status`, whose body instructs the agent to run `install.sh`/`uninstall.sh`/`jq` against `folders.json` for each subcommand.
- [ ] **Step 4: Validate** — `jq -e . plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json`.
- [ ] **Step 5: Commit** — `git commit -m "feat: Claude Code plugin (guard hook + /identity-lock command)"`

---

## Task 8: Leak gate + git hook + CI

**Files:** Create `scripts/leak-gate.sh`, `.githooks/pre-commit`, `.github/workflows/test.yml`, `test/run.sh`

- [ ] **Step 1: `scripts/leak-gate.sh`** — scan tracked files (excluding `docs/` author metadata) for the forbidden pattern (handles, ID-emails, `/Users/<name>`, `gh*_` tokens); exit 1 on any hit. Include a self-test asserting a planted fixture string is caught and removed.
- [ ] **Step 2: `test/run.sh`** — runs `resolve-account`, `identity-guard`, `session-init`, and `install` test files; non-zero on any failure.
- [ ] **Step 3: `.githooks/pre-commit`** — runs `scripts/leak-gate.sh` then `test/run.sh`; README documents `git config core.hooksPath .githooks`.
- [ ] **Step 4: `.github/workflows/test.yml`** — on push/PR: install `jq`+`gh`, run `bash test/run.sh` and `bash scripts/leak-gate.sh`.
- [ ] **Step 5: Verify** — `bash test/run.sh` green; `bash scripts/leak-gate.sh` → `clean`.
- [ ] **Step 6: Commit** — `git commit -m "ci: test runner, leak gate, pre-commit hook, GitHub Actions"`

---

## Task 9: Docs — README, ROADMAP, CONTRIBUTING, LICENSE

**Files:** Create `README.md`, `ROADMAP.md`, `CONTRIBUTING.md`, `LICENSE`

- [ ] **Step 1: `README.md`** — what/why; the 4-layer pinning table (from spec §2); quickstart (`./install.sh`); how the deny-guard works; **"Threat model & residual limits"** verbatim-in-spirit from spec §7 (default-correct pinning; deny filter; fail-closed; the irreducible quote-split/RCE floor; OS-level isolation needed beyond that); a "plain git/gh (no Claude)" note (L1/L3 still apply); uninstall.
- [ ] **Step 2: `ROADMAP.md`** — the spec §9 items, framed as owner-curated future plans (placeholder for the user to expand).
- [ ] **Step 3: `CONTRIBUTING.md`** — run tests, the leak-gate rule (never commit real identifiers), TDD expectation.
- [ ] **Step 4: `LICENSE`** — MIT (owner placeholder).
- [ ] **Step 5: Leak gate + commit** — `bash scripts/leak-gate.sh && git commit -m "docs: README (incl. honest threat model), ROADMAP, CONTRIBUTING, LICENSE"`

---

## Task 10: End-to-end dry-run on throwaway fixtures + publish checklist

**Files:** none (verification); update README badges if desired

- [ ] **Step 1:** In a sandbox `HOME` + stub gh + `mktemp` folders, run `install.sh` end-to-end, then `uninstall.sh`; assert wiring appears then disappears. **Never run against the real locked folders.**
- [ ] **Step 2:** `bash test/run.sh` (all suites green) and `bash scripts/leak-gate.sh` (clean) over the whole tree.
- [ ] **Step 3:** Final history-wide leak scan: `git grep -InE '<forbidden>' $(git rev-list --all)` → empty.
- [ ] **Step 4:** Write `docs/PUBLISH-CHECKLIST.md` (gate steps + "create the public repo and push ONLY after explicit owner go-ahead").
- [ ] **Step 5: Commit** — `git commit -m "chore: e2e fixture validation + publish checklist"`. **Do NOT create the GitHub repo or push without the owner's explicit go.**

---

## Self-Review (completed by plan author)

- **Spec coverage:** §1 purpose → README/Task 9; §2 layers → Tasks 2,5; §3 components → Tasks 1–9; §4 config schema → Task 1; §5 install flow → Tasks 4–6; §6 anonymization → Task 8 + leak gate every task; §7 threat model → Task 9 Step 1; §8 scope (CI/plugin/contributing/demo) → Tasks 7–9 (demo gif optional, noted); §9 roadmap → Task 9 Step 2. Covered.
- **Placeholders:** none — every file has concrete code or a precise spec + commands. The guard/test *bodies* are ported verbatim from a named, verified source (not re-derived), with the exact resolution-block diff shown.
- **Naming consistency:** `resolve_account` (Task 1) used identically in Tasks 2–3; `folders.json`, `IDENTITY_LOCK_CONFIG`, `wire_folder`, the credential-helper string, and the `Bash|mcp__plugin_github_github__.*` matcher are consistent across tasks.
- **Demo gif** (spec §8 "demo") is intentionally optional/last; not a blocker for a runnable v1.
