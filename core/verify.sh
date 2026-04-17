#!/bin/bash
# totp-presence core: verify.sh
#
# Pure verification primitive. Answers one question: is this 6-digit code
# the current valid TOTP for the installed seed?
#
# Usage:
#   sudo /etc/totp-presence/verify <code>
#   sudo /etc/totp-presence/verify <code> --session <path>
#
# Modes:
#   Without --session:
#     Pure function. Reads /etc/totp-presence/secret, checks the code,
#     exits 0 if valid, 2 if not.
#
#   With --session <path>:
#     On valid code, additionally writes a unix timestamp into <path>
#     and chowns/chmods it to root:wheel 644. The path MUST be under
#     /var/run/totp-presence/<invoking-user>/ — this is enforced — so
#     an integration cannot trick the verifier into clobbering arbitrary
#     files. Session file management (window length, retention,
#     multi-integration layout) is the responsibility of each integration,
#     not of the core.
#
# Layout (FHS-compliant):
#   Static, sysadmin-managed:
#     /etc/totp-presence/secret                       root:wheel 600
#     /etc/totp-presence/verify                       root:wheel 755
#     /etc/totp-presence/<integration>-config         root:wheel 644
#     /etc/totp-presence/<integration>-guard.sh       root:wheel 755
#
#   Runtime, ephemeral (tmpfs on Linux, synthetic on macOS — cleared on reboot):
#     /var/run/totp-presence/                         root:wheel 755 (lazy-create)
#     /var/run/totp-presence/fail-counter             root:wheel 644 (global rate-limit)
#     /var/run/totp-presence/.verify-lock/            root:wheel       (global serialization)
#     /var/run/totp-presence/<user>/                  root:wheel 755 (lazy-create per-user)
#     /var/run/totp-presence/<user>/<integration>-session
#                                                     root:wheel 644
#
#   The runtime tree is per-machine for the lock and counter (one secret →
#   one global rate-limit) and per-user for sessions (each user holds
#   their own presence signal). Reboot clears every runtime artefact;
#   after a reboot the user must re-authenticate. This is intentional:
#   "the owner was at the machine N minutes ago" should not survive a
#   power cycle.
#
# Brute-force protection:
#   verify.sh tracks consecutive failures in a root-owned file at
#   /var/run/totp-presence/fail-counter. After MAX_FAILS consecutive
#   invalid codes, verify is locked out for LOCKOUT_SECONDS. A
#   successful verification clears the counter. The counter is global
#   across users — one secret, one rate-limit.
#
#   To prevent parallel brute-force, verify acquires an exclusive
#   lock (atomic mkdir) at startup, serializing all concurrent
#   calls. This makes the counter reliable regardless of
#   parallelism: expected time-to-break of a 6-digit code is on
#   the order of years (~MAX_FAILS attempts per LOCKOUT_SECONDS).
#
#   Without serialization, a parallel attacker forking N concurrent
#   calls would read the same counter N times and bypass the
#   threshold. The lock closes this gap.
#
# Exit codes:
#   0 — code valid (session written if --session was passed)
#   1 — usage error, missing seed, missing python3, invalid --session path
#   2 — code invalid
#   3 — locked out after too many consecutive failures (try later)
#
# Security notes:
#   - Must be run as root via sudo from a regular user account. The
#     installed sudoers rule grants NOPASSWD execution to a single
#     user for this exact script. SUDO_USER is read to determine
#     the per-user runtime directory — running verify as root
#     directly (without sudo from a normal account) is rejected.
#   - The secret file (/etc/totp-presence/secret) is root:wheel 0600 and
#     readable only by this script.
#   - The 6-digit code is validated by shape before the secret is touched.
#   - TOTP verification uses only Python standard library (hmac,
#     hashlib, struct, base64, time). No pip dependencies.
#   - The secret is passed to python via an env var, not argv, so it
#     never appears in `ps`.

# -------- sane PATH --------
# When invoked via `sudo -n` with a sudoers rule that does not preserve
# secure_path, PATH can be empty or minimal. Ensure core utilities like
# chown, chmod, date are found on both macOS (chown in /usr/sbin) and
# Linux (chown in /usr/bin). Observed failure: `chown: command not
# found`, session write silently degraded.
#
# We deliberately do NOT append the inherited $PATH here. macOS sudo
# does not configure secure_path by default, so the caller can plant
# attacker-controlled directories that would shadow a missing system
# utility (renamed/removed). System utilities live in the four
# directories below; nothing else is needed for verify to do its job.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

