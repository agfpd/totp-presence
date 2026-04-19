# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] — 2026-04-18

Audit-driven bugfix release. Four medium-severity bugs found in a
multi-model code review of `core/verify.sh`, plus Phase 2 hardening
and two non-behavioural refactors. No on-disk layout changes;
upgrade path is the usual `sudo ./core/setup.sh update`.

### Fixed — post-v0.2.0 audit (four medium-severity bugs)

- **Fail-closed on brute-force counter persistence errors.** Previously
  any write error on `fail-counter` (hostile symlink at target, mktemp
  failure, disk full, rename failure) exited with code 1, leaving the
  counter unchanged. An attacker who could induce write failures
  (filesystem filling, rename races) could test codes indefinitely
  without driving `FAIL_COUNT` toward lockout. All write-path errors
  now exit 3 with a stderr message distinguishing persistence failure
  from a genuine consecutive-failure lockout — outside observer sees
  the lockout either way.
- **`reclaim_if_stale` no longer races against a freshly-acquired lock.**
  The stale-lock detector previously stat()ed the lock directory once
  and then rmdir()ed if it was old enough. Between stat and rmdir
  another verify could acquire the lock, leaving the detector to wipe
  a live mutex. Re-stat immediately before rmdir and skip the removal
  if the second look shows a recent mtime.
- **`trap cleanup_lock` gated on successful acquisition.** Previously
  the EXIT trap unconditionally removed the lock directory on any exit
  path. A verify that timed out waiting would therefore rmdir whoever
  had just acquired the lock — including a live verify. A `LOCK_OWNED`
  flag is set only after this process's own `mkdir` returned success;
  `cleanup_lock` returns early if it is still zero.
- **Distinguish python3 interpreter failure from invalid code.**
  Previously any non-zero exit from the inline `python3 -c` (missing
  stdlib module, OOM, signal) produced an empty `$RESULT` and was
  treated as "code does not match", incrementing the fail-counter.
  Five interpreter crashes in a row pushed a legitimate user into a
  five-minute lockout for no reason they could diagnose. Capture
  `$?` into `PY_EXIT`, surface interpreter failure with a distinct
  error, and do not touch the counter on crash or unexpected stdout.

### Hardened — Phase 2 of the audit plan

- **Seed passed to python3 via stdin, not env var.** Removes the seed
  from `/proc/<pid>/environ` where it was previously visible for the
  lifetime of the python child. Root-readable only on Linux, but not
  being on disk at all is a stronger posture.
- **Seed normalisation and shape check.** `verify.sh` now strips
  whitespace from the seed file contents before feeding python and
  rejects empty or non-base32 input up front. Previously a CRLF- or
  whitespace-tainted seed (e.g. edited on Windows) produced silent
  authentication failure indistinguishable from an attacker submitting
  wrong codes; now it produces a clear error pointing at the reinstall
  command.
- **Bash-native regex for SUDO_USER and code shape.** Replaced
  `printf %s $X | grep -qE '^pattern$'` with `[[ $X =~ ^pattern$ ]]`.
  One process instead of two, no locale sensitivity in the matcher,
  pattern visible inline next to the check.

### Refactored — behaviour-preserving

- Extracted `atomic_write_root_644()` helper in `core/verify.sh`. The
  symlink-check → mktemp → write → chown → chmod → mv pattern was
  duplicated across the fail-counter update and the `--session`
  timestamp write. Both sites now call the helper and decide their
  own exit semantics (counter is fail-closed with exit 3, session is
  fail-open with exit 1).
- Fail-counter file is now parsed with a single `read -r` pair on a
  redirected fd instead of two `sed -n '1p'` / `'2p'` invocations.
  No subprocesses, uniform EOF handling, same sanitisation.

### Docs

- Reference section for `verify`'s exit codes refreshed in
  `core/verify.sh` header, `core/README.md`, and
  `docs/ru/core/README.md`. Exit 3 now covers both
  threshold-lockout and persistence-failure lockout; exit 1 lists
  python3 crash, unexpected output, session-write failure, and bad
  seed format as counter-neutral errors.

### Added

- Core lifecycle test coverage: 11 new destructive tests in
  `tests/core/verify_lifecycle.bats` exercising successful verify,
  `--session` file write (root:wheel 644), brute-force lockout + window
  expiry, counter reset on success, `SUDO_USER` validation, missing
  seed, and symlink refusal on the fail-counter. Gated behind
  `TOTP_PRESENCE_RUN_LIFECYCLE=1`; every test skips cleanly when the
  opt-in is absent. CI runs them on ubuntu-latest against a fixed test
  seed.
