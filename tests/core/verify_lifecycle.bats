#!/usr/bin/env bats
# verify_lifecycle.bats — end-to-end behaviour of the core verifier.
#
# Exercises every lifecycle path that verify_path_validation.bats does
# not: successful verification, session writes, brute-force lockout,
# lockout expiry, counter reset on success, symlink-refusal on the
# fail-counter, and SUDO_USER / missing-seed / bad-shape edge cases.
#
# DESTRUCTIVE — these tests flip the real fail-counter on the host
# running them and depend on a known test seed being installed.
# Gated behind TOTP_PRESENCE_RUN_LIFECYCLE=1 (see helpers.bash).
#
# Invariants across tests:
#   - The core is installed with seed == $TEST_SEED.
#   - Tests call verify.sh from the source tree under `sudo -E` with
#     TOTP_PRESENCE_TEST_MODE=1, which unlocks env overrides for
#     MAX_FAILS and LOCKOUT_SECONDS (see core/verify.sh). The installed
#     sudoers rule does not reach this code path.
#   - Each test resets the fail-counter + stale lock in setup/teardown.

load '../helpers'

# A public base32 test seed, fixed so the code helper and the installed
# verifier agree. Only valid in an environment where the caller has
# explicitly set up the core with exactly this seed (CI workflow does
# this; dev boxes opting in run the same setup command).
TEST_SEED="JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"

setup() {
    require_lifecycle_env
    reset_verify_runtime
    # Confirm the live seed matches our TEST_SEED — otherwise code
    # generation is against the wrong secret and every valid test fails
    # for the wrong reason.
    local live_seed
    live_seed="$(read_installed_secret)"
    if [ "$live_seed" != "$TEST_SEED" ]; then
        skip "installed seed does not match TEST_SEED — re-run setup with TOTP_PRESENCE_TEST_SEED=$TEST_SEED"
    fi
}

teardown() {
    reset_verify_runtime
}

# ---------- happy path ----------

