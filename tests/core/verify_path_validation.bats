#!/usr/bin/env bats
# verify_path_validation.bats — --session path validation (C1).
#
# Requires a live core install: /etc/totp-presence/verify + sudoers
# NOPASSWD rule. Tests pass a shape-valid dummy code and a crafted
# --session path; path validation happens BEFORE the TOTP compare,
# so a bad path returns exit 1 without touching the fail-counter.
# Non-destructive for brute-force state.

load '../helpers'

setup() {
    require_core_installed
}

# ---------- C1: path prefix rule ----------

@test "rejects --session outside runtime base" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/tmp/any-session"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "path must" || return 1
}

@test "rejects --session in /etc (legacy v1 layout hint)" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/etc/totp-presence/claude-code-session"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "layout changed" || return 1
}

@test "rejects --session under a different user's runtime dir" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/nosuch-user-zzz/claude-code-session"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "path must" || return 1
}

# ---------- C1: no .. or // ----------

@test "rejects --session with .. component" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER/../$USER/claude-code-session"
    [ "$status" -eq 1 ] || return 1
    # Either the .. detector or the prefix check may fire first;
    # both are acceptable outcomes.
    if ! { [[ "$output" == *"'..'"* ]] || [[ "$output" == *"path must"* ]]; }; then
        printf 'expected .. or path rejection, got: %s\n' "$output" >&2
        return 1
    fi
}

@test "rejects --session with // component" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER//claude-code-session"
    [ "$status" -eq 1 ] || return 1
    if ! { [[ "$output" == *"'//'"* ]] || [[ "$output" == *"path must"* ]]; }; then
        printf 'expected // or path rejection, got: %s\n' "$output" >&2
        return 1
    fi
}

# ---------- C1: no subdirectories ----------

@test "rejects --session in a subdirectory of the runtime user dir" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER/sub/claude-code-session"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "direct child" || return 1
}

# ---------- C1: suffix rule — basename must end with -session ----------

@test "rejects --session without -session suffix (basename 'secret')" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER/secret"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "-session" || return 1
}

@test "rejects --session without -session suffix (arbitrary basename)" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER/evil.sh"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "-session" || return 1
}

@test "rejects --session with .bak suffix after -session" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" --session "/var/run/totp-presence/$USER/claude-code-session.bak"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "-session" || return 1
}

# ---------- argument shape ----------

@test "rejects code that is not exactly 6 digits (5 digits)" {
    run sudo -n "$VERIFY" "12345"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "6 digits" || return 1
}

@test "rejects code that is not exactly 6 digits (7 digits)" {
    run sudo -n "$VERIFY" "1234567"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "6 digits" || return 1
}

@test "rejects code with letters" {
    run sudo -n "$VERIFY" "abc123"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "6 digits" || return 1
}

@test "rejects empty code" {
    run sudo -n "$VERIFY"
    [ "$status" -eq 1 ] || return 1
    # Prints usage when no argv.
    if ! { [[ "$output" == *"usage"* ]] || [[ "$output" == *"6-digit"* ]]; }; then
        printf 'expected usage or 6-digit message, got: %s\n' "$output" >&2
        return 1
    fi
}

@test "rejects unknown flag in place of --session" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" "--not-a-flag" "/tmp/x"
    [ "$status" -eq 1 ] || return 1
    if ! { [[ "$output" == *"unknown argument"* ]] || [[ "$output" == *"--session"* ]]; }; then
        printf 'expected unknown-argument error, got: %s\n' "$output" >&2
        return 1
    fi
}

@test "rejects --session without a path value" {
    run sudo -n "$VERIFY" "$DUMMY_CODE" "--session"
    [ "$status" -eq 1 ] || return 1
    assert_output_contains "requires a path" || return 1
}
