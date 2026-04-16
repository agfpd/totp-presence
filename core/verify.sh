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
#     /etc/totp-presence/ — this is enforced — so an integration cannot
#     trick the verifier into clobbering arbitrary files. Session file
#     management (window length, retention, multi-integration layout)
#     is the responsibility of each integration, not of the core.
#
# Brute-force protection:
#   verify.sh tracks consecutive failures in a root-owned file at
#   /etc/totp-presence/fail-counter. After MAX_FAILS consecutive
#   invalid codes, verify is locked out for LOCKOUT_SECONDS. A
#   successful verification clears the counter.
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
#   - Must be run as root. The installed sudoers rule grants NOPASSWD
#     execution to a single user for this exact script.
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

# -------- serialize concurrent calls --------
# mkdir is atomic on all POSIX systems (macOS + Linux). Ensures
# brute-force counter cannot be bypassed by parallel forks.
LOCK_DIR="/etc/totp-presence/.verify-lock"
LOCK_TIMEOUT=30          # seconds — wait this long for an in-flight verify
LOCK_STALE_AGE=60        # seconds — older than this is considered stale
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

INSTALL_DIR="/etc/totp-presence"
SECRET_FILE="$INSTALL_DIR/secret"
FAIL_COUNTER_FILE="$INSTALL_DIR/fail-counter"

# Brute-force ceiling. Adjust only if you understand the trade-off:
# lower MAX_FAILS is safer but more hostile to typos; higher
# LOCKOUT_SECONDS is safer but takes longer to recover from a
# lockout. Defaults are calibrated for a single human operator who
# rarely fumbles a code more than twice in a row.
MAX_FAILS=5
LOCKOUT_SECONDS=300   # 5 minutes

# -------- require root --------

if [ "$(id -u)" -ne 0 ]; then
    echo "error: verify must be run as root (use sudo)" >&2
    echo "       sudo $INSTALL_DIR/verify <code> [--session <path>]" >&2
    exit 1
fi

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

if [ "$SESSION_FLAG" = "--session" ]; then
    if [ -z "$SESSION_PATH" ]; then
        echo "error: --session requires a path" >&2
        exit 1
    fi
    case "$SESSION_PATH" in
        "$INSTALL_DIR"/*)
            case "$SESSION_PATH" in
                *..*|*//*)
                    echo "error: --session path must not contain '..' or '//'" >&2
                    exit 1
                    ;;
            esac
            REL="${SESSION_PATH#$INSTALL_DIR/}"
            case "$REL" in
                */*)
                    echo "error: --session path must be a direct child of $INSTALL_DIR (no subdirectories)" >&2
                    exit 1
                    ;;
            esac
            # Restrict --session targets to filenames ending in '-session'.
            # Without this restriction, a caller (or a prompt-injected
            # agent that already holds a valid code) could pass any
            # direct child of INSTALL_DIR — including the secret, the
            # verify binary itself, an integration's hook script, or
            # the fail-counter — and have it overwritten by a unix
            # timestamp and chmod'd to 644. The session-write path
            # would silently brick the protection it is meant to
            # gate. The '-session' suffix is the convention every
            # documented integration already follows
            # (claude-code-session, my-integration-session, ...).
            case "$REL" in
                *-session) ;;
                *)
                    echo "error: --session filename must end with '-session' suffix (e.g. claude-code-session)" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "error: --session path must be under $INSTALL_DIR/" >&2
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
    # (root-only to plant in /etc/totp-presence/, but possible via
    # earlier integration bug or install error), the brute-force
    # bookkeeping would land somewhere root can write — e.g. /etc/shadow.
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
    chown root:wheel "$TMP_FC" 2>/dev/null || chown root:root "$TMP_FC"
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
#      a hostile symlink (root-only to plant in /etc/totp-presence/,
#      but possible via earlier integration bug or install error)
#      could redirect the timestamp write to /etc/shadow or any
#      root-writable file.
#   2. Stage the new contents in a temp file (mktemp creates with a
#      random suffix in the same directory, so the rename below is on
#      the same filesystem and is atomic). The temp file gets the
#      target ownership and mode before the rename, so consumers
#      never observe a half-written session file with wrong perms.
#   3. mv -f replaces the target atomically. If the target was a
#      regular file, it is unlinked. If the target did not exist,
#      it is created. Either way, no partial state is observable.

if [ "$SESSION_FLAG" = "--session" ] && [ -n "$SESSION_PATH" ]; then
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
    chown root:wheel "$TMP_SESSION" 2>/dev/null || chown root:root "$TMP_SESSION"
    chmod 644 "$TMP_SESSION"
    if ! mv -f "$TMP_SESSION" "$SESSION_PATH"; then
        rm -f "$TMP_SESSION"
        echo "error: failed to move temporary session file into place at $SESSION_PATH" >&2
        exit 1
    fi
fi

echo "ok"
exit 0
