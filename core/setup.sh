#!/bin/bash
# totp-presence core: setup.sh
#
# Installs the core primitive: a root-owned TOTP seed, a verifier script,
# and a narrow NOPASSWD sudoers rule scoped to the verifier. Nothing else.
#
# Session files, time windows, hooks, harness integrations — all of that
# lives in separate install scripts under examples/, not in the core.
#
# Usage:
#   sudo ./core/setup.sh install
#   sudo ./core/setup.sh uninstall
#   ./core/setup.sh status       # no sudo required
#
# Requirements:
#   - macOS or Linux
#   - python3 (standard library only, no pip packages needed)
#   - qrencode (optional, for terminal QR — brew install qrencode
#     on macOS, apt install qrencode on Linux)

set -euo pipefail

INSTALL_DIR="/etc/totp-presence"
SECRET_FILE="$INSTALL_DIR/secret"
VERIFY_INSTALLED="$INSTALL_DIR/verify"
SUDOERS_FILE="/etc/sudoers.d/totp-presence"

# Runtime tree — must match verify.sh. `update` clears the fail-counter
# here; `status` and `uninstall` don't need it, they stay under
# INSTALL_DIR.
RUNTIME_BASE="/var/run/totp-presence"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SRC="$SCRIPT_DIR/verify.sh"

# VERSION — single source of truth lives at the repo root. Copied into
# $INSTALL_DIR on install so `./core/setup.sh status` can report it on a
# live host without the source tree being present.
VERSION_SRC="$SCRIPT_DIR/../VERSION"
VERSION_FILE="$INSTALL_DIR/VERSION"
VERSION="unknown"
if [ -f "$VERSION_SRC" ]; then
    _v=$(tr -d '[:space:]' < "$VERSION_SRC" 2>/dev/null || true)
    [ -n "$_v" ] && VERSION="$_v"
    unset _v
fi

# -------- helpers --------

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s %s\n' "$(c_green '✓')" "$*"; }
warn() { printf '  %s %s\n' "$(c_yellow '!')" "$*"; }
die()  { printf '  %s %s\n' "$(c_red '✗')" "$*" >&2; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "this command requires root. run: sudo $0 $*"
    fi
}

require_os() {
    case "$(uname -s)" in
        Darwin|Linux) : ;;
        *) die "unsupported OS. totp-presence runs on macOS and Linux only. On Windows, use WSL." ;;
    esac
}

require_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"
}

invoking_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        printf '%s' "$SUDO_USER"
        return
    fi
    die "could not determine invoking non-root user. Run with sudo from your normal account, not as root."
}

# -------- install --------