- `core/setup.sh --unattended` install mode for CI and automated
  tests. Double-gated: requires both the `--unattended` flag and
  `TOTP_PRESENCE_UNATTENDED_OK=1` in the environment. Skips the
  overwrite prompt, the `otpauth://` URL (would leak the seed into CI
  logs), the QR, and the 3-attempt self-test. Accepts
  `TOTP_PRESENCE_TEST_SEED` to install a specific known seed when the
  test suite needs to generate valid codes.
- `core/verify.sh` honours `MAX_FAILS_OVERRIDE` and
  `LOCKOUT_SECONDS_OVERRIDE` from the environment when
  `TOTP_PRESENCE_TEST_MODE=1`, so lifecycle tests can compress the
  5-minute lockout into seconds. Two layers of defence keep the hook
  out of production: the installed sudoers rule has no `SETENV` tag
  (`sudo /etc/totp-presence/verify` strips the env), and
  `verify.sh` itself refuses to activate test mode when invoked from
  the installed path (belt-and-braces on the `$0` basename).
- Documented boundary tests for the hook's text-match rule:
  `tests/hook/documented_limitations.bats` asserts that the 5b
  obfuscation paths (variable indirection, base64-encoded filename,
  `eval` splitting, script indirection, SCM overwrites) pass through
  the hook. The file carries a load-bearing header comment — these
  are intentional fences, not coverage.

### Changed