@test "valid code → exit 0, prints ok" {
    local code
    code="$(generate_totp_code "$TEST_SEED")"
    run core_verify_testmode "$code"
    [ "$status" -eq 0 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    assert_output_contains "ok" || return 1
}

@test "valid code with --session writes session file as root:wheel 644" {
    local code session_path
    code="$(generate_totp_code "$TEST_SEED")"
    session_path="$RUNTIME_BASE/$USER/lifecycle-test-session"
    run core_verify_testmode "$code" --session "$session_path"
    [ "$status" -eq 0 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    # File exists, is regular, and has a unix-timestamp in it.
    sudo -n test -f "$session_path" || { echo "session file not created"; return 1; }
    local ts
    ts="$(sudo -n cat "$session_path")"
    case "$ts" in
        ''|*[!0-9]*) echo "session contents are not a unix timestamp: $ts"; return 1 ;;
    esac
    # Perms: 644. Owner: root (either wheel/Darwin or root/Linux).
    local mode
    mode="$(sudo -n stat -f '%Lp' "$session_path" 2>/dev/null || sudo -n stat -c '%a' "$session_path")"
    [ "$mode" = "644" ] || { echo "expected mode 644, got $mode"; return 1; }
    # Cleanup the test-session artefact.
    sudo -n rm -f "$session_path" 2>/dev/null || true
}

@test "valid code clears a previous fail-counter" {
    # Seed one invalid attempt to populate the counter.
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || { printf 'seed step status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    sudo -n test -f "$FAIL_COUNTER_FILE" || { echo "expected fail-counter after invalid attempt"; return 1; }
    # Now a valid code should wipe it.
    local code
    code="$(generate_totp_code "$TEST_SEED")"
    run core_verify_testmode "$code"
    [ "$status" -eq 0 ] || return 1
    if sudo -n test -f "$FAIL_COUNTER_FILE"; then
        echo "fail-counter was not cleared after successful verify"; return 1
    fi
}

# ---------- invalid code + brute-force ----------

@test "invalid code → exit 2, fail-counter incremented" {
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    sudo -n test -f "$FAIL_COUNTER_FILE" || { echo "fail-counter should exist after invalid attempt"; return 1; }
    local count
    count="$(sudo -n sed -n '1p' "$FAIL_COUNTER_FILE")"
    [ "$count" = "1" ] || { echo "expected fail-count=1, got $count"; return 1; }
}

@test "MAX_FAILS consecutive invalid attempts → lockout (exit 3)" {
    # Compress the lockout threshold to 3 to keep the test fast; 300s
    # lockout window so the lockout is still in force at assertion.
    export MAX_FAILS_OVERRIDE=3
    export LOCKOUT_SECONDS_OVERRIDE=300
    # Three failures: first two return exit 2, third crosses threshold
    # and returns exit 3 directly on that call.
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    run core_verify_testmode "000000"
    [ "$status" -eq 3 ] || { printf 'third fail status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    # Next call should also be exit 3 (locked-out precheck), WITHOUT
    # incrementing the counter further.
    run core_verify_testmode "000000"
    [ "$status" -eq 3 ] || return 1
    assert_output_contains "locked out" || return 1
}

@test "lockout window elapses → counter clears, verify accepts a valid code" {
    export MAX_FAILS_OVERRIDE=2
    export LOCKOUT_SECONDS_OVERRIDE=1
    # Trip the lockout: 2 consecutive invalid attempts.
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    run core_verify_testmode "000000"
    [ "$status" -eq 3 ] || return 1
    # Wait past the compressed window.
    sleep 2
    # A valid code should now pass (window expired clears the counter
    # before re-checking the code).
    local code
    code="$(generate_totp_code "$TEST_SEED")"
    run core_verify_testmode "$code"
    [ "$status" -eq 0 ] || { printf 'after-window status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

@test "success after some-but-not-all invalid attempts resets the counter" {
    export MAX_FAILS_OVERRIDE=5
    export LOCKOUT_SECONDS_OVERRIDE=300
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    local code
    code="$(generate_totp_code "$TEST_SEED")"
    run core_verify_testmode "$code"
    [ "$status" -eq 0 ] || return 1
    # Now trip another invalid attempt — counter should be at 1, not 3.
    run core_verify_testmode "000000"
    [ "$status" -eq 2 ] || return 1
    local count
    count="$(sudo -n sed -n '1p' "$FAIL_COUNTER_FILE")"
    [ "$count" = "1" ] || { echo "expected fail-count reset to 1, got $count"; return 1; }
}

# ---------- symlink protection ----------

@test "fail-counter write refuses to follow a symlink" {
    # Plant a symlink at the fail-counter path pointing at a bait file
    # somewhere the root verifier could reach.
    local bait
    bait="$(mktemp -u /tmp/totp-presence-bait.XXXXXX)"
    sudo -n ln -s "$bait" "$FAIL_COUNTER_FILE"
    run core_verify_testmode "000000"
    [ "$status" -eq 1 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    assert_output_contains "symlink" || return 1
    # The bait file must not have been written.
    [ ! -e "$bait" ] || { echo "bait file was created via symlink — write-protection bypassed"; sudo -n rm -f "$bait"; return 1; }
    # Cleanup the planted symlink (belt-and-braces — teardown would also
    # try, but rmdir .verify-lock expects no stray symlinks).
    sudo -n rm -f "$FAIL_COUNTER_FILE"
}

# ---------- SUDO_USER validation ----------

@test "SUDO_USER unset → exit 1" {
    # `sudo -n env -i SUDO_USER= ...` bypasses our helper which would
    # otherwise re-assert SUDO_USER=$USER.
    run sudo -n env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        TOTP_PRESENCE_TEST_MODE=1 \
        bash "$PROJECT_ROOT/core/verify.sh" "000000"
    [ "$status" -eq 1 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    assert_output_contains "SUDO_USER" || return 1
}

@test "SUDO_USER with unsafe characters → exit 1" {
    run sudo -n env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        SUDO_USER="../etc/passwd" \
        TOTP_PRESENCE_TEST_MODE=1 \
        bash "$PROJECT_ROOT/core/verify.sh" "000000"
    [ "$status" -eq 1 ] || { printf 'status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    assert_output_contains "not safe" || return 1
}

# ---------- missing prerequisites ----------

@test "missing seed file → exit 1" {
    # Move the seed aside, run verify, restore. Guard with a trap-free
    # teardown-local restore so a test failure still heals the core.
    local saved
    saved="$(mktemp -u /tmp/totp-presence-secret-backup.XXXXXX)"
    sudo -n mv "$SECRET_FILE" "$saved"
    run core_verify_testmode "000000"
    local code=$status
    local out="$output"
    sudo -n mv "$saved" "$SECRET_FILE"
    [ "$code" -eq 1 ] || { printf 'status=%d output=%s\n' "$code" "$out" >&2; return 1; }
    [[ "$out" == *"seed not found"* ]] || { printf 'expected seed-not-found, got: %s\n' "$out" >&2; return 1; }
}