set -u

# -------- static + runtime paths --------

INSTALL_DIR="/etc/totp-presence"
SECRET_FILE="$INSTALL_DIR/secret"

RUNTIME_BASE="/var/run/totp-presence"
FAIL_COUNTER_FILE="$RUNTIME_BASE/fail-counter"
LOCK_DIR="$RUNTIME_BASE/.verify-lock"

# Brute-force ceiling. Adjust only if you understand the trade-off:
# lower MAX_FAILS is safer but more hostile to typos; higher
# LOCKOUT_SECONDS is safer but takes longer to recover from a
# lockout. Defaults are calibrated for a single human operator who
# rarely fumbles a code more than twice in a row.
MAX_FAILS=5
LOCKOUT_SECONDS=300   # 5 minutes
LOCK_TIMEOUT=30       # seconds — wait this long for an in-flight verify
LOCK_STALE_AGE=60     # seconds — older than this is considered stale

# -------- test-mode overrides --------
#
# The lifecycle tests need to trip a lockout and then watch it clear
# within seconds, not 5 minutes. Re-reading the constants from env under
# an explicit test-mode gate lets the test suite compress LOCKOUT_SECONDS
# without touching the script.
#
# Why this is safe in production:
#   The installed sudoers rule (see core/setup.sh) does NOT preserve env
#   when a user invokes `sudo /etc/totp-presence/verify`. `sudo` strips
#   everything outside its env_keep list, so TOTP_PRESENCE_TEST_MODE,
#   MAX_FAILS_OVERRIDE and LOCKOUT_SECONDS_OVERRIDE set by a regular
#   user never reach this script. The hook is only reachable when the
#   caller explicitly invokes bash on the source tree under `sudo -E`,
#   which requires root to begin with — i.e. tests in CI or on a dev box.
#
# Do not read these overrides in any path the installed sudoers rule
# can reach.
if [ "${TOTP_PRESENCE_TEST_MODE:-}" = "1" ]; then
    if [ -n "${MAX_FAILS_OVERRIDE:-}" ]; then
        case "$MAX_FAILS_OVERRIDE" in
            ''|*[!0-9]*) : ;;  # ignore garbage
            *) MAX_FAILS="$MAX_FAILS_OVERRIDE" ;;
        esac
    fi
    if [ -n "${LOCKOUT_SECONDS_OVERRIDE:-}" ]; then
        case "$LOCKOUT_SECONDS_OVERRIDE" in
            ''|*[!0-9]*) : ;;
            *) LOCKOUT_SECONDS="$LOCKOUT_SECONDS_OVERRIDE" ;;
        esac
    fi
fi

# -------- helpers --------

set_root_owner() {
    chown root:wheel "$1" 2>/dev/null || chown root:root "$1"
}

ensure_dir() {
    # Lazy-create a runtime directory under root:wheel 755. Idempotent.
    local d="$1"
    if [ ! -d "$d" ]; then
        mkdir -p "$d" 2>/dev/null || return 1
    fi
    chmod 755 "$d" 2>/dev/null || true
    set_root_owner "$d" || true
    return 0
}

# Lazy migration v1 → v2: in v1 the fail-counter lived under
# /etc/totp-presence/. Move it to the runtime base on the first run
# under v2. After a single move it is gone from the legacy location;
# subsequent runs are no-ops. Best-effort — if the move fails (e.g. the
# legacy file is locked or unreadable), drop it: a missing counter is
# treated as "no failures yet", which is the safe default.
migrate_legacy_fail_counter() {
    local legacy="$INSTALL_DIR/fail-counter"
    if [ -f "$legacy" ] && [ ! -e "$FAIL_COUNTER_FILE" ]; then
        mv "$legacy" "$FAIL_COUNTER_FILE" 2>/dev/null || rm -f "$legacy" 2>/dev/null || true
        if [ -f "$FAIL_COUNTER_FILE" ]; then
            chmod 644 "$FAIL_COUNTER_FILE" 2>/dev/null || true
            set_root_owner "$FAIL_COUNTER_FILE" || true
        fi
    fi
}

# -------- require root --------

if [ "$(id -u)" -ne 0 ]; then
    echo "error: verify must be run as root (use sudo)" >&2
    echo "       sudo $INSTALL_DIR/verify <code> [--session <path>]" >&2
    exit 1
