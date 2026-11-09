# Handoff: TeslaLink → local Mac (2026-11-09)

Work moves from a cloud Claude Code session (Linux container, no Xcode) to the owner's
local Mac. Everything is committed and pushed; nothing lives only in the old session.

Repo `rmantilla13/teslalink`, branch `claude/admiring-pascal-wx9wxl`,
HEAD `e78e8cf` at handoff. This is the ONLY branch in the repo (no `main` yet).

## What the product is (the owner's brief, verbatim intent)

"A standalone Tesla data logger using ideas from TeslaMate, built into an iOS app with
model graphics and enhanced functionality. No Grafana or external stuff. Everything on
iOS, optimized for duo."

- "Duo" was interpreted as **iPhone + iPad** (universal app, sidebar on iPad). The owner
  never confirmed this; it could also mean two cars (multi-vehicle is supported anyway).
  Ask if it matters.
- "Backend" = the on-device engine (`Packages/TeslaLinkCore`), not a server. Do not add a
  server without the owner asking.

## Status

- DONE: core Swift package `Packages/TeslaLinkCore`: Fleet API client + OAuth PKCE,
  state machine (online/suspended/asleep/driving/charging/updating), SQLite log store,
  drive/charge summarizers, gap reconciliation, phone-GPS matching, efficiency /
  degradation / parked-drain analytics, route previews, live (open) session totals,
  demo data. Verified: `swift test` → 27 tests pass on Linux (Swift 6.0.3) and macOS CI.
- DONE: SwiftUI app `App/` (iOS 18+, iPhone + iPad): onboarding + sign-in, Car
  dashboard, Drives list, Drive detail (map + charts), Live charging, Charging history +
  detail, Insights, Settings (places/tariffs, polling, export), iPad sidebar, demo mode.
  Verified: **compiles** with Xcode in CI (`.github/workflows/ios-build.yml`, run
  `42548072178` on `e78e8cf`: BUILD SUCCEEDED).
- DONE: brand + design system (stainless steel, chamfered corners, light only for live
  state). Tokens/components in `App/Design/`; fonts in `App/Resources/Fonts/` (OFL);
  logo in `design/logo/`; app icon rendered.
- NOT STARTED: running the app on a simulator/device, any UI test, real Tesla sign-in.

## Verification

- Ran `swift test` in `Packages/TeslaLinkCore`: 27/27 pass (Linux; also macOS in CI).
- Ran Xcode build for `generic/platform=iOS Simulator` in CI: succeeds.
- **UNVERIFIED (important):** the app has never been launched. Nobody has tapped through
  a screen. Layout, fonts actually registering (PostScript names assumed:
  `ChakraPetch-SemiBold`, `ChakraPetch-Medium`, `Barlow-Regular|Medium|SemiBold`,
  `IBMPlexMono-Medium`), chart rendering, map styling, the glow-copy chart overlay
  alignment, background location relaunch, BGAppRefresh, Keychain, and the OAuth
  redirect are all untested.
- **UNVERIFIED:** Fleet API against a real car. Field names follow Tesla's documented
  `vehicle_data` shape; decoding is tested only against a hand-written JSON sample.
- **UNVERIFIED:** whether Tesla's developer portal accepts the custom-scheme redirect
  `teslalink://auth/callback`. If not, use an https redirect + Associated Domains
  (see `docs/FLEET_API_SETUP.md`).

## Decisions (and why)

- **No TeslaMate code copied.** TeslaMate is AGPL-3.0 and its name/logo are trademarked;
  copying source would make the app AGPL (hard to ship on the App Store). Ideas were
  re-implemented in Swift. Keep it that way.
- **Fleet API, not the owner API** (owner API is closing to third parties). One-time
  partner registration needs a domain hosting a public key: `scripts/register-partner.sh`.
- **Client secret compiled into the app** because Tesla's code exchange requires it.
  Acceptable for a personal build only; a public release needs a tiny token-exchange
  endpoint (the one unavoidable "external" piece). Owner has not decided.