cmd_install() {
    require_root "install"
    require_os
    require_python

    # -------- unattended mode --------
    #
    # Non-interactive install path for CI and automated tests. Requires
    # TWO explicit signals so it is never triggered by accident:
    #
    #   1. The --unattended flag on the command line
    #   2. The TOTP_PRESENCE_UNATTENDED_OK=1 environment variable
    #
    # Differences from interactive install:
    #   - No "overwrite existing seed?" prompt (always overwrites)
    #   - No otpauth URL printed (would leak the seed into CI logs)
    #   - No QR rendering
    #   - No 3-attempt self-test (no human at the keyboard)
    #
    # The seed can be supplied explicitly via TOTP_PRESENCE_TEST_SEED (a
    # base32 string) — tests that need to generate valid codes use this
    # to know the seed. If unset, a fresh seed is generated as usual but
    # is NOT printed anywhere; the caller is expected not to need it.
    #
    # Refuse to run unless both gates are present, with a clear error.
    local unattended=0
    for arg in "$@"; do
        case "$arg" in
            --unattended) unattended=1 ;;
        esac
    done
    if [ "$unattended" -eq 1 ]; then
        if [ "${TOTP_PRESENCE_UNATTENDED_OK:-}" != "1" ]; then
            die "--unattended requires TOTP_PRESENCE_UNATTENDED_OK=1 to be set. This mode is for CI and automated tests only; it skips the overwrite prompt, QR, and self-test. Do not run it on a machine you rely on."
        fi
    fi

    local user
    user="$(invoking_user)"

    [ -f "$VERIFY_SRC" ] || die "verify.sh source not found at $VERIFY_SRC"

    say ""
    say "$(c_bold 'totp-presence core install')"
    say "  install dir:  $INSTALL_DIR"
    say "  user:         $user"
    [ "$unattended" -eq 1 ] && say "  mode:         unattended (CI / test)"
    say ""

    if [ -f "$SECRET_FILE" ]; then
        if [ "$unattended" -eq 1 ]; then
            warn "seed already exists at $SECRET_FILE — overwriting (unattended)"
        else
            warn "seed already exists at $SECRET_FILE"
            printf '  overwrite it? existing authenticator pairings will break [y/N] '
            read -r ans
            case "$ans" in y|Y|yes) ok "overwriting existing seed" ;; *) die "aborted by user" ;; esac
        fi
    fi

    mkdir -p "$INSTALL_DIR"
    chown root:wheel "$INSTALL_DIR" 2>/dev/null || chown root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    ok "prepared $INSTALL_DIR"

    # Generate seed using system CSPRNG (os.urandom). No pip packages.
    # In unattended mode, honour TOTP_PRESENCE_TEST_SEED if the caller
    # pre-supplied a seed (the tests need a known seed to synthesise
    # valid codes). A supplied seed is validated as a proper base32
    # string so a typo doesn't leave an unusable install.
    local secret
    if [ "$unattended" -eq 1 ] && [ -n "${TOTP_PRESENCE_TEST_SEED:-}" ]; then
        if ! printf '%s' "$TOTP_PRESENCE_TEST_SEED" | python3 -c 'import sys, base64; base64.b32decode(sys.stdin.read().strip(), casefold=True)' 2>/dev/null; then
            die "TOTP_PRESENCE_TEST_SEED is not valid base32"
        fi
        secret="$TOTP_PRESENCE_TEST_SEED"
    else
        secret=$(python3 -c 'import base64, os; print(base64.b32encode(os.urandom(20)).decode())')
    fi
    printf '%s' "$secret" > "$SECRET_FILE"
    chown root:wheel "$SECRET_FILE" 2>/dev/null || chown root:root "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ok "generated seed ($SECRET_FILE, 600)"

    # Clear any leftover fail-counter from a previous install or
    # a previous aborted self-test. The new seed invalidates any
    # counter tied to the old one.
    rm -f "$INSTALL_DIR/fail-counter"

    # Install verifier.
    install -m 755 "$VERIFY_SRC" "$VERIFY_INSTALLED"
    chown root:wheel "$VERIFY_INSTALLED" 2>/dev/null || chown root:root "$VERIFY_INSTALLED"
    ok "installed $VERIFY_INSTALLED"

    # Install sudoers rule.
    local sudoers_tmp
    sudoers_tmp="$(mktemp)"
    cat > "$sudoers_tmp" <<EOF