fi

# -------- determine invoking user --------
#
# verify must be invoked through `sudo` from a regular (non-root)
# account. SUDO_USER tells us who the human is, which becomes the
# per-user runtime namespace under /var/run/totp-presence/<user>/.
# Running verify as root directly would leave SUDO_USER unset and
# the session would have no per-user scope. Reject that case.

INVOKING_USER="${SUDO_USER:-}"
case "$INVOKING_USER" in
    ''|root)
        echo "error: verify must be invoked through sudo from a regular user account" >&2
        echo "       SUDO_USER is not set (or is 'root') — do not run verify as root directly" >&2
        exit 1
        ;;
esac
# Sanity: only allow user names matching the standard POSIX-portable
# character class so the value is safe to splice into a directory path.
if ! printf '%s' "$INVOKING_USER" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$'; then
    echo "error: SUDO_USER value '$INVOKING_USER' contains characters that are not safe for a path component" >&2
    exit 1
fi

# -------- runtime base setup + legacy migration --------

ensure_dir "$RUNTIME_BASE" || {
    echo "error: failed to create runtime directory at $RUNTIME_BASE" >&2
    exit 1
}
migrate_legacy_fail_counter

# -------- serialize concurrent calls --------
# mkdir is atomic on all POSIX systems (macOS + Linux). Ensures
# brute-force counter cannot be bypassed by parallel forks.
cleanup_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }
trap cleanup_lock EXIT

# Try to detect a stale lock left behind by a SIGKILL'd / OOM'd verify
# and reclaim it without manual `sudo rmdir`. If the lock dir is older
# than LOCK_STALE_AGE seconds, no live verify can be holding it (any
# real verify completes in well under a second, and clients are
# serialised by us). Remove and retry once. If a second mkdir loses a
# race against another verify that just reclaimed it, fall through
# and wait normally — that one is fresh.
reclaim_if_stale() {
    if [ ! -d "$LOCK_DIR" ]; then
        return
    fi
    local lock_mtime now age
    lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null \
                 || stat -c %Y "$LOCK_DIR" 2>/dev/null \
                 || echo 0)
    now=$(date +%s)
    age=$(( now - lock_mtime ))
    if [ "$age" -ge "$LOCK_STALE_AGE" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

_lock_start=$(date +%s)
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ $(( $(date +%s) - _lock_start )) -ge "$LOCK_TIMEOUT" ]; then
        # One last attempt: maybe the holder is dead, give the stale
        # path a chance before refusing the user.
        reclaim_if_stale
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            break
        fi
        echo "error: lock acquisition timed out after ${LOCK_TIMEOUT}s (stale lock at $LOCK_DIR?). Remove manually: sudo rmdir $LOCK_DIR" >&2
        exit 1
    fi
    sleep 0.05
done

# -------- parse arguments --------

CODE="${1:-}"
SESSION_FLAG="${2:-}"
SESSION_PATH="${3:-}"

if [ -z "$CODE" ]; then
    echo "usage: sudo $INSTALL_DIR/verify <6-digit-code> [--session <path>]" >&2
    exit 1
fi

if ! printf '%s' "$CODE" | grep -qE '^[0-9]{6}$'; then
    echo "error: code must be exactly 6 digits" >&2
    exit 1
fi

if [ -n "$SESSION_FLAG" ] && [ "$SESSION_FLAG" != "--session" ]; then
    echo "error: unknown argument '$SESSION_FLAG' (expected --session)" >&2
    exit 1
fi

USER_RUNTIME_DIR="$RUNTIME_BASE/$INVOKING_USER"

