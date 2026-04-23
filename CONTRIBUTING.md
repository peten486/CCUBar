# Contributing to CCU Bar

Thanks for considering a contribution! CCU Bar is a small, focused app — the goal is to keep the scope tight and the surface area obvious. Before you start a big change, please open a Discussion or a Feature request issue so we can align on direction.

## Ground rules

- **Keep it boring.** No new runtime dependencies in the Swift target without discussion (we're currently at zero external Swift packages). Bridge Python deps should stay pinned to the versions in `bridge/requirements.txt`.
- **Respect the bridge's unofficial status.** Don't add marketing claims about being an "official" Claude Code client. See [`bridge/README.md`](bridge/README.md) for the risk statement wording.
- **Translations matter.** UI strings live in [`Sources/CCUBar/Utilities/Localization.swift`](Sources/CCUBar/Utilities/Localization.swift) and all three locales (en / ja / ko) must stay in sync. Adding a new string without its Japanese + Korean counterparts is not merge-ready.

---

## Local setup

```bash
git clone https://github.com/peten486/CCUBar.git
cd CCUBar

# Swift side
swift build
swift test           # 16 unit tests, ~0.1 s total

# Bridge side (only if you're changing Python)
cd bridge
pip3 install --user -r requirements.txt
./run.sh             # foreground: python3 claude_usage_scraper.py --server
```

Editor: any — the code is plain Swift Package Manager + a Python script. If you use Xcode, open `Package.swift`. If you use VSCode, install the Swift plugin.

## Running the app you just built

```bash
./Scripts/build_app.sh                    # regenerates build/CCUBar.app
open build/CCUBar.app                     # or cp to /Applications/
```

Settings and logs live in `~/Library/Application Support/CCUBar/bridge/`. To reset onboarding when testing first-launch flows:

```bash
defaults delete dev.ccubar.app
rm -rf "$HOME/Library/Application Support/CCUBar"
```

---

## Code style

### Swift

- Target Swift 5.9 syntax; no features that require 5.10+ without a very good reason.
- `@MainActor` on UI-adjacent types; subprocess / network work stays on detached tasks to keep the main thread unblocked. See `BridgeRunner` for the pattern.
- 4-space indentation, no trailing whitespace.
- Prefer value types (`struct`) over classes unless reference semantics are genuinely needed.
- Public-ish APIs stay `internal`; use `fileprivate` / `private` aggressively.
- Tests are plain XCTest — no external test frameworks.

### Python (bridge)

- Runs under the system `python3`; must not assume pip-installed extras beyond what's in `requirements.txt`.
- Keep logging in the existing format (`[timestamp] [level] [func] message`) so grepping stays consistent.
- Don't log the `sessionKey` cookie or its prefix. The organization UUID is OK.

### Localization

Every user-visible string must route through `LocalizedStrings`:

```swift
var someLabel: String {
    pick("English copy", "日本語のコピー", "한국어 카피")
}
```

Order is **always en / ja / ko**. When you introduce a new property, add it to the same section as related strings.

---

## Commits and PRs

### Commit messages

We use short prefixes that survive `git log --oneline` well:

- `Add :: <what>` — introduces a new file, module, or feature-flag default.
- `Modify :: <what>` — changes existing behaviour or refactors.
- `Fix :: <what>` — targeted bug fix with a clear before/after.
- `Docs :: <what>` — README / comments / templates only.
- `Test :: <what>` — test-only changes.

Body is optional but encouraged for anything non-trivial; focus on *why*, not *what*.

### Pull requests

1. Branch from `main`. Name the branch anything — we squash on merge.
2. Make sure `swift build` and `swift test` both pass.
3. Attach a short video / screenshot for UI changes.
4. Check the three locales if you touched any user-visible string.
5. Update the README if behaviour that users observe has changed.
6. Request review; the maintainer will either merge or leave inline comments.

Small PRs (< 200 lines) ship quickly. Large refactors should come with a Discussion thread first so we don't end up with wasted work.

---

## Adding a new setting

Settings live in [`Sources/CCUBar/Models/Settings.swift`](Sources/CCUBar/Models/Settings.swift). When adding a field:

1. Declare the property with a sensible default.
2. Bump `schemaVersion` and add a default in `init(from:)` so older payloads still decode.
3. Expose it in [`SettingsView.swift`](Sources/CCUBar/Popover/SettingsView.swift) — new UI goes under an appropriate `Section {}`.
4. If the change should take effect immediately, add a Combine observer in [`AppDelegate.swift`](Sources/CCUBar/App/AppDelegate.swift).
5. Localise the label + help text (see above).

---

## Security

If you found something security-sensitive, please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
