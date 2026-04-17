Russian version: [README.ru.md](./README.ru.md)

# claude-code-hook — integration for Claude Code

Tool lockdown in Claude Code via a `PreToolUse` hook. Protected tools
cannot be invoked until the owner has opened a session with a valid
TOTP code.

## What gets installed

Two static files under root, plus a runtime session file created lazily
on the first successful TOTP code:

```
/etc/totp-presence/claude-code-guard.sh                  root:wheel 755 — hook
/etc/totp-presence/claude-code-config                    root:wheel 644 — integration settings

/var/run/totp-presence/<user>/claude-code-session        root:wheel 644 — session timestamp
                                                                          (lazy-create, cleared on reboot)
```

The session file lives under the per-user runtime tree (tmpfs on
Linux, synthetic on macOS) and is therefore ephemeral by design: a
machine reboot clears every session and the user must re-authenticate.

The integration does not add its own sudoers rule — it uses the core's
rule for `verify`.

## Installation

The core must be installed first:

```sh
sudo ./core/setup.sh install
```

Then the integration:

```sh
sudo ./examples/claude-code-hook/install.sh
# or with a different session window:
sudo ./examples/claude-code-hook/install.sh --window-minutes 15
# for agents without a terminal (Telegram, etc.):
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
# explicit full lockdown (recommended for a fresh install with matcher ".*"):
sudo ./examples/claude-code-hook/install.sh --full-lockdown
# explicit selective lockdown (pair with a narrow matcher):
sudo ./examples/claude-code-hook/install.sh --selective-edit-write
```

The installer:

1. Copies `guard.sh` to `/etc/totp-presence/claude-code-guard.sh`.
2. Writes `claude-code-config` with `WINDOW_SECONDS` and optionally
   `EXTRA_SAFE_TOOLS` and `EDIT_WRITE_CONFIG_ONLY`. On reinstallation,
   `EXTRA_SAFE_TOOLS` from the existing config is preserved silently
   if not overridden by a flag. `EDIT_WRITE_CONFIG_ONLY` is
   preserved too, but with a warning printed when the inherited
   value is `true` — because that mode is security-critical (it
   lets non-config Edit/Write through without a session), so silent
   inheritance across reinstalls is a footgun. Pass
   `--full-lockdown` to force it off, or `--selective-edit-write`
   to force it on and silence the warning.
3. If a legacy v1 session file (`/etc/totp-presence/claude-code-session`)
   is detected, it is moved to the new per-user runtime location and
   the legacy file is removed. Sessions and the brute-force counter
   are no longer stored under `/etc/totp-presence/`.
4. Does NOT pre-create the session file — the verifier creates it
   lazily on the first successful TOTP code at
   `/var/run/totp-presence/<user>/claude-code-session`. The hook
   treats a missing session file as "session never opened" (deny).
5. Prints a JSON snippet for `~/.claude/settings.json`. It must be
   added manually — Claude Code will ask for explicit confirmation.

> **First-run order.** If using full lockdown (matcher `.*`), the
> totp-presence MCP server must be connected and loaded **before**
> adding the hook. Otherwise the agent cannot invoke `totp_verify` to
> open a session. Order: add MCP server to config → restart Claude
> Code → verify MCP tools appeared → add hook.

## How the agent opens a session

When the agent invokes a protected tool and the session has expired,
the hook returns a rejection with the exact command. The agent asks
the owner for a code and executes:

```sh
sudo /etc/totp-presence/verify 123456 --session /var/run/totp-presence/$USER/claude-code-session
```

The core verifies the code and writes a timestamp to the session file
(creating the per-user directory on first use). On the next
invocation the hook sees a fresh session and allows the tool through.

## Two lockdown modes

### Full lockdown (matcher `.*`)

Every tool invocation passes through the hook. The hook allows a short
list of safe tools through without verification:

```
Read | Glob | Grep | LS | TodoWrite | WebSearch | ToolSearch | mcp__totp-presence__*
```

Everything else requires an open session:

- `Bash` (shell commands)
- `Write`, `Edit`, `NotebookEdit` (file modification)
- `WebFetch` (may hit an action URL)
- `Task` / `Agent` (subagents that invoke tools themselves)
- Any other MCP tools

