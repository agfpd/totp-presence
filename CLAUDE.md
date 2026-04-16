Russian version: [CLAUDE.ru.md](./CLAUDE.ru.md)

# totp-presence — project instructions

This file is read by Claude Code when the repository is opened.
Project description — in [README.md](./README.md).

---

## For humans

**totp-presence** — a mechanism that gives an AI agent a way to
verify that it is talking to its actual owner. Details and
installation — in [README.md](./README.md). You can simply tell
the agent: *"install totp-presence for me"*.

---

## For AI agents

If a human asks to install totp-presence — follow these
instructions. Post-installation behavioral rules are described in
[examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md) —
they are copied into CLAUDE.md or the agent's system prompt.

**Warn the human before starting.** You cannot execute sudo commands
yourself — they require a password that only the human enters.
Explain in advance which commands will be needed:

**Required sudo commands:**
```sh
# Step 2 — core installation (key generation, sudoers, self-test)
sudo ./core/setup.sh install

# Step 3 — integration installation (hook, session file, config)
sudo ./examples/claude-code-hook/install.sh
```

**Optional sudo commands (depend on configuration):**
```sh
# Step 3, if a different session window is needed (default 25 min):
sudo ./examples/claude-code-hook/install.sh --window-minutes 15

# Step 3, to pin the lockdown mode explicitly (recommended on reinstall):
sudo ./examples/claude-code-hook/install.sh --full-lockdown
sudo ./examples/claude-code-hook/install.sh --selective-edit-write

# Step 6, if the agent operates via Telegram/Slack:
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
```

**What the human will need to do besides entering a password:**
- Step 2: scan the QR code with an authenticator (appears in the
  terminal) and enter a 6-digit code for verification.
- Step 6 (optional): confirm the `settings.json` edit when Claude
  Code prompts.

The authenticator must be ready before step 2 — the QR needs to be
scanned immediately. If the human wants hard lockdown (step 6) —
steps 1–5 must be completed first and Claude Code must be restarted.

### Step 1. Check platform and dependencies

```sh
uname -s       # must be Darwin or Linux. If not — WSL is needed.
command -v python3   # standard library, pip not needed
```

If python3 is not found: on macOS install via Xcode Command Line
Tools (`xcode-select --install`), on Linux — via the package manager
(`apt install python3` or equivalent).

Optional: `qrencode` for terminal QR display
(`brew install qrencode` on macOS, `apt install qrencode` on Linux).
Without it the installer will display the URL as text.

### Step 2. Install the core

**Before running** prepare the authenticator — the QR will appear
during installation and must be scanned immediately:

- **Full-featured authenticators** (Google Authenticator, Authy,
  1Password, Bitwarden) — ready immediately, simply scan the QR.
- **Apple Passwords on macOS** — requires a placeholder entry in
  advance: Passwords → New Password → Title `totp-presence`, any
  username/password, Website `https://totp-presence.local`.
  Save. Then when scanning: Codes → + → Scan QR Code with Camera →
  select the entry.

When the authenticator is ready:

```sh
sudo ./core/setup.sh install
```

sudo will ask for a password once. The installer:
- generates a secret key under root
- displays a QR code — scan it with the authenticator
- writes a sudoers rule: passwordless sudo **only** for
  `/etc/totp-presence/verify`
- runs a self-test — requests a fresh code

If the self-test is not passed within 3 attempts — the core is
installed, but the authenticator binding may be incorrect. Ask the
human to check: is the correct entry in the authenticator, does the
phone time match. Re-verification:
`sudo /etc/totp-presence/verify <fresh-code>`.

### Step 3. Install the integration

```sh
sudo ./examples/claude-code-hook/install.sh
```

Creates three files in `/etc/totp-presence/`: the hook, the session
file, and the configuration. All owned by root. Prints a JSON snippet
for the hook — **do not add it yet**.

### Step 4. Connect the MCP server

```sh
pip3 install fastmcp
```

On macOS with Homebrew Python, `pip3 install fastmcp` may fail with
a PEP 668 error. Solution: `pip3 install --break-system-packages
fastmcp` or `pipx install fastmcp`.

Add an entry to the MCP server configuration. **Ask the human** where
to add it — there are two options:
- `~/.claude.json` — global for all projects
- `.mcp.json` in the root of the target agent's project — only for it

