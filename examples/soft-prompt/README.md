Russian version: [README.ru.md](./README.ru.md)

# soft-prompt — agent instructions + MCP tools

A combination of two layers: text instructions in the prompt tell the
agent **when** to verify the interlocutor's identity, MCP tools from
[mcp-server](../mcp-server/) provide **the means** to verify. The
agent decides on its own when verification is needed and invokes the
tools itself.

## When this is appropriate

- As a supplement to `claude-code-hook` — the agent proactively checks
  the session in situations the hook does not cover (read-only tools,
  sequences of benign actions).
- For agents in soft mode — without hard lockdown, but with conscious
  identity verification.

## Installation

1. Install the core: `sudo ./core/setup.sh install`
2. Install an integration for session files:
   `sudo ./examples/claude-code-hook/install.sh` (or your own)
3. Connect the MCP server — see
   [mcp-server/README.md](../mcp-server/README.md)
4. Open [prompt.md](./prompt.md), replace `<integration>` with the
   integration name (e.g. `claude-code`)
5. Copy the block into the agent's system prompt or CLAUDE.md

## What the agent will do

With this prompt and MCP tools the agent:

- Before sensitive actions invokes `totp_check_session` — checks
  whether the session is open.
- If not — asks the owner for a code and invokes `totp_verify`.
- The owner sees why the agent is requesting a code and decides
  whether to provide one.
- When in doubt about the interlocutor's identity — checks
  proactively.

## Mode comparison

| | Hook only | Soft-prompt + MCP | Hook + soft-prompt + MCP |
|---|---|---|---|
| Injection cannot bypass | yes | no* | yes |
| Agent understands why | no | yes | yes |
| Agent checks proactively | no | yes | yes |
| Works without hook support | no | yes | — |

\* An injection can force the agent not to invoke the verification
tools, but cannot produce a valid TOTP code.

**Recommendation:** combine all three layers. The hook enforces at
the OS level (injection cannot bypass). The soft prompt provides
understanding (the agent knows why and when). MCP provides the tools.

## Customization

**Different integration name:** replace `<integration>` in prompt.md
with the name of your integration. The name = the file name prefix in
`/etc/totp-presence/` (e.g. `aider` → `aider-session`,
`aider-config`).

**Different triggers:** the "when to verify" list in prompt.md is a
starting point. If the agent works only with code and has no access to
SSH or GUI — the corresponding items can be removed.

## Agents without a terminal (Telegram, Slack, etc.)

In soft mode (soft-prompt + MCP only, no hook) the agent freely
invokes messaging tools and can ask for a code through the
communication channel — no issues.

In hard mode (with hook) the messaging tool must be allowed without a
session — otherwise the agent cannot ask for a code. Details — in
[claude-code-hook/README.md](../claude-code-hook/README.md), section
"Communication channels."

**Prompt customization:** the human does not see a terminal — all
agent instructions must go through the communication channel.
Wording in prompt.md should be appropriate for the channel in use.