# totp-presence: allow $user to run the verifier without a password.
# Scoped exclusively to the verifier script. No other sudo privileges
# are granted. Managed by core/setup.sh.
$user ALL=(root) NOPASSWD: $VERIFY_INSTALLED
EOF
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
        rm -f "$sudoers_tmp"
        die "sudoers validation failed — refusing to install a broken rule"
    fi
    install -m 440 -o root "$sudoers_tmp" "$SUDOERS_FILE" 2>/dev/null || {
        chown root:wheel "$sudoers_tmp" 2>/dev/null || chown root:root "$sudoers_tmp"
        chmod 440 "$sudoers_tmp"
        mv "$sudoers_tmp" "$SUDOERS_FILE"
    }
    rm -f "$sudoers_tmp"
    ok "installed sudoers rule $SUDOERS_FILE"

    # Install VERSION marker so `./core/setup.sh status` can report which
    # build is live. Missing source is a warning, not a failure — users
    # who installed from a tarball without VERSION still get a working
    # core, just without the version field.
    if [ -f "$VERSION_SRC" ]; then
        install -m 644 "$VERSION_SRC" "$VERSION_FILE"
        chown root:wheel "$VERSION_FILE" 2>/dev/null || chown root:root "$VERSION_FILE"
        ok "installed $VERSION_FILE (v$VERSION)"
    else
        warn "VERSION source not found at $VERSION_SRC — core installed without version marker"
    fi

    # In unattended mode, skip the interactive pairing + self-test flow:
    #   - no otpauth URL on stdout (would leak the seed into CI logs)
    #   - no QR
    #   - no 3-attempt self-test (nobody is at the keyboard)
    if [ "$unattended" -eq 1 ]; then
        say ""
        ok "core installation complete (unattended)"
        say ""
        return 0
    fi

    # Print otpauth URL and optional QR.
    say ""
    say "$(c_bold 'Pair your authenticator')"
    local hostname_short
    hostname_short="$(hostname -s 2>/dev/null || hostname)"
    local label="totp-presence:${user}@${hostname_short}"
    local issuer="totp-presence"
    local otpauth="otpauth://totp/${label}?secret=${secret}&issuer=${issuer}"

    say ""
    say "  otpauth URL (paste into your authenticator if you can't scan):"
    say ""
    say "  $(c_red 'WARNING: the URL below contains your TOTP seed in plain text.')"
    say "  $(c_red 'Do NOT screenshot, log, copy-paste into chat, or pipe this output to a file.')"
    say "  $(c_red 'After pairing, clear your terminal scrollback: Cmd+K / clear && printf "\033[3J"')"
    say ""
    say "  $otpauth"
    say ""

    if command -v qrencode >/dev/null 2>&1; then
        say "  scan this QR with your authenticator app:"
        say ""
        qrencode -t ANSIUTF8 "$otpauth"
    else
        warn "qrencode not installed — terminal QR unavailable"
        warn "paste the URL above into your authenticator manually,"
        warn "or install qrencode for QR next time:"
        warn "  macOS:  brew install qrencode"
        warn "  Linux:  apt install qrencode (or your distro equivalent)"
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        say ""
        say "  $(c_bold 'Using Apple Passwords?') It stores TOTP only as an attribute"
        say "  of an existing password entry. Create one first (Passwords → New"
        say "  Password): Title 'totp-presence', any username, any password,"
        say "  Website 'https://totp-presence.local'. Then Codes → + → Scan QR →"
        say "  pick the entry you just made."
    fi

    # Self-test uses the real verifier, so failed attempts dirty the
    # fail-counter. Clear it on any exit from cmd_install (success,
    # warn-after-3, or Ctrl+C), so runtime starts from a clean slate.
    trap 'rm -f "$INSTALL_DIR/fail-counter" 2>/dev/null || true' EXIT

    # Self-test (pure verify, no --session).
    say ""
    say "$(c_bold 'Self-test')"
    say "  Enter the current 6-digit code from your authenticator."
    say ""
    local attempts=3
    local i=1
    while [ "$i" -le "$attempts" ]; do
        printf '  code (attempt %d/%d): ' "$i" "$attempts"
        read -r code
        if "$VERIFY_INSTALLED" "$code" >/dev/null 2>&1; then
            ok "self-test passed"
            break
        fi
        warn "code rejected"
        i=$((i + 1))
    done
    if [ "$i" -gt "$attempts" ]; then
        warn "self-test failed after $attempts attempts — core is installed but"
        warn "your authenticator pairing may be wrong. retry manually:"
        warn "  sudo $VERIFY_INSTALLED <code>"
    fi

    say ""
    ok "core installation complete"
    say ""
    say "$(c_bold 'Next step')"
    say "  The core alone doesn't block anything. To get runtime protection"
    say "  in Claude Code, install the reference integration:"
    say ""
    say "    sudo ./examples/claude-code-hook/install.sh"
    say ""
    say "  Or write your own — see core/README.md for the API contract."
    say ""
}

