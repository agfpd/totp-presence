#!/bin/bash
# claude-code-hook: install.sh
#
# Installs the Claude Code reference integration on top of the core.
#
# Prerequisite: the core must already be installed (run `sudo
# ./core/setup.sh install` first). This script adds only the
# integration-specific pieces:
#
#   /etc/totp-presence/claude-code-guard.sh       root:wheel 755 — PreToolUse hook
#   /etc/totp-presence/claude-code-config         root:wheel 644 — WINDOW_SECONDS
#
# The session file lives under the FHS-compliant runtime tree and is
# created lazily by the verifier on the first successful TOTP code:
#
#   /var/run/totp-presence/<user>/claude-code-session
#
# It is per-user (each non-root account has its own session) and
# ephemeral (the runtime tree is tmpfs on Linux, synthetic on macOS,
# cleared at reboot). The installer never creates it directly.
#
# This script does NOT edit ~/.claude/settings.json automatically. It
# prints a JSON snippet you can merge in manually. Claude Code will ask
# your explicit approval before saving any edit to settings.json
# anyway, even in bypass-permissions mode — so there's no honest
# shortcut here.
#
# Usage:
#   sudo ./examples/claude-code-hook/install.sh [--window-minutes N] [--messaging-tools "tool1|tool2"]
#   sudo ./examples/claude-code-hook/install.sh uninstall

set -euo pipefail

INSTALL_DIR="/etc/totp-presence"
CONFIG_FILE="$INSTALL_DIR/claude-code-config"
GUARD_INSTALLED="$INSTALL_DIR/claude-code-guard.sh"
VERIFY_INSTALLED="$INSTALL_DIR/verify"

# Runtime tree (per-machine + per-user). Sessions live under
# $RUNTIME_BASE/<user>/<integration>-session and are created lazily by
# the verifier. The installer only references this path for migration
# of legacy v1 layout and for printing the example verify command.
RUNTIME_BASE="/var/run/totp-presence"

# Legacy v1 path — used only for one-shot migration on reinstall.
LEGACY_SESSION_FILE="$INSTALL_DIR/claude-code-session"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SRC="$SCRIPT_DIR/guard.sh"

DEFAULT_WINDOW_MINUTES=25
MESSAGING_TOOLS=""

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s %s\n' "$(c_green '✓')" "$*"; }
warn() { printf '  %s %s\n' "$(c_yellow '!')" "$*"; }
die()  { printf '  %s %s\n' "$(c_red '✗')" "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this command requires root. run: sudo $0 $*"
}

require_core() {
    [ -f "$VERIFY_INSTALLED" ] || die "core is not installed. run first: sudo ./core/setup.sh install"
}

invoking_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        printf '%s' "$SUDO_USER"
        return
    fi
    die "could not determine invoking non-root user. Run with sudo from your normal account, not as root."
}

set_root_owner() {
    chown root:wheel "$1" 2>/dev/null || chown root:root "$1"
}

# Lazy migration v1 → v2 for the session file. v1 stored the session
# under /etc/totp-presence/claude-code-session; v2 stores it under
# /var/run/totp-presence/<user>/claude-code-session. On reinstall, if
# the legacy file exists, move its content (the session timestamp) to
# the new per-user location and remove the legacy file. Best-effort —
# missing or unreadable legacy means there is nothing to migrate.
migrate_legacy_session() {
    local user="$1"
    [ -f "$LEGACY_SESSION_FILE" ] || return 0
    local user_dir="$RUNTIME_BASE/$user"
    if [ ! -d "$user_dir" ]; then
        mkdir -p "$user_dir" 2>/dev/null || true
        chmod 755 "$user_dir" 2>/dev/null || true
        set_root_owner "$user_dir" || true
    fi
    local target="$user_dir/claude-code-session"
    if [ ! -e "$target" ]; then
        mv "$LEGACY_SESSION_FILE" "$target" 2>/dev/null || rm -f "$LEGACY_SESSION_FILE" 2>/dev/null || true
        if [ -f "$target" ]; then
            chmod 644 "$target" 2>/dev/null || true
            set_root_owner "$target" || true
            ok "migrated legacy session $LEGACY_SESSION_FILE -> $target"
        fi
    else
        rm -f "$LEGACY_SESSION_FILE" 2>/dev/null || true
        ok "removed obsolete legacy session $LEGACY_SESSION_FILE (new location already populated)"
    fi
}

