# totp-presence tests

Bats-based regression suite. 72 hook tests + 26 core tests. Covers:

- **`tests/hook/`** — `claude-code-guard.sh` behaviour: read-only
  exit list, session check, config-path protection (H1 case-insensitive
  matching, H2 relative paths, §5b Bash scanning), `EXTRA_SAFE_TOOLS`
  validation (M2), `EDIT_WRITE_CONFIG_ONLY` modes (H3), parse-failure
  fail-safe deny (M1), session-timestamp sanity (L3). Also
  `documented_limitations.bats` — anchor tests for the known-gaps
  table in `SECURITY_MODEL.md` §5b (obfuscation paths the text match
  deliberately lets through).

- **`tests/core/`** — `verify.sh` behaviour. Two files:
  - `verify_path_validation.bats` — `--session` path rules (C1 prefix,
    `..` / `//` / subdir / suffix rejections), argument shape, legacy
    v1 migration hint. Non-destructive: the path check exits 1 before
    the TOTP compare, so the brute-force counter is never touched.
  - `verify_lifecycle.bats` — end-to-end lifecycle: successful verify,
    session-file write (root:wheel 644), brute-force lockout + window
    expiry, counter reset on success, `SUDO_USER` validation, missing
    seed, symlink refusal on the fail-counter. **Destructive** — trips
    the real fail-counter and depends on a known test seed being
    installed. Opt-in via `TOTP_PRESENCE_RUN_LIFECYCLE=1`; otherwise
    every test skips cleanly.

## Running

Install bats-core:

```sh
# macOS
brew install bats-core

# Ubuntu / Debian
sudo apt install bats

# Fedora
sudo dnf install bats
```

From the repo root:

```sh
# Default suite — hook tests run anywhere, path-validation skips if
# the core is not installed, lifecycle tests skip without the opt-in.
bats tests/

# Just hook tests — no sudo, no install needed
bats tests/hook/

# Path-validation core tests — require `sudo ./core/setup.sh install`
bats tests/core/verify_path_validation.bats

# Lifecycle core tests — destructive, CI or throwaway dev box only
sudo TOTP_PRESENCE_UNATTENDED_OK=1 \
     TOTP_PRESENCE_TEST_SEED=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP \
     ./core/setup.sh install --unattended
TOTP_PRESENCE_RUN_LIFECYCLE=1 bats tests/core/verify_lifecycle.bats
```

## Test design

### Hook tests (no sudo)

`tests/helpers.bash::hook_sandbox_setup` builds a temp directory that
looks like a totp-presence install (simulated `/etc/totp-presence/` and
`/var/run/totp-presence/<user>/`) and copies `guard.sh` with every
hardcoded path rewritten into the sandbox. The resulting guard runs
under the current user without touching the live system — each test
gets a fresh sandbox via `setup` / `teardown`.

The tests feed the guard a JSON payload on stdin (the same shape
Claude Code sends on `PreToolUse`) and assert on exit code and stdout.

### Core path-validation tests (sudo required, non-destructive)

`tests/core/verify_path_validation.bats` exercises the installed
verifier at `/etc/totp-presence/verify` through the sudoers NOPASSWD
rule the core install already created. Tests pass a shape-valid dummy
code (`000000`) and a crafted `--session` path; verify checks the
path first and exits 1 on a bad path BEFORE comparing the code, so
the brute-force fail-counter is not touched. This makes the file
non-destructive even on a live install.

If `/etc/totp-presence/verify` is not installed, the whole file skips
via `require_core_installed`.

### Core lifecycle tests (sudo required, destructive, opt-in)

`tests/core/verify_lifecycle.bats` invokes `bash core/verify.sh` from
the source tree under `sudo -E` with `TOTP_PRESENCE_TEST_MODE=1`,
which unlocks env overrides for `MAX_FAILS` and `LOCKOUT_SECONDS`
(see `core/verify.sh`). The override path is unreachable through the
installed sudoers rule — it has no `SETENV` tag, and `verify.sh`
itself refuses to activate test mode when `$0` resolves to
`/etc/totp-presence/verify`.

A TOTP helper in `tests/helpers.bash` generates valid codes with the
same RFC 6238 algorithm the verifier uses, so a code produced locally
is accepted by the same script. The helper needs a known seed —
CI installs the core unattended with `TOTP_PRESENCE_TEST_SEED` fixed
to a public base32 value (see the snippet above).

Tests are gated by `TOTP_PRESENCE_RUN_LIFECYCLE=1`. Without it, every
test skips with a clear message. Do NOT run them against a seed you
rely on for anything real: some tests deliberately trip a lockout,
some corrupt the fail-counter between tests, and one briefly renames
the seed file.

## Adding tests

### Hook behaviour

1. Decide where: `guard_basic.bats` for general tool handling,
   `guard_config_protection.bats` for anything touching the
   configuration-file matcher / config-window.
2. Use `hook_sandbox_setup` / `hook_sandbox_teardown` in `setup` / `teardown`.
3. Set up config via `config_set KEY VALUE` or `config_reset [window]`.
4. Set session state via `set_session_age <seconds>` or
   `set_session_literal "<raw>"`.
5. Feed input via `run_guard '<json>'` — this invokes the sandboxed
   guard with the JSON on stdin.
6. Assert on `$status` (0 for both allow and deny — hooks communicate
   the decision via stdout JSON) and `$output` (check for
   `"permissionDecision":"deny"` and message text).

### Core verify behaviour

Keep path-validation tests non-destructive: always use a crafted
`--session` path that triggers a validation failure (exit 1) rather
than letting the verifier reach the TOTP comparison. Destructive
lifecycle cases (lockout, counter reset, symlink refusal) belong in
`verify_lifecycle.bats` and must be gated by the
`require_lifecycle_env` helper.
