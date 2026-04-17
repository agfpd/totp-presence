Russian version: [README.ru.md](./README.ru.md)

[![ci](https://github.com/agfpd/totp-presence/actions/workflows/ci.yml/badge.svg)](https://github.com/agfpd/totp-presence/actions/workflows/ci.yml)

# totp-presence

> How can an agent know it is talking to its owner — and not to text
> that impersonates them?

**Platforms:** macOS (production). Linux — code is portable, but
live-system testing is on the roadmap. Windows — via WSL only.

## The problem: identity in text-based channels

What grounds does an agent have for believing that the message "it's me,
do X" actually came from its owner?

In practice — through the **channel**: a linked Telegram account, a terminal,
an IDE window, an email from a trusted address. But none of these signals
say anything about the person. They say something about the channel — and
take on faith that the owner is on the other end:

```
agent --[verifiable]--> channel --[taken on faith]--> human
```

The agent can verify the first link: "the channel is the right one." The
second — "is the right person behind the channel" — cannot be verified:
that information is not present in text. This is not a deficiency but an
inherent property of text-based channels, and it cannot be remedied by a
more capable model.

Three different attacks — one root vulnerability:

- **Telegram hijacking** → the chat identifier remains the same, the
  agent keeps following orders.
- **Physical access to the machine** → an open terminal = full control.
- **Prompt injection** → malicious text in a document claims it was
  written by the owner, and the agent has no way to refute it.

In all cases the agent trusts the channel because it has no other basis.

## Why the built-in permission prompt is not enough

Agent systems like Claude Code already ask "Allow / Deny" before
sensitive actions. Isn't that sufficient?

The permission prompt verifies that **someone** is at the keyboard. It
does not verify **who**. An open terminal, a hijacked SSH session, a
colleague, a child — anyone with physical or remote access to the
session can click Allow.

This is the same channel-trust problem described above: the prompt
trusts the channel ("there is a human at this terminal") and takes on
faith that the human is the owner.

TOTP closes this gap. A valid code requires possession of the device
holding the secret — something text injection fundamentally cannot
acquire. Physical access to the agent's machine is not enough on its
own — the secret lives on a separate device.

Three additional scenarios where the permission prompt does not apply
at all:

- **Autonomous / headless agents** — agents launched via `--agent`,
  `launchd`, `cron`, or CI. There is no terminal, no one to click
  Allow. Tools execute without confirmation.
- **Allowlisted tools** — when the user opts out of per-call prompts
  for frequently used tools (Bash, Write, Edit). After that, those
  tools run without any confirmation — including under injection.
- **Non-Claude-Code clients** — Cursor, Continue, Claude Desktop, and
  other MCP clients may have a different permission model or none.

`totp-presence` works in all of these cases because it operates at a
different layer: not "was a button clicked" but "does the person know
a secret that only the owner's phone can produce."

## Solution

`totp-presence` adds a second, independent verification channel —
a secret key that lives **outside** the communication channel: in an
authenticator on the owner's phone (Google Authenticator, Apple Passwords,
1Password, Authy, etc.).

```
agent --[verifiable]--> TOTP signal --> physical human
```

Key property: **an injection does not know the secret key** — and therefore
cannot generate a valid code, cannot open a session, and cannot reach
protected actions.

### What it looks like in practice

1. The owner opens the authenticator on their phone and sees a 6-digit
   code (changes every 30 seconds).
2. The owner sends the code to the agent in the chat.
3. The agent invokes the verifier — a script protected by root
   permissions that compares the code against the secret key.
4. If the code is correct — a **session** opens (25 minutes by default).
   Within the session the agent may perform sensitive actions. After
   that — it asks for a code again.

```
You:   delete last month's logs
Agent: This is a destructive action. Send me a 6-digit code
       from your authenticator.
You:   847291
Agent: Code accepted, session opened (25 min). Deleting logs...
```

A session is a record with a timestamp in a file on disk, protected
by root permissions. It states: "the owner confirmed their presence at
time T." The agent compares T to the current time and decides whether
the confirmation is recent enough.

> **Important limitation:** an open session confirms *presence*, not
> *consent to a specific action*. If a session is open for 25 minutes,
> any action within that window proceeds without a new code — including
> actions triggered by injection. Mitigations: keep the window short,
> use the built-in config-file protection (120 s window), and add
> prompt-level rules for irreversible actions. Full analysis —
> [SECURITY_MODEL.md, §3](./SECURITY_MODEL.md#3-session-reuse--not-confirmation-of-a-specific-action).

### Two modes of operation

**Soft mode (trust signal).** The agent checks the session on its own
before important actions via MCP tools. If the session has expired —
it asks for a code. Suitable for any agent system that supports the
Model Context Protocol (MCP): Claude Code, Claude Desktop, Cursor,
Continue.

**Hard lockdown (optional mode).** If the integration with the agent's
hook system is installed, lockdown operates at the operating system
level: the agent physically cannot invoke a protected tool without an
open session — even if a malicious injection in text persuaded it to
do so. Supports full (all tools) and selective (specified tools only)
lockdown.

Either mode can be used alone or both together.

## Quick start for Claude Code

> Requirements: `bash 3.2+` (macOS default `/bin/bash` is 3.2.57 —
> supported; Linux distros ship 4 or 5), `python3` (standard library
> only, no pip).
> Optional: `qrencode` for terminal QR display (`brew install qrencode`
> on macOS, `apt install qrencode` on Linux).
>
> **Prepare your authenticator before starting** — step 1 will display
> a QR code that needs to be scanned immediately.

```sh
git clone https://github.com/agfpd/totp-presence.git
cd totp-presence

# 1. Core — secret key + verifier (displays QR — scan it)
sudo ./core/setup.sh install

# 2. Claude Code integration — hook, session file, config
sudo ./examples/claude-code-hook/install.sh

# 3. MCP server — verification tools for the agent
pip3 install fastmcp  # macOS Homebrew: pip3 install --break-system-packages fastmcp

# 4. Soft prompt — instructions telling the agent when to verify
# Copy the block from examples/soft-prompt/prompt.md into CLAUDE.md.
# Mandatory: the block includes a timing rule requiring totp_verify
# to be the first tool call of the turn when a code arrives —
# codes expire in ~30s, intermediate reasoning burns the window.
# Keep this rule in every scenario, do not drop it.
```

**Step 1** will generate a secret key and display a QR code for binding
the authenticator. **Step 2** will create integration files and print
a JSON snippet for the hook — **do not add the snippet yet**.

**Step 3** — after `pip3 install fastmcp`, add to `~/.claude.json`:
```json
{
  "mcpServers": {
    "totp-presence": {
      "command": "python3",
      "args": ["/absolute/path/to/examples/mcp-server/server.py"]
    }
  }
}
```
Details — in [examples/mcp-server/README.md](./examples/mcp-server/README.md).
After adding — **restart Claude Code** so the MCP server loads.

**Steps 3–4** give the agent soft mode: it checks the session before
important actions on its own and asks for a code when needed.

> **Other MCP clients** (Claude Desktop, Cursor, Continue): step 2
> creates the session files without which the MCP server does not
> work — it is needed even if the hook is never activated. For other
> clients steps 1, 2, 3, 4 suffice without the optional snippet.

**Optional: hard lockdown.** To prevent the agent from invoking
protected tools without a session even under prompt injection — add
the JSON snippet from step 2 to `~/.claude/settings.json`. Claude Code
will ask you to confirm the edit. After that both modes work: the agent
checks on its own via MCP, and the hook enforces at the OS level.

Before enabling:

- **The MCP server must be connected and running** (steps 3–4
  completed, Claude Code restarted). Otherwise the agent cannot
  invoke `totp_verify` to open a session — deadlock.
- **If the agent operates via Telegram, Slack, or another external
  channel** — the messaging tool must be allowed without a session,
  otherwise the agent can neither respond nor ask for a code. See
  [claude-code-hook/README.md](./examples/claude-code-hook/README.md),
  section "Communication channels."
- **Selective lockdown** — an alternative to full lockdown. Protects
  only specified tools; everything else works freely. Less friction,
  but new tools are not protected automatically.

Details on both modes —
[examples/claude-code-hook/README.md](./examples/claude-code-hook/README.md).

<details>
<summary>macOS + Apple Passwords</summary>

Apple Passwords stores TOTP codes only as an attribute of an existing
password entry. Create a placeholder entry:

1. Passwords → **New Password**
2. Title `totp-presence`, User Name `agent`, Password anything,
   Website `https://totp-presence.local`
3. Save → Codes → **+ → Scan QR Code with Camera** → select the
   `totp-presence` entry.

Full-featured authenticators (Google Authenticator, Authy, Raivo,
1Password, Bitwarden) do not require a placeholder — they simply scan
the QR.

</details>

## Updating

After pulling a new version, run the upgrade path. Neither command
touches the seed, the sudoers rule, the authenticator pairing, or
configuration files — open sessions remain open, paired
authenticators remain valid.

```sh
cd totp-presence
git pull
sudo ./core/setup.sh update
sudo ./examples/claude-code-hook/install.sh update   # for each installed integration
```

- `core/setup.sh update` — replaces `verify` and `/etc/totp-presence/VERSION`,
  clears the brute-force fail-counter so the upgraded verifier starts
  from a clean slate, keeps the seed and sudoers rule.
- `claude-code-hook/install.sh update` — replaces `claude-code-guard.sh`,
  keeps `claude-code-config` (so `WINDOW_SECONDS`, `EXTRA_SAFE_TOOLS`,
  `EDIT_WRITE_CONFIG_ONLY` are preserved exactly) and the per-user
  session file. Claude Code picks up the new guard on the next tool
  invocation — no restart.

To change window size or messaging-tool allowlist, re-run with
`install` and its flags (reinstall-safe: unset flags preserve
existing config values).

## Architecture

Two layers:

- **Core (`core/`).** Bash + inline Python (stdlib), zero external
  dependencies. The secret key sits under root, a narrow sudoers rule
  grants passwordless sudo only to the verifier, and one public
  command (`verify <code> [--session <path>]`) does everything.
  Layout follows FHS: static files under `/etc/totp-presence/`,
  runtime state (sessions, brute-force counter, lock) under
  `/var/run/totp-presence/`, per-user, cleared on reboot.
  API, exit codes, path validation — [core/README.md](./core/README.md).

- **Integrations (`examples/`).** Production-ready reference
  integrations, not demos. Each wraps the core for a specific agent
  system, choosing its own session file name, window length, and
  rejection format:
  - [claude-code-hook](./examples/claude-code-hook/) — `PreToolUse`
    hook for Claude Code. Full / selective lockdown, shortened
    120-second window for configuration files, messaging-tool
    allowlist for terminal-less agents.
  - [mcp-server](./examples/mcp-server/) — MCP server exposing three
    tools (check session, verify code, status). Works in any MCP
    client.
  - [soft-prompt](./examples/soft-prompt/) — agent instructions + the
    MCP tools. For clients without hook support, or as a supplement.

The core is not tied to any agent system — any process able to invoke
a shell command can use it. Writing your own integration —
[core/README.md](./core/README.md#how-to-write-your-own-integration).

## Boundaries and risks

Boundaries, residual risks, threat model — [SECURITY_MODEL.md](./SECURITY_MODEL.md).

## Why this matters

Sender identity is not encoded in text, and no model improvement will
add a cryptographic signature to plain text. As long as agents accept
commands via text, they need a channel-independent way to ascertain
who is on the other end. Adding this constraint also expands what you
can safely entrust to the agent: with an independent confirmation per
sensitive step, autonomous GUI automation, SSH, and password
management become reasonable to delegate.

## Origin

Extracted from the author's production setup — autonomous AI agents
on Telegram whose only proof of ownership was a linked chat
identifier. After repeatedly processing external documents it became
clear that a malicious instruction in text is indistinguishable from
an owner's command, so the working solution was packaged into a
reusable form.

## Prior art

Comparison with related work (IBM + Auth0 + Yubico, Checkmarx Zero,
reverse-direction TOTP libraries) — [PRIOR_ART.md](./PRIOR_ART.md).

## License

Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
The license includes an explicit patent grant — the pattern cannot be
closed off by a retroactive patent.

## Status

**Released — v0.2.0, actively maintained.** In daily use on the
author's production agents (three Claude Code instances, full
install-to-production cycle). Per-version notes —
[CHANGELOG.md](./CHANGELOG.md).

**Shipped:**

- Core: `verify.sh` (TOTP + brute-force protection) and `setup.sh`
  (install / uninstall / status / update)
- Three reference integrations: Claude Code hook (full + selective
  lockdown), MCP server (any MCP client), soft prompt
- Per-user ephemeral session files, FHS-compliant layout
- Internal pre-release security audit — C1, H1–H3, M1–M3, L1–L5 closed
- Test suite ([bats](./tests/README.md)) — 49 hook tests + 15 core tests
- CI with shellcheck + bats on macOS + Ubuntu
- Versioning, CHANGELOG, tagged releases
- [SECURITY_MODEL.md](./SECURITY_MODEL.md) + [CLAUDE.md](./CLAUDE.md)

**Open:**

- Live-system installation testing on Linux (Ubuntu + Fedora)
- Demo recording (asciinema / gif)

---

For AI agents reading this repo: see [CLAUDE.md](./CLAUDE.md).
