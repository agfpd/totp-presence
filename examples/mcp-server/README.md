Russian version: [../../docs/ru/examples/mcp-server/README.md](../../docs/ru/examples/mcp-server/README.md)

# mcp-server — MCP integration for totp-presence

An MCP server (Model Context Protocol) that provides the agent with
tools for verifying the owner's identity and managing the session.
Unlike the hook, the agent decides on its own when to invoke a check —
proactively, before an action, rather than reactively upon rejection.

Works in any MCP client: Claude Code, Claude Desktop, Cursor,
Continue — anything that can launch a stdio MCP server.

## Three tools

### `totp_verify(code, integration)`

Code verification and session opening. The agent receives a code from
the owner and invokes:

Request: `totp_verify("847291", "claude-code")`

Response on success:
```json
{
  "valid": true,
  "session_opened": true,
  "integration": "claude-code",
  "window_seconds": 1500,
  "opened_at": 1775914871,
  "expires_at": 1775916371
}
```

On an incorrect code or lockout — returns an error with a description.
On lockout (5 consecutive incorrect codes, 5-minute wait) the error
text will include the time until unlock. No need to retry.

### `totp_check_session(integration)`

Non-invasive check — whether the session is open:

```json
// session open
{ "open": true, "expires_in_seconds": 1266 }

// session expired
{ "open": false, "reason": "session expired" }
```

Allows the agent to learn the state before acting, without waiting for
a rejection from the hook.

### `totp_status()`

Diagnostics — what is installed, which integrations are visible:

```json
{
  "core_installed": true,
  "integrations": [
    { "integration": "claude-code", "open": true, ... }
  ]
}
```

## Why this on top of a hook

A hook is a hard block: the agent learns about the problem only when
it has already stumbled. MCP tools add a proactive layer: the agent
checks the session in advance and makes decisions based on structured
context (window, age, time until expiry).

Especially valuable when:
- An action is not formally protected by the hook, but the agent
  considers it important.
- The client does not support hooks (Claude Desktop, Cursor, Continue).

## Installation

### Requirements

1. Core: `sudo ./core/setup.sh install`
2. At least one integration installed (e.g.
   `sudo ./examples/claude-code-hook/install.sh` creates
   `/etc/totp-presence/claude-code-config` and registers the
   integration; the matching session file is created lazily under
   `/var/run/totp-presence/<user>/claude-code-session` on the first
   successful TOTP code).
3. Python 3.9+ and FastMCP:
   ```sh
   pip3 install fastmcp
   ```

### Connecting to an MCP client

The MCP server is a stdio process. It is added via an entry in the
client's configuration.

**Claude Code** (`~/.claude.json`):
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

After restarting, the following tools will appear:
`mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS) — same `mcpServers` format.

**Cursor / Continue / others** — each has its own way to register an
MCP server; the command and arguments are the same.

## Integration naming

An integration name is a short string matching `[a-z0-9][a-z0-9-]{0,63}`.
It corresponds to the file name prefix used across the static and
runtime trees:

| Name | Configuration file (static)              | Session file (runtime, per-user)                           |
|---|------------------------------------------|------------------------------------------------------------|
| `claude-code` | `/etc/totp-presence/claude-code-config`  | `/var/run/totp-presence/<user>/claude-code-session`        |
| `aider`       | `/etc/totp-presence/aider-config`        | `/var/run/totp-presence/<user>/aider-session`              |

Names containing `..`, `/`, or uppercase letters are rejected by the
server. The core additionally validates the path on its side — a
double layer of defense against path traversal.

## Why passwordless sudo

The server runs under a regular user. When invoking verify it uses
`sudo -n` (do not prompt for a password; if NOPASSWD is not configured
— immediate error). The core's sudoers rule allows passwordless sudo
only for `/etc/totp-presence/verify`.

## Boundaries

The server is a thin wrapper. It cannot read the secret key
(root:600), cannot write a session directly (only the core does, on a
correct code), cannot create integrations (a missing config file is
an error), and does not register itself in client configurations
(added manually).

## Troubleshooting

**`sudo: a password is required`** — the sudoers rule is not
installed. Check: `./core/setup.sh status`.

**`integration 'X' is not installed`** — the config file
`/etc/totp-presence/X-config` is missing. Invoke `totp_status` to
see available integrations.

**`fastmcp package not installed`** — `pip3 install fastmcp`. If
Python is managed via pyenv/conda, ensure the MCP client launches the
correct python — specify the full path in `"command"` if necessary.
