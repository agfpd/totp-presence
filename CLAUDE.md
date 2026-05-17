# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the guide for working **on** the totp-presence codebase. The
runbook an agent follows to **install** totp-presence for a user is a
separate file: [AGENT_INSTALL.md](./AGENT_INSTALL.md). Product
description — [README.md](./README.md). Threat model and residual
risks — [SECURITY_MODEL.md](./SECURITY_MODEL.md).

There is no build step: pure `bash` + inline Python standard library,
zero pip/npm dependencies.

## Commands

Lint (the CI gate — anything at `warning` or `error` fails):

```sh
find . -type f -name '*.sh' -not -path './.git/*' -not -path './tests/*' -print0 \
  | xargs -0 shellcheck --shell=bash --severity=warning --exclude=SC1091
```

Info-level hints (SC2015, SC2012, SC2181) are acknowledged, not
CI-blocking — do not churn code to silence them.

Tests (bats; install `bats-core`):

```sh
bats tests/hook/                         # default loop: no sudo, sandboxed, runs anywhere
bats tests/                              # full suite (path-val skips w/o core, lifecycle skips w/o opt-in)
bats tests/hook/guard_basic.bats         # one file
bats tests/hook/guard_basic.bats -f 'substring'   # one test by name
bats tests/core/verify_path_validation.bats       # needs an installed core; non-destructive
```

Destructive lifecycle suite — CI or a throwaway box only (trips the real
fail-counter, briefly renames the seed):

```sh
sudo TOTP_PRESENCE_UNATTENDED_OK=1 \
     TOTP_PRESENCE_TEST_SEED=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP \
     ./core/setup.sh install --unattended
TOTP_PRESENCE_RUN_LIFECYCLE=1 bats tests/core/verify_lifecycle.bats
```

## Architecture

Two layers with a hard boundary:

- **`core/`** — the verification primitive. `verify.sh` answers exactly
  one question ("is this the current TOTP for the installed seed?") and
  optionally stamps a session file; `setup.sh` installs/updates it.
  Public API: `sudo /etc/totp-presence/verify <code> [--session <path>]`,
  exit codes `0` ok / `1` usage-or-env error / `2` invalid / `3` locked
  out (see `core/README.md`). The core knows nothing about windows,
  agents, or config editing.
- **`examples/`** — integrations, each owning its own session-file
  name, window length, and rejection format: `claude-code-hook/`
  (PreToolUse hook `guard.sh` + installer), `mcp-server/` (FastMCP
  stdio server, 3 tools, any MCP client), `soft-prompt/` (behavioural
  rules, no code).

Rule of thumb: if a change concerns session windows, a specific agent
system, or editing user config, it belongs in `examples/`, never in
`core/`. See "What the core does NOT do" in `core/README.md`.

**Trust chain.** agent → a narrow NOPASSWD sudoers rule scoped to the
verifier alone → root `verify` reads the seed, compares RFC 6238 →
writes a timestamp into the session file → the integration compares
that timestamp against its window. The seed never leaves root and is
fed to Python on stdin (not argv/env), so it never appears in `ps` or
procfs.

**FHS layout.** Static root-owned under `/etc/totp-presence/` (`secret`
600, `verify` 755, `<int>-config` 644, `<int>-guard.sh` 755) plus the
440 sudoers rule. Ephemeral under `/var/run/totp-presence/` (global
`fail-counter` + `.verify-lock/`, per-user `<user>/<int>-session`).
The runtime tree is wiped on reboot **by design** — "the owner was
here N minutes ago" must not survive a power cycle.

**Docs are mirrored EN↔RU.** Any change to `README.md`,
`SECURITY_MODEL.md`, `PRIOR_ART.md`, `AGENT_INSTALL.md`, or the
`core/` and `examples/*` READMEs must update `docs/ru/<same path>`.
This file (`CLAUDE.md`) is intentionally English-only — do **not**
create a `docs/ru/CLAUDE.md`.

## Invariants you can break without noticing

These span multiple files and are not obvious from any single one.

1. **Fail-closed vs fail-open is deliberately asymmetric** in
   `verify.sh`. A brute-force-counter persistence failure exits `3`
   (an outside observer cannot distinguish "counter saturated" from
   "counter not written", so brute-force via induced write failures is
   blocked). A session-write failure exits `1` (an absent session is
   the safe default and cannot be mistaken for "verified"). Do not
   collapse these to one code.

