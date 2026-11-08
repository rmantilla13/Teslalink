import SwiftUI
import TeslaLinkCore

/// Hero image: the real paint & wheels from Tesla's configurator compositor, with the
/// drawn "live" top-down view as the alternative (and fallback when offline).
struct VehicleHeroView: View {
    let vehicle: Vehicle?
    let snapshot: VehicleSnapshot?
    let units: UnitSystem
    @State private var mode: Mode = .photo
    @State private var angle: VehicleImage.View = .threeQuarter

    enum Mode: String, CaseIterable { case photo = "Photo", live = "Live" }

    var config: VehicleConfig? { snapshot?.config ?? vehicle?.config }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                switch mode {
                case .photo:
                    if let config, let url = VehicleImage.url(for: config, view: angle) {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                            switch phase {
                            case let .success(img): img.resizable().scaledToFit().transition(.opacity)
                            case .failure: live
                            default: ProgressView()
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 30).onEnded { g in rotate(g.translation.width < 0) })
                    } else {
                        live
                    }
                case .live:
                    live
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .animation(.spring, value: mode)

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    private var live: some View {
        TopDownCarView(snapshot: snapshot, paint: .paint(config?.exteriorColor), units: units)
    }

    private func rotate(_ forward: Bool) {
        let all = VehicleImage.View.allCases
        guard let i = all.firstIndex(of: angle) else { return }
        withAnimation { angle = all[(i + (forward ? 1 : all.count - 1)) % all.count] }
    }
}

/// A drawn top-down car that mirrors the live state: open doors and trunks, charge port,
/// tire pressures, lock and sentry status.
struct TopDownCarView: View {
    let snapshot: VehicleSnapshot?
    var paint: Color = .gray
    var units: UnitSystem = .metric
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let h = min(geo.size.height, geo.size.width * 2.1)
            let w = h * 0.45
            let doors = snapshot?.doorsOpen ?? DoorState()
            ZStack {
                // Wheels
                ForEach(WheelPosition.allCases, id: \.self) { pos in
                    RoundedRectangle(cornerRadius: w * 0.05)
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: w * 0.14, height: h * 0.15)
                        .offset(x: pos.isLeft ? -w * 0.48 : w * 0.48, y: pos.isFront ? -h * 0.29 : h * 0.29)
                    pressureLabel(pos)
                        .offset(x: pos.isLeft ? -w * 0.95 : w * 0.95, y: pos.isFront ? -h * 0.29 : h * 0.29)
                }