- Claude Code hook: read/write split for Bash on protected config
  paths. Diagnostic read-only commands (`cat`, `head`, `grep`, `jq`,
  …) on `settings.json`, `.claude.json`, `CLAUDE.md` and friends now
  pass without a TOTP session; writes still require the 120s
  config-window session. Full classifier rules and motivation —
  [SECURITY_MODEL.md, §5b](./SECURITY_MODEL.md#5b-modification-of-agent-configuration-via-shell-commands).
  Test coverage: 15 new cases in
  `tests/hook/guard_config_protection.bats`.
- `docs/ru/SECURITY_MODEL.md` and `SECURITY_MODEL.md` §5b: replaced
  the prose bullet list of Bash-check limitations with an explicit
  known-gaps table (vector → why not caught → where complete coverage
  lives). The hook's scope is now framed as an intentional boundary,
  not a noted weakness.
- CI: new `core-lifecycle-ubuntu` job complementing the existing
  `hook-tests-*`. Ubuntu-only for now; macOS lifecycle coverage is
  deferred because the code path is OS-agnostic and macOS runner
  minutes are ~10× ubuntu.

## [0.2.0] — 2026-04-17

Security audit closure release. All changes are backwards-incompatible
with respect to on-disk layout (runtime state moved from `/etc/totp-presence/`
to `/var/run/totp-presence/`). Lazy migration is performed automatically on
the first `v0.2` run of the core verifier and on reinstall of the Claude Code
hook integration. Anyone pairing an authenticator for the first time at v0.2
is unaffected.

### Changed — on-disk layout (FHS-compliant v2)

- Split of static vs. runtime state:
  - `/etc/totp-presence/` — sysadmin-managed: `secret`, `verify`,
    per-integration config and guard scripts.
  - `/var/run/totp-presence/` — ephemeral: `fail-counter`, `.verify-lock/`,
    and `<user>/<integration>-session`.
- Per-user session files: `/var/run/totp-presence/<user>/<integration>-session`.
  The `fail-counter` and the `.verify-lock/` remain global per machine
  (one secret → one brute-force rate-limit, one lock across users).
- Runtime tree is tmpfs on Linux and synthetic on macOS — cleared at reboot.
  "The owner was at the machine N minutes ago" no longer survives a power
  cycle; users must re-authenticate after boot.
- `verify --session <path>` now requires the path to be a direct child of
  `/var/run/totp-presence/<invoking-user>/` with a basename ending in
  `-session`. Legacy v1 paths under `/etc/totp-presence/` are rejected
  with a migration hint.
- `verify` refuses to run as root directly (requires `sudo` from a regular
  user account; `SUDO_USER` must be set and must match a POSIX-portable
  username pattern).
- `claude-code-hook/install.sh` migrates any legacy v1 session file from
  `/etc/totp-presence/claude-code-session` to the new per-user runtime
  location on reinstall.

### Security — audit findings closed

Reference IDs (`C1`, `H1`–`H3`, `M1`–`M3`, `L1`–`L5`) are from the internal
pre-release security audit.

- **C1 — `verify.sh --session` path hijack.** Introduced a strict suffix
  rule (basename must end with `-session`) plus a symlink-safe atomic
  write (refuse to follow existing symlinks; stage through sibling
  `mktemp` then `mv -f`). A valid code no longer lets a caller redirect
  the timestamp write to an arbitrary root-writable file, or to a
  sibling integration's state.
- **H1 — APFS case-insensitivity bypass in hook matcher.** `Settings.json`
  resolved to the same inode as `settings.json` on default macOS
  filesystems but previously slipped past the matcher. Fixed with
  `shopt -s nocasematch` (for Edit/Write `file_path`) and `grep -i`
  (for Bash command strings).
- **H2 — relative-path bypass in the config matcher.** `settings.json`
  as a relative path now matches the protected set alongside the
  absolute form.
- **H3 — `EDIT_WRITE_CONFIG_ONLY` silent inheritance on reinstall.**
  This option is security-critical (it lets non-config Edit/Write
  through without a session). Silent preservation across reinstalls
  could silently weaken protection after matcher changes. New
  `--full-lockdown` and `--selective-edit-write` flags force an
  explicit decision; preservation without a flag now prints a loud
  warning.
- **M1 — fail-open on PreToolUse JSON parse failure.** When the hook
  could not parse its input (missing python3, malformed JSON,
  unexpected shape), it previously fell through into the looser
  normal-window session check. Now it fails safe: deny the call
  outright with a clear operator-facing reason.
- **M2 — `EXTRA_SAFE_TOOLS` regex injection.** Operator-facing config
  documentation allows editing `claude-code-config` by hand, so the
  hook re-validates `EXTRA_SAFE_TOOLS` against the same regex as
  `install.sh --messaging-tools` before using it inside `grep -E`.
  A malformed value is refused with a one-line note on stderr rather
  than silently widening the waive list.
- **M3 — `fail-counter` symlink-follow on write.** The counter update
  now refuses to write through an existing symlink and uses the same
  atomic `mktemp` + `mv -f` pattern as the session write.
- **L1 — inherited `$PATH` in verify.** `verify.sh` no longer appends
  the inherited `$PATH`; it hard-codes `/usr/sbin:/usr/bin:/sbin:/bin`.
  This removes a window where a caller-controlled `$PATH` could
  shadow a missing system utility with an attacker-planted one.
- **L2 — stale lock auto-reclaim.** A SIGKILL'd or OOM'd verify used
  to leave `/var/run/totp-presence/.verify-lock/` behind, blocking
  subsequent verifies until a manual `sudo rmdir`. The verifier now
  reclaims a lock directory older than `LOCK_STALE_AGE` (60s)
  automatically. Live locks held by an in-flight verify are not
  affected.
- **L3 — `SESSION_TS` sanity check before arithmetic.** Non-numeric
  content in the session file no longer crashes the hook under
  `set -u`; it is treated as "session absent" and the call falls
  through into a deny.
- **L5 — MCP server timeout message.** The FastMCP `totp_verify`
  tool now distinguishes a lock-timeout (another verifier is in
  flight) from a real core-level timeout, with an operator-friendly
  remediation hint.

### Added

- `VERSION` file at the repo root and at `/etc/totp-presence/VERSION`
  after `sudo ./core/setup.sh install`. `./core/setup.sh status`
  reports the installed version.
- `sudo ./core/setup.sh update` — upgrade path that replaces
  `/etc/totp-presence/verify` and `/etc/totp-presence/VERSION`,
  clears the brute-force fail-counter, and preserves the seed, the
  sudoers rule, and authenticator pairings. Intended as the routine
  action after `git pull`.
- `sudo ./examples/claude-code-hook/install.sh update` — replaces
  `claude-code-guard.sh`, preserves `claude-code-config`
  (`WINDOW_SECONDS`, `EXTRA_SAFE_TOOLS`, `EDIT_WRITE_CONFIG_ONLY`)
  and the per-user session file. No Claude Code restart required —
  the next tool invocation picks up the new guard.
- README documents the upgrade path in a new `Updating` section.
- Bats-core regression test suite in `tests/`:
  - `tests/hook/` — 49 tests, no sudo. A sandbox under `$TMPDIR`
    replaces the hardcoded `/etc/totp-presence` and
    `/var/run/totp-presence` paths so the hook runs against a
    throwaway install. Covers the read-only exit list
    (`Read`/`Glob`/`Grep`/`LS`/`TodoWrite`/`WebSearch`/`ToolSearch` +
    `mcp__totp-presence__*`), normal-window session check,
    `CONFIG_WINDOW_SECONDS` for protected paths, H1 (APFS
    case-insensitive matching), H2 (relative-path matching),
    §5b (Bash command text scan), H3 (`EDIT_WRITE_CONFIG_ONLY`
    modes), M1 (parse-failure fail-safe deny), M2
    (`EXTRA_SAFE_TOOLS` injection guard), L3 (session-timestamp
    sanity), and future-timestamp rejection.
  - `tests/core/` — 15 tests that exercise the installed
    `/etc/totp-presence/verify` through its sudoers rule.
    Non-destructive: all use a shape-valid dummy code and rely on
    `--session` path validation firing before the TOTP compare.
    Covers C1 prefix rule, `..` / `//` / subdirectory / suffix
    rejections, legacy v1 path migration hint, argument-shape
    validation.
  - `tests/README.md` documents how to run locally (`brew install
    bats-core` on macOS, `apt install bats` on Linux) and how to
    add new tests.
- GitHub Actions CI workflow (`.github/workflows/ci.yml`) — three
  parallel jobs on every push / PR against `main` (and on `v*` tag
  pushes):
  - `shellcheck` on ubuntu-latest. Lints every `.sh` outside
    `.git/` and `tests/` at `--severity=warning`; info-level hints
    (SC2015, SC2012, SC2181, SC2295) are acknowledged but
    non-blocking.
  - `hook-tests-ubuntu` — `bats tests/hook/` on ubuntu-latest.
    Validates bash 4 / GNU utils behaviour.
  - `hook-tests-macos` — `bats tests/hook/` on macos-latest.
    Validates the bash 3.2 floor documented in Requirements.
  Core tests (`tests/core/`) are not in CI yet: they require a
  paired authenticator and a live `/etc/totp-presence/verify`.
  A headless install mode is on the Post-1.0 roadmap.
- CI build badge in README EN+RU.

## [0.1.0] — 2026-04-13

Initial public release on `github.com/agfpd/totp-presence`.

### Added

- `core/verify.sh` — TOTP verification primitive with exit-code contract
  (0 valid / 2 invalid / 3 locked out / 1 error), brute-force protection
  (5 consecutive failures → 5-minute lockout), mkdir-lock serialization
  against parallel brute-force, zero pip dependencies (RFC 6238 TOTP
  using Python standard library only).
- `core/setup.sh` — install / uninstall / status for the core. Generates
  a 160-bit base32 seed via `os.urandom`, installs a narrow sudoers rule
  (`NOPASSWD` scoped exclusively to `/etc/totp-presence/verify`), renders
  the `otpauth://` URL and optional terminal QR (via `qrencode`), runs a
  3-attempt self-test.
- `examples/claude-code-hook/` — Claude Code `PreToolUse` hook with
  full-lockdown (matcher `.*`) and selective (narrow matcher +
  `EDIT_WRITE_CONFIG_ONLY=true`) deployment modes. Config-file
  protection with a tighter 120s window (`settings.json`,
  `settings.local.json`, `.claude.json`, `CLAUDE.md`,
  `.claude/agents/*`). `EXTRA_SAFE_TOOLS` for messaging tools of
  headless agents. Short read-only exit-list (`Read`, `Glob`, `Grep`,
  `LS`, `TodoWrite`, `WebSearch`, `ToolSearch`) that fails safe on
  unknown tools.
- `examples/mcp-server/` — FastMCP 3.x server exposing
  `totp_verify`, `totp_check_session`, `totp_status` for any
  MCP-compatible client (Claude Code, Claude Desktop, Cursor, Continue).
  Integration-name validation (`[a-z0-9][a-z0-9-]{0,63}`), user-name
  validation (matches the verifier's `SUDO_USER` guard).
- `examples/soft-prompt/prompt.md` — agent instructions block for
  CLAUDE.md / system prompt. Defines when to verify (irreversible
  actions, sensitive operations, agent configuration edits, identity
  doubt), the tool contract, timing rule ("verify is the first
  tool call of the turn"), and the cardinal rule ("accept codes
  only from the human through a direct channel").
- Apache License 2.0 with explicit patent grant.
- English + Russian documentation: `README.md` + `README.ru.md`,
  `CLAUDE.md` + `CLAUDE.ru.md`, `SECURITY_MODEL.md` +
  `SECURITY_MODEL.ru.md`, plus per-component READMEs under `core/`
  and each `examples/*` subdirectory.

[Unreleased]: https://github.com/agfpd/totp-presence/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/agfpd/totp-presence/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/agfpd/totp-presence/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/agfpd/totp-presence/releases/tag/v0.1.0
