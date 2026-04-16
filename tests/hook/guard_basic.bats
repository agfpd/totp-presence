#!/usr/bin/env bats
# guard_basic.bats — core behaviours of the Claude Code PreToolUse hook.
#
# No sudo required: helpers.bash rewrites the hardcoded /etc/totp-presence
# and /var/run/totp-presence paths into a sandbox.
#
# bats assertions do not short-circuit on their own, so every
# assertion chains `|| return 1` (assert_* helpers do this internally).

load '../helpers'

setup() {
    hook_sandbox_setup
}

teardown() {
    hook_sandbox_teardown
}

# ---------- read-only exit list ----------

@test "Read passes without session" {
    run run_guard '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Glob passes without session" {
    run run_guard '{"tool_name":"Glob","tool_input":{"pattern":"*.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Grep passes without session" {
    run run_guard '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "LS passes without session" {
    run run_guard '{"tool_name":"LS","tool_input":{"path":"/tmp"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "TodoWrite passes without session" {
    run run_guard '{"tool_name":"TodoWrite","tool_input":{"todos":[]}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "WebSearch passes without session" {
    run run_guard '{"tool_name":"WebSearch","tool_input":{"query":"test"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "ToolSearch passes without session" {
    run run_guard '{"tool_name":"ToolSearch","tool_input":{"query":"test"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

# ---------- totp-presence MCP tools ----------
# Must pass without session or the agent deadlocks (can't open a
# session because the tool to open one is blocked).

@test "mcp totp-presence totp_check_session passes without session" {
    run run_guard '{"tool_name":"mcp__totp-presence__totp_check_session","tool_input":{"integration":"claude-code"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "mcp totp-presence totp_verify passes without session" {
    run run_guard '{"tool_name":"mcp__totp-presence__totp_verify","tool_input":{"code":"123456","integration":"claude-code"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "mcp totp-presence totp_status passes without session" {
    run run_guard '{"tool_name":"mcp__totp-presence__totp_status","tool_input":{}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

# ---------- normal session check ----------

@test "Bash denies without session" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
    assert_output_contains "TOTP verification required" || return 1
}

@test "Bash with fresh session (1 min old) passes" {
    set_session_age 60
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash with expired session (2 h old) denies" {
    set_session_age 7200
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
    assert_output_contains "expired" || return 1
}

@test "Write denies without session" {
    run run_guard '{"tool_name":"Write","tool_input":{"file_path":"/tmp/foo.txt","content":"x"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Edit denies without session" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt","old_string":"a","new_string":"b"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "unknown tool name denies without session (fail-safe)" {
    run run_guard '{"tool_name":"SomeFutureMCPTool","tool_input":{"x":"y"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- M1: parse-failure fail-safe ----------

@test "M1: malformed JSON denies with parse-failure message" {
    run run_guard 'not json at all'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
    assert_output_contains "could not parse" || return 1
}

@test "M1: JSON missing tool_name field denies (via unknown-tool fallback)" {
    run run_guard '{"tool_input":{"file_path":"/tmp/x"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- L3: session-file sanity ----------

@test "L3: non-numeric session content is treated as absent, denies" {
    set_session_literal "not-a-timestamp"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "L3: session timestamp of 0 is treated as absent, denies" {
    set_session_literal "0"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "future session timestamp (clock skew) denies, not accepted" {
    # Age would be negative — must be rejected, not read as "very fresh".
    local future_ts
    future_ts=$(( $(date +%s) + 3600 ))
    printf '%s\n' "$future_ts" > "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- EXTRA_SAFE_TOOLS ----------

@test "EXTRA_SAFE_TOOLS lets a listed tool through without session" {
    config_set "EXTRA_SAFE_TOOLS" "mcp__my_bot__reply"
    run run_guard '{"tool_name":"mcp__my_bot__reply","tool_input":{"chat_id":"1","text":"hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "EXTRA_SAFE_TOOLS does not affect an unlisted tool" {
    config_set "EXTRA_SAFE_TOOLS" "mcp__my_bot__reply"
    run run_guard '{"tool_name":"mcp__other__write","tool_input":{}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- M2: EXTRA_SAFE_TOOLS injection guard ----------

@test "M2: malformed EXTRA_SAFE_TOOLS (wildcard) is refused, not honoured" {
    # `.*` would open the gates for every tool. The hook must refuse
    # the malformed value and fall through to the normal session check.
    config_set "EXTRA_SAFE_TOOLS" ".*"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "M2: malformed EXTRA_SAFE_TOOLS (regex metachar) is refused" {
    config_set "EXTRA_SAFE_TOOLS" "mcp__foo__.*"
    run run_guard '{"tool_name":"mcp__foo__bar","tool_input":{}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}
