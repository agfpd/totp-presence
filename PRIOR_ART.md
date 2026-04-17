Russian version: [docs/ru/PRIOR_ART.md](./docs/ru/PRIOR_ART.md)

# Prior art

We could not find a public prior-art description of exactly this
pattern — a TOTP code from the human, treated as a
channel-independent identity signal that gates agent tool use — as of
April 2026. If you know of one, please open an issue; the comparison
below should be extended, not the claim defended. Related work that
does exist:

## [IBM + Auth0 + Yubico, RSAC 2026](https://www.ibm.com/new/announcements/securing-agentic-ai-why-automation-still-needs-human-oversight)

"Human-in-the-Loop authorization framework" for agentic AI. Same core
idea: cryptographic proof of human presence before high-risk agent
actions. Their approach is enterprise-grade — watsonx.ai + CIBA + a
YubiKey hardware key, per-action consent. `totp-presence` solves the
same problem for individual developers: zero dependencies, any agent,
any MCP client.

## [Checkmarx Zero, 2025](https://checkmarx.com/zero-post/turning-ai-safeguards-into-weapons-with-hitl-dialog-forging/)

"Lies-in-the-Loop / HITL Dialog Forging" identifies the problem,
states "no silver bullet", offers no solution. This repository is one
possible answer.

## 1Password + Browserbase, Authn8, open2fa, etc.

TOTP in the *reverse* direction: agents prove themselves to services.
Here — the opposite: a human proves themselves to an agent.
