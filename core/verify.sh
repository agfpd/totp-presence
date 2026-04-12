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
#   Important caveat: this counter is rate-limiting, not a hard
#   lock. The read-check-verify-write sequence is NOT serialized,
#   so a parallel attacker forking N concurrent verify calls
#   through the NOPASSWD sudoers rule reads the same pre-check
#   counter N times and bypasses the threshold for that round.
#
#   Concretely:
#   - Against a serial attacker, the counter rate-limits to
#     ~MAX_FAILS attempts per LOCKOUT_SECONDS window. Expected
#     time-to-break of a 6-digit code is on the order of years.
#   - Against a parallel attacker (~100 concurrent forks per
#     round, one round per LOCKOUT_SECONDS), with valid_window=1
#     giving 3 valid codes out of 10^6 at any instant, expected
#     time-to-break drops to roughly two weeks of uninterrupted
#     brute-force.
#
#   Two weeks is still slow enough to dominate any realistic
#   injection scenario (an injected agent will not quietly brute-
#   force for two weeks without tripping other defenses), but it
#   is not the "years" floor that a fully serialized verifier
#   would give. If your threat model needs that hard floor, wrap
#   verify in an external flock, or add a lock around the
#   read-check-verify-write block in this script.
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

set -u

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
    if ! {
        printf '%s\n' "$NEW_COUNT"
        printf '%s\n' "$NOW"
    } > "$FAIL_COUNTER_FILE"; then
        echo "error: failed to update fail-counter at $FAIL_COUNTER_FILE" >&2
        exit 1
    fi
    chown root:wheel "$FAIL_COUNTER_FILE" 2>/dev/null || chown root:root "$FAIL_COUNTER_FILE"
    chmod 644 "$FAIL_COUNTER_FILE"

    if [ "$NEW_COUNT" -ge "$MAX_FAILS" ]; then
        echo "invalid — locked out for $LOCKOUT_SECONDS seconds after $NEW_COUNT consecutive failures" >&2
        exit 2
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

if [ -n "$SESSION_PATH" ]; then
    if ! date +%s > "$SESSION_PATH"; then
        echo "error: failed to write session file at $SESSION_PATH" >&2
        exit 1
    fi
    chown root:wheel "$SESSION_PATH" 2>/dev/null || chown root:root "$SESSION_PATH"
    chmod 644 "$SESSION_PATH"
fi

echo "ok"
exit 0
