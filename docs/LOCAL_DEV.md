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

Expect 28 tests to pass.

## 4. Open the app in Xcode

The `.xcodeproj` is generated, not committed:

```bash
xcodegen generate
open TeslaLink.xcodeproj
```

Pick the **TeslaLink** scheme and an iPhone simulator, then Run. On the first screen tap
**Explore with a demo car**. You get a month of sample drives and charges and a live
charge from 55% to 80% that takes about two minutes (accelerated clock). No Tesla account
needed.

Re-run `xcodegen generate` whenever you add or remove files (sources come from `App/`).

The main target is the **iPhone Duo** (owner, 2026-11-08): check layouts closed (outer
screen) and open (inner screen) on an iPhone Duo simulator, which only the iOS 27.1 runtime
offers. Switch posture with the Closed / Partially Open / Open buttons under the device in
Device Hub (`simctl` has no posture command). `xcrun simctl io <udid> screenshot` captures
only the inner screen: black while closed, turned a quarter while open. The outer screen
shows in the Device Hub window. iPad stays supported. An iPhone 16e (390×844) matches the
design artboards.

Debug builds take launch arguments for walkthroughs and screenshots, so you can skip taps:

```bash
xcrun simctl launch booted com.example.teslalink -TLDemo YES -TLTab drives
```

`-TLDemo YES` runs demo mode for that launch only (not saved). `-TLTab` takes `car`,
`drives`, `charges`, `stats` or `settings`. `-TLGeometry YES` adds a yellow strip with the
content size, safe-area insets, hinge state and hinge position, for checking a new device or
posture.

### The Duo open

Open or partially open in landscape, TeslaLink splits at the hinge. The left half is the
phone app (sections and the tab bar, as on the outer screen). The right half goes with the
current section:

- Car: this week's numbers, recent drives and the map, or live charging while the car charges.
- Drives and Charging: the drive or session picked on the left. Lists select instead of
  pushing, and the newest one is picked to start.
- Insights: battery health and parked drain, beside the overview. Both halves share the period.
- Settings: Places.

How it behaves:

- Folding keeps the tab and goes back to its list.
- Unfolding with a drive, charging session or live charging open on the outer screen moves
  it to the right pane.
- Open in portrait, the Duo keeps the phone layout (not designed yet).

The code is in `App/Views/DuoPanes.swift`. The hinge is read with `UIHingeInteraction`,
which needs the iOS 27.1 SDK. Older Xcode builds leave it out (CI's Xcode 26.3 among them),
and their open Duo gets the iPad sidebar layout instead. The Duo reports its hinge about
0.1 s after launch; a device that hasn't reported within half a second is taken to have none.
There's no API for where the fold is, so the split assumes the hinge is centred.

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

First local run, 2026-11-08. Every demo screen was walked on an iPhone 16e simulator and
compared against the design canvas. The Duo (closed and open) and an iPad Pro 11" were
checked too.

- Fixed: custom fonts never registered (`UIAppFonts` listed `Fonts/…`, but xcodegen copies
  the files to the bundle root).
- Fixed: location was requested on the welcome screen.
- Fixed: polling stopped while a system alert was showing, and slept 30 s before the first
  car reading. A first demo launch showed dashes for about 90 s.
- Fixed: the chart glow copy drifted off the line (each copy had its own automatic domain).
- Fixed: the Parked drain bars were invisible.
- Fixed: elevation was charted in metres under a feet header.
- Fixed: Drive detail used street names where the list used place names.
- Fixed: missing values showed "Off"/"Yes" instead of an en dash.
- Fixed: the demo charge sat at its 80% limit while still "charging".
- Chrome now follows the design rather than the system: a screen header instead of
  navigation bars, a flat steel tab bar (owner's choice over Liquid Glass), chamfered row
  groups instead of rounded `List` sections, no glyphs in panel headers. See
  `App/Design/Chrome.swift`.
- Done: the open Duo splits at the hinge (see section 4). Checked closed, partially open
  and open, and folding and unfolding with a screen pushed. For regressions, an iPhone 16e
  (both orientations) and an iPad were checked on iOS 27.0, where the hinge code doesn't run.
  The iOS 27.1 simulator runtime only offers the Duo, so an iPhone or iPad on 27.1 or later
  is unchecked. The no-hinge fallback was checked by withholding the Duo's hinge reports.
- Fixed: on Car, the gap between the Charging chip and "Updated…" didn't open live charging.
- Not done yet: the iPad artboard's two-column dashboard (Tonight's charge, Recent drives).
- Still unverified: real Tesla sign-in and real-car data (needs the Fleet API setup),
  background location relaunch, BGAppRefresh, and Keychain on a device.

The cloud session's original list is in `.ai/handoffs/claude-admiring-pascal-wx9wxl-2026-11-09.md`.

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
