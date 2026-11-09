import SwiftUI
import TeslaLinkCore

/// The charging session in progress: energy so far, live charger telemetry, the curve and cost.
struct LiveChargeView: View {
    @Environment(AppModel.self) private var model
    let vin: String
    /// The screen this was opened from, for the back link ("Car", "Charging"); nil in the open
    /// Duo's right pane.
    var backTitle: String?
    @Environment(\.paneSelection) private var pane
    @Environment(\.dismiss) private var dismiss
    @State private var session: ChargeSession?
    @State private var samples: [ChargeSample] = []
    @State private var placeName: String?

    var body: some View {
        let f = Fmt(model.settings.units)
        let s = model.status(for: vin).snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
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

                HStack(alignment: .top, spacing: TL.Space.s3) {
                    Metric(label: "Power", value: f.power(s?.chargerPowerKw), tone: TL.Palette.charge).frame(maxWidth: .infinity, alignment: .leading)
                    Metric(label: "Voltage", value: s?.chargerVoltage.map { "\(Int($0)) V" } ?? "–").frame(maxWidth: .infinity, alignment: .leading)
                    Metric(label: "Current", value: s?.chargerActualCurrent.map { "\(Int($0)) A" } ?? "–").frame(maxWidth: .infinity, alignment: .leading)
                    Metric(label: "To \(s?.chargeLimitSoc ?? 80)%", value: f.duration(minutes: s?.minutesToFullCharge.map(Double.init)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                let curve = samples.compactMap { x in x.chargerPowerKw.map { TLPoint(x: x.timestamp, y: $0) } }
                Card(title: "Charge curve", hero: true, aside: AnyView(ChartUnit(text: "kW"))) {
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

                Card(title: "", lightbar: false) {
                    HStack(alignment: .top) {
                        Metric(label: session?.cost == nil ? "No price set" : "Estimated cost", value: f.money(session?.cost))
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
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .tlScreen()
        .onChange(of: pane != nil, initial: true) { _, inPanes in
            // Unfolded while this was pushed on the outer screen: the right pane takes it over.
            if inPanes, backTitle != nil, let pane {
                pane.liveCharge = true
                dismiss()
            }
        }
        .task(id: model.dataVersion) { await load() }
    }

    /// Live charging artboard: "Fast charger · 250 kW" over "Charging", with a DC / AC chip.
    private func header(_ s: VehicleSnapshot?) -> some View {
        let dc = s?.fastChargerPresent == true
        let place = placeName ?? session?.address
        let label = dc
            ? "Fast charger" + (session?.powerMaxKw.map { " · up to \(Int($0.rounded())) kW" } ?? "")
            : [place, "AC"].compactMap { $0 }.joined(separator: " · ")
        return ScreenHeader(back: backTitle, label: label, title: Text("Charging")) {
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
