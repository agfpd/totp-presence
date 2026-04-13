Russian version: [README.ru.md](./README.ru.md)

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
/etc/totp-presence/
├── secret           root:wheel 600 — secret key (base32)
└── verify           root:wheel 755 — verifier

/etc/sudoers.d/totp-presence        root:wheel 440 — passwordless sudo for verify
```

Three artifacts under root. That is all.

During operation `/etc/totp-presence/fail-counter` (root:wheel 644)
may also appear — a counter of failed attempts for brute-force
protection. Created automatically, reset upon successful verification.

## Public API

### `sudo /etc/totp-presence/verify <code>`

Pure verification. Reads the secret key, compares the 6-digit code
(HMAC-SHA1, RFC 6238), returns an exit code:

- `0` — code correct
- `2` — code incorrect
- `3` — locked out: too many consecutive incorrect attempts
- `1` — error (empty input, missing key, missing python3, invalid
  `--session` path, etc.)

Output: on success — `ok` on stdout. On error — a message on
**stderr** (not stdout). This is important for scripting: stdout is
clean for any outcome other than success.

**Brute-force protection.** After 5 consecutive incorrect codes the
verifier locks out for 5 minutes. A successful verification resets the
counter. Concurrent invocations are serialized via an exclusive lock
(atomic mkdir), so a parallel attacker cannot bypass the counter.

### `sudo /etc/totp-presence/verify <code> --session <path>`

Same as above, but on a correct code it **additionally** writes the
current timestamp (unix timestamp) to the specified file. The path is
strictly validated:

- must be inside `/etc/totp-presence/`
- must be a direct child of the directory (no subdirectories)
- no `..`, no `//`

After writing, the file receives permissions `root:wheel 644`.

This is the only way for integrations to securely store a session.
The path and name are chosen by the integration:

```sh
sudo /etc/totp-presence/verify 123456 \
     --session /etc/totp-presence/claude-code-session
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
     --session /etc/totp-presence/test-session
ls -l /etc/totp-presence/test-session    # root:wheel 644
cat /etc/totp-presence/test-session      # unix timestamp

# cleanup
sudo rm /etc/totp-presence/test-session
```

## How to write your own integration

Minimum:

1. Choose a session file name inside `/etc/totp-presence/`, e.g.
   `my-integration-session`.
2. At every check point, read this file and compare the timestamp to
   the current time minus the window duration.
3. When the session has expired — instruct the user or agent to
   execute:
   ```sh
   sudo /etc/totp-presence/verify <code> --session /etc/totp-presence/my-integration-session
   ```
4. That is all. The core handles the rest.

A real-world example — [../examples/claude-code-hook/](../examples/claude-code-hook/).

## Why so little

Less code — smaller audit surface. Less state — fewer ways to make a
mistake. The core does one thing, does it well, and the rest is the
integration's concern.