- **iOS background reality drives the design:** the logger is "tickable"
  (`VehicleLogger.poll()`), checkpointed to SQLite, phone GPS keeps the app alive during
  drives (significant-location relaunch + live updates), BGAppRefresh catches charges,
  `GapReconciler` reconstructs missed drives/charges. See `docs/ARCHITECTURE.md`.
- **Cost-aware polling defaults** (10 s driving, 60 s charging, suspend after 15 min
  idle) because Tesla bills Fleet API per request.
- **Demo data in a separate database file** (`demo.sqlite` vs `log.sqlite`) so it never
  mixes with real data.
- **Design:** Night theme is primary; ion blue is the only interactive color; charts
  follow the "Chart style" board. Design system and canvas links below.

## Changes

Branch `claude/admiring-pascal-wx9wxl`, commits (oldest → newest):
`1e3dd27` core + app · `f522eab` brand/design system · `451b0ec` chart style ·
`37fc0da` iOS CI · `9f3d5b6` live sessions, route previews, addresses, mockup layouts ·
`5d30566` demo mode · `980d419` README · `f120e15` split DriveDetailView ·
`e78e8cf` AppModel init fix. No PR exists (no base branch to target).

External artifacts (private to the owner until shared):
- Design system: https://claude.ai/artifact/4RWrU35d1TqMKueNKZfWUj
- Screen layouts + chart style canvas: https://claude.ai/artifact/VTPntuBcebWCULjEhBzTdm

## Blockers

- **No `main` branch → no PR.** Unblocked by the owner creating `main` (or making this
  branch default) on GitHub.
- **Real-car testing needs the owner's Tesla developer app** (client id/secret, domain
  with public key, partner registration). Only the owner can do this. Demo mode works
  without it.

## Next action

On the Mac: `brew install xcodegen && xcodegen generate && open TeslaLink.xcodeproj`,
run the `TeslaLink` scheme on an iPhone 16 simulator, tap **Explore with a demo car**,
and walk every screen against the design canvas. Fix whatever looks wrong. Full steps:
`docs/LOCAL_DEV.md`.

## Open follow-ups

1. First simulator run; confirm custom fonts register (look for Chakra Petch numerals);
   if not, check PostScript names with Font Book and update `App/Design/Theme.swift`.
2. Check the `TLLineChart` glow copy lines up with the crisp line (two stacked charts).
3. iPad: run on an iPad simulator; confirm `SidebarRoot` appears in regular width.
4. Tesla setup per `docs/FLEET_API_SETUP.md`, then a real sign-in and a real drive.
5. Decide the app name: "Tesla" in the name is likely to be rejected by App Review.
6. Roadmap in `docs/ARCHITECTURE.md`: Live Activity, widgets (App Group), BLE reads,
   CarPlay, TeslaMate import.

## Skills Review

- ✅ code-quality: core logic is pure and tested; app logic reads cleanly. ⚠️ `AppModel`
  is getting large (auth, demo, polling, notifications); split when it next grows.
- ✅ tdd-skill: every core feature landed with tests (27). ⚠️ No app-level tests; the
  demo data source makes UI/snapshot tests cheap to add.
- ⚠️ frontend: views compile but were never rendered; two compile failures came from
  oversized SwiftUI bodies / Observable init order. Keep bodies split into sub-views.
- ✅ design-guide: one token system across Swift, web previews and canvas; contrast
  checked (text ≥ 4.5:1 both themes). ⚠️ charge green vs taillight red rely on glyph +
  word, not lightness.
- ✅ git-sync: everything committed and pushed; tree clean. ⚠️ Branch-only repo; no PR.
- Environment: the cloud box had no Xcode, so CI was the only compiler for SwiftUI
  (~2 min per round). On the Mac, build locally first; keep CI as the gate.

## Resume brief (for a Claude Code session on the Mac)

See the copyable prompt at the end of `docs/LOCAL_DEV.md`.