# -------- update --------
#
# Replace the installed verifier and VERSION marker with a freshly
# checked-out source tree, preserving the seed, the sudoers rule, and
# all per-integration config/session files. The upgrade path for
# existing installs: pull the latest commit, `sudo ./core/setup.sh
# update`, then run the integration's `update` if you have one.
#
# Why a separate command rather than re-running `install`:
#   - `install` asks whether to overwrite the seed, which is the wrong
#     question for a routine upgrade — the operator sees the prompt
#     and reflexively answers one way or the other.
#   - `install` generates and prints an `otpauth://` URL and a QR code
#     for pairing. Printing this on every upgrade is noisy and (worse)
#     mixes the real enrolment flow with the code-bump flow.
#   - `install` runs a self-test that requires a fresh TOTP code. An
#     upgrade shouldn't ask for human input.
#
# What update does:
#   - replace /etc/totp-presence/verify with the script from the source tree
#   - replace /etc/totp-presence/VERSION with the repo's VERSION
#   - clear the fail-counter (both the current /var/run location and the
#     legacy /etc location) so the upgraded verifier doesn't inherit an
#     active lockout from the previous version's rate-limit state.
#
# What update does NOT touch:
#   - the seed (/etc/totp-presence/secret) — authenticator pairings stay valid
#   - the sudoers rule — the verifier's path is unchanged, the rule still applies
#   - integration configs and session files — each integration has its
#     own `update` command if it needs one

cmd_update() {
    require_root "update"
    require_os
    require_python

    [ -f "$VERIFY_SRC" ] || die "verify.sh source not found at $VERIFY_SRC"
    [ -f "$VERIFY_INSTALLED" ] || die "core is not installed. run first: sudo $0 install"
    [ -f "$SECRET_FILE" ] || die "secret not found at $SECRET_FILE — core state is inconsistent; run 'sudo $0 install' and pair the authenticator again"

    local old_version="unknown"
    if [ -f "$VERSION_FILE" ]; then
        _ov=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
        [ -n "${_ov:-}" ] && old_version="$_ov"
        unset _ov
    fi

    say ""
    say "$(c_bold 'totp-presence core update')"
    say "  old version: $old_version"
    say "  new version: $VERSION"
    say ""

    # Replace verifier. `install -m 755` creates or overwrites atomically
    # via the same mechanism as first install; no half-written verifier
    # is ever observable by a concurrent sudo invocation.
    install -m 755 "$VERIFY_SRC" "$VERIFY_INSTALLED"
    chown root:wheel "$VERIFY_INSTALLED" 2>/dev/null || chown root:root "$VERIFY_INSTALLED"
    ok "replaced $VERIFY_INSTALLED"

    # Replace VERSION marker. Missing source is a warning, not an error.
    if [ -f "$VERSION_SRC" ]; then
        install -m 644 "$VERSION_SRC" "$VERSION_FILE"
        chown root:wheel "$VERSION_FILE" 2>/dev/null || chown root:root "$VERSION_FILE"
        ok "updated $VERSION_FILE ($old_version → $VERSION)"
    else
        warn "VERSION source not found at $VERSION_SRC — left existing marker unchanged"
    fi

    # Clear the fail-counter so the upgrade starts from a clean slate.
    # Runtime location (v2) is authoritative; the legacy /etc path is a
    # best-effort cleanup for very old installations that never migrated.
    if [ -f "$RUNTIME_BASE/fail-counter" ]; then
        rm -f "$RUNTIME_BASE/fail-counter"
        ok "cleared runtime fail-counter at $RUNTIME_BASE/fail-counter"
    fi
    if [ -f "$INSTALL_DIR/fail-counter" ]; then
        rm -f "$INSTALL_DIR/fail-counter"
        ok "cleared legacy fail-counter at $INSTALL_DIR/fail-counter"
    fi

    say ""
    ok "core update complete — seed and sudoers rule preserved"
    say ""
    say "  Authenticator pairings remain valid. Any open integration"
    say "  session files are untouched and continue to tick against"
    say "  their configured windows."
    say ""
    say "$(c_bold 'Next step')"
    say "  If you have integrations installed, update each one in turn:"
    say ""
    say "    sudo ./examples/claude-code-hook/install.sh update"
    say ""
}

