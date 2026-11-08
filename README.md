# TeslaLink

A standalone Tesla data logger for iPhone and iPad. It covers what TeslaMate does (drives,
charging, battery health, parked drain) without a server, Docker, PostgreSQL or Grafana.
The logger, database and charts all run inside the app.

- **Car tab:** your car in its real paint and wheels, or a drawn live view showing open
  doors, trunks, charge port, tire pressures, lock and Sentry. Also battery ring, climate,
  live charging details and location.
- **Drives:** automatic logging. Routes come from phone GPS, colored by speed, power or
  elevation, with speed, power and elevation charts and per-drive efficiency.
- **Charging:** sessions with energy added, wall energy, charging efficiency, charge curve,
  and cost per place with off-peak pricing.
- **Insights:** distance, efficiency vs. temperature, battery health (range at 100%,
  usable kWh), parked drain, cost per km/mi, fast-charging share.
- Multiple cars, metric/imperial units, notifications, JSON export. Read-only: it never
  sends commands to your car.

## Project layout

```
App/                      SwiftUI app (iOS 18+, iPhone & iPad)
  Services/               AppModel, phone GPS tracker, Keychain, settings
  Views/                  Dashboard, Drives, Charging, Insights, Settings
Packages/TeslaLinkCore/   Swift package with all logic, testable without Xcode
  API/                    Fleet API client, OAuth (PKCE), vehicle image URLs
  Engine/                 State machine, logger actor, summarizers
  Analytics/              Efficiency, degradation, parked drain, geo math
  Storage/                SQLite log store
docs/                     Architecture and Fleet API setup
scripts/                  One-time Tesla partner registration
```

## Getting started

1. Set up a Tesla developer app: see [docs/FLEET_API_SETUP.md](docs/FLEET_API_SETUP.md).
2. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and fill it in.
3. `brew install xcodegen && xcodegen && open TeslaLink.xcodeproj`
4. Run on your phone. Sign in with Tesla, and allow location **Always** so drives are
   logged automatically.

Core tests (Linux or macOS): `cd Packages/TeslaLinkCore && swift test`

## How it works on iOS

iOS doesn't let apps run in the background all the time, so TeslaLink works around that:

- When you start moving, the app is relaunched and kept running for the whole drive.
- Background refresh catches charging sessions.
- Activity it missed (say, someone else drove the car) is reconstructed from the readings
  before and after.

Details are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Relationship to TeslaMate

TeslaLink is inspired by [TeslaMate](https://github.com/teslamate-org/teslamate) and
re-implements its logging approach from scratch in Swift. It contains no TeslaMate code
and is not affiliated with TeslaMate or Tesla, Inc. TeslaMate is AGPL-3.0. Copying its
source into this project would make the app AGPL as well.
