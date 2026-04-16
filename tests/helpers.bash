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
DUMMY_CODE="000000"

core_installed() {
    [ -x "$VERIFY" ] && [ -f "/etc/totp-presence/secret" ]
}

require_core_installed() {
    core_installed || skip "totp-presence core not installed at $VERIFY (run sudo ./core/setup.sh install)"
}