                // Body
                CarBodyShape()
                    .fill(LinearGradient(colors: [paint.opacity(0.95), paint.opacity(0.75), paint.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(CarBodyShape().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)

                // Glass roof
                RoundedRectangle(cornerRadius: w * 0.18)
                    .fill(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.72, height: h * 0.48)
                    .offset(y: h * 0.02)

                // Frunk / trunk
                trunk(open: doors.frontTrunk, front: true, w: w, h: h)
                trunk(open: doors.rearTrunk, front: false, w: w, h: h)

                // Doors
                door(open: doors.driverFront, left: true, front: true, w: w, h: h)
                door(open: doors.passengerFront, left: false, front: true, w: w, h: h)
                door(open: doors.driverRear, left: true, front: false, w: w, h: h)
                door(open: doors.passengerRear, left: false, front: false, w: w, h: h)

                // Charge port (rear left)
                chargePort(w: w, h: h)

                // Center status
                VStack(spacing: 6) {
                    if let locked = snapshot?.locked {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(locked ? Color.white : Color.orange)
                    }
                    if snapshot?.sentryMode == true {
                        Image(systemName: "eye.circle.fill").foregroundStyle(.red)
                            .opacity(pulse ? 1 : 0.4)
                    }
                    if let t = snapshot?.insideTempC {
                        Text(Fmt(units).temperature(t)).font(.caption2.bold()).foregroundStyle(.white)
                    }
                }
                .font(.title3)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .rotationEffect(.degrees(geo.size.width > geo.size.height * 1.2 ? -90 : 0))
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { pulse = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    enum WheelPosition: CaseIterable { case fl, fr, rl, rr
        var isLeft: Bool { self == .fl || self == .rl }
        var isFront: Bool { self == .fl || self == .fr }
    }

    @ViewBuilder private func pressureLabel(_ pos: WheelPosition) -> some View {
        let t = snapshot?.tirePressureBar
        let v: Double? = switch pos { case .fl: t?.frontLeft; case .fr: t?.frontRight; case .rl: t?.rearLeft; case .rr: t?.rearRight }
        if let v {
            Text(Fmt(units).pressure(v))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(v < 2.5 ? .orange : .secondary)
        }
    }

    private func door(open: Bool, left: Bool, front: Bool, w: CGFloat, h: CGFloat) -> some View {
        Capsule()
            .fill(open ? Color.red : Color.clear)
            .frame(width: w * 0.06, height: h * 0.17)
            .rotationEffect(.degrees(open ? (left ? -28 : 28) : 0), anchor: .top)
            .offset(x: (left ? -1 : 1) * w * (open ? 0.6 : 0.5), y: front ? -h * 0.06 : h * 0.13)
            .animation(.spring(duration: 0.4), value: open)
    }

    private func trunk(open: Bool, front: Bool, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: w * 0.12)
            .fill(open ? Color.red.opacity(0.85) : Color.white.opacity(0.08))
            .frame(width: w * 0.66, height: h * 0.14)
            .offset(y: (front ? -1 : 1) * h * (open ? 0.42 : 0.37))
            .animation(.spring(duration: 0.4), value: open)
    }

    @ViewBuilder private func chargePort(w: CGFloat, h: CGFloat) -> some View {
        let charging = snapshot?.chargingState?.isActive == true
        let open = snapshot?.chargePortDoorOpen == true || charging
        if open {
            Circle()
                .fill(charging ? Color.green : Color.white)
                .frame(width: w * 0.09, height: w * 0.09)
                .shadow(color: charging ? .green : .clear, radius: pulse ? 10 : 2)
                .offset(x: -w * 0.5, y: h * 0.39)
        }
    }

    private var accessibilitySummary: String {
        guard let s = snapshot else { return "Car illustration" }
        var parts: [String] = []
        if let l = s.locked { parts.append(l ? "Locked" : "Unlocked") }
        if s.doorsOpen.anyDoorOpen { parts.append("a door is open") }
        if s.doorsOpen.frontTrunk { parts.append("frunk open") }
        if s.doorsOpen.rearTrunk { parts.append("trunk open") }
        if s.chargingState?.isActive == true { parts.append("charging") }
        if s.sentryMode == true { parts.append("Sentry on") }
        return parts.joined(separator: ", ")
    }
}

/// Top-down body outline, nose up.
struct CarBodyShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX - w * 0.02, y: r.minY + h * 0.16),
                   control1: CGPoint(x: r.maxX - w * 0.12, y: r.minY), control2: CGPoint(x: r.maxX - w * 0.02, y: r.minY + h * 0.05))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.5))
        p.addCurve(to: CGPoint(x: r.maxX - w * 0.06, y: r.maxY - h * 0.04),
                   control1: CGPoint(x: r.maxX + w * 0.01, y: r.maxY - h * 0.2), control2: CGPoint(x: r.maxX - w * 0.02, y: r.maxY - h * 0.08))
        p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.06, y: r.maxY - h * 0.04), control: CGPoint(x: r.midX, y: r.maxY + h * 0.01))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.5),
                   control1: CGPoint(x: r.minX + w * 0.02, y: r.maxY - h * 0.08), control2: CGPoint(x: r.minX - w * 0.01, y: r.maxY - h * 0.2))
        p.addLine(to: CGPoint(x: r.minX + w * 0.02, y: r.minY + h * 0.16))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.5, y: r.minY),
                   control1: CGPoint(x: r.minX + w * 0.02, y: r.minY + h * 0.05), control2: CGPoint(x: r.minX + w * 0.12, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Ring gauge for state of charge.
struct BatteryRing: View {
    let level: Int?
    let limit: Int?
    let charging: Bool

    var body: some View {
        let v = Double(level ?? 0) / 100
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 12)
            if let limit {
                Circle().trim(from: 0, to: Double(limit) / 100)
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle().trim(from: 0, to: v)
                .stroke(color(v), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: v)
            VStack(spacing: 0) {
                if charging { Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption) }
                Text(level.map { "\($0)%" } ?? "–").font(.title2.bold().monospacedDigit())
            }
        }
    }

    private func color(_ v: Double) -> Color { v < 0.2 ? .red : v < 0.35 ? .orange : .green }
}
