Russian version: [README.ru.md](./README.ru.md)

[![ci](https://github.com/agfpd/totp-presence/actions/workflows/ci.yml/badge.svg)](https://github.com/agfpd/totp-presence/actions/workflows/ci.yml)

# totp-presence

> How an agent can know it is talking to its owner — and not to
> text that impersonates them.

**Platforms:** macOS (primary target, daily production use). Linux
natively supported by design — the code is portable bash + Python
stdlib — but live-system testing on Ubuntu / Fedora is still on the
roadmap, so expect rough edges on Linux until that lands. Windows
via WSL (the Unix permission model is fundamental to the security
design).

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

The project is split into two layers:

### Core (`core/`)

Two scripts: bash with inline Python using the standard library. Zero
external dependencies. Secret key under root permissions, a narrow
sudoers rule (passwordless sudo only for the verifier), one public
command:

```sh
# Verify a code — yes/no, changes nothing
sudo /etc/totp-presence/verify 123456
# exit 0 = correct, exit 2 = incorrect, exit 3 = locked out, exit 1 = error

# Verify a code and open a session — writes a timestamp to a file
sudo /etc/totp-presence/verify 123456 \
     --session /var/run/totp-presence/$USER/claude-code-session
```

Layout follows FHS: static files (the secret, the verifier, integration
configs) live under `/etc/totp-presence/`; runtime state (session
timestamps, the brute-force counter, the lock) lives under
`/var/run/totp-presence/`, scoped per user and cleared on reboot.

The `--session` path is strictly validated: only files directly inside
`/var/run/totp-presence/<invoking-user>/` whose name ends with
`-session` are allowed — nothing else can be overwritten through the
verifier, and the write itself is atomic and refuses to follow
symlinks. Details — [core/README.md](./core/README.md).

### Integrations (`examples/`)

Despite the directory name, these are not demo examples but production-ready
reference integrations. Wrappers around the core, tailored for a specific
agent system. Each integration chooses a session file name, window length,
and rejection response format:

- **[claude-code-hook](./examples/claude-code-hook/)** — a hook for
  Claude Code that fires on every tool invocation. Supports full and
  selective lockdown, protection of configuration files with a shortened
  window (120 seconds), and communication channel configuration for
  headless agents.
- **[mcp-server](./examples/mcp-server/)** — an MCP server
  (Model Context Protocol) with three tools: check session, verify
  code, show status. Works in **any** MCP client — Claude Code, Claude
  Desktop, Cursor, Continue, or any future client that supports MCP.
  This is the primary cross-platform integration: no hooks or
  client-specific code required.
- **[soft-prompt](./examples/soft-prompt/)** — text instructions for
  the agent + MCP tools. The prompt tells the agent *when* to verify
  (before dangerous actions, when in doubt), MCP provides *the means*.
  For systems without hook support or as a supplement to hooks.

The core is not tied to any specific agent system. Any agent capable
of invoking a shell command can use it.

<details>
<summary>How to write your own integration</summary>

1. Choose a session file name. The path must end with `-session` and
   live under the per-user runtime directory, e.g.
   `/var/run/totp-presence/<user>/my-agent-session`. The verifier
   creates the directory lazily on the first successful code.
2. Decide how long a session is considered fresh (sliding window,
   per-action check, etc.).
3. At every check point, read the session file and compare the
   timestamp to the current time.
4. When the session has expired — instruct the user or agent to
   invoke `verify --session <path>` with a fresh code.

Reference example —
[claude-code-hook](./examples/claude-code-hook/).

</details>

## What this is NOT

A brief honesty section. Full version —
[SECURITY_MODEL.md](./SECURITY_MODEL.md).

- **Not a substitute for isolation.** If an attacker has gained root
  access to the machine, they can read the secret key — protection
  is broken.
- **Not protection against arbitrary code execution.** If the agent
  executes shell commands bypassing its standard tool system, hooks
  do not fire.
- **Not a universal lock.** Protects only what a specific integration
  has placed a check on.
- **Not confirmation of a specific action.** Presence ≠ consent —
  see the callout in ["What it looks like in practice"](#what-it-looks-like-in-practice)
  and [SECURITY_MODEL.md, §3](./SECURITY_MODEL.md).
- **Not magic.** Kerckhoffs's principle: the secret key is the only
  thing that is private. The project code is open and must remain
  secure under this condition.

## Why this matters

Models are getting better at recognizing malicious injections — but
sender identity is still not encoded in text. No amount of AI
advancement will add a cryptographic signature to plain text. As long
as agents accept commands via text, they need a channel-independent
way to ascertain who is on the other end.

Hard lockdown as an optional layer becomes less critical with more
capable models. But the core function — a verifiable identity signal —
does not depend on model capability: it is about the absence of
information in the channel, not about the model's ability to detect
attacks.

Moreover, by adding a constraint you **expand** what you can entrust
to the agent. Without TOTP you are unlikely to allow autonomous GUI
automation, SSH, or password management — the risk surface is too
large. With TOTP — you will: every sensitive step has an independent
confirmation.

## Origin

The author operates several autonomous AI agents that accept commands
via Telegram. The only "proof of ownership" is a linked chat identifier.
If Telegram were hijacked, all agents would continue following commands
as if nothing happened.

During operation the system repeatedly processed external documents —
and it became clear that a malicious instruction in text is
indistinguishable from an owner's command. The question was not "if"
but "when."

`totp-presence` is the answer before it became an incident: give one's
own agents grounds for believing that commands come from the owner.
This repository extracts a working solution into a reusable form.

## Prior art

A prior-art search (April 2026) found no earlier description of this
exact pattern. Related work:

- **[IBM + Auth0 + Yubico, RSAC 2026](https://www.ibm.com/new/announcements/securing-agentic-ai-why-automation-still-needs-human-oversight)** —
  "Human-in-the-Loop authorization framework" for agentic AI.
  Same core idea: cryptographic proof of human presence before
  high-risk agent actions. Their approach is enterprise-grade
  (watsonx.ai + CIBA + YubiKey hardware key, per-action consent).
  `totp-presence` solves the same problem for individual developers:
  zero dependencies, any agent, any MCP client.
- **[Checkmarx Zero, 2025](https://checkmarx.com/zero-post/turning-ai-safeguards-into-weapons-with-hitl-dialog-forging/)** —
  "Lies-in-the-Loop / HITL Dialog Forging" identifies the problem,
  says "no silver bullet," offers no solution. This repository is a
  possible answer.
- **1Password + Browserbase, Authn8, open2fa, etc.** — TOTP in the
  *reverse* direction: agents prove themselves to services. Here —
  the opposite: a human proves themselves to an agent.

## License

Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
The license includes an explicit patent grant — the pattern cannot be
closed off by a retroactive patent.

## Status and Roadmap

**Released — v0.2.0, actively maintained.** In daily use on the
author's production agents (three Claude Code instances, full
install-to-production cycle). See [CHANGELOG.md](./CHANGELOG.md) for
per-version notes.

**Done:**

- [x] Core: `verify.sh` (TOTP + brute-force protection) + `setup.sh` (install/uninstall/status)
- [x] Claude Code hook integration — full-lockdown + selective modes
- [x] MCP server integration — works in any MCP client
- [x] Soft-prompt integration
- [x] [SECURITY_MODEL.md](./SECURITY_MODEL.md) + [CLAUDE.md](./CLAUDE.md)
- [x] Per-user ephemeral session files (FHS-compliant v2 layout, v0.2.0)
- [x] Internal pre-release security audit — C1 + H1–H3 + M1–M3 + L1–L5 closed (v0.2.0)
- [x] Versioning + CHANGELOG + tagged releases (v0.2.0)

**Pre-1.0 roadmap:**

- [x] Test suite ([bats](./tests/README.md)) for core and hook — 49 hook tests + 15 core tests *(implemented, pending next release tag)*
- [x] CI with lint + tests (matrix: macOS + Ubuntu) — shellcheck + bats hook suite *(implemented, pending next release tag)*
- [ ] Live-system installation testing on Linux (Ubuntu + Fedora)
- [x] `update` mode for `setup.sh` / `install.sh` — preserve seed across upgrades *(implemented, pending next release tag)*
- [ ] Demo recording (asciinema / gif)

**Post-1.0:**

- [ ] Claude Code plugin package
- [ ] Read/write semantic split in hook (`cat settings.json` should not require TOTP)
- [ ] Homebrew formula + one-command installer
- [ ] Notification before session-window expiry
- [ ] Native Windows support (PowerShell + DPAPI)

---

For AI agents reading this repo: see [CLAUDE.md](./CLAUDE.md).
