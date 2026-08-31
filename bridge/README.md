# claude-usage-bridge

> ⚠️ **UNOFFICIAL — Not an Anthropic API.**
> This tool does **not** use the official Anthropic API. It reads your locally logged-in `sessionKey` cookie from Safari or Chrome and calls an **internal, undocumented** `claude.ai` endpoint on your behalf. The endpoint shape, cookie names, and Cloudflare/TLS behaviour can change without notice, at which point this project will simply break until the scraping logic is updated.
>
> Use at your own risk. Do not deploy this as a shared/public service. The project is designed for a **single signed-in user on their own machine**, and the exact code path is indistinguishable from a manual browser session.

A tiny Flask service that extracts your `claude.ai` session cookie from the browser you're already logged into, calls the internal `/api/organizations/<id>/usage` endpoint, and exposes the result as JSON on `http://127.0.0.1:<port>/api/usage`.

It ships as the `bridge/` subdirectory of [CCU Bar](https://github.com/peten486/CCUBar) — a macOS menu-bar app that visualises Claude Code usage — but the JSON contract is small enough that any client (a shell script, a Raycast extension, a different menu-bar app) can consume it.

---

## Response format

```
GET /api/usage
```

```json
{
  "five_hour":        { "utilization": 57, "remaining_minutes": 281,  "resets_at": "..." },
  "seven_day":        { "utilization": 84, "remaining_minutes": 301,  "resets_at": "..." },
  "seven_day_sonnet": { "utilization":  8, "remaining_minutes": 4801, "resets_at": "..." },
  "source": "api",
  "cached": true,
  "timestamp": "..."
}
```

### Field reference

| Field | Type | Meaning |
|---|---|---|
| `five_hour` | object | The rolling 5-hour session window |
| `seven_day` | object — **may be absent** | The combined 7-day cap (Max plans) |
| `seven_day_sonnet` | object — **may be absent** | The Sonnet-specific 7-day cap |
| `source` | string | `"api"` — where the numbers came from |
| `cached` | bool | `true` if served from the in-process cache with no network call (default 5 min TTL) |
| `timestamp` | string | When this data was fetched from claude.ai, ISO-8601 UTC |

A period key is **omitted entirely** when your plan has no such quota — claude.ai returns
`null` for it, and the bridge passes that through as absence rather than inventing a
`utilization` of `0.0`. Read a missing key as *"not applicable"*, never as *"0% used"*.
Only `five_hour` is required; if it is missing the upstream schema has changed, and the
bridge logs a warning. Consumers should hide the corresponding gauge for absent keys —
that is what CCU Bar's popover does.

Each period object that *is* present contains:

| Field | Type | Meaning |
|---|---|---|
| `utilization` | float | Percent of that quota consumed, **0–100** (not 0.0–1.0) |
| `resets_at` | string | When the window rolls over, ISO-8601 UTC |
| `remaining_minutes` | int | Minutes until `resets_at`. Computed locally, not returned by claude.ai |

These are the only three keys CCU Bar itself reads. Everything below is additive.

---

## Token statistics (`tokens` block)

The same response also carries a `tokens` block with **absolute token counts read from your local Claude Code session logs** (`~/.claude/projects/**/*.jsonl`). No network call, no cookie — just files already on your disk.

```json
"tokens": {
  "schema_version": 1,
  "source": "local_logs",
  "scope": "claude_code_this_machine",
  "ready": true,
  "scanned_at": "2026-07-19T02:31:20Z",
  "timezone": "Asia/Seoul",
  "utc_offset_minutes": 540,
  "range": { "key": "today", "since": "...", "until": "..." },

  "totals":  { "input_tokens": 128340, "output_tokens": 48211,
               "cache_creation_input_tokens": 903112, "cache_read_input_tokens": 14882301,
               "total_tokens": 15961964, "billable_tokens": 176551, "requests": 1204 },
  "today":   { "…same fields…" },
  "by_model":   [ { "model": "claude-opus-4-8", "…same fields…" } ],
  "by_hour":    [ { "hour": "2026-07-19T09:00:00+09:00", "hour_of_day": 9, "…same fields…" } ],
  "by_project": [ { "project": "CCUBar", "cwd": "/Users/you/CCUBar", "…same fields…" } ],

  "stats": { "files_tracked": 206, "lines_parsed": 27353, "duplicates_skipped": 15080,
             "malformed_lines": 0, "files_skipped": 2, "scan_ms": 7 },
  "warnings": []
}
```

### Token field reference

**Metadata** — describes the aggregate itself, not your usage:

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | int | Bumped on any breaking change to this block. Currently `1` |
| `source` | string | Always `"local_logs"` — distinguishes it from the `"api"` numbers above |
| `scope` | string | Always `"claude_code_this_machine"`. A machine-readable reminder that this is **not** account-wide |
| `ready` | bool | `false` while the first full scan is still running. All counters read 0 until it flips |
| `scanned_at` | string \| null | When the logs were last read, ISO-8601 UTC. `null` before the first scan |
| `timezone` | string | The zone used for day boundaries and hour labels. An IANA name when you pass `tz`, otherwise whatever the system reports (which may be an abbreviation like `KST`) |
| `utc_offset_minutes` | int | That zone's offset — `540` for KST. Use this rather than parsing `timezone` |
| `range.key` | string | Which window was applied: `today`, `7d`, `30d`, or `custom` |
| `range.since` / `range.until` | string | The window's actual bounds, ISO-8601 with local offset. Half-open: `since` inclusive, `until` exclusive |

**Counters** — these seven fields appear identically in `totals`, `today`, and every row of `by_model` / `by_hour` / `by_project`:

| Field | Type | Meaning |
|---|---|---|
| `input_tokens` | int | Prompt tokens sent fresh, i.e. **not** served from cache. Often surprisingly small on a cache-heavy workload |
| `output_tokens` | int | Tokens the model generated, including thinking |
| `cache_creation_input_tokens` | int | Tokens written **into** the prompt cache. Billed at a premium over normal input |
| `cache_read_input_tokens` | int | Tokens read **from** the prompt cache. Heavily discounted, and usually 10–100× larger than everything else combined |
| `total_tokens` | int | Sum of the four above. Dominated by cache reads, so rarely the number you want to show |
| `billable_tokens` | int | `input + output + cache_creation` — cache reads excluded. See below |
| `requests` | int | Distinct API responses, after deduplication |

**Grouped arrays** — each row carries all seven counters plus its own key field:

| Array | Key fields | Notes |
|---|---|---|
| `totals` | *(object, not array)* | Everything inside `range` |
| `today` | *(object, not array)* | Local calendar day. **Ignores `range`** — it is always today, so a `range=30d` request still gives you a usable "today" figure |
| `by_model` | `model` | Raw model id, e.g. `claude-opus-4-8`. New/unknown ids pass through verbatim. Sorted by `billable_tokens`, descending |
| `by_hour` | `hour`, `hour_of_day` | `hour` is a local ISO-8601 timestamp; `hour_of_day` is `0`–`23`, denormalized so "usage by time of day" needs no date parsing. **Dense** — every hour in `range` is present, zero-filled |
| `by_project` | `project`, `cwd` | `project` is the basename of the working directory, `cwd` the full path. Sorted by `billable_tokens`, descending |

`by_hour` and `by_project` appear only with `?tokens=full`.

**Diagnostics:**

| Field | Type | Meaning |
|---|---|---|
| `stats.files_tracked` | int | Log files currently being followed |
| `stats.files_skipped` | int | Files not read — outside the retention window, or unreadable |
| `stats.lines_parsed` | int | Usage-bearing lines seen, cumulative since process start |
| `stats.duplicates_skipped` | int | Repeat lines dropped by dedup. Normally **larger than** `requests` — see the note below |
| `stats.malformed_lines` | int | Lines skipped as unparseable. Should be 0 |
| `stats.scan_ms` | int | Duration of the last scan. ~1–2 s on the first pass, single-digit ms after |
| `warnings` | string[] | Human-readable problems — missing log directory, unreadable files. The block degrades into warnings rather than failing the request |

### Query parameters

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `tokens` | `full` / `off` | *(compact)* | `full` adds `by_hour` + `by_project`; `off` omits the block entirely |
| `range` | `today` / `7d` / `30d` | `today` | Window for `totals`, `by_model`, `by_hour`, `by_project` |
| `since` / `until` | ISO-8601 | — | Explicit window; overrides `range` |
| `tz` | IANA name (`Asia/Seoul`) | system zone | Day boundaries and hour labels |

The default response is **compact** — `by_hour` can reach 720 rows over 30 days, which is far too much to ship on a 60-second poll. Ask for `?tokens=full` when you actually want to draw a chart.

### `total_tokens` vs `billable_tokens`

`billable_tokens` = input + output + cache_creation. Cache **reads** are excluded because they dwarf everything else — a typical 30-day window here shows 2.3 B cache-read tokens against 60 M of everything else. If you display one number, display `billable_tokens`, and label whichever you pick.

### Why don't these numbers match the percentages above?

They measure different things and there is **no conversion between them**:

| | `five_hour` / `seven_day` / `seven_day_sonnet` | `tokens` |
|---|---|---|
| Source | claude.ai servers | log files on this Mac |
| Covers | your whole account — web, desktop, every device | Claude Code on this machine only |
| Unit | quota utilization % | absolute token counts |

Usage from the web app, from another machine, or from a session whose log you deleted is invisible to `tokens` but still counted against your quota. Quota utilization is also not a linear function of token count. Don't derive one from the other.

### Notes

- Logs older than 30 days are ignored (`TOKENS_RETENTION_DAYS`).
- Counts are deduplicated by `requestId`. A single API response is written to the log as several lines — one per content block — each repeating the identical `usage` object, so naive summation roughly doubles every total.
- The aggregate is in-memory only. It is rebuilt on start (~1–2 s for 600 MB of logs) and updated incrementally afterwards; nothing is written to disk.
- Set `TOKENS_ENABLED=0` to switch the whole feature off.

---

## Requirements

| | |
|---|---|
| **OS** | macOS 13 or newer (tested on arm64) |
| **Python** | 3.8+ |
| **Browser** | You must be logged into `claude.ai` in **either** Safari **or** Chrome (or a Chromium-derivative) |
| **Permissions** | Full Disk Access for the terminal (to read Safari cookies) **or** Keychain access to *"Chrome Safe Storage"* (for Chrome) |

The bridge detects your macOS **default browser** and tries that one first. If it's unsupported or extraction fails, it falls back to the other supported browser.

| Default browser | Extraction path used |
|---|---|
| Safari | Safari priority → Chrome fallback |
| Chrome / Chromium / Brave / Edge / Opera / Vivaldi | Chrome priority → Safari fallback |
| Firefox / other | Safari priority → Chrome fallback (Firefox cookies not yet supported) |

Default-browser detection reads `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist` via `plutil` — no private APIs or extra permissions.

---

## Install

```bash
git clone git@github.com:peten486/CCUBar.git
cd CCUBar/bridge
pip3 install -r requirements.txt
cp token.ini.example token.ini
# Edit token.ini and paste your claude.ai organization UUID.
```

### Getting your organization UUID

1. Open `claude.ai` in your browser and sign in.
2. Open DevTools → **Network** tab.
3. Send any message or just switch views — you'll see XHR requests to `/api/organizations/<UUID>/...`.
4. Copy that `<UUID>` into the `org_id =` line in `token.ini`.

### Granting cookie-read permissions

**If you use Safari:** System Settings → Privacy & Security → **Full Disk Access** → add your terminal app (Terminal / iTerm / Warp / etc.).

macOS attributes that grant to the app that *launched* the bridge, not to the `python3`
binary. Running the bridge yourself from a shell means the terminal needs the grant;
running it under CCU Bar means **`CCUBar.app`** does, and granting it to your terminal
has no effect there. The log line printed on a permission failure names the right target.

**If you use Chrome (or a Chromium derivative):** The first run will raise a Keychain dialog asking to unlock *"Chrome Safe Storage"*. Click **Always Allow** — the grant is attached to `/usr/bin/security`, which `browser_cookie3` invokes on every refresh, so it won't prompt again. If you miss the dialog, trigger it up front with:

```bash
./refresh_keychain.sh
```

---

## Run

```bash
./run.sh                 # start in the background with auto-restart
./stop.sh                # graceful shutdown
./refresh_keychain.sh    # pre-grant Keychain access for Chrome cookie decryption
```

`run.sh` starts a watchdog that restarts the server within 3 seconds if it crashes. Logs are written to `app.log` (rotating, 10 MB × 3 files).

To pick a different port:

```bash
API_PORT=9999 ./run.sh
curl http://127.0.0.1:9999/api/usage
```

Foreground / no-watchdog usage (e.g. for debugging):

```bash
python3 claude_usage_scraper.py --server --port 8080
```

One-shot usage (prints JSON and exits, no server):

```bash
python3 claude_usage_scraper.py
```

### Environment variables

| Variable | Default | Effect |
|---|---|---|
| `CCUBAR_USAGE_SOURCE` | `snapshot` | Data source. `snapshot` reads the statusline snapshot file (no auth, no network). `browser_cookie` is the legacy path that extracts the `sessionKey` cookie and calls claude.ai directly |
| `CCUBAR_USAGE_SNAPSHOT` | `~/.claude/usage-snapshot.json` | Path to the snapshot written by `statusline-custom.sh` (snapshot source only) |
| `STALE_THRESHOLD_SECONDS` | `1800` | A snapshot older than this is served with `"stale": true` (snapshot source only) |
| `API_PORT` | `8306` | Listening port |
| `BRIDGE_HOST` | `0.0.0.0` | Bind address. Set to `127.0.0.1` to accept local connections only |
| `CACHE_TTL_SECONDS` | `300` | How long an upstream quota response is reused |
| `FAILURE_COOLDOWN_SECONDS` | `60` | After a failed lookup, how long before cookies are read again. Requests inside the window fail fast from the cached reason instead of re-reading Safari/Chrome every poll |
| `TOKENS_ENABLED` | `1` | `0` removes the `tokens` block entirely |
| `TOKENS_SCAN_INTERVAL` | `30` | Minimum seconds between log rescans |
| `TOKENS_RETENTION_DAYS` | `30` | Logs older than this are not read |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | Where to look for session logs |
| `LOG_LEVEL` | `INFO` | Console log level |

### Exposing it to other devices

The default bind is `0.0.0.0`, so a phone, watchface, or home server on your network can poll it. **There is no authentication of any kind** — anyone who can reach the port reads the whole response, which includes:

- your quota utilization
- your project names and their **absolute filesystem paths** (`tokens.by_project[].cwd`)
- **when you work**, hour by hour (`tokens.by_hour`)
- token volumes and per-model breakdown

Your `sessionKey` cookie is never included in a response, so this is activity metadata, not a credential leak. Still, think before forwarding the port through a router to the public internet.

Three ways to narrow it, in increasing order of openness:

```bash
BRIDGE_HOST=127.0.0.1 ./run.sh   # this machine only
TOKENS_ENABLED=0 ./run.sh        # reachable, but quota percentages only
./run.sh                         # default — everything, to anyone who can reach the port
```

A private network overlay (Tailscale, WireGuard) is a better answer than a public port forward if your client device supports it. The server logs a warning at startup listing exactly what it is publishing whenever it binds outside loopback.

---

## Data source (`snapshot`, default)

Since v0.3 the bridge reads usage from a **local snapshot file** instead of the browser
cookie, so it never authenticates to claude.ai and never triggers a session-invalidation
logout from repeated polling.

Claude Code passes account-level rate-limit data (`rate_limits.five_hour` /
`rate_limits.seven_day`, each with `used_percentage` and `resets_at`) to its status line
script on stdin — the same numbers `/status` shows. A thin collector wrapper captures those
into a snapshot the bridge reads.

**Setup on the machine that runs Claude Code (the Mac mini):**

1. Point `settings.json`'s `statusLine.command` at the wrapper (it runs your existing
   statusline unchanged and writes the snapshot as a side effect):

   ```bash
   cp bridge/statusline-custom.sh ~/.claude/statusline-custom.sh
   chmod +x ~/.claude/statusline-custom.sh
   # then set "statusLine": { "command": "~/.claude/statusline-custom.sh" } in ~/.claude/settings.json
   ```

   The wrapper calls `~/.claude/statusline.sh` for the visible output; override with
   `CCUBAR_STATUSLINE_ORIGINAL` if your original lives elsewhere.

