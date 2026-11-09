import SwiftUI
import TeslaLinkCore

/// The charging session in progress: energy so far, live charger telemetry, the curve and cost.
struct LiveChargeView: View {
    @Environment(AppModel.self) private var model
    let vin: String
    @State private var session: ChargeSession?
    @State private var samples: [ChargeSample] = []
    @State private var placeName: String?

    var body: some View {
        let f = Fmt(model.settings.units)
        let s = model.status(for: vin).snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: TL.Space.s6) {
                header(s)

                VStack(alignment: .leading, spacing: TL.Space.s1) {
                    Text("Energy added").tlLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("+" + ((session?.energyAddedKwh ?? s?.chargeEnergyAddedKwh).map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"))
                            .font(TL.Typeface.readoutXL)
                            .monospacedDigit()
                            .foregroundStyle(TL.Palette.charge)
                            .shadow(color: TL.Palette.charge.opacity(0.35), radius: 14)
                        Text("kWh").font(TL.Typeface.display(24)).foregroundStyle(TL.Palette.inkMuted)
                    }
                    Text(progressLine(s)).font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                }

                HStack(alignment: .top, spacing: TL.Space.s4) {
                    Metric(label: "Power", value: f.power(s?.chargerPowerKw), tone: TL.Palette.charge)
                    Metric(label: "Voltage", value: s?.chargerVoltage.map { "\(Int($0)) V" } ?? "–")
                    Metric(label: "Current", value: s?.chargerActualCurrent.map { "\(Int($0)) A" } ?? "–")
                    Metric(label: "To \(s?.chargeLimitSoc ?? 80)%", value: f.duration(minutes: s?.minutesToFullCharge.map(Double.init)))
                }

                BatteryBar(level: s?.batteryLevel, limit: s?.chargeLimitSoc, charging: true)

                let curve = samples.compactMap { x in x.chargerPowerKw.map { TLPoint(x: x.timestamp, y: $0) } }
                Card(title: "Charge curve", symbol: "chart.line.uptrend.xyaxis", hero: true, aside: AnyView(ChartUnit(text: "kW"))) {
                    if curve.count >= 2 {
                        TLLineChart(points: curve, color: TL.Palette.charge, liveEnd: true, height: 170,
                                    valueFormat: { "\(Int($0.rounded())) kW" })
                        if let peak = session?.powerMaxKw, peak > 0 {
                            ChartNote(text: "Peak \(Int(peak.rounded())) kW" + (s?.fastChargerPresent == true ? ". Power tapers as the battery fills." : "."))
                        }
                    } else {
                        ChartNote(text: "The curve appears after a few readings. Keep TeslaLink open for a detailed curve.")
                    }
                }

                Card(title: "Cost", symbol: "creditcard", lightbar: false) {
                    HStack(alignment: .top) {
                        Metric(label: session?.cost == nil ? "No price set" : "Cost so far", value: f.money(session?.cost))
                        Spacer()
                        if session?.geofenceID == nil {
                            Text("Add this place in Settings › Places to track what charging here costs.")
                                .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 200, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
        .navigationTitle("Charging")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { await load() }
    }

    private func header(_ s: VehicleSnapshot?) -> some View {
        let dc = s?.fastChargerPresent == true
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dc ? "Fast charger" + (session?.powerMaxKw.map { " · up to \(Int($0.rounded())) kW" } ?? "") : "AC charging").tlLabel()
                Text(placeName ?? session?.address ?? (dc ? "Fast charger" : "Charging"))
                    .font(TL.Typeface.display).foregroundStyle(TL.Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(dc ? TL.Palette.amber : TL.Palette.charge)
                Text(dc ? "DC" : "AC").font(TL.Typeface.sans(13, .semibold))
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill((dc ? TL.Palette.amber : TL.Palette.charge).opacity(0.14)))
        }
    }

    private func progressLine(_ s: VehicleSnapshot?) -> String {
        var parts: [String] = []
        if let a = session?.startBatteryLevel, let b = s?.batteryLevel ?? session?.endBatteryLevel { parts.append("\(a)% → \(b)%") }
        if let start = session?.startDate {
            let minutes = Date().timeIntervalSince(start) / 60
            parts.append(Fmt(model.settings.units).duration(minutes: minutes) + " so far")
        }
        return parts.isEmpty ? "Waiting for the first reading" : parts.joined(separator: " · ")
    }

    private func load() async {
        session = try? await model.store.openCharge(vin: vin)
        if let id = session?.id { samples = (try? await model.store.samples(sessionID: id)) ?? [] }
        if let fid = session?.geofenceID { placeName = ((try? await model.store.geofences()) ?? []).first { $0.id == fid }?.name }
    }
}
