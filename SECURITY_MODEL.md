Russian version: [SECURITY_MODEL.ru.md](./SECURITY_MODEL.ru.md)

# Security model

This document answers the question "where are the boundaries." What
totp-presence does and why — in [README.md](./README.md). Here — what
it **does not** do, what assumptions it rests on, and what risks remain
after installation.

## Assumptions

The protection offered by totp-presence relies on three conditions. If
any of them is violated, guarantees are weakened or eliminated:

1. **The host is not compromised at root level.** The secret key
   (`/etc/totp-presence/secret`) is protected by root:600 permissions.
   If an attacker has obtained root — they can read the key and
   generate codes themselves.
2. **The authenticator is not compromised.** If the phone is stolen,
   the key is phished, or exported from the application — the attacker
   has everything needed to generate codes.
3. **System time is correct.** TOTP and session verification depend on
   the clock. A time skew may cause anomalies (details — §6).

## Signal strength

A TOTP session is an additional confirmation factor, not absolute
identity verification. It raises confidence but does not replace other
security mechanisms.

An open session is evidence that someone with physical access to the
authenticator produced a valid code within the last N seconds
(configurable by the integration). Properties of this signal:

- Malicious text cannot obtain it — it does not have the secret key.
- The signal relies on a device outside the communication channel (the
  authenticator on a phone). Compromise of Telegram, the terminal, or
  the IDE alone does not enable opening a session.
- The signal is time-limited and does not accumulate into permanent
  trust.

**Practical implication.** An open session is grounds for *raising*
trust in the conversation, but not for *abandoning* sound judgment. For
irreversible actions (data deletion, money transfers, granting access)
the agent should continue to request additional confirmation even with
an open session.

### Brute-force protection

After 5 consecutive incorrect codes the verifier locks out for
5 minutes. A successful verification resets the counter.

At ~5 attempts every 5 minutes the expected time to guess a 6-digit
code is on the order of years. The verifier serializes concurrent
invocations via an exclusive lock (atomic mkdir), so a parallel
attacker cannot bypass the counter.

### Signal boundaries

- **Physical coercion** is not covered. A code obtained under duress
  is still valid.
- **Stolen authenticator** — see §2.
- **Session reuse.** An open session proves that *some* action was
  authorized by the owner, but not that the *current* action
  specifically was authorized — see §3.

## What totp-presence does NOT protect against

Recommended reading before use.

### §1. Host compromise

`/etc/totp-presence/secret` — root-owned, permissions 600. This is
meaningless if the host is compromised at root level. A malicious
process can read the key and generate valid codes.

**Mitigation:** the pattern assumes the host is not captured. If the
assumption does not hold, OS-level isolation is needed, not a shell
script.

### §2. Authenticator compromise

If the phone is stolen, the code is obtained under duress, the key is
phished, or exported from a compromised application — the attacker has
everything needed.

**Mitigation:** standard second-factor hygiene. Secure backups, key
rotation upon suspicion
(`sudo ./core/setup.sh install` with `y` at the overwrite prompt).

### §3. Session reuse — not confirmation of a specific action

This is the most subtle point. The contract of totp-presence: "a
session is currently open." The contract **does not** say: "the human
approved the specific action that is happening right now."

Example: the agent requested a code for task A. The task completed in
two seconds. The session remains open for another 25 minutes. An
injection arrives within this window and launches task B. No new code
was required.

**Mitigation, time-based:** keep the session window short.

**Mitigation, configuration protection:** in `claude-code-hook`,
editing files that control agent security (`settings.json`,
`settings.local.json`, `.claude.json`, `CLAUDE.md`,
`.claude/agents/*`) requires a **fresh** session (a separate 120s
window) — even if the regular session is still active. This prevents
an injection within an open window from disabling the hook or altering
agent instructions.