2. Use Claude Code once. The snapshot appears at `~/.claude/usage-snapshot.json`.
   (`rate_limits` only exists for Pro/Max and only after the session's first API response,
   so a brand-new session shows nothing until you send a turn.)

Machines that only *display* usage (phone, watch, home server) need no collector — they
just poll the bridge's REST endpoint. `seven_day_sonnet` is **not** available from the
statusline and is therefore omitted from the response in this mode; consumers already hide
that gauge when it is absent. When a snapshot is missing or older than
`STALE_THRESHOLD_SECONDS`, the response carries `"stale": true` with the last known values.

To A/B test the logout hypothesis, set `CCUBAR_USAGE_SOURCE=browser_cookie` to restore the
legacy path below.

## How it works — legacy `browser_cookie` path (for the curious)

Only used when `CCUBAR_USAGE_SOURCE=browser_cookie`.

1. On startup, `plutil` is used to read the default-browser handler for `https://` URLs and map that bundle ID to `safari` or `chrome`.
2. [`browser-cookie3`](https://github.com/borisbabic/browser_cookie3) is used to open the appropriate cookie jar:
   - **Safari**: parses `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`.
   - **Chrome**: reads the SQLite cookie database and decrypts the `sessionKey` cookie with AES-128-CBC using the *Chrome Safe Storage* password from Keychain.
3. The `sessionKey` is injected into a request session powered by [`curl-cffi`](https://github.com/lexiforest/curl_cffi) with `impersonate="chrome124"` so that Cloudflare's TLS fingerprint check doesn't reject us.
4. `GET https://claude.ai/api/organizations/<org_id>/usage` → normalise into the `five_hour / seven_day / seven_day_sonnet` shape above.
5. The response is cached in-memory (default 5 min TTL) behind a thread-safe lock and served from `/api/usage`.

Nothing is ever written to disk other than the rotating log file and `token.ini` (which holds only your organization UUID). The `sessionKey` cookie and the Chrome Safe Storage password are read on demand and kept in memory only — never cached to a file.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `sessionKey를 찾을 수 없음` | Sign into `claude.ai` in Safari or Chrome, then restart the bridge. |
| Safari extraction silently fails | Grant Full Disk Access to whichever app launched the bridge — your terminal if you ran it by hand, `CCUBar.app` if the menu-bar app spawned it. |
| Chrome Keychain prompt appears on every request | Run `./refresh_keychain.sh` and click **Always Allow** so `/usr/bin/security` keeps the grant. |
| HTTP 401 / 403 from `claude.ai` | The cookie likely expired (~30 days) — sign in again. |
| Cloudflare HTML instead of JSON | `curl_cffi`'s `impersonate=` may need bumping as Chrome versions change; open an issue with the HTML snippet. |
| `org_id` wrong / missing | See [Getting your organization UUID](#getting-your-organization-uuid). |

---

## Risk statement (please read)

- This tool reads private cookies from your browser's storage. Make sure you trust every process that has access to this repository's directory.
- The scraping surface is **entirely undocumented**. Anthropic can change it at any time and can consider it a policy violation. This project carries no warranty and no guarantee of continued operation.
- `claude-usage-bridge` listens on `127.0.0.1` only. **Do not bind it to `0.0.0.0`** unless you know exactly what you're doing — anyone on your network could otherwise read your current session quota.
- If you have a corporate Anthropic agreement or handle regulated data, consult your admin before running reverse-engineered access tools against `claude.ai`.

---

## License

[MIT](LICENSE) © 2026 peten486.

The repository bundles no third-party source code. Runtime dependencies (`flask`, `browser-cookie3`, `curl-cffi`, `cryptography`, `certifi`) are installed via `pip` and governed by their own licenses.