Do not choose yourself — this is the user's decision. Format and
examples — in
[examples/mcp-server/README.md](./examples/mcp-server/README.md).
sudo is not needed. After restarting Claude Code, the agent will have
access to the tools `mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

### Step 5. Add the soft prompt

Open [examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md),
replace `<integration>` with the integration name (e.g., `claude-code`).
**Ask the human** whose CLAUDE.md should receive the block — the current
agent's (if it will be using totp-presence) or another's. Do not silently
copy it into the first file you find.

This gives the agent rules: when to check the session, how to accept
codes, what not to do.

### Step 6 (optional). Enable hard lockdown

**Do not add the snippet yourself — propose it to the human and
explain what will happen.**

**Important:** the MCP server from step 4 must be connected and
running before enabling the hook. Verify that the tools
`mcp__totp-presence__totp_verify` are available. If the hook is
active but the MCP server is not loaded — the agent is locked out
with no way to open a session.

Before configuring:

1. **Which tools to protect?** Check which MCP servers and tools are
   available in the current session. Compile a recommendation — show
   the human the list and suggest a lockdown mode.

2. **Which lockdown mode?** Explain both:

**Full lockdown** (recommended). Matcher `".*"` — every invocation
passes through the hook. The hook allows only safe read-only tools
and totp-presence MCP tools through. Everything else requires a
session. New tools, plugins, and MCP servers are automatically
protected.

```json
{
  "matcher": ".*",
  "hooks": [
    {
      "type": "command",
      "command": "/etc/totp-presence/claude-code-guard.sh"
    }
  ]
}
```

Safe tools (pass without a session):
- Built-in read-only: `Read`, `Glob`, `Grep`, `LS`,
  `TodoWrite`, `WebSearch`, `ToolSearch`
- totp-presence MCP tools: `mcp__totp-presence__*`
- Communication channels: configured via `EXTRA_SAFE_TOOLS`
  in the configuration (see below)

**Selective lockdown.** Matcher on specific tools. Everything else
works freely. The agent asks for a code less often, but new tools are
not protected automatically.

```json
{
  "matcher": "Bash|Write|Edit|NotebookEdit|WebFetch|Agent|Task",
  "hooks": [
    {
      "type": "command",
      "command": "/etc/totp-presence/claude-code-guard.sh"
    }
  ]
}
```

For MCP tools, add their servers to the matcher:
`"Bash|Write|Edit|mcp__peekaboo__.*|mcp__computer-use__.*"`

3. **Communication channels.** If the agent communicates with the
   human through an external channel (Telegram, Slack), the messaging
   tool **must** be allowed without a session — otherwise the agent
   cannot ask for a code and will be locked out. Ask which channel is
   used and set it during installation:
```sh
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
```
   Or manually in `/etc/totp-presence/claude-code-config` (sudo):
```
EXTRA_SAFE_TOOLS=mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment
```

4. **Pin the lockdown mode.** Pass `--full-lockdown` (matcher `.*`,
   recommended) or `--selective-edit-write` (narrow matcher) to the
   installer. This writes `EDIT_WRITE_CONFIG_ONLY` explicitly into
   the config and silences the warning the installer would otherwise
   print on reinstall. Without an explicit flag the installer
   preserves the existing value, but warns loudly if the inherited
   value is `true` — that mode lets non-config Edit/Write through
   without a session and must match the matcher choice in
   `settings.json`.

5. **Where to add the snippet? Ask the human.**
   - **Project-level** `<project>/.claude/settings.json` — only for
     this agent.
   - **Global** `~/.claude/settings.json` — for all projects.

It is added to the `hooks.PreToolUse` array. Claude Code will ask for
explicit confirmation — this confirmation must come from the human,
not from you.

**How to disable hard lockdown:** remove the snippet from
settings.json. Soft mode (MCP + soft prompt) will continue to work.

### Reference commands

| Action | Command |
|---|---|
| Check installation | `./core/setup.sh status` (no sudo) |
| Change session window | `sudo ./examples/claude-code-hook/install.sh --window-minutes N` |
| Pin full lockdown | `sudo ./examples/claude-code-hook/install.sh --full-lockdown` |
| Pin selective lockdown | `sudo ./examples/claude-code-hook/install.sh --selective-edit-write` |
| Configure messaging | `sudo ./examples/claude-code-hook/install.sh --messaging-tools "tool1\|tool2"` |
| Remove integration | `sudo ./examples/claude-code-hook/install.sh uninstall` |
| Remove core | `sudo ./core/setup.sh uninstall` |

Removal: integration first, then core. The hook from
`~/.claude/settings.json` is removed by the human manually — the
installer will print the exact command.