**Mitigation, prompt-level:** a rule in
[soft-prompt/prompt.md](./examples/soft-prompt/prompt.md) — for
irreversible actions, request additional confirmation even with an
open session. This is a soft rule; an injection can theoretically
bypass it — but it operates on top of the hard layers above: even if
the prompt is bypassed, the injection cannot disable the hook or
modify agent instructions (CONFIG_WINDOW blocks it), and the core
remains untouched (root ownership).

### §4. The safe-tool allowlist must remain narrow

Applies only to integrations with hooks.

In `claude-code-hook` the hook by default checks **all** tool
invocations and passes a short list of read-only tools without
verification: `Read`, `Glob`, `Grep`, `LS`, `TodoWrite`, `WebSearch`, `ToolSearch`.
Everything else requires a session.

This closes the classic vulnerability of "forgot to add a new tool to
the protected list" — because the list is inverted: the **safe** tools
are enumerated, not the dangerous ones. A new tool is automatically
placed under protection.

However, the vulnerability exists in a different form: **if someone
adds a tool to the safe list that is not read-only**, it will remain
unprotected.

**Mitigation:** add a tool to the safe list only if it is guaranteed
read-only. Do not add anything that:
- writes to disk
- launches a shell or subprocess
- makes network calls with side effects
- launches a subagent — the subagent itself may invoke dangerous
  tools, and its actions will fall outside the hook

With selective lockdown (selective matcher) this issue does not arise —
totp-presence tools and communication channels simply do not match the
matcher. With full lockdown (matcher `.*`) two additional classes enter
the safe list.

**totp-presence tools.** Hard-coded in the hook
(`mcp__totp-presence__*` → exit 0). Without them — mutual deadlock:
the agent can neither open a session nor check it. Does not weaken
protection:

- `totp_verify` — passes through the core with brute-force
  protection. Without a correct code the session will not open.
- `totp_check_session`, `totp_status` — pure reads.

**Communication channels (agents without a terminal).** Under full
lockdown, messaging tools must be explicitly added to the configuration
(`EXTRA_SAFE_TOOLS`) — otherwise the agent cannot ask for a code: the
hook blocks, the agent is silent, the owner waits. Under selective
lockdown there is no issue — messaging does not match the matcher.

Messaging tools are a riskier extension than totp-presence tools. An
injection can force the agent to send a message through the
communication channel. However, sending a message is not a host
mutation and does not give the injection the ability to open a session
or perform a protected action.

Additionally: the MCP tool `totp_check_session` remains a second
layer — the agent can check the session on its own before any action
it considers important, even if the tool is formally on the safe list.

### §5. The owner can disable the protection themselves

Removing `/etc/sudoers.d/totp-presence` or the hook settings breaks
the protection. This is by design — the human remains the master of
the machine. But it means that totp-presence is not protection against
a deliberate insider.

### §5b. Modification of agent configuration via shell commands

Files that control agent behavior (`settings.json`,
`settings.local.json`, `.claude.json`, `CLAUDE.md`,
`.claude/agents/*`) are owned by the user, not root. Unlike core
files, they can be modified without privileges — including via shell
commands that bypass the file-name check in Edit and Write.

**Three layers of configuration file protection:**

1. **Built-in Claude Code protection.** Editing `settings.json`
   requires explicit human confirmation even with
   `bypassPermissions`. Independent of totp-presence.

2. **Hook: Edit and Write.** Shortened window (120 seconds) for
   configuration files. An injection cannot disable the hook or
   modify agent instructions through the standard editing tools,
   even if the regular session is active.

3. **Hook: Bash.** The hook parses the shell command content and
   performs a text search for configuration paths. Direct commands
   (`echo >> settings.json`, `sed -i CLAUDE.md`,
   `cp ... .claude.json`) are caught and require the same shortened
   window (120 seconds).

The match is case-insensitive (both for `file_path` in Edit/Write and
for the Bash command string). On APFS (the macOS default) the
filesystem is case-insensitive: `Settings.json` resolves to the same
inode as `settings.json` on disk, so the matcher would otherwise miss
a write that actually lands on the protected file.

**Limitations of the Bash check.** Text search over the command
string catches direct commands but does not catch obfuscation:

