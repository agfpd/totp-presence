Russian version: [../docs/ru/core/README.md](../docs/ru/core/README.md)

# core — the verification primitive of totp-presence

The project's core. Does one thing: answers the question "is this
the correct 6-digit TOTP code from the owner?" The answer is yes
or no.

Everything else — session windows, hooks, integrations with specific
agent systems — lives **outside the core**, in `examples/`.

## Contents

```
core/
├── setup.sh         — core installer (run via sudo)
├── verify.sh        — verifier
└── README.md        — this file
```

After installation (`sudo ./core/setup.sh install`) the following
appears on disk:

```
/etc/totp-presence/                    static, sysadmin-managed
├── secret                             root:wheel 600 — secret key (base32)
├── verify                             root:wheel 755 — verifier
└── VERSION                            root:wheel 644 — installed build marker

/etc/sudoers.d/totp-presence           root:wheel 440 — passwordless sudo for verify
```

Four artefacts under root. That is all the static install.

During operation the following ephemeral runtime tree is created
lazily (tmpfs on Linux, synthetic filesystem on macOS — cleared on
reboot):

```
/var/run/totp-presence/                root:wheel 755 — runtime base
├── fail-counter                       root:wheel 644 — failed-attempt counter (global)
├── .verify-lock/                      root:wheel     — concurrency lock (global)
└── <user>/                            root:wheel 755 — per-user namespace
    └── <integration>-session          root:wheel 644 — session timestamp (per-integration)
```

Per-machine for the lock and counter (one secret → one global
rate-limit), per-user for sessions (each user holds their own
presence signal). Reboot clears every runtime artefact; after a
reboot the user must re-authenticate. This is intentional:
"the owner was at the machine N minutes ago" should not survive a
power cycle.

## Updating

After a `git pull` to a newer release, run the upgrade command
instead of re-running `install`:

```sh
sudo ./core/setup.sh update
```

`update` replaces `/etc/totp-presence/verify` and
`/etc/totp-presence/VERSION` with the copies from the source tree
and clears the brute-force fail-counter so the upgraded verifier
starts from a clean slate. It leaves the seed
(`/etc/totp-presence/secret`), the sudoers rule, authenticator
pairings, and every per-integration session file untouched. No
re-enrolment is needed.

If integrations are installed, each one typically has its own
`update` subcommand — see the integration's README
(e.g., [`examples/claude-code-hook/README.md`](../examples/claude-code-hook/README.md)).

The `install` command is the wrong tool for an upgrade: it asks
whether to overwrite the seed (answering wrongly either breaks
the authenticator pairing or aborts), prints a fresh
`otpauth://` URL and QR code, and runs a self-test that blocks
on human input for a current code. `update` avoids all three.

## Public API

### `sudo /etc/totp-presence/verify <code>`

Pure verification. Reads the secret key, compares the 6-digit code
(HMAC-SHA1, RFC 6238), returns an exit code:

- `0` — code correct
- `2` — code incorrect (fail-counter incremented)
- `3` — locked out. Either the counter reached `MAX_FAILS` consecutive
  failures in the last `LOCKOUT_SECONDS` window, or the counter could
  not be persisted on this attempt (fail-closed: this blocks
  brute-force via induced write failures). The stderr message tells
  the two apart.
- `1` — error without counter change: empty input, missing or
  badly-formatted key, missing python3, invalid `--session` path,
  session-file write failure, python3 interpreter failure, or
  unexpected python3 output.

Output: on success — `ok` on stdout. On error — a message on
**stderr** (not stdout). This is important for scripting: stdout is
clean for any outcome other than success.

**Brute-force protection.** After 5 consecutive incorrect codes the
verifier locks out for 5 minutes. A successful verification resets the
counter. Concurrent invocations are serialized via an exclusive lock
(atomic mkdir), so a parallel attacker cannot bypass the counter.

If a verifier was killed mid-flight (SIGKILL, OOM), the lock dir is
left behind and would normally hold every subsequent verify off for
the full 30 s timeout. The verifier reclaims a lock that has been
present longer than ~60 s automatically — `sudo rmdir` is no longer
needed for that case. A live verify that grabbed the lock in the
meantime still keeps it.

### `sudo /etc/totp-presence/verify <code> --session <path>`

Same as above, but on a correct code it **additionally** writes the
current timestamp (unix timestamp) to the specified file. The path is
strictly validated:

- must be inside `/var/run/totp-presence/<invoking-user>/`
  (where `<invoking-user>` is taken from `SUDO_USER` — running verify
  as root directly is rejected)
- must be a direct child of that per-user directory (no subdirectories)
- no `..`, no `//`
- basename must end with `-session` (so a caller cannot redirect the
  write to a sibling integration's state, or to anything else under
  the runtime tree)
- must not be a symlink

The per-user runtime directory is created lazily by the verifier on
the first successful code — the integration installer does not need
to create it.

The write itself is atomic and symlink-safe: contents are staged in a
sibling temp file (`mktemp` in the same directory), the ownership and
mode are set on the temp file, and `mv -f` swaps it into place. No
partial state is observable.

After the swap, the file is `root:wheel 644`.

This is the only way for integrations to securely store a session.
The path and name are chosen by the integration:

```sh
sudo /etc/totp-presence/verify 123456 \
     --session /var/run/totp-presence/$USER/claude-code-session
```

## What the core does NOT do

- Does not know about session windows or their duration.
- Does not know about specific agent systems or their interfaces.
- Does not edit user configurations
  (`~/.claude/settings.json`, etc.).
- Does not provide a "check if session is open" command — that is
  the integration's job: reading its session file and comparing the
  timestamp to the current time.

If it seems like the core should do any of the above — it is most
likely integration logic, and its place is in `examples/`.

## Post-installation verification

```sh
# 1. Pure verification — yes/no only, changes nothing
sudo /etc/totp-presence/verify 123456   # substitute a fresh code
echo $?                                  # 0 = correct, 2 = incorrect

# 2. Verification + session — writes a timestamp to a file
sudo /etc/totp-presence/verify 123456 \
     --session /var/run/totp-presence/$USER/test-session
ls -l /var/run/totp-presence/$USER/test-session    # root:wheel 644
cat /var/run/totp-presence/$USER/test-session      # unix timestamp

# cleanup
sudo rm /var/run/totp-presence/$USER/test-session
```

## How to write your own integration

Minimum:

1. Choose a session file name. The path must end with `-session` and
   live under the per-user runtime directory, e.g.
   `/var/run/totp-presence/<user>/my-integration-session`. The
   verifier will create the directory lazily on the first successful
   code.
2. At every check point, read this file and compare the timestamp to
   the current time minus the window duration.
3. When the session has expired — instruct the user or agent to
   execute:
   ```sh
   sudo /etc/totp-presence/verify <code> --session /var/run/totp-presence/$USER/my-integration-session
   ```
4. That is all. The core handles the rest.

A real-world example — [../examples/claude-code-hook/](../examples/claude-code-hook/).

