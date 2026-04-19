#!/usr/bin/env bats
# documented_limitations.bats — boundary tests for the hook's text-match rule.
#
# READ BEFORE EDITING.
#
# This file is unusual: every test in it asserts that the hook ALLOWS a
# command that writes to a protected config file. That is intentional.
# The hook is a deterministic text filter over the command string — it
# catches direct writes like `echo >> settings.json`, but not obfuscated
# writes where the config path is built at runtime (variable expansion,
# base64 decode, eval, shell script, SCM indirection). Those paths are
# documented in docs/ru/SECURITY_MODEL.md §5b as known gaps; they are
# closed on the filesystem layer with `chflags uchg` / `chattr +i`, not
# inside the hook.
#
# These tests exist so the known-gaps table in the security model stays
# honest: if a future commit were to extend the hook's text match to
# cover one of these cases, the corresponding test here would start
# failing — which is the correct signal that the docs need to follow.
#
# Do NOT read these tests as "coverage" for obfuscation. They are the
# opposite: a machine-checked pointer at the fence the hook does not
# cross.

load '../helpers'

setup() {
    hook_sandbox_setup
    # No session written on purpose — direct writes to config files
    # would be denied; obfuscated ones must still pass.
}

teardown() {
    hook_sandbox_teardown
}

# ---------- §5b: variable expansion ----------

@test "[documented-gap] variable in path bypasses text match" {
    # `FILE=settings.json; echo >> $FILE` — the literal string "settings.json"
    # is present but only as a RHS assignment, not the write target. The
    # hook cannot statically resolve $FILE.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"FILE=settings.json; echo something >> $FILE"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
    # NOTE: this test may start failing if the hook learns to catch RHS
    # variable references. If it does, update SECURITY_MODEL.md §5b to
    # reflect that this gap has been closed.
}

# ---------- §5b: base64 decode ----------

@test "[documented-gap] base64-decoded filename bypasses text match" {
    # 'c2V0dGluZ3MuanNvbg==' decodes to 'settings.json'. The literal
    # "settings.json" does not appear in the command string.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"TARGET=$(echo c2V0dGluZ3MuanNvbg== | base64 -d); echo x >> $TARGET"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

# ---------- §5b: eval defers the string ----------

@test "[documented-gap] eval wrapping a literal write bypasses text match" {
    # The config path appears inside a string passed to `eval`. The
    # hook sees eval and a string literal; the write happens at agent
    # runtime, not at hook time. (eval-based classification would
    # over-deny benign eval patterns, so we explicitly do not try.)
    #
    # Caveat: some hooks do catch the literal "settings.json" inside
    # the eval argument because the text still appears in the command
    # string. If this test becomes red on a real hook, the correct move
    # is to replace the literal with an obfuscated form that genuinely
    # hides the name, so the test continues to mean what it says.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"X=\"settings\"; Y=\".json\"; eval \"echo x >> ${X}${Y}\""}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

# ---------- §5b: indirection through a script file ----------

@test "[documented-gap] running an external script bypasses text match" {
    # The command launches /tmp/x.sh. The hook does not open the script
    # to inspect what it writes.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"bash /tmp/some-script.sh"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

# ---------- §5b: whitelisted interpreter spawns a shell ----------

@test "[documented-gap] awk BEGIN system() bypasses text match" {
    # `awk` is on the read-only first-token whitelist (diagnostic awk
    # over configs is a legitimate, common pattern). Its `system()`
    # builtin spawns /bin/sh with the literal argument. The hook's
    # write-marker scan looks for ` rm `, `>`, `;`, `&&`, `||` in the
    # outer command — it does NOT parse the awk program. Markers like
    # ` rm ` (space-bounded) do not match against `"rm` inside a
    # quoted system() argument.
    #
    # Closed at the filesystem layer with `chflags uchg` (macOS) /
    # `chattr +i` (Linux) on the protected configs — not by teaching
    # the hook to parse awk (which would cascade into parsing every
    # interpreter language: perl -e, python -c, ruby -e, ...).
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"awk '\''BEGIN{system(\"id\")}'\'' settings.json"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

@test "[documented-gap] awk getline through pipe bypasses text match" {
    # `("cmd") | getline var` is awk syntax that invokes /bin/sh from
    # inside the awk program. The pipe `|` here is an awk operator
    # inside the single-quoted program — bash sees it as text, and the
    # hook's write-marker list intentionally does NOT include a bare
    # `|` (it is a normal pipeline operator in legitimate shell
    # commands like `cat foo | head -5`).
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"awk '\''BEGIN{(\"id\") | getline x}'\'' settings.json"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

# ---------- §5b: SCM indirection ----------

@test "[documented-gap] git pull can overwrite config without naming it" {
    # git pull may overwrite any tracked file in the working tree.
    # Config paths are not mentioned in argv, so the hook has nothing
    # to match on. git commands are common enough that denying every
    # git invocation would be impractical.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"git pull"}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}

@test "[documented-gap] git checkout of a tracked config is not caught by name" {
    # `git checkout -- .` restores every tracked file from HEAD,
    # including config files, without naming them. The hook sees only
    # git + flag args.
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"git checkout -- ."}}'
    [ "$status" -eq 0 ] || { printf 'expected allow for documented-gap, got status=%d output=%s\n' "$status" "$output" >&2; return 1; }
}
