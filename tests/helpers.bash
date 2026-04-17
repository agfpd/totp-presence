# Shared helpers for the bats test suite.
#
# Loaded by every .bats file via `load '../helpers'`. Provides:
#   - a sandbox for hook tests (no sudo)
#   - assertion helpers for the two JSON outputs the hook may emit
#     (allow = empty stdout, deny = JSON with "permissionDecision":"deny")
#   - a guard for core tests that skips the file if the core is not installed
#
# NOTE on bats assertion semantics: bare `[[ ... ]]` inside a test
# does NOT abort on failure. Chain every assertion with `|| return 1`
# (or use the assert_* helpers below, which do it for you) — otherwise
# a later passing check will mask an earlier failing one.

# Repo root, independent of where bats is invoked from.
PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")"/../.. && pwd)"
export PROJECT_ROOT

# ---------- hook sandbox ----------
#
# Builds a throwaway directory that looks like a totp-presence install
# and copies guard.sh with hardcoded paths rewritten into the sandbox.
# Call hook_sandbox_setup in setup(), hook_sandbox_teardown in teardown().

hook_sandbox_setup() {
    TEST_TMPDIR=$(mktemp -d)
    TEST_INSTALL_DIR="$TEST_TMPDIR/etc/totp-presence"
    TEST_RUNTIME_BASE="$TEST_TMPDIR/var/run/totp-presence"
    TEST_USER_DIR="$TEST_RUNTIME_BASE/$USER"
    TEST_SESSION_FILE="$TEST_USER_DIR/claude-code-session"
    TEST_CONFIG_FILE="$TEST_INSTALL_DIR/claude-code-config"
    TEST_GUARD="$TEST_TMPDIR/claude-code-guard.sh"

    mkdir -p "$TEST_INSTALL_DIR" "$TEST_USER_DIR"

    sed \
        -e "s|/etc/totp-presence|$TEST_INSTALL_DIR|g" \
        -e "s|/var/run/totp-presence|$TEST_RUNTIME_BASE|g" \
        "$PROJECT_ROOT/examples/claude-code-hook/guard.sh" > "$TEST_GUARD"
    chmod 755 "$TEST_GUARD"

    cat > "$TEST_CONFIG_FILE" <<EOF
WINDOW_SECONDS=1500
EOF
}

hook_sandbox_teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Write a session timestamp <age> seconds in the past.
set_session_age() {
    local age=$1
    local ts
    ts=$(( $(date +%s) - age ))
    printf '%s\n' "$ts" > "$TEST_SESSION_FILE"
}

# Write an arbitrary literal into the session file.
set_session_literal() {
    printf '%s' "$1" > "$TEST_SESSION_FILE"
}

# Append a KEY=VALUE to the sandbox config.
config_set() {
    printf '%s=%s\n' "$1" "$2" >> "$TEST_CONFIG_FILE"
}

# Overwrite the config with a single WINDOW_SECONDS line.
config_reset() {
    local window="${1:-1500}"
    printf 'WINDOW_SECONDS=%s\n' "$window" > "$TEST_CONFIG_FILE"
}

# Invoke the sandboxed guard with JSON input on stdin. Pairs with
# bats `run`: `run run_guard '{"tool_name":"Bash",...}'`
run_guard() {
    local input="$1"
    printf '%s' "$input" | "$TEST_GUARD"
}

# ---------- assertion helpers ----------
#
# Use with `|| return 1` so bats propagates the failure:
#   assert_deny || return 1
# The helpers print the full output on mismatch so debugging a test
# doesn't require a second run with --print-output-on-failure.

