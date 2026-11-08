import SwiftUI
import TeslaLinkCore

/// Panel: chamfered container with a light line on its top edge. One `hero` per screen.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var hero = false
    var lightbar = true
    var aside: AnyView?
    @ViewBuilder let content: Content

    init(title: String, symbol: String, hero: Bool = false, lightbar: Bool = true, aside: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.hero = hero
        self.lightbar = lightbar
        self.aside = aside
        self.content = content()
    }

    var body: some View {
        let cut = hero ? TL.Chamfer.lg : TL.Chamfer.md
        VStack(alignment: .leading, spacing: TL.Space.s3) {
            HStack(spacing: TL.Space.s2) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.Palette.inkMuted)
                Text(title).tlLabel()
                Spacer(minLength: 0)
                aside
            }
            content
        }
        .padding(TL.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if hero {
                // Faint top-down light falloff on the hero panel.
                LinearGradient(colors: [TL.Palette.lightbar.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .tlSurface(cut: cut)
        .overlay(alignment: .top) {
            if lightbar { LightbarLine().padding(.leading, cut + TL.Space.s2).padding(.trailing, TL.Space.s8) }
        }
    }
}

/// One measured value: uppercase label over a display-face number and its unit.
struct Metric: View {
    let label: String
    let value: String
    var tone: Color = TL.Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).tlLabel()
            valueText
                .font(TL.Typeface.display(22, .medium))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Splits "412 km" so the unit renders smaller and muted.
    private var valueText: Text {
        guard let space = value.lastIndex(of: " "), value[value.index(after: space)...].allSatisfy({ !$0.isNumber }) else {
            return Text(value)
        }
        return Text(value[..<space]) + Text(" " + value[value.index(after: space)...])
            .font(TL.Typeface.sans(13, .medium)).foregroundColor(TL.Palette.inkMuted)
    }
}

/// Period total on Insights.
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tone: Color = TL.Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: TL.Space.s2) {
            HStack(spacing: TL.Space.s1) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title)
            }
            .tlLabel()
            Text(value)
                .font(TL.Typeface.readout)
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, TL.Space.s4)
        .padding(.top, TL.Space.s3)
        .padding(.bottom, TL.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tlSurface()
    }
}

/// Logger state as glyph + word, tinted by state.
struct StateChip: View {
    let state: LoggerState
    var detail: String?

    var body: some View {
        HStack(spacing: TL.Space.s2) {
            Image(systemName: state.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(state.color)
            Text(state.label).font(TL.Typeface.sans(13, .semibold)).foregroundStyle(TL.Palette.ink)
            if let detail { Text(detail).font(TL.Typeface.sans(13, .medium)).foregroundStyle(TL.Palette.inkMuted) }
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(state.color.opacity(0.14)))
        .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(TL.Palette.surface1))
        .accessibilityElement(children: .combine)
    }
}

/// Hero state of charge: a big percentage and 20 slanted segments like a light bar.
struct BatteryBar: View {
    let level: Int?
    let limit: Int?
    let charging: Bool
    var segments = 20
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lvl = max(0, min(100, level ?? 0))
        let on = Int((Double(lvl) / 100 * Double(segments)).rounded())
        VStack(alignment: .leading, spacing: TL.Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(level.map(String.init) ?? "–").font(TL.Typeface.readoutXL).monospacedDigit().foregroundStyle(TL.Palette.ink)
                Text("%").font(TL.Typeface.display(24)).foregroundStyle(TL.Palette.inkMuted)
                if charging { Image(systemName: "bolt.fill").foregroundStyle(TL.Palette.charge).padding(.leading, 6) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(0..<segments, id: \.self) { i in
                            SlantSegment()
                                .fill(color(i, on: on, lvl: lvl))
                                .shadow(color: isLive(i, on) ? TL.Palette.charge.opacity(0.6) : .clear, radius: 8)
                                .opacity(isLive(i, on) && pulse ? 0.45 : 1)
                        }
                    }
                    if let limit {
                        Rectangle()
                            .fill(TL.Palette.ion)
                            .frame(width: 2, height: geo.size.height + 10)
                            .tlGlow()
                            .offset(x: geo.size.width * CGFloat(limit) / 100 - 1)
                    }
                }
            }
            .frame(height: 22)
            if let limit {
                Text(charging ? "Charging to \(limit)%" : "Limit \(limit)%").tlLabel()
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(lvl) percent\(charging ? ", charging" : "")")
    }

    private func isLive(_ i: Int, _ on: Int) -> Bool { charging && i == on }

    private func color(_ i: Int, on: Int, lvl: Int) -> Color {
        if isLive(i, on) { return TL.Palette.charge }
        guard i < on else { return TL.Palette.steelDeep }
        if charging { return TL.Palette.charge }
        return lvl <= 20 ? TL.Palette.taillight : TL.Palette.ink
    }
}

