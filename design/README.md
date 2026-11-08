# TeslaLink brand

The full design system (tokens, components with live previews, logo and usage rules) lives in the
TeslaLink design system artifact: https://claude.ai/artifact/4RWrU35d1TqMKueNKZfWUj

In this repo:

- `App/Design/Theme.swift`: the tokens in Swift (`TL.Palette`, `TL.Typeface`, `TL.Space`, `TL.Chamfer`),
  `ChamferedRectangle`, `LightbarLine`.
- `App/Design/Components.swift`: `Card` (panel), `Metric`, `StatTile`, `StateChip`, `BatteryBar`,
  `TLSegmented`, `TLButtonStyle`, `TeslaLinkMark`.
- `App/Design/Appearance.swift`: navigation and tab bar styling.
- `App/Resources/Fonts/`: Chakra Petch, Barlow, IBM Plex Mono (SIL Open Font License, licenses alongside).
- `design/logo/`: mark (Night, Daylight) and the app icon master. `AppIcon-1024.png` is rendered from it.

Direction in one line: stainless steel surfaces, cut corners instead of rounded ones, and light
(`lightbar`, `ion`, glows) only where something is live.
