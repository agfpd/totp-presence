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
#   /etc/totp-presence/claude-code-session        root:wheel 644 — timestamp (init 0)
#   /etc/totp-presence/claude-code-config         root:wheel 644 — WINDOW_SECONDS
#
# It does NOT edit ~/.claude/settings.json automatically. It prints a
# JSON snippet you can merge in manually. Claude Code will ask your
# explicit approval before saving any edit to settings.json anyway,
# even in bypass-permissions mode — so there's no honest shortcut here.
#
# Usage:
#   sudo ./examples/claude-code-hook/install.sh [--window-minutes N] [--messaging-tools "tool1|tool2"]
#   sudo ./examples/claude-code-hook/install.sh uninstall

set -euo pipefail

INSTALL_DIR="/etc/totp-presence"
SESSION_FILE="$INSTALL_DIR/claude-code-session"
CONFIG_FILE="$INSTALL_DIR/claude-code-config"
GUARD_INSTALLED="$INSTALL_DIR/claude-code-guard.sh"
VERIFY_INSTALLED="$INSTALL_DIR/verify"

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

cmd_install() {
    local window_minutes="$DEFAULT_WINDOW_MINUTES"
    local messaging_tools="$MESSAGING_TOOLS"
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
            *) die "unknown flag: $1" ;;
        esac
        shift || true
    done

    require_root "install"
    require_core
    [ -f "$GUARD_SRC" ] || die "guard.sh source not found at $GUARD_SRC"

    local window_seconds=$(( window_minutes * 60 ))

    # Preserve existing config values on reinstall.
    # If --messaging-tools was not passed but config already has
    # EXTRA_SAFE_TOOLS, keep the old value. Same for EDIT_WRITE_CONFIG_ONLY.
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
    local edit_write_config_only="${existing_ewco:-}"

    say ""
    say "$(c_bold 'claude-code-hook install')"
    say "  window:    ${window_minutes} min (${window_seconds} s)"
    if [ -n "$messaging_tools" ]; then
        say "  messaging: ${messaging_tools}"
    fi
    say ""

    # Install guard hook.
    install -m 755 "$GUARD_SRC" "$GUARD_INSTALLED"
    chown root:wheel "$GUARD_INSTALLED" 2>/dev/null || chown root:root "$GUARD_INSTALLED"
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
    chown root:wheel "$CONFIG_FILE" 2>/dev/null || chown root:root "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    ok "wrote $CONFIG_FILE (WINDOW_SECONDS=$window_seconds)"

    # Initialize session file (expired).
    printf '0' > "$SESSION_FILE"
    chown root:wheel "$SESSION_FILE" 2>/dev/null || chown root:root "$SESSION_FILE"
    chmod 644 "$SESSION_FILE"
    ok "initialized $SESSION_FILE (expired)"

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
    say "  WebSearch) and requires a fresh TOTP session for everything else."
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
    say "    sudo /etc/totp-presence/verify 123456 --session $SESSION_FILE"
    say ""
    ok "claude-code-hook installed"
}

cmd_uninstall() {
    require_root "uninstall"
    say ""
    say "$(c_bold 'claude-code-hook uninstall')"
    for f in "$GUARD_INSTALLED" "$SESSION_FILE" "$CONFIG_FILE"; do
        [ -e "$f" ] && { rm -f "$f"; ok "removed $f"; } || warn "$f did not exist"
    done
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
  sudo $0 uninstall

Options:
  --window-minutes N          Session window in minutes (default: 25)
  --messaging-tools "tools"   Pipe-separated tool names to allow without
                              a session (e.g. Telegram reply tool). Required
                              for headless agents using matcher ".*".

The core must be installed first: sudo ./core/setup.sh install
EOF
}

main() {
    local cmd="${1:-install}"
    case "$cmd" in
        install)   shift || true; cmd_install "$@" ;;
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
