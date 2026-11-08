import Charts
import SwiftUI

/// TeslaLink chart style. Charts read like instruments: flat steel, thin lines, and light only
/// on data that is live, current or extreme. See the "Chart style" board in the design canvas.
///
/// Rules encoded here:
/// - Baseline `steelDeep`, grid `edge`, horizontal only, at most 3 lines; no vertical grid.
/// - Tick labels in IBM Plex Mono 10, `inkMuted`. Units go in the panel header, not on the axis.
/// - Lines are 2 px with a blurred glow copy; areas fade from 32% to 0.
/// - Maximums get a `lightbar` dot and value; the live end gets a dot with a halo.
/// - Averages/trends: dashed `lightbar`. Time windows: `ion` at 6% with dashed edges.

// MARK: - Axes

extension View {
    /// Applies TeslaLink axes. `xLabels` false hides the x labels (sparklines, stacked charts).
    /// `ghost` keeps the exact layout but paints nothing (used under the glow copy of a line).
    func tlChartAxes(yCount: Int = 3, xCount: Int = 3, xLabels: Bool = true, ghost: Bool = false) -> some View {
        self
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: yCount)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(ghost ? Color.clear : (value.index == 0 ? TL.Palette.steelDeep : TL.Palette.edge))
                    AxisValueLabel(horizontalSpacing: 6)
                        .font(TL.Typeface.mono(10))
                        .foregroundStyle(ghost ? Color.clear : TL.Palette.inkMuted)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: xCount)) { _ in
                    if xLabels {
                        AxisValueLabel(collisionResolution: .greedy)
                            .font(TL.Typeface.mono(10))
                            .foregroundStyle(ghost ? Color.clear : TL.Palette.inkMuted)
                    }
                }
            }
            .chartPlotStyle { $0.background(Color.clear) }
    }
}

// MARK: - Header

/// Panel header for a chart: uppercase title, then a legend or the unit on the right.
struct ChartHeader: View {
    let title: String
    var unit: String?
    var legend: [(String, Color)] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).tlLabel()
            Spacer(minLength: TL.Space.s2)
            if !legend.isEmpty {
                HStack(spacing: TL.Space.s3) {
                    ForEach(legend.indices, id: \.self) { i in
                        HStack(spacing: 5) {
                            Rectangle().fill(legend[i].1).frame(width: 8, height: 8)
                            Text(legend[i].0)
                        }
                    }
                }
                .font(TL.Typeface.sans(12, .medium))
                .foregroundStyle(TL.Palette.inkMuted)
            } else if let unit {
                Text(unit).font(TL.Typeface.mono(11)).foregroundStyle(TL.Palette.inkMuted)
            }
        }
    }
}

// MARK: - Line / area

struct TLPoint<X: Plottable & Comparable>: Identifiable {
    var x: X
    var y: Double
    var id: String { "\(x)" }
}

/// A continuous series drawn with the glowing line, fading area, max marker and live end.
struct TLLineChart<X: Plottable & Comparable>: View {
    let points: [TLPoint<X>]
    var color: Color = TL.Palette.ion
    var area = true
    var markMax = true
    var liveEnd = false
    var average: Double?
    var threshold: (value: Double, label: String)?
    var band: (from: X, to: X, label: String)?
    var yDomain: ClosedRange<Double>?
    var height: CGFloat = 150
    var valueFormat: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        ZStack {
            // Glow copy: same layout, axis labels hidden, blurred.
            chart(glow: true)
                .blur(radius: 4)
                .opacity(0.55)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            chart(glow: false)
        }
        .frame(height: height)
    }

    private var maxPoint: TLPoint<X>? { points.max { $0.y < $1.y } }

    @ChartContentBuilder
    private func marks(glow: Bool) -> some ChartContent {
        if let band, !glow {
            RectangleMark(xStart: .value("From", band.from), xEnd: .value("To", band.to))
                .foregroundStyle(TL.Palette.ion.opacity(0.06))
                .annotation(position: .top, alignment: .center, spacing: -14) {
                    Text(band.label.uppercased()).font(TL.Typeface.mono(10)).foregroundStyle(TL.Palette.ion)
                }
        }
        ForEach(points) { p in
            if area && !glow {
                AreaMark(x: .value("x", p.x), yStart: .value("base", yDomain?.lowerBound ?? 0), yEnd: .value("y", p.y))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            LineMark(x: .value("x", p.x), y: .value("y", p.y))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: glow ? 4 : 2, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        if !glow {
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(TL.Palette.lightbar.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            if let threshold {
                RuleMark(y: .value("Limit", threshold.value))
                    .foregroundStyle(TL.Palette.ion.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(threshold.label).font(TL.Typeface.mono(10)).foregroundStyle(TL.Palette.ion)
                    }
            }
            if markMax, let m = maxPoint {
                PointMark(x: .value("x", m.x), y: .value("y", m.y))
                    .symbolSize(150)
                    .foregroundStyle(TL.Palette.lightbar.opacity(0.2))
                PointMark(x: .value("x", m.x), y: .value("y", m.y))
                    .symbolSize(28)
                    .foregroundStyle(TL.Palette.lightbar)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(valueFormat(m.y)).font(TL.Typeface.mono(10)).foregroundStyle(TL.Palette.ink)
                    }
            }
            if liveEnd, let last = points.last {
                PointMark(x: .value("x", last.x), y: .value("y", last.y))
                    .symbolSize(220)
                    .foregroundStyle(color.opacity(0.2))
                PointMark(x: .value("x", last.x), y: .value("y", last.y))
                    .symbolSize(40)
                    .foregroundStyle(color)
                    .annotation(position: .topTrailing, spacing: 4) { ValueTag(text: valueFormat(last.y), color: color) }
            }
        }
    }

    @ViewBuilder
    private func chart(glow: Bool) -> some View {
        let c = Chart { marks(glow: glow) }
            .tlChartAxes(ghost: glow)
        if let yDomain {
            c.chartYScale(domain: yDomain)
        } else {
            c
        }
    }
}

/// Chamfered value tag used on live ends and peaks.
struct ValueTag: View {
    let text: String
    var color: Color = TL.Palette.ion

    var body: some View {
        Text(text)
            .font(TL.Typeface.display(11, .semibold))
            .foregroundStyle(TL.Palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(ChamferedRectangle(cut: 4).fill(TL.Palette.surface2))
            .overlay(ChamferedRectangle(cut: 4).stroke(color, lineWidth: 1))
    }
}

// MARK: - Bars

enum TLBars {
    /// Totals are steel; the highlighted (current) bar is ion.
    static func totalColor(highlighted: Bool) -> Color { highlighted ? TL.Palette.ion : TL.Palette.steel }

    /// Signed values: draw above zero in ion, regen below in charge.
    static func signedColor(_ v: Double) -> Color { v < 0 ? TL.Palette.charge : TL.Palette.ion }
}

/// Legend swatches for a panel header (`Card(aside:)`).
struct ChartLegend: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: TL.Space.s3) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Rectangle().fill(items[i].1).frame(width: 8, height: 8)
                    Text(items[i].0)
                }
            }
        }
        .font(TL.Typeface.sans(12, .medium))
        .foregroundStyle(TL.Palette.inkMuted)
    }
}

/// Unit label for a panel header.
struct ChartUnit: View {
    let text: String
    var body: some View { Text(text).font(TL.Typeface.mono(11)).foregroundStyle(TL.Palette.inkMuted) }
}

/// Caption under a chart that states the takeaway.
struct ChartNote: View {
    let text: String
    var body: some View { Text(text).font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted) }
}