Why the safe list is inverted (enumerate safe, not dangerous), and
why totp-presence MCP tools are built in — see
[SECURITY_MODEL.md, §4](../../SECURITY_MODEL.md#4-the-safe-tool-allowlist-must-remain-narrow).

### Selective lockdown (selective matcher)

Instead of `.*`, specific tools can be specified in the matcher:

```json
{
  "matcher": "Bash|Edit|Write|mcp__peekaboo__.*|mcp__computer-use__.*"
}
```

Only the listed tools pass through the hook; everything else works
freely. More flexible, but new tools are not protected automatically.

With selective lockdown the option `EDIT_WRITE_CONFIG_ONLY=true` can
additionally be enabled in the integration configuration. With it,
Edit and Write on regular files pass without session verification,
while configuration files (`settings.json`, `settings.local.json`,
`.claude.json`, `CLAUDE.md`, `.claude/agents/*`) still require the
shortened window (120 seconds). Bash commands mentioning configuration
paths are also blocked. Without this option (the default) Edit and
Write require a session like any other tool.

Set the mode explicitly via the installer:

```sh
# turn it on (selective):
sudo ./examples/claude-code-hook/install.sh --selective-edit-write
# turn it off (full lockdown):
sudo ./examples/claude-code-hook/install.sh --full-lockdown
```

The two flags conflict and cannot be combined in one command. Without
either flag, the existing value is preserved on reinstall — and if the
inherited value is `true`, the installer prints a warning, because
that combination silently lets non-config Edit/Write through and is
easy to leave behind after switching the matcher in `settings.json`.

## Communication channels (EXTRA_SAFE_TOOLS)

If the agent communicates with the human through an external channel
(Telegram, Slack), the messaging tool must be allowed without a
session — otherwise the agent cannot ask for a code. Set during
installation:

```sh
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
```

Or manually in `/etc/totp-presence/claude-code-config` (sudo):

```
EXTRA_SAFE_TOOLS=mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment
```

Multiple tools separated by `|`. Each tool name must match
`[a-zA-Z0-9_]+`. The hook re-validates the value on load: a
malformed `EXTRA_SAFE_TOOLS` (regex metacharacters such as `.*`,
or any character outside that set) is refused with a one-line note
on stderr and the call falls into the normal session check, rather
than silently whitelisting every tool through a wider regex.

With selective lockdown `EXTRA_SAFE_TOOLS` is usually not needed —
the messaging tool simply does not match the matcher.

## Configuration file protection

In addition to the regular session window (25 min), the hook applies
a shortened 120-second window for files that control agent security:
`settings.json`, `settings.local.json`, `.claude.json`, `CLAUDE.md`,
`.claude/agents/*`. Edit and Write are matched by `file_path`; Bash
commands are scanned for the same paths, with diagnostic read-only
commands (`cat`, `grep`, `jq`, …) allowed through.

Full classifier rules, obfuscation limits, and the rationale for a
shortened window rather than a full block —
[SECURITY_MODEL.md, §5b](../../SECURITY_MODEL.md#5b-modification-of-agent-configuration-via-shell-commands).

## Headless operation specifics

In headless mode (Telegram, Slack) the built-in Claude Code approval
dialog is not a reliable check: the human sees only
"Permission: Edit / Allowed" without the edit content. A TOTP request
before a configuration edit serves as additional confirmation — the
human sees that the agent is about to modify settings and decides
whether to provide a code.

## Uninstallation

```sh
sudo ./examples/claude-code-hook/install.sh uninstall
```

Removes the integration's static files (`claude-code-guard.sh`,
`claude-code-config`) and any per-user session files under
`/var/run/totp-presence/<user>/claude-code-session`. A legacy v1
session file under `/etc/totp-presence/` is removed too if present.
The core remains — it can be removed separately via
`sudo ./core/setup.sh uninstall`.

The hook entry in `~/.claude/settings.json` is not touched by the
installer — it will print a `jq` command for manual removal.

## What it covers and what it does not

**Covers:** tool invocation without a fresh TOTP code. Session file
forgery (root-owned). Hook substitution (root-owned).

**Does not cover:** code execution bypassing the tool system. An
injection convincing the owner to provide a code under the pretext of
a benign task (session reuse within an open window).

Full analysis — [SECURITY_MODEL.md](../../SECURITY_MODEL.md).
