# totp-presence tests

Bats-based regression suite. Covers:

- **`tests/hook/`** — `claude-code-guard.sh` behaviour: read-only
  exit list, session check, config-path protection (H1 case-insensitive
  matching, H2 relative paths, §5b Bash scanning), `EXTRA_SAFE_TOOLS`
  validation (M2), `EDIT_WRITE_CONFIG_ONLY` modes (H3), parse-failure
  fail-safe deny (M1), session-timestamp sanity (L3).

- **`tests/core/`** — `verify.sh` behaviour: `--session` path
  validation (C1 prefix rule, `..` / `//` / subdir / suffix rejections),
  argument shape, legacy v1 path migration hint.

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
# Full suite (hook tests run anywhere; core tests skip if core is not installed)
bats tests/

# Just hook tests — no sudo, no install needed
bats tests/hook/

# Just core tests — require `sudo ./core/setup.sh install` first
bats tests/core/
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

### Core tests (sudo required)

`tests/core/verify_path_validation.bats` exercises the installed
verifier at `/etc/totp-presence/verify` through the sudoers NOPASSWD
rule the core install already created. Tests pass a shape-valid dummy
code (`000000`) and a crafted `--session` path; verify checks the
path first and exits 1 on a bad path BEFORE comparing the code, so
the brute-force fail-counter is not touched. This makes the suite
non-destructive even on a live install.

If `/etc/totp-presence/verify` is not installed, the whole file skips
via `require_core_installed`.

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
than letting the verifier reach the TOTP comparison.

Brute-force tests (lockout, counter reset) ARE destructive — they
deliberately bump the fail-counter. They belong in a separate
`verify_bruteforce.bats` and are not part of the default suite.
