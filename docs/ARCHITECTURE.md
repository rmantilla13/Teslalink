# Architecture

TeslaMate is a server: an Elixir process polls the car around the clock, writes to
PostgreSQL, and Grafana draws the dashboards. TeslaLink keeps the ideas and drops the
infrastructure. The logger, database, analytics and charts all run inside the iOS app.

```
┌──────────────────────────── iOS app ────────────────────────────┐
│  SwiftUI views (Car · Drives · Charging · Insights · Settings)   │
│        ▲ reads                                                   │
│  AppModel ── schedules work ── PhoneDriveTracker (CoreLocation)  │
│        │                              │ dense GPS while driving  │
│        ▼                              ▼                          │
│  ┌────────────── TeslaLinkCore (Swift package) ───────────────┐ │
│  │ VehicleLogger (actor, one per car)                          │ │
│  │   ├─ VehicleStateMachine   pure: events → effects + plan    │ │
│  │   ├─ Drive/ChargeSummarizer, GapReconciler, PhoneTrackMatcher│ │
│  │   └─ LogStore (SQLite: positions, drives, charges, states)  │ │
│  │ Analytics: efficiency, battery health, parked drain, stats  │ │
│  │ FleetAPIClient + FleetAuth per account (PKCE, refresh)      │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
                                 │ HTTPS (read-only)
                                 ▼
                        Tesla Fleet API
```

## The hard part: iOS won't let an app poll forever

A server can ask the car for data every few seconds, all day. An iOS app can't. It gets
execution time in bursts. TeslaLink is designed around that.

| Situation | How the app gets to run | What gets logged |
|---|---|---|
| App open | Foreground loop, poll on schedule | Everything, TeslaMate-level detail |
| **Driving, phone in the car** | Significant-location-change monitoring relaunches the app; live location updates keep it running for the whole drive | Phone GPS every 5 s / 25 m (elevation, speed) **plus** car data every 10 s (SoC, power, odometer, temperatures) |
| Charging at home | `BGAppRefreshTask`, which iOS runs when it chooses (often every 15–60 min) | Start/end SoC, **exact energy added** (Tesla's counter is cumulative, so sparse samples are enough), cost |
| Car used while the app was asleep (e.g. someone else drove it) | Next run notices the odometer/SoC jump | **Reconstructed** drive or charge, flagged "inferred" |

So the design rules are:

1. **The state machine is "tickable".** `VehicleLogger.poll()` does whichever request is due
   next and returns. It doesn't matter if the next tick comes 10 seconds or 3 hours later.
   State is checkpointed to SQLite after every tick, so a relaunch mid-drive picks up the open drive.
2. **Gaps are reconciled, not ignored.** `GapReconciler` compares the snapshots on either
   side of a gap and records missed drives or charges.
3. **The phone is a sensor, but it is checked.** Phone GPS only becomes part of a drive if
   the car itself reported driving during that time, and `PhoneTrackMatcher` confirms the
   track is near the car's own positions. If you're on a bus while your partner drives the
   Tesla, your bus ride doesn't end up in the car's log.
4. **Let the car sleep.** Same strategy as TeslaMate: after 15 minutes idle with nothing
   blocking sleep (Sentry, climate, open doors, a person inside), stop calling
   `vehicle_data` and only use the non-waking status endpoint until the car is asleep.

## What came from TeslaMate (and what didn't)

TeslaMate is AGPL-3.0. TeslaLink contains **no TeslaMate code**. Elixir doesn't run on iOS
anyway. These *ideas* were studied and re-implemented from scratch:

- The online → suspended → asleep cycle and the list of things that keep a car awake.
- Deriving consumption (kWh per rated km) from charges: the most common
  `energy_added / rated_range_added` ratio, with stricter agreement at finer precision.
- Drive summaries from odometer and rated range, plus charge summaries using the cumulative
  `charge_energy_added` counter and wall-energy integration (phases × V × A).

If you ever copy actual TeslaMate source into this project, the app becomes a derivative
work under AGPL-3.0. That is hard to reconcile with App Store distribution. Also don't use
the "TeslaMate" name or logo (see their TRADEMARK.md).

## What TeslaLink adds

- **Model graphics.** Your real paint and wheels from Tesla's configurator compositor
  (swipe to rotate), and a drawn "live" top-down view that shows open doors, trunks,
  charge port, tire pressures, lock and Sentry state.
- **Phone-GPS drive tracks** colored by speed, power or elevation. They are denser than the
  API and give real elevation.
- **Time-of-use charging cost** per place (off-peak windows, per-kWh or per-minute billing).
- **Efficiency vs. temperature**, **battery health** (projected range at 100%, estimated
  usable kWh) and **parked drain** split by whether the car actually slept.
- **Multiple cars**, with a picker in the toolbar.
- **iPhone + iPad**. The tab bar becomes a sidebar on iPad, and cards reflow into columns.
- Local notifications when charging finishes, and JSON export.

## Storage

One SQLite file: `Application Support/TeslaLink/log.sqlite` (WAL mode). Positions and
charge samples get real columns because they are the high-volume tables. Drive and charge
summaries keep indexed key columns plus a JSON payload, so new fields don't need migrations.
The file is included in the normal encrypted iCloud/device backup.

## Testing

The core is plain Swift and builds on Linux and macOS:

```bash
cd Packages/TeslaLinkCore && swift test
```

The tests cover the state machine (suspend/sleep, offline tolerance during drives,
blockers), Fleet API decoding and unit conversion, PKCE, the summaries, efficiency
derivation, gap reconciliation, phone-track matching, and full logger runs against a
scripted car and a real SQLite database.

## Roadmap ideas

- Live Activity / Dynamic Island while charging or driving
- Home-screen and Lock Screen widgets (needs an App Group to share the database)
- Bluetooth (BLE) data via Tesla's vehicle-command protocol, for zero-cost local reads when the phone is near the car
- CarPlay dashboard
- Import from an existing TeslaMate PostgreSQL export