cmd_install() {
    local window_minutes="$DEFAULT_WINDOW_MINUTES"
    local messaging_tools="$MESSAGING_TOOLS"
    # mode_flag tracks the explicit operator choice for EDIT_WRITE_CONFIG_ONLY:
    #   ""        — not specified, preserve existing (with a warning)
    #   "off"     — --full-lockdown, force EDIT_WRITE_CONFIG_ONLY off
    #   "on"      — --selective-edit-write, force EDIT_WRITE_CONFIG_ONLY=true
    local mode_flag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --window-minutes)
                shift
                window_minutes="${1:-}"
                [ -n "$window_minutes" ] || die "--window-minutes requires a value"
                printf '%s' "$window_minutes" | grep -qE '^[0-9]+$' || die "--window-minutes must be a positive integer"
                [ "$window_minutes" -gt 0 ] || die "--window-minutes must be > 0"
                ;;
            --messaging-tools)
                shift
                messaging_tools="${1:-}"
                [ -n "$messaging_tools" ] || die "--messaging-tools requires a value (pipe-separated tool names)"
                # Validate: each pipe-separated element must be a valid tool name
                # (alphanumeric, underscores, no regex metacharacters).
                # This prevents accidental regex injection into guard.sh's grep -E.
                if ! printf '%s' "$messaging_tools" | grep -qE '^[a-zA-Z0-9_]+(\|[a-zA-Z0-9_]+)*$'; then
                    die "--messaging-tools: each tool name must match [a-zA-Z0-9_], separated by |. Got: $messaging_tools"
                fi
                ;;
            --full-lockdown)
                # Force EDIT_WRITE_CONFIG_ONLY off: every Edit/Write requires
                # a session, regardless of path. Pair this with matcher ".*".
                [ "$mode_flag" = "on" ] && die "--full-lockdown conflicts with --selective-edit-write"
                mode_flag="off"
                ;;
            --selective-edit-write)
                # Force EDIT_WRITE_CONFIG_ONLY=true: Edit/Write on non-config
                # files pass through without a session; only protected config
                # paths require TOTP. Pair with a narrow matcher.
                [ "$mode_flag" = "off" ] && die "--selective-edit-write conflicts with --full-lockdown"
                mode_flag="on"
                ;;
            *) die "unknown flag: $1" ;;
        esac
        shift || true
    done

    require_root "install"
    require_core
    [ -f "$GUARD_SRC" ] || die "guard.sh source not found at $GUARD_SRC"

    local user
    user="$(invoking_user)"

    local window_seconds=$(( window_minutes * 60 ))

    # Preserve existing config values on reinstall.
    # If --messaging-tools was not passed but config already has
    # EXTRA_SAFE_TOOLS, keep the old value.
    #
    # EDIT_WRITE_CONFIG_ONLY is handled differently: it is a security-
    # critical mode (it determines whether non-config Edit/Write bypass
    # the session check), so silent preservation across reinstalls is a
    # footgun. If the operator switched the matcher in settings.json
    # from a narrow selective list to ".*" but forgot to reset this
    # flag, every Edit/Write would pass through without TOTP. Require
    # an explicit mode flag, or warn loudly when preserving.
    local existing_est=""
    local existing_ewco=""
    if [ -r "$CONFIG_FILE" ]; then
        existing_est=$(grep -E '^[[:space:]]*EXTRA_SAFE_TOOLS[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null \
                       | head -1 \
                       | sed -E 's/^[[:space:]]*EXTRA_SAFE_TOOLS[[:space:]]*=[[:space:]]*//; s/^"//; s/"$//; s/^'\''//; s/'\''$//; s/[[:space:]]+$//') || true
        existing_ewco=$(grep -E '^[[:space:]]*EDIT_WRITE_CONFIG_ONLY[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null \
                       | head -1 \
                       | sed -E 's/^[[:space:]]*EDIT_WRITE_CONFIG_ONLY[[:space:]]*=[[:space:]]*//; s/^"//; s/"$//; s/^'\''//; s/'\''$//; s/[[:space:]]+$//') || true
    fi
    if [ -z "$messaging_tools" ] && [ -n "$existing_est" ]; then
        messaging_tools="$existing_est"
    fi

    local edit_write_config_only=""
    case "$mode_flag" in
        off)
            edit_write_config_only=""
            ;;
        on)
            edit_write_config_only="true"
            ;;
        "")
            # No explicit flag — preserve existing, but warn so the
            # operator notices what they inherited.
            edit_write_config_only="${existing_ewco:-}"
            if [ "$edit_write_config_only" = "true" ]; then
                warn "preserving EDIT_WRITE_CONFIG_ONLY=true from existing config."
                warn "  Non-config Edit/Write will bypass the session check."
                warn "  If your settings.json matcher is now '.*' or has widened,"
                warn "  re-run with --full-lockdown to require TOTP for every Edit/Write."
                warn "  Pass --selective-edit-write to acknowledge and silence this warning."
            fi
            ;;
    esac

    local session_file="$RUNTIME_BASE/$user/claude-code-session"

    say ""
    say "$(c_bold 'claude-code-hook install')"
    say "  user:      ${user}"
    say "  window:    ${window_minutes} min (${window_seconds} s)"
    say "  session:   ${session_file} (created lazily on first verify)"
    if [ -n "$messaging_tools" ]; then
        say "  messaging: ${messaging_tools}"
    fi
    say ""

    # Install guard hook.
    install -m 755 "$GUARD_SRC" "$GUARD_INSTALLED"
    set_root_owner "$GUARD_INSTALLED"
    ok "installed $GUARD_INSTALLED"

    # Write config.
    #
    # Format: one \`KEY=VALUE\` line per setting. This file is PARSED
    # (not sourced) by guard.sh using grep — do not add shell code,
    # command substitutions, or multi-line values. They will be
    # silently ignored at best and become a security mine at worst
    # if the file ever loses its root-only write permission.
    cat > "$CONFIG_FILE" <<EOF
