import SwiftUI
import TeslaLinkCore

/// Small route drawing for list rows, from a drive's simplified `routePreview`.
/// Live drives draw in ion with a glowing end; reconstructed drives draw a dashed straight line.
struct RouteThumbnail: View {
    let drive: Drive
    var size = CGSize(width: 52, height: 40)

    var body: some View {
        Canvas { ctx, canvasSize in
            let inset: CGFloat = 6
            let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)
            let pts = projected(in: rect)
            guard pts.count >= 2 else { return }
            var path = Path()
            path.addLines(pts)
            if drive.isInferred && (drive.routePreview?.count ?? 0) < 3 {
                ctx.stroke(path, with: .color(TL.Palette.edgeStrong), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                return
            }
            let color = drive.isOpen ? TL.Palette.ion : TL.Palette.steel
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if drive.isOpen, let end = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 7, y: end.y - 7, width: 14, height: 14)), with: .color(TL.Palette.ion.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(TL.Palette.ion))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(TL.Palette.ground.opacity(0.6))
        .clipShape(ChamferedRectangle(cut: TL.Chamfer.sm))
        .accessibilityHidden(true)
    }

    /// Fits the route into the rect, keeping its aspect ratio (north up).
    private func projected(in rect: CGRect) -> [CGPoint] {
        var route = drive.routePreview ?? []
        if route.count < 2, let a = drive.startLatitude, let b = drive.startLongitude, let c = drive.endLatitude, let d = drive.endLongitude {
            route = [RoutePoint(lat: a, lon: b), RoutePoint(lat: c, lon: d)]
        }
        guard route.count >= 2 else { return [] }
        let midLat = route.map(\.lat).reduce(0, +) / Double(route.count) * .pi / 180
        let xs = route.map { $0.lon * cos(midLat) }, ys = route.map(\.lat)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let w = max(maxX - minX, 1e-6), h = max(maxY - minY, 1e-6)
        let scale = min(rect.width / w, rect.height / h)
        let ox = rect.midX - (w * scale) / 2, oy = rect.midY - (h * scale) / 2
        return zip(xs, ys).map { x, y in CGPoint(x: ox + (x - minX) * scale, y: oy + (maxY - y) * scale) }
    }
}