struct SlantSegment: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 4, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 4, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Chamfered buttons: primary (ion fill, once per view), secondary (steel outline), ghost.
struct TLButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost }
    var variant: Variant = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(TL.Typeface.sans(15, .semibold))
            .tracking(0.3)
            .padding(.vertical, 10)
            .padding(.horizontal, variant == .ghost ? TL.Space.s2 : 18)
        Group {
            switch variant {
            case .primary:
                label.foregroundStyle(isEnabled ? TL.Palette.onIon : TL.Palette.inkMuted)
                    .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(isEnabled ? TL.Palette.ion : TL.Palette.steelDeep))
            case .secondary:
                label.foregroundStyle(TL.Palette.ink)
                    .tlSurface(configuration.isPressed ? TL.Palette.surface2 : TL.Palette.surface1, border: TL.Palette.edgeStrong, cut: TL.Chamfer.sm)
            case .ghost:
                label.foregroundStyle(TL.Palette.ion)
            }
        }
        .offset(y: configuration.isPressed ? 1 : 0)
        .brightness(configuration.isPressed && variant == .primary ? 0.06 : 0)
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TLButtonStyle {
    static var tlPrimary: TLButtonStyle { TLButtonStyle(variant: .primary) }
    static var tlSecondary: TLButtonStyle { TLButtonStyle(variant: .secondary) }
    static var tlGhost: TLButtonStyle { TLButtonStyle(variant: .ghost) }
}

/// The TeslaLink mark: a steel wedge over a single light bar.
struct TeslaLinkMark: View {
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 96, sy = size.height / 64
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            var wedge = Path()
            wedge.addLines([pt(4, 44), pt(4, 37), pt(58, 17), pt(92, 29), pt(92, 44)])
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(TL.Palette.steel))
            var facet = Path()
            facet.addLines([pt(58, 17), pt(92, 29), pt(92, 44), pt(70, 44)])
            facet.closeSubpath()
            ctx.fill(facet, with: .color(TL.Palette.steelDeep))
            ctx.fill(Path(CGRect(x: 4 * sx, y: 50 * sy, width: 88 * sx, height: 3 * sy)), with: .color(TL.Palette.lightbar))
        }
        .aspectRatio(96 / 64, contentMode: .fit)
        .accessibilityLabel("TeslaLink")
    }
}

/// Angular segmented control: the selected option gets `surface-2` and a glowing ion underline.
struct TLSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { o in
                let selected = o == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = o }
                } label: {
                    Text(title(o))
                        .font(TL.Typeface.sans(13, .semibold))
                        .tracking(0.5)
                        .foregroundStyle(selected ? TL.Palette.ink : TL.Palette.inkMuted)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(selected ? TL.Palette.surface2 : TL.Palette.surface1)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Rectangle().fill(TL.Palette.ion).frame(height: 2).padding(.horizontal, 8).tlGlow(radius: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(1)
        .background(TL.Palette.edgeStrong)
        .clipShape(ChamferedRectangle(cut: TL.Chamfer.sm))
        .fixedSize(horizontal: true, vertical: false)
    }
}