# claude-code-hook integration config for totp-presence.
#
# This file is PARSED AS DATA by guard.sh, not executed. Only simple
# \`KEY=VALUE\` lines are read. Do not add shell code here — it would
# be ignored in normal operation and become a latent code-execution
# hazard if this file ever became writable by a non-root user.
#
# Edited only via: sudo ./examples/claude-code-hook/install.sh [flags]
WINDOW_SECONDS=$window_seconds
EOF
    # Append optional settings only when they have values.
    # This keeps a clean default config for simple installations.
    if [ -n "$messaging_tools" ]; then
        cat >> "$CONFIG_FILE" <<EOF
EXTRA_SAFE_TOOLS=$messaging_tools
EOF
    fi
    if [ -n "$edit_write_config_only" ]; then
        cat >> "$CONFIG_FILE" <<EOF
EDIT_WRITE_CONFIG_ONLY=$edit_write_config_only
EOF
    fi
    set_root_owner "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    ok "wrote $CONFIG_FILE (WINDOW_SECONDS=$window_seconds)"

    # One-shot migration of any legacy v1 session file.
    migrate_legacy_session "$user"

    say ""
    say "$(c_bold 'Next step: enable the hook in Claude Code')"
    say "  Merge this into ~/.claude/settings.json under hooks.PreToolUse:"
    say ""
    cat <<EOF
    {
      "matcher": ".*",
      "hooks": [
        {
          "type": "command",
          "command": "$GUARD_INSTALLED"
        }
      ]
    }
