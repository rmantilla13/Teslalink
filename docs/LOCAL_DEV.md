# Working on TeslaLink locally (Mac)

## 1. Requirements

- macOS with **Xcode 16 or newer** (iOS 18 SDK). CI uses the newest Xcode on `macos-15`.
- Homebrew, then: `brew install xcodegen`
- Optional: an Apple developer team for running on a real iPhone.

## 2. Get the code

```bash
git clone https://github.com/rmantilla13/teslalink.git TeslaLink
cd TeslaLink
git checkout claude/admiring-pascal-wx9wxl     # the only branch right now
git log --oneline -1                            # e78e8cf or newer
```

## 3. Run the core tests (no Xcode project needed)

```bash
cd Packages/TeslaLinkCore && swift test && cd ../..
```

Expect 27 tests to pass.

## 4. Open the app in Xcode

The `.xcodeproj` is generated, not committed:

```bash
xcodegen generate
open TeslaLink.xcodeproj
```

Pick the **TeslaLink** scheme and an iPhone simulator, then Run. On the first screen tap
**Explore with a demo car**. You get a month of sample drives and charges and a live
charge that finishes in about 90 seconds (accelerated clock). No Tesla account needed.

Re-run `xcodegen generate` whenever you add or remove files (sources come from `App/`).

## 5. Running on your iPhone

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # git-ignored
```

Set `TESLALINK_BUNDLE_ID` and `TESLALINK_TEAM_ID`, run `xcodegen generate` again, select
your phone, Run. Allow location **Always** to get automatic drive logging.

## 6. Connecting your real car

Follow `docs/FLEET_API_SETUP.md`: create a developer app at developer.tesla.com, register
your domain (`scripts/register-partner.sh`), then put the client id, secret and redirect
URI into `Config/Secrets.xcconfig` (or type them into Settings › Advanced › Developer
app on the device).

## 7. Where things are

| Path | What |
| --- | --- |
| `Packages/TeslaLinkCore` | All logic: Fleet API, state machine, SQLite store, analytics, demo data. Tested. |
| `App/Services` | App wiring: `AppModel`, phone GPS tracker, Keychain, addresses. |
| `App/Views` | Screens. |
| `App/Design` | Brand tokens (`Theme.swift`), components, chart style, appearance. |
| `docs/` | Architecture, Fleet API setup, this file. |
| `.ai/handoffs/` | Session handoff records: status, decisions, what is unverified. |

Design references (private links, owner only until shared):
design system https://claude.ai/artifact/4RWrU35d1TqMKueNKZfWUj ·
screen layouts https://claude.ai/artifact/VTPntuBcebWCULjEhBzTdm

## 8. What has and hasn't been checked

The app **compiles** (CI) and the core is **tested**, but the app has **never been run**.
The first local session should launch it and fix what looks wrong. The full list is in
`.ai/handoffs/claude-admiring-pascal-wx9wxl-2026-11-09.md`.

## 9. Resume prompt for Claude Code on your Mac

Open Claude Code in the cloned folder and paste:

```text
Resume TeslaLink (iOS Tesla data logger) in this repo, rmantilla13/teslalink.
Branch claude/admiring-pascal-wx9wxl was at e78e8cf at handoff (the repo has no main yet).
1. git fetch && git checkout claude/admiring-pascal-wx9wxl
   git branch --show-current must print claude/admiring-pascal-wx9wxl.
   Then read .ai/handoffs/claude-admiring-pascal-wx9wxl-2026-11-09.md (status, decisions,
   what is UNVERIFIED) and docs/LOCAL_DEV.md.
2. Blocker for real-car testing: the owner's Tesla developer app (docs/FLEET_API_SETUP.md).
   It doesn't block UI work: use demo mode.
3. First action: cd Packages/TeslaLinkCore && swift test && cd ../.. && brew install xcodegen
   && xcodegen generate, then build and run the TeslaLink scheme on an iPhone simulator
   (xcodebuild -project TeslaLink.xcodeproj -scheme TeslaLink -destination
   'platform=iOS Simulator,name=iPhone 16' build), launch it, tap "Explore with a demo car",
   and check every screen against the design canvas. Start with follow-ups 1–3 in the
   handoff (fonts, chart glow alignment, iPad sidebar).
Rules: no server, no TeslaMate source code (AGPL); keep CI green
(.github/workflows/ios-build.yml).
Recommended model: opus — first real run of an untested UI, needs judgment on visual fixes.
```