- Variables: `FILE=settings.json; echo >> $FILE`
- Encoding: `echo <base64> | base64 -d > file`
- Eval: `eval "echo >> settings.json"`
- Git: `git pull` can overwrite configuration files without
  mentioning their names in the command

False positives are possible: `git commit -m "updated CLAUDE.md"`
will be blocked even though the command is benign. Resolved by
rephrasing.

**The core is immune to this vector.** The secret key, session file,
hook configuration, verifier — all owned by root. A shell command
from a regular user cannot modify them.

**Mitigation: filesystem-level protection.** `chflags uchg`
(macOS) or `chattr +i` (Linux) makes agent configuration files
immutable for regular users. Complete coverage: neither direct
commands nor obfuscation will help. The trade-off — every legitimate
edit will require sudo.

### §6. System time manipulation

TOTP and session verification depend on the system clock. If the agent
shifts the clock, it can theoretically affect both.

**Backward shift** (revive an expired session): the hook verifies that
session age >= 0. With a backward clock shift the age is negative →
rejection. Handled in code.

**Forward shift + rollback** (open a session with a future timestamp):
after rolling back the clock the age will be negative → rejection.
Also handled.

**Can the agent shift the clock?** `date -s`, `timedatectl`,
`systemsetup` — all require root. The totp-presence sudoers rule
grants passwordless sudo only for `/etc/totp-presence/verify`. Via
GUI (System Settings → Date & Time) it is theoretically possible with
GUI automation and disabled auto-sync — exotic.

**Mitigation:** enable automatic time synchronization (NTP). The hook
checks age >= 0. Sudoers is restricted to a single command.

### §7. TOTP is not magic cryptography

TOTP (RFC 6238) provides what TOTP provides: a 6-digit code derived
from a secret key and the current time, valid for ~30 seconds.
totp-presence does not strengthen TOTP itself and inherits its
limitations: clock drift tolerance (valid_window=1 means 3 valid codes
simultaneously, guessing probability ~3 in 1,000,000 per attempt),
loss of the key = loss of all authenticator bindings.

### §8. Dependency compromise and MCP server response spoofing

The MCP server depends on `fastmcp` (an external pip package).
Compromise of the package gives the attacker access to the user
process. The secret key is inaccessible (root:600), but the attacker
can modify MCP server responses — for example, making
`totp_check_session` always return `{"open": true}`.

**In hard mode** (hook) this is not a bypass: the hook operates
independently of the MCP server and checks the session file directly.
A compromised MCP can deceive the agent, but the hook will still block
the tool invocation.

**In soft mode** (soft-prompt + MCP only, no hook) this is a complete
bypass: the agent trusts the response from `totp_check_session`, and a
spoofed response means the check no longer functions.

**Mitigation:** hard mode as the primary. In soft mode — pin the
fastmcp version in requirements.txt, use
`pip install --require-hashes`, or verify the package hash at
installation time.

## Kerckhoffs's principle

The project is designed with the assumption that the attacker knows
everything about totp-presence: paths, permissions, sudoers, the code
of `verify.sh` and `guard.sh`, the configuration format, the contents
of this document. The secret key is the only thing considered private.

Protection that works only because the attacker has not read the
documentation is not considered protection. totp-presence is published
openly so that the mechanism can be audited.

## Residual risks, ranked

1. **Injection exploits an open session window** (§3). Most probable.
   Includes Bash check bypass via obfuscation (§5b).
2. **Owner forgot to protect a new tool** (§4). Happens.
3. **Authenticator compromise** (§2). Standard hygiene.
4. **Host compromise at root level** (§1). If this happens —
   totp-presence is the least of the problems.
5. **Owner disabled it themselves** (§5). By definition not an attack.

## When totp-presence is NOT needed

- The agent has no tools capable of affecting the host (read-only,
  analysis only).
- Windows without WSL — the Unix permissions model does not apply.
- A stronger guarantee is needed than "a text injection cannot open a
  session." For that, OS-level isolation is required, not a shell
  script.