EOF
    say ""
    say "  The matcher is '.*' by design: fail-safe default. Every tool call"
    say "  arrives at the hook, which short-circuits an internal stable list"
    say "  of unambiguously read-only tools (Read, Glob, Grep, LS, TodoWrite,"
    say "  WebSearch, ToolSearch) and requires a fresh TOTP session for everything else."
    say "  New or custom tools are protected by default, not by mistake left"
    say "  unprotected."
    say ""
    say "  Claude Code will prompt you to approve the edit before saving."
    say ""
    if [ -n "$messaging_tools" ]; then
        say "$(c_bold 'Messaging tools (EXTRA_SAFE_TOOLS):')"
        say "  The following tools are allowed without a session so the agent"
        say "  can ask you for a TOTP code:"
        say "    $messaging_tools"
        say ""
    else
        say "$(c_yellow 'Headless agent? (Telegram, Slack, etc.)')"
        say "  If your agent communicates through a messaging channel, it needs"
        say "  the messaging tool unblocked — otherwise it cannot ask for a code"
        say "  and will deadlock. Re-run with:"
        say "    sudo $0 --messaging-tools \"mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment\""
        say "  Or edit /etc/totp-presence/claude-code-config directly (sudo):"
        say "    EXTRA_SAFE_TOOLS=mcp__plugin_telegram_telegram__reply|..."
        say ""
    fi
    say "$(c_bold 'How the agent opens a session when it is blocked:')"
    say "  Ask the human for a TOTP code, then:"
    say "    sudo /etc/totp-presence/verify 123456 --session $session_file"
    say ""
    say "  The session file is created on the first successful verify and"
    say "  lives in the per-user runtime tree (cleared on reboot)."
    say ""
    ok "claude-code-hook installed"
}

# -------- update --------
#
# Replace the installed guard.sh with the source from the current
# checkout, preserving the config file (WINDOW_SECONDS,
# EXTRA_SAFE_TOOLS, EDIT_WRITE_CONFIG_ONLY) and the per-user session
# file. Intended as the routine upgrade path after `git pull` +
# `sudo ../../core/setup.sh update`.
#
# Why separate from `install`:
#   - install re-reads flags from argv and regenerates the config
#     file. That's right for the first setup or for a re-pinning of
#     EDIT_WRITE_CONFIG_ONLY, but wrong for a code-only bump.
#   - install prints the full onboarding block (hook snippet, messaging
#     guidance, verify command). On every upgrade that's noise.
#   - install warns loudly about inherited EDIT_WRITE_CONFIG_ONLY=true.
#     That warning is helpful when the operator is actively switching
#     matchers in settings.json; it's noise when they just pulled a
#     bug fix.
#
# What update does:
#   - replace /etc/totp-presence/claude-code-guard.sh with the source guard.sh
#   - run the legacy v1 → v2 session migration (no-op after the first
#     v0.2 run, idempotent)
#
# What update does NOT touch:
#   - /etc/totp-presence/claude-code-config — preserves WINDOW_SECONDS,
#     EXTRA_SAFE_TOOLS, EDIT_WRITE_CONFIG_ONLY
#   - per-user session files — any currently open session stays open
#   - ~/.claude/settings.json — the entry still points at the same
#     guard path, so Claude Code picks up the new hook on the next
#     tool invocation

cmd_update() {
    require_root "update"
    require_core
    [ -f "$GUARD_SRC" ] || die "guard.sh source not found at $GUARD_SRC"
    [ -f "$GUARD_INSTALLED" ] || die "integration is not installed. run first: sudo $0 install"

    local user
    user="$(invoking_user)"

    say ""
    say "$(c_bold 'claude-code-hook update')"
    say "  user:            $user"
    say "  guard script:    $GUARD_INSTALLED"
    if [ -f "$CONFIG_FILE" ]; then
        say "  config (kept):   $CONFIG_FILE"
    else
        warn "config file $CONFIG_FILE missing — integration is in an odd state"
    fi
    say ""

    # Replace guard. install -m 755 performs the same atomic swap as on
    # first install; an in-flight Claude Code tool call either sees the
    # old guard or the new one, never a half-written one.
    install -m 755 "$GUARD_SRC" "$GUARD_INSTALLED"
    set_root_owner "$GUARD_INSTALLED"
    ok "replaced $GUARD_INSTALLED"

    # Legacy v1 → v2 session migration. Idempotent; after the first v0.2
    # run it's a no-op, but cheap enough to run on every update in case
    # the host somehow missed it on the v0.2 bootstrap.
    migrate_legacy_session "$user"

    say ""
    ok "claude-code-hook update complete — config and session preserved"
    say ""
    say "  The entry in ~/.claude/settings.json still points at the"
    say "  same guard path. Claude Code picks up the new guard on the"
    say "  next tool invocation — no restart required."
    say ""
}

