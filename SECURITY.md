# Security policy

## Supported versions

CCU Bar is pre-1.0 and ships from `main`. Only the **latest `main`** is supported — please reproduce any finding against the current build before reporting.

## Reporting a vulnerability

If you believe you've found a security issue that could harm users (privilege escalation, credential leakage, local RCE, etc.), **please do not open a public issue.**

Instead, email the maintainer directly:

> **peten486@gmail.com** — subject line starting with `[CCU Bar security]`

Include:

- A short description of the impact (what can an attacker do?).
- Steps to reproduce, ideally against the prebuilt `build/CCUBar.app`.
- Any relevant logs from `~/Library/Application Support/CCUBar/bridge/`.
- Suggested mitigation (optional).

You should receive an acknowledgement within **5 working days**. A fix (or an explicit triage note) will follow within 30 days where feasible. Please hold public disclosure until the fix is released — we'll coordinate a timeline with you.

## Threat model — what is and isn't in scope

### In scope

- **Local privilege or data exposure in CCU Bar itself** — menu-bar app reading or writing data it shouldn't, leaking settings, spawning unexpected processes, etc.
- **Log files** in `~/Library/Application Support/CCUBar/bridge/` accidentally containing the `sessionKey` cookie or other secrets. (We intentionally never log it today — if a future change does, that's a bug.)
- **Bundled bridge Python script** mishandling inputs, following untrusted redirects, or widening the attack surface beyond `127.0.0.1`.
- **Update / distribution channel** — anything that would let an attacker ship malicious builds through this repository.

### Out of scope

- **Fundamental bridge design risks** already disclosed in [bridge/README.md](bridge/README.md#risk-statement): we scrape a `claude.ai` cookie and call an undocumented endpoint. This is a known, deliberate trade-off.
- **macOS-level cookie readability** — if an attacker already has code execution under your user account, they can read your cookies directly without our help.
- **Cloudflare / Anthropic server-side rate limiting** or API shape changes. Those are out of our control; the scraper simply stops working.
- **Bundling a known-vulnerable pip dependency** — pip's own advisory database is the right place to report those. We'll accept PRs bumping pinned versions.

## Data handled by CCU Bar

| Datum | Where it lives | Ever sent off-device? |
|---|---|---|
| `sessionKey` cookie | Safari `Cookies.binarycookies` / Chrome `Cookies` DB (your browser's stores) | Only to `claude.ai` by the bridge — the same host that issued the cookie |
| Organization UUID | `~/Library/Application Support/CCUBar/bridge/token.ini` | Only to `claude.ai` |
| Usage percentages | `UserDefaults` (`ccubar.settings.v1`) + in-memory cache | No |
| App preferences | `UserDefaults` | No |
| Bridge logs | `~/Library/Application Support/CCUBar/bridge/app.log` | No (unless you paste them into a GitHub issue) |

The only network destination used is `127.0.0.1:<bridge-port>` (the app) and `claude.ai` (the bridge). There is no telemetry, analytics, or update-ping channel.
