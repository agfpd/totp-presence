#!/usr/bin/env bats
# guard_config_protection.bats — configuration-file protection regressions.
#
# The hook enforces a tighter window (CONFIG_WINDOW_SECONDS, default
# 120s) for files that control agent security: settings.json,
# settings.local.json, .claude.json, CLAUDE.md, .claude/agents/*.
# Even a fresh normal-window session must NOT be enough to touch
# these files.

load '../helpers'

setup() {
    hook_sandbox_setup
    # Normal-window session: 5 min old — fresh enough for the 25-min
    # normal window, well past the 120s config window.
    set_session_age 300
}

teardown() {
    hook_sandbox_teardown
}

# ---------- baseline: protected paths with normal (but not config-window) session ----------

@test "Edit settings.json denies with 5-min session (past 120s config window)" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude/settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
    assert_output_contains "configuration files" || return 1
}

@test "Edit settings.local.json denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude/settings.local.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Edit .claude.json denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Edit CLAUDE.md denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/repo/CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Edit .claude/agents/* denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/repo/.claude/agents/linus.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- baseline: non-config passes with normal session ----------

@test "Edit non-config file passes with normal session" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt","old_string":"a","new_string":"b"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Write non-config file passes with normal session" {
    run run_guard '{"tool_name":"Write","tool_input":{"file_path":"/tmp/foo.txt","content":"x"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

# ---------- H1: APFS case-insensitive matching ----------

@test "H1: Edit Settings.JSON (uppercase basename) denies same as lowercase" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude/Settings.JSON"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "H1: Edit claude.md (lowercase) denies same as CLAUDE.md" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/repo/claude.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "H1: Edit Settings.LOCAL.json denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude/Settings.LOCAL.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- H2: relative paths ----------

@test "H2: Edit bare 'settings.json' (relative) denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "H2: Edit bare 'CLAUDE.md' (relative) denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "H2: Edit relative .claude/agents/foo.md denies" {
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":".claude/agents/foo.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- §5b: Bash command text scan ----------
# Obfuscation (variables, base64, eval) is explicitly NOT caught —
# documented limitation in SECURITY_MODEL.md §5b.

@test "Bash echo >> settings.json denies" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo x >> ~/.claude/settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash sed -i CLAUDE.md denies" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"sed -i s/foo/bar/ CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash with case-different Settings.JSON denies" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cp bad Settings.JSON"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash touching .claude/agents/ denies" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"rm -rf .claude/agents/"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- config-window permits fresh TOTP ----------

@test "Edit settings.json with 60s session (within 120s config window) passes" {
    set_session_age 60
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/Users/foo/.claude/settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash touching settings.json with 60s session passes" {
    set_session_age 60
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo x >> settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

# ---------- Read/write split for Bash on config paths ----------
#
# A clearly read-only Bash command on a protected config path is
# lifted from the TOTP requirement — diagnostic reads move no
# security state and gating them on a fresh code is bad UX. Writes
# still require TOTP.
#
# Classifier lives in guard.sh::is_bash_read_only: first token must
# be a known read utility (cat/head/tail/grep/wc/stat/file/ls/diff/
# awk/find/jq/cut/sort/uniq/...), and the command must contain no
# write markers anywhere (>, >>, ;, &&, ||, backticks, <(...), >(...),
# tee, sed -i, cp, mv, rm, rmdir, chmod, chown, install, touch, dd,
# ln, find -delete, find -exec).

@test "Bash cat settings.json passes without session (diagnostic read)" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat ~/.claude/settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash head -20 CLAUDE.md passes without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"head -20 CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash grep hook settings.json passes without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"grep hook /Users/foo/.claude/settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash wc -l settings.json passes without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"wc -l settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash stat CLAUDE.md passes without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"stat /repo/CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash read pipeline (cat | head) on settings.json passes" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat settings.json | head -5"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash jq .mcpServers .claude.json passes without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"jq .mcpServers ~/.claude.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

# Write must still be blocked even if the first token is read-only.

@test "Bash cat settings.json with output redirect denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat settings.json > /tmp/copy"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash cat settings.json append redirect denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat extra >> settings.json"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash cat settings.json with semicolon denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat settings.json; echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash read chain ending in tee denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat settings.json | tee /tmp/backup"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash find -delete on config path denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"find . -name settings.json -delete"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash find -exec rm denies" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"find . -name CLAUDE.md -exec rm {} ;"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "Bash command substitution with cat still read-only (config path not written)" {
    # `cat` inside $() does not write — the outer command decides.
    # Here we `echo` the result to stdout, no redirection, so allow.
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo $(cat settings.json)"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "Bash non-whitelisted first token on config path denies (fail-safe)" {
    # An unknown tool might be a write tool — reject conservatively.
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"x=open(\\\"settings.json\\\",\\\"w\\\"); x.write(\\\"bad\\\")\""}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

# ---------- H3: EDIT_WRITE_CONFIG_ONLY modes ----------

@test "EDIT_WRITE_CONFIG_ONLY=true: non-config Edit passes without session" {
    rm -f "$TEST_SESSION_FILE"
    config_set "EDIT_WRITE_CONFIG_ONLY" "true"
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "EDIT_WRITE_CONFIG_ONLY=true: non-config Bash passes without session" {
    rm -f "$TEST_SESSION_FILE"
    config_set "EDIT_WRITE_CONFIG_ONLY" "true"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ] || return 1
    assert_allow || return 1
}

@test "EDIT_WRITE_CONFIG_ONLY=true: config Edit still denies without session" {
    rm -f "$TEST_SESSION_FILE"
    config_set "EDIT_WRITE_CONFIG_ONLY" "true"
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/repo/CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "EDIT_WRITE_CONFIG_ONLY=true: config Bash still denies without session" {
    rm -f "$TEST_SESSION_FILE"
    config_set "EDIT_WRITE_CONFIG_ONLY" "true"
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"echo x >> CLAUDE.md"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}

@test "EDIT_WRITE_CONFIG_ONLY absent (default): non-config Edit denies without session" {
    rm -f "$TEST_SESSION_FILE"
    run run_guard '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt"}}'
    [ "$status" -eq 0 ] || return 1
    assert_deny || return 1
}