# -------- uninstall --------

cmd_uninstall() {
    require_root "uninstall"
    say ""
    say "$(c_bold 'totp-presence core uninstall')"

    [ -f "$SUDOERS_FILE" ] && { rm -f "$SUDOERS_FILE"; ok "removed $SUDOERS_FILE"; } || warn "$SUDOERS_FILE did not exist"
    [ -f "$SECRET_FILE" ] && { rm -f "$SECRET_FILE"; ok "removed $SECRET_FILE"; }
    [ -f "$VERIFY_INSTALLED" ] && { rm -f "$VERIFY_INSTALLED"; ok "removed $VERIFY_INSTALLED"; }
    [ -f "$VERSION_FILE" ] && { rm -f "$VERSION_FILE"; ok "removed $VERSION_FILE"; }
    [ -f "$INSTALL_DIR/fail-counter" ] && { rm -f "$INSTALL_DIR/fail-counter"; ok "removed $INSTALL_DIR/fail-counter"; }

    # If the install directory is empty (no integrations left), remove it.
    if [ -d "$INSTALL_DIR" ]; then
        if [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
            rmdir "$INSTALL_DIR" && ok "removed empty $INSTALL_DIR"
        else
            warn "$INSTALL_DIR is not empty (integration files still present); left in place"
            warn "  contents: $(ls "$INSTALL_DIR" | tr '\n' ' ')"
        fi
    fi

    say ""
    ok "core uninstall complete"
    say ""
    warn "if you installed any integrations (claude-code-hook etc), uninstall"
    warn "them separately with their own uninstall scripts."
}

# -------- status --------

cmd_status() {
    say ""
    say "$(c_bold 'totp-presence core status')"
    [ -d "$INSTALL_DIR" ] && ok "install dir:  $INSTALL_DIR" || warn "install dir:  $INSTALL_DIR (missing)"
    if [ -f "$VERSION_FILE" ]; then
        ok "version:      $(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)"
    else
        warn "version:      unknown (no $VERSION_FILE)"
    fi
    for f in "$SECRET_FILE" "$VERIFY_INSTALLED" "$SUDOERS_FILE"; do
        [ -e "$f" ] && ok "$(ls -l "$f" 2>/dev/null)" || warn "missing: $f"
    done
    if [ -d "$INSTALL_DIR" ]; then
        say ""
        say "  all files in $INSTALL_DIR (including integration session/config files):"
        ls -l "$INSTALL_DIR" 2>/dev/null | sed 's/^/    /'
    fi
    say ""
}

usage() {
    cat <<EOF
totp-presence core — the verification primitive

Usage:
  sudo $0 install      generate seed, install verifier, add sudoers rule
  sudo $0 update       replace verifier + VERSION, preserve seed and sudoers (upgrade path)
  sudo $0 uninstall    remove seed, verifier, sudoers rule
  $0 status            show what's installed (no sudo needed)

The core alone is not a runtime defence. To actually block anything
in a real agent, install an integration from examples/ afterwards.
EOF
}

main() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local cmd="$1"; shift
    case "$cmd" in
        install)   cmd_install "$@" ;;
        update)    cmd_update "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        status)    cmd_status "$@" ;;
        -h|--help|help) usage ;;
        *)         usage; exit 1 ;;
    esac
}

main "$@"
