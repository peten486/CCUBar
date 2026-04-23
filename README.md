<h1 align="center">CCU Bar</h1>

<p align="center"><strong>Claude Code Usage Bar — Native macOS Menu-bar App</strong></p>

<p align="center">
  <a href="https://swift.org"><img alt="Swift 5.9 / SwiftUI" src="https://img.shields.io/badge/Swift_5.9-SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white"></a>
  <a href="https://www.apple.com/macos/"><img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13+-000000?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://www.python.org/"><img alt="Python 3.8+ / Flask" src="https://img.shields.io/badge/Python_3.8+-Flask-3776AB?style=for-the-badge&logo=python&logoColor=white"></a>
  <a href="https://developer.apple.com/sf-symbols/"><img alt="SF Symbols" src="https://img.shields.io/badge/SF_Symbols-Icon-007AFF?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-FDDC35?style=for-the-badge"></a>
</p>

**Claude Code Usage Bar** — a native macOS menu-bar app that shows your current Claude Code session quota at a glance.

The menu-bar item displays a compact progress bar (with optional percentage and 🤖 icon) that turns orange at 60 % and red at 85 %. Clicking it opens a translucent popover with three quotas:

- **5-hour session** — the rolling session window
- **Weekly (7-day)** — the combined weekly cap (Max plans)
- **Sonnet 7-day** — the Sonnet-specific weekly cap

<p align="center">
  <img src="docs/screenshots/popover.png" alt="CCU Bar menu bar and popover" width="520" />
  <br />
  <em>Menu-bar indicator (top) and popover (3 quotas)</em>
</p>

---

## Features

- **Always-on menu bar gauge** — bar + percentage + 🤖 icon (all three toggleable in settings)
- **Three quota tracks** in the popover
  - 5-hour rolling session
  - 7-day weekly combined
  - 7-day Sonnet-only