2. **Config and seed are parsed as data, never `source`d/`eval`d.**
   `claude-code-config` is 0644 root:wheel today; sourcing it would
   become RCE the instant that permission invariant slips
   (containerisation, bind-mount, umask race). The rationale block in
   `guard.sh` (~line 116) is load-bearing — keep parsing, don't
   "simplify" to `source`.

3. **The hook's read-only exit-list is short and stable on purpose.**
   `Read|Glob|Grep|LS|TodoWrite|WebSearch|ToolSearch` plus
   `mcp__totp-presence__*` only. Any unrecognised, new, or MCP tool
   must fail safe into the session check. Never add Bash, Write, Edit,
   NotebookEdit, Task, WebFetch, or any other MCP tool.
   `is_bash_read_only` is reject-on-any-doubt: a write misread as a
   read is a security bug; a read misread as a write is just an extra
   TOTP prompt.

4. **bash 3.2 is the floor** (macOS `/bin/bash` is 3.2.57; CI runs
   `macos-latest` to enforce it). Notably: `$'\0'` inside `${...}`
   parameter expansion silently misbehaves on 3.2 and once broke
   config protection entirely — prefer `read -r` line parsing (see the
   JSON-parse comment in `guard.sh`).

5. **Test-mode overrides are double-gated.**
   `TOTP_PRESENCE_TEST_MODE` / `MAX_FAILS_OVERRIDE` /
   `LOCKOUT_SECONDS_OVERRIDE` are honoured only when *both* hold: the
   installed sudoers rule carries no `SETENV` tag, *and* `verify.sh`
   sees `$0` resolving to the source tree (`*/core/verify.sh`), never
   `/etc/totp-presence/verify`. Weakening either makes the production
   rate-limit bypassable.

6. **One untrusted-name→path regex, three copies, kept in lockstep:**
   `^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$` in `verify.sh` (`SUDO_USER`),
   `guard.sh` (`HOOK_USER`), and `mcp-server/server.py`
   (`USER_NAME_RE`). The `--session` filename suffix rule
   (`*-session`, direct child of the per-user dir, no `..`/`//`) is
   enforced in `verify.sh` and assumed by every integration.

7. **The protected-config-path set is duplicated** across `guard.sh`
   (selective Edit/Write bypass, `IS_PROTECTED_PATH`, the Bash command
   scan — three spots), `examples/soft-prompt/prompt.md`, and
   `SECURITY_MODEL.md`: `settings.json`, `settings.local.json`,
   `.claude.json`, `CLAUDE.md`, `.claude/agents/*`. Change all
   together. These paths use the tighter `CONFIG_WINDOW_SECONDS`
   (120 s), not the normal `WINDOW_SECONDS`.

8. **Some obfuscation gaps are intentional, not bugs.** awk
   `system()`/`getline`, shell variables/`eval`/base64, and indirect
   writes are deliberately *not* caught by `guard.sh`'s text matching —
   catching them would cascade into parsing every interpreter
   language. They are anchored by `tests/hook/documented_limitations.bats`
   and the §5b known-gaps table in `SECURITY_MODEL.md`. Read that
   rationale before "fixing" a gap, and update both anchors if the
   behaviour really changes.

## Versioning & release

- `/VERSION` at the repo root is the single source of truth; `setup.sh`
  copies it into `/etc/totp-presence/VERSION` on install so `status`
  can report the live build.
- `CHANGELOG.md` follows Keep a Changelog + SemVer — put user-visible
  changes under `## [Unreleased]`.
- **The upgrade path is the `update` subcommand, never re-`install`.**
  `sudo ./core/setup.sh update` plus each integration's `install.sh
  update` replace only scripts and preserve the seed, sudoers rule,
  config, and open sessions. `install` regenerates the seed (breaks
  every authenticator pairing) and reprints the otpauth URL/QR. The
  "Updating" sections of `README.md` / `AGENT_INSTALL.md` must stay in
  sync with the actual subcommand behaviour.

## Test design gotchas

- Hook tests sandbox by `sed`-rewriting guard.sh's hardcoded `/etc/...`
  and `/var/run/...` paths into a tmpdir (`tests/helpers.bash`,
  `hook_sandbox_setup`). If you add a new hardcoded absolute path to
  `guard.sh`, add the matching `sed -e` rewrite there, or every
  sandboxed test silently reads the real system path.
- bats gotcha: a bare `[[ ... ]]` does **not** abort a test on
  failure. Chain `|| return 1` or use the `assert_*` helpers.
