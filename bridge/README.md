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

Each `*_percent` is 0–100 (not 0.0–1.0). `remaining_minutes` is an integer. `resets_at` is an ISO-8601 UTC timestamp. When the cache is fresh (default 5 min TTL), the response is served without a network call and `cached` is `true`.

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

**If you use Chrome (or a Chromium derivative):** The first run will raise a Keychain dialog asking to unlock *"Chrome Safe Storage"*. Click **Always Allow** so the background watchdog can re-extract the password without prompting again. You can also pre-cache it with:

```bash
./refresh_keychain.sh
```

---

## Run

```bash
./run.sh                 # start in the background with auto-restart
./stop.sh                # graceful shutdown
./refresh_keychain.sh    # re-cache Chrome Safe Storage password
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

---

## How it works (for the curious)

1. On startup, `plutil` is used to read the default-browser handler for `https://` URLs and map that bundle ID to `safari` or `chrome`.
2. [`browser-cookie3`](https://github.com/borisbabic/browser_cookie3) is used to open the appropriate cookie jar:
   - **Safari**: parses `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`.
   - **Chrome**: reads the SQLite cookie database and decrypts the `sessionKey` cookie with AES-128-CBC using the *Chrome Safe Storage* password from Keychain.
3. The `sessionKey` is injected into a request session powered by [`curl-cffi`](https://github.com/lexiforest/curl_cffi) with `impersonate="chrome124"` so that Cloudflare's TLS fingerprint check doesn't reject us.
4. `GET https://claude.ai/api/organizations/<org_id>/usage` → normalise into the `five_hour / seven_day / seven_day_sonnet` shape above.
5. The response is cached in-memory (default 5 min TTL) behind a thread-safe lock and served from `/api/usage`.

Nothing is ever written to disk other than the rotating log file and the cached Chrome keychain password in `.chrome_safe_storage_pass` (chmod `600`, never committed).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `sessionKey를 찾을 수 없음` | Sign into `claude.ai` in Safari or Chrome, then restart the bridge. |
| Safari extraction silently fails | Grant Full Disk Access to your terminal. |
| Chrome Keychain prompt appears on every request | Click **Always Allow** once, then run `./refresh_keychain.sh`. |
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