# Assert the hook emitted a deny decision. Accepts any whitespace
# around the JSON colon — python's json.dumps default separators put
# a space between key and value, but callers may compact.
assert_deny() {
    if ! [[ "$output" =~ \"permissionDecision\"[[:space:]]*:[[:space:]]*\"deny\" ]]; then
        printf 'expected deny in output, got:\n%s\n' "$output" >&2
        return 1
    fi
}

# Assert the hook allowed the call (empty stdout — an implicit allow).
assert_allow() {
    if [ -n "$output" ]; then
        printf 'expected allow (empty output), got:\n%s\n' "$output" >&2
        return 1
    fi
}

# Assert $output contains <substring>. Useful for checking deny
# messages and error strings.
assert_output_contains() {
    local needle="$1"
    if [[ "$output" != *"$needle"* ]]; then
        printf 'expected output to contain: %s\ngot:\n%s\n' "$needle" "$output" >&2
        return 1
    fi
}

# ---------- core verify helpers ----------

VERIFY="/etc/totp-presence/verify"
SECRET_FILE="/etc/totp-presence/secret"
RUNTIME_BASE="/var/run/totp-presence"
FAIL_COUNTER_FILE="/var/run/totp-presence/fail-counter"
DUMMY_CODE="000000"

core_installed() {
    [ -x "$VERIFY" ] && [ -f "$SECRET_FILE" ]
}

require_core_installed() {
    core_installed || skip "totp-presence core not installed at $VERIFY (run sudo ./core/setup.sh install)"
}

# ---------- core lifecycle helpers ----------
#
# Lifecycle tests are destructive: they trip the real fail-counter, make
# several consecutive invalid attempts, and reset state between tests.
# They require:
#   - a core install from a KNOWN seed (TOTP_PRESENCE_TEST_SEED)
#   - passwordless sudo for the invoking user
#   - TOTP_PRESENCE_TEST_MODE=1 so the brute-force constants can be
#     compressed via env overrides (see core/verify.sh)
#
# To prevent accidental local runs that trip the real counter against
# the real seed, require an explicit opt-in via TOTP_PRESENCE_RUN_LIFECYCLE=1.

require_lifecycle_env() {
    if [ "${TOTP_PRESENCE_RUN_LIFECYCLE:-}" != "1" ]; then
        skip "lifecycle tests disabled — set TOTP_PRESENCE_RUN_LIFECYCLE=1 to opt in (they are destructive; only run in CI or a throwaway dev box)"
    fi
    core_installed || skip "core not installed"
    command -v python3 >/dev/null 2>&1 || skip "python3 required for TOTP helper"
    if ! sudo -n true 2>/dev/null; then
        skip "passwordless sudo required for lifecycle tests"
    fi
}

# Generate a valid 6-digit TOTP code for a given base32 secret and a
# 30-second-step offset (0 = now, -1 = previous step, +1 = next step).
# Mirrors the RFC 6238 implementation in core/verify.sh byte-for-byte
# so a code produced here is accepted by the same verifier.
generate_totp_code() {
    local secret="$1"
    local offset="${2:-0}"
    SECRET="$secret" OFFSET="$offset" python3 -c '
import hmac, hashlib, struct, time, base64, os
key = base64.b32decode(os.environ["SECRET"], casefold=True)
counter = (int(time.time()) // 30) + int(os.environ.get("OFFSET", "0"))
msg = struct.pack(">Q", counter)
digest = hmac.new(key, msg, hashlib.sha1).digest()
ob = digest[-1] & 0x0F
tr = struct.unpack(">I", digest[ob:ob + 4])[0] & 0x7FFFFFFF
print(f"{tr % 1000000:06d}")
'
}

# Read the installed seed (root:wheel 600) via sudo cat. Only callable
# from lifecycle tests (guarded by require_lifecycle_env).
read_installed_secret() {
    sudo -n cat "$SECRET_FILE" 2>/dev/null
}

# Invoke verify.sh from the source tree (not the installed path) under
# test-mode env, so MAX_FAILS_OVERRIDE / LOCKOUT_SECONDS_OVERRIDE take
# effect. `sudo -E` preserves the env vars in CI and on dev boxes where
# sudoers allows it. We also set SUDO_USER explicitly to cover setups
# where sudo would otherwise strip or munge it.
#
# Args: code [--session path] …
# Env in:
#   MAX_FAILS_OVERRIDE (optional)
#   LOCKOUT_SECONDS_OVERRIDE (optional)
# Exit: same as verify.sh (0 ok, 1 usage/missing, 2 invalid, 3 lockout)
core_verify_testmode() {
    local max_fails="${MAX_FAILS_OVERRIDE:-5}"
    local lockout_seconds="${LOCKOUT_SECONDS_OVERRIDE:-300}"
    sudo -n -E env \
        TOTP_PRESENCE_TEST_MODE=1 \
        MAX_FAILS_OVERRIDE="$max_fails" \
        LOCKOUT_SECONDS_OVERRIDE="$lockout_seconds" \
        SUDO_USER="$USER" \
        bash "$PROJECT_ROOT/core/verify.sh" "$@"
}

# Clear any pending fail-counter + stale lock directory between tests so
# a failure in one test doesn't cascade into the next.
reset_verify_runtime() {
    sudo -n rm -f "$FAIL_COUNTER_FILE" 2>/dev/null || true
    sudo -n rmdir "$RUNTIME_BASE/.verify-lock" 2>/dev/null || true
}