- **Live progress bar** with tier colours (green → orange → red) that mirror the menu-bar state
- **Time-to-reset countdown** for each quota (e.g. "1h 23m until reset")
- **Auto-refresh** every 30 s / 60 s / 5 min (configurable); manual refresh button + right-click context menu
- **Threshold notifications** at 75 % and 90 % (once per session, auto-reset after session rollover)
- **Three-language UI** — English, Japanese, Korean — switchable live from Settings
- **Dark-mode HUD popover** (`.hudWindow` + `vibrantDark` appearance, regardless of system theme)
- **Launch at login** via `SMAppService`
- **Menu-bar icon toggle** — hide the 🤖 for minimal style
- **Display modes** — bar-only, number-only, or both
- **No data leaves your machine** — see [Architecture](#architecture)

---

## Requirements

### Runtime

| Requirement | Detail |
|---|---|
| **macOS** | 13 Ventura or newer |
| **Architecture** | Apple Silicon or Intel (fat binary when built with `--arch` flags) |
| **Data source** | A local HTTP service that returns Claude usage JSON **or** a claude.ai `sessionKey` cookie pasted into Settings. See [Data source](#data-source). |

### Build-from-source (optional)

| Requirement | Detail |
|---|---|
| **Swift** | 5.9 or newer (Xcode 15 / Command Line Tools for Xcode 15+) |
| **iconutil** | Ships with macOS; used to pack the icon |
| **curl** | Ships with macOS; used once to download the Twemoji SVG |

No third-party Swift packages. Only Foundation, AppKit, SwiftUI, Combine, UserNotifications, and ServiceManagement are linked.

---

## Data source

CCU Bar polls a tiny local HTTP service that exposes usage in the JSON shape shown below. The reference implementation — **claude-usage-bridge** — ships in the [`bridge/`](bridge/) subdirectory of this repo and is bundled inside the `.app`, so the app launches and manages it for you automatically.

> ⚠️ **claude-usage-bridge is an unofficial tool.** It scrapes your locally logged-in `claude.ai` cookie rather than calling the official Anthropic API. See [`bridge/README.md`](bridge/README.md) for the full risk statement.

Expected JSON from the bridge:

```json
{
  "five_hour":        { "utilization": 57, "remaining_minutes": 281,  "resets_at": "..." },
  "seven_day":        { "utilization": 84, "remaining_minutes": 301,  "resets_at": "..." },
  "seven_day_sonnet": { "utilization":  8, "remaining_minutes": 4801, "resets_at": "..." }
}
```

Any Flask/Node/Go service that produces the same format would work — CCU Bar only speaks HTTP over `127.0.0.1` on the port you configure.

---

## Installation

```bash
git clone https://github.com/peten486/CCUBar.git
cd CCUBar
./Scripts/build_app.sh
```

Then drag `build/CCUBar.app` into `/Applications/` (or just double-click to run it in place). The first launch starts the initial setup wizard below.

### Initial setup (first launch)

The first time you open CCU Bar it walks you through a two-step wizard, then starts the bundled Python bridge and verifies the first API call end-to-end. If you've already completed this once, you can skip straight to [Usage](#usage).

<table>
<tr>
<td width="50%">
  <img src="docs/screenshots/init-setup-1.png" alt="Language selection (step 1 of 2)" />
  <br />
  <strong>1. Language</strong><br />
  Pick English / 日本語 / 한국어. The choice propagates to every window (popover, settings, notifications) immediately and can be changed later in Settings.
</td>
<td width="50%">
  <img src="docs/screenshots/init-setup-2.png" alt="Bridge port entry (step 2 of 2)" />
  <br />
  <strong>2. Bridge port</strong><br />
  CCU Bar pre-fills a random free port in the 49152–65500 range. Change it if you like, then click <em>Save &amp; Start</em>. No separate terminal step is required — the app launches the bundled Python bridge for you.
</td>
</tr>
<tr>
<td width="50%">
  <img src="docs/screenshots/init-setup-3.png" alt="Startup progress bar" />
  <br />
  <strong>3. Startup progress</strong><br />
  The wizard spawns the bridge process, polls the port until it starts listening (up to 20 s), then exercises <code>/api/usage</code> with a 30 s timeout. The progress bar animates across these phases; the current phase is printed below.
</td>
<td width="50%">
  <img src="docs/screenshots/init-setup-4.png" alt="Setup complete confirmation" />
  <br />
  <strong>4. Setup complete</strong><br />
  When the first API call succeeds the wizard stays on this screen until you click <em>Done</em>. CCU Bar is now polling your Claude Code usage on the menu bar.
</td>
</tr>
</table>

If step 3 fails (missing Python, missing pip dependencies, cookie access denied, etc.), the wizard switches to an error screen with <em>Install dependencies</em> and <em>Retry</em> buttons. <em>Install dependencies</em> runs <code>python3 -m pip install --user -r bridge/requirements.txt</code> and automatically retries.

---

---

## Privacy & Security permissions

CCU Bar itself does not phone home, but the bundled bridge needs to read the `sessionKey` cookie that `claude.ai` sets in your browser. macOS protects those files under Transparency-Consent-Control (TCC), so a few one-time permissions are required.

### Required

| Permission | Where to grant | Why |
|---|---|---|
| **Full Disk Access** | System Settings → Privacy & Security → **Full Disk Access** → add `CCUBar.app` | Needed to read `Cookies.binarycookies` for Safari users. Without it the bridge can still fall back to Chrome / Chromium, but the Safari path returns *Operation not permitted*. |
| **Notifications** | First launch shows a banner automatically — click **Allow**. Can be changed later in System Settings → Notifications → **CCU Bar** | Used for the 75 % / 90 % threshold alerts. |

### On demand (first-time prompts)

| Permission | When it appears | What to do |
|---|---|---|
| **Keychain → *Chrome Safe Storage*** | First time the bridge tries to decrypt Chrome cookies | Click **Always Allow** so the app can re-decrypt the cookie at every refresh without prompting again. If you miss the dialog, run `./bridge/refresh_keychain.sh` from a terminal to re-cache. |
| **Login Items** | When you toggle *Launch at login* in Settings | macOS may open *System Settings → General → Login Items* and list **CCU Bar**. Keep the switch **on**. |

### Not required

- **Accessibility** — not used
- **Camera / Microphone / Screen Recording** — not used
- **Internet / outbound network access** — the app talks only to `127.0.0.1:<bridge-port>`; the bridge talks to `claude.ai` on your behalf with your session cookie

### If something fails

| Symptom | Fix |
|---|---|
| Onboarding step 3 fails with "bridge did not open port" | Usually a Python dependency issue — click **Install dependencies** on the failure screen |
| `app.log` shows *Safari 쿠키 접근 권한 없음 / Operation not permitted* | Grant **Full Disk Access** to `CCUBar.app` and retry from Settings → Randomize/Change |
| Menu-bar bar never updates after enabling *Launch at login* | Make sure the app lives at `/Applications/CCUBar.app` (required by `SMAppService`). Moving or renaming the bundle breaks the login item |

---

## Usage

- **Click** the menu-bar item → opens the popover with all three quotas.
- **Right-click** (or **⌃-click**) → context menu with Refresh / Settings / Quit.
- **Right-click the popover’s "Refresh" button** → same context menu inside the popover.
- **Settings** — change language, menu-bar display (bar / number / both), icon visibility, refresh interval, `claude` CLI path override, notifications, and login-at-startup.
- Settings persist to `UserDefaults` under the key `ccubar.settings.v1` and migrate automatically from the legacy `ccbar.settings.v1` key if present.

Thresholds 75 % and 90 % each fire a single `UNUserNotificationCenter` alert, deduped until the session resets (detected by a monotonically-decreasing session percent or a changed `resets_at`).

---

## Architecture

```
┌────────────────────────────────────────────────────┐
│                    CCUBarApp (@main)               │
│              AppDelegate + MenuBarController       │
└────────────────┬───────────────────────────────────┘
                 │
       ┌─────────┼──────────┬─────────────┬──────────┐
       ▼         ▼          ▼             ▼          ▼
┌────────────┐┌────────┐┌─────────┐ ┌────────┐ ┌──────────┐
│CompositeFet││UsageSt.││Notifier │ │Settings│ │LoginItem │
│ ├─ HTTP    ││ObsObj  ││UN       │ │Store   │ │Manager   │
│ └─ PTY(fb) ││@Published         │ │        │ │SMAppSvc  │
└─────┬──────┘└───┬────┘└─────────┘ └────────┘ └──────────┘
      │          ▼
      │    ┌──────────────┐
      │    │ PopoverView  │   SwiftUI
      │    │ StatusItemView│  AppKit
      │    └──────────────┘
      ▼
┌─────────────────────┐
│ HttpUsageFetcher    │  URLSession → /api/usage
│ PTYUsageFetcher     │  forkpty + `claude` CLI (fallback)
│ UsageParser         │  regex extraction for PTY path
└─────────────────────┘
```

Key components:

| File | Responsibility |
|---|---|
| `Sources/CCUBar/App/CCUBarApp.swift` | `@main`, `Settings {}` scene |
| `Sources/CCUBar/App/AppDelegate.swift` | DI wiring, accessory activation policy |
| `Sources/CCUBar/MenuBar/MenuBarController.swift` | `NSStatusItem`, popover, context menu |
| `Sources/CCUBar/MenuBar/StatusItemProgressView.swift` | Custom `NSView` progress-bar renderer |
| `Sources/CCUBar/Popover/PopoverView.swift` | SwiftUI popover (three quotas + dark HUD) |
| `Sources/CCUBar/Popover/SettingsView.swift` | SwiftUI settings window |
| `Sources/CCUBar/Core/HttpUsageFetcher.swift` | Primary fetcher (JSON API) |
| `Sources/CCUBar/Core/UsageFetcher.swift` | PTY fallback via `forkpty` |
| `Sources/CCUBar/Core/UsageStore.swift` | `@Published` state, threshold detection |
| `Sources/CCUBar/Core/Notifier.swift` | `UNUserNotificationCenter` wrapper |
| `Sources/CCUBar/Utilities/Localization.swift` | Three-language string catalogue |

All business logic lives in free structs/actors; UI types depend on them and are fully testable.

---

## Project layout

```
Claude_Usage_Monitor/
├── Package.swift
├── README.md                   ← this file
├── NOTICE.md                   ← Twemoji attribution
├── LICENSE                     ← MIT
├── Sources/CCUBar/             ← app target
│   ├── App/                    (@main + AppDelegate)
│   ├── MenuBar/                (NSStatusItem + progress view)
│   ├── Popover/                (SwiftUI views)
│   ├── Core/                   (fetcher/parser/store/notifier)
│   ├── Models/                 (value types)
│   └── Utilities/              (GaugeRenderer, ClaudeLocator, Localization)
├── Tests/CCUBarTests/          ← 21 unit tests + 1 opt-in integration test
├── Resources/
│   ├── AppIcon.icns            ← generated from Twemoji SVG
│   └── twemoji_robot.svg       ← CC-BY 4.0
└── Scripts/
    ├── build_app.sh            ← Swift build + bundle assembly
    ├── generate_app_icon.sh    ← Twemoji SVG → iconset → .icns
    ├── render_icon.swift       ← SVG rasterizer helper
    └── Info.plist.template
```

---

## Development

```bash
swift build                # compile (debug)
swift test                 # 21 unit tests, <0.1 s total
swift test --filter Xxx    # filter by suite/test
CCUBAR_LIVE=1 swift test --filter LiveFetchTests   # hits the configured local endpoint
CCUBAR_DEBUG=1 swift run CCUBar                    # verbose PTY trace
./Scripts/build_app.sh     # build + bundle
```

Tests are in pure XCTest and use protocol-based fakes (`UsageFetching` / `NotificationDispatching`) — no UI harness needed.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu-bar shows `Setup` / no bar | Verify Settings → Data source is configured (scraper port reachable, or sessionKey + org ID populated) |
| Menu-bar shows `…` forever | Launch from Terminal with `CCUBAR_DEBUG=1 build/CCUBar.app/Contents/MacOS/CCUBar` — inspect stderr |
| Popover renders light-grey | Make sure you're running the latest build; older revisions didn't force `vibrantDark` |
| Notification not firing | Check *System Settings → Notifications → CCU Bar* is allowed; the first launch asks once |
| Icon didn't update in Finder | `touch build/CCUBar.app && killall Finder` (or re-register via `lsregister`) |
| Login-item toggle fails | Bundle must live at a stable location — move `CCUBar.app` to `/Applications` first |

---

## Limitations & roadmap

- **Hard dependency on a local HTTP service** — by design, since Claude Code's `/usage` slash-command isn't exposed non-interactively. Once Anthropic publishes a machine-readable endpoint, the PTY fallback will be dropped and the HTTP fetcher will be repointed.
- **No historical chart** — each refresh is a point-in-time snapshot; sparkline support is a post-1.0 item.
- **No Windows / Linux support** — AppKit-native; would need a Tauri/Electron port.
- **No App Store build** — uses `SMAppService` in a way that needs `/Applications`, fine for direct download, not for sandboxed MAS distribution.

---

## License

Project source: [MIT License](LICENSE) — Copyright © 2026 peten486.

Third-party assets are listed in [NOTICE.md](NOTICE.md). The application icon is rendered from Apple's SF Symbols at build time; the 🤖 glyph in the menu bar is drawn from the system emoji font at runtime — no Apple graphics are embedded in the shipped bundle.