if [ "$SESSION_FLAG" = "--session" ]; then
    if [ -z "$SESSION_PATH" ]; then
        echo "error: --session requires a path" >&2
        exit 1
    fi
    case "$SESSION_PATH" in
        "$USER_RUNTIME_DIR"/*)
            case "$SESSION_PATH" in
                *..*|*//*)
                    echo "error: --session path must not contain '..' or '//'" >&2
                    exit 1
                    ;;
            esac
            REL="${SESSION_PATH#$USER_RUNTIME_DIR/}"
            case "$REL" in
                */*)
                    echo "error: --session path must be a direct child of $USER_RUNTIME_DIR (no subdirectories)" >&2
                    exit 1
                    ;;
            esac
            # Restrict --session targets to filenames ending in '-session'.
            # Without this restriction, a caller (or a prompt-injected
            # agent that already holds a valid code) could pass any
            # direct child of the per-user runtime directory and have it
            # overwritten by a unix timestamp and chmod'd to 644. Even
            # though that directory is scoped to the user, the suffix
            # rule defends against a compromised integration writing
            # over its sibling integrations' state. Every documented
            # integration follows this convention (claude-code-session,
            # my-integration-session, ...).
            case "$REL" in
                *-session) ;;
                *)
                    echo "error: --session filename must end with '-session' suffix (e.g. claude-code-session)" >&2
                    exit 1
                    ;;
            esac
            ;;
        # Backwards-compat detection: in v1 the session lived under
        # /etc/totp-presence/<integration>-session. Reject with a
        # specific error so the caller integration knows to update its
        # path resolution. Tihaya migration of session files themselves
        # is the responsibility of each integration's install.sh.
        "$INSTALL_DIR"/*-session)
            echo "error: --session path layout changed in v2." >&2
            echo "       use: $USER_RUNTIME_DIR/<integration>-session" >&2
            echo "       instead of: $INSTALL_DIR/<integration>-session" >&2
            echo "       reinstall the integration to pick up the new path." >&2
            exit 1
            ;;
        *)
            echo "error: --session path must be under $USER_RUNTIME_DIR/" >&2
            exit 1
            ;;
    esac
fi

# -------- require seed and python3 --------

if [ ! -f "$SECRET_FILE" ]; then
    echo "error: seed not found at $SECRET_FILE" >&2
    echo "       has totp-presence been installed? run: sudo ./core/setup.sh install" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found in PATH" >&2
    exit 1
fi

# -------- brute-force lockout check --------
#
# File format (two lines, both root-owned):
#   line 1: current consecutive failure count
#   line 2: unix timestamp of the last failure
#
# A missing/unreadable/garbled file is treated as "no failures yet".

FAIL_COUNT=0
FAIL_LAST_TS=0
if [ -r "$FAIL_COUNTER_FILE" ]; then
    FAIL_COUNT=$(sed -n '1p' "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    FAIL_LAST_TS=$(sed -n '2p' "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    # Sanitize: require integers, otherwise reset.
    case "$FAIL_COUNT" in
        ''|*[!0-9]*) FAIL_COUNT=0 ;;
    esac
    case "$FAIL_LAST_TS" in
        ''|*[!0-9]*) FAIL_LAST_TS=0 ;;
    esac
fi

NOW=$(date +%s)
AGE_SINCE_LAST_FAIL=$(( NOW - FAIL_LAST_TS ))

if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ] && [ "$AGE_SINCE_LAST_FAIL" -lt "$LOCKOUT_SECONDS" ]; then
    REMAINING=$(( LOCKOUT_SECONDS - AGE_SINCE_LAST_FAIL ))
    echo "error: locked out after $FAIL_COUNT consecutive invalid codes. try again in $REMAINING seconds." >&2
    exit 3
fi

# If the lockout window has passed, clear the counter before the next
# attempt so a single wrong code after the cool-off doesn't trip the
# wall immediately.
if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ] && [ "$AGE_SINCE_LAST_FAIL" -ge "$LOCKOUT_SECONDS" ]; then
    if ! rm -f "$FAIL_COUNTER_FILE"; then
        echo "error: failed to clear fail-counter at $FAIL_COUNTER_FILE" >&2
        exit 1
    fi
    FAIL_COUNT=0
    FAIL_LAST_TS=0
fi

# -------- verify --------

SECRET=$(cat "$SECRET_FILE")

# Inline TOTP verification using only Python standard library.
# No pip dependencies. Implements RFC 6238 (TOTP) / RFC 4226 (HOTP).
# The secret is passed via env var, not argv, so it never appears in `ps`.
RESULT=$(SECRET="$SECRET" CODE="$CODE" python3 -c '
import hmac, hashlib, struct, time, base64, os

secret_b32 = os.environ["SECRET"]
code = os.environ["CODE"]
valid_window = 1

try:
    key = base64.b32decode(secret_b32, casefold=True)
except Exception:
    print("INVALID")
    raise SystemExit(0)

now = int(time.time())
for offset in range(-valid_window, valid_window + 1):
    counter = (now // 30) + offset
    msg = struct.pack(">Q", counter)
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    ob = digest[-1] & 0x0F
    tr = struct.unpack(">I", digest[ob:ob + 4])[0] & 0x7FFFFFFF
    expected = f"{tr % 1000000:06d}"
    if hmac.compare_digest(expected, code):
        print("VALID")
        raise SystemExit(0)

print("INVALID")
')

unset SECRET

if [ "$RESULT" != "VALID" ]; then
    NEW_COUNT=$(( FAIL_COUNT + 1 ))
    # Atomic, symlink-safe update of the fail-counter, mirroring the
    # session-write below. Direct redirection ('> "$FAIL_COUNTER_FILE"')
    # follows symlinks: if a hostile symlink were planted at this path
    # (root-only to plant in the runtime base, but possible via earlier
    # bug or install error), the brute-force bookkeeping would land
    # somewhere root can write — e.g. /etc/shadow.
    if [ -L "$FAIL_COUNTER_FILE" ]; then
        echo "error: refusing to write through symlink at $FAIL_COUNTER_FILE" >&2
        exit 1
    fi
    TMP_FC=$(mktemp "${FAIL_COUNTER_FILE}.XXXXXX") || {
        echo "error: failed to create temporary fail-counter alongside $FAIL_COUNTER_FILE" >&2
        exit 1
    }
    if ! {
        printf '%s\n' "$NEW_COUNT"
        printf '%s\n' "$NOW"
    } > "$TMP_FC"; then
        rm -f "$TMP_FC"
        echo "error: failed to write temporary fail-counter" >&2
        exit 1
    fi
    set_root_owner "$TMP_FC"
    chmod 644 "$TMP_FC"
    if ! mv -f "$TMP_FC" "$FAIL_COUNTER_FILE"; then
        rm -f "$TMP_FC"
        echo "error: failed to move temporary fail-counter into place at $FAIL_COUNTER_FILE" >&2
        exit 1
    fi

    if [ "$NEW_COUNT" -ge "$MAX_FAILS" ]; then
        echo "locked out for $LOCKOUT_SECONDS seconds after $NEW_COUNT consecutive failures" >&2
        exit 3
    fi
    echo "invalid" >&2
    exit 2
fi

# -------- success — reset fail counter --------

if ! rm -f "$FAIL_COUNTER_FILE"; then
    echo "error: failed to reset fail-counter at $FAIL_COUNTER_FILE" >&2
    exit 1
fi

# -------- write session (optional) --------
#
# Atomic, symlink-safe write:
#   1. Refuse to write through an existing symlink at SESSION_PATH —
#      a hostile symlink could redirect the timestamp write to /etc/shadow
#      or any root-writable file.
#   2. Stage the new contents in a temp file (mktemp creates with a
#      random suffix in the same directory, so the rename below is on
#      the same filesystem and is atomic). The temp file gets the
#      target ownership and mode before the rename, so consumers
#      never observe a half-written session file with wrong perms.
#   3. mv -f replaces the target atomically. If the target was a
#      regular file, it is unlinked. If the target did not exist,
#      it is created. Either way, no partial state is observable.

if [ "$SESSION_FLAG" = "--session" ] && [ -n "$SESSION_PATH" ]; then
    # Lazy-create the per-user runtime directory only when we are
    # actually about to write a session — verify-without-session never
    # needs it. The directory is root:wheel 755 so the (non-root)
    # owner can read their own session file via their hook.
    ensure_dir "$USER_RUNTIME_DIR" || {
        echo "error: failed to create per-user runtime directory at $USER_RUNTIME_DIR" >&2
        exit 1
    }
    if [ -L "$SESSION_PATH" ]; then
        echo "error: refusing to write through symlink at $SESSION_PATH" >&2
        exit 1
    fi
    TMP_SESSION=$(mktemp "${SESSION_PATH}.XXXXXX") || {
        echo "error: failed to create temporary session file alongside $SESSION_PATH" >&2
        exit 1
    }
    if ! date +%s > "$TMP_SESSION"; then
        rm -f "$TMP_SESSION"
        echo "error: failed to write temporary session file" >&2
        exit 1
    fi
    set_root_owner "$TMP_SESSION"
    chmod 644 "$TMP_SESSION"
    if ! mv -f "$TMP_SESSION" "$SESSION_PATH"; then
        rm -f "$TMP_SESSION"
        echo "error: failed to move temporary session file into place at $SESSION_PATH" >&2
        exit 1
    fi
fi

echo "ok"
exit 0