cmd_uninstall() {
    require_root "uninstall"
    say ""
    say "$(c_bold 'claude-code-hook uninstall')"
    # Remove static integration files.
    for f in "$GUARD_INSTALLED" "$CONFIG_FILE"; do
        [ -e "$f" ] && { rm -f "$f"; ok "removed $f"; } || warn "$f did not exist"
    done
    # Remove any leftover legacy session from v1 layout.
    [ -e "$LEGACY_SESSION_FILE" ] && { rm -f "$LEGACY_SESSION_FILE"; ok "removed legacy $LEGACY_SESSION_FILE"; } || true
    # Remove this integration's session files across all users on the
    # machine. Each lives at $RUNTIME_BASE/<user>/claude-code-session.
    if [ -d "$RUNTIME_BASE" ]; then
        local removed_any=""
        for user_dir in "$RUNTIME_BASE"/*/; do
            [ -d "$user_dir" ] || continue
            local s="${user_dir%/}/claude-code-session"
            if [ -e "$s" ]; then
                rm -f "$s"
                ok "removed $s"
                removed_any="1"
            fi
        done
        [ -z "$removed_any" ] && warn "no per-user session files found under $RUNTIME_BASE/*/"
    fi
    say ""
    warn "Manual step: remove the matcher from ~/.claude/settings.json."
    warn "  jq '(.hooks.PreToolUse) |= map(select(.hooks[0].command != \"$GUARD_INSTALLED\"))' \\"
    warn "    ~/.claude/settings.json > ~/.claude/settings.json.new && \\"
    warn "    mv ~/.claude/settings.json.new ~/.claude/settings.json"
    say ""
    ok "claude-code-hook uninstalled"
}

usage() {
    cat <<EOF
claude-code-hook — reference totp-presence integration for Claude Code

Usage:
  sudo $0 [install] [--window-minutes N] [--messaging-tools "tool1|tool2"]
                    [--full-lockdown | --selective-edit-write]
  sudo $0 update              replace guard.sh, preserve config and session
  sudo $0 uninstall

Options (for install only — update keeps existing values):
  --window-minutes N          Session window in minutes (default: 25)
  --messaging-tools "tools"   Pipe-separated tool names to allow without
                              a session (e.g. Telegram reply tool). Required
                              for headless agents using matcher ".*".
  --full-lockdown             Force EDIT_WRITE_CONFIG_ONLY off. Every
                              Edit/Write requires a session, regardless of
                              path. Pair with matcher ".*". This is the
                              fail-safe default for a fresh install.
  --selective-edit-write      Force EDIT_WRITE_CONFIG_ONLY=true. Edit/Write
                              on non-config files pass through without a
                              session; only protected config paths
                              (settings.json, CLAUDE.md, .claude/agents/*)
                              require TOTP. Pair with a narrow matcher
                              such as "Edit|Write|mcp__peekaboo__.*".

If neither --full-lockdown nor --selective-edit-write is given, an
existing EDIT_WRITE_CONFIG_ONLY value is preserved with a warning.
Picking one explicitly silences the warning and pins the mode.

The \`update\` command replaces only the guard script and is the
intended upgrade path after \`git pull\` + \`sudo ../../core/setup.sh
update\`. It never re-reads the installer's flags and never asks about
inherited config values — the existing config file is kept verbatim.
To change window size or messaging tools after install, re-run with
\`install\` (reinstall-safe: config values are preserved silently
unless a flag overrides them).

The session file is created lazily by the verifier on the first
successful TOTP code. It lives at
/var/run/totp-presence/<user>/claude-code-session and is cleared at
reboot. The installer never creates it directly.

The core must be installed first: sudo ./core/setup.sh install
EOF
}

main() {
    local cmd="${1:-install}"
    case "$cmd" in
        install)   shift || true; cmd_install "$@" ;;
        update)    shift || true; cmd_update "$@" ;;
        uninstall) shift || true; cmd_uninstall "$@" ;;
        -h|--help|help) usage ;;
        *)
            # If the first arg is --something, treat as install with flags.
            case "$cmd" in
                --*) cmd_install "$@" ;;
                *)   usage; exit 1 ;;
            esac
            ;;
    esac
}

main "$@"
