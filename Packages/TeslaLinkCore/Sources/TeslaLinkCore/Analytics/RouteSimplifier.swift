import Foundation

/// Douglas–Peucker simplification for small route previews (list thumbnails, widgets).
public enum RouteSimplifier {
    /// Simplifies to at most `maxPoints`, keeping the shape. Tolerance grows until it fits.
    public static func preview(_ points: [RoutePoint], maxPoints: Int = 32) -> [RoutePoint]? {
        guard points.count >= 2 else { return nil }
        guard points.count > maxPoints else { return points }
        // Work in a local equirectangular projection (metres) so tolerance is in metres.
        let lat0 = points.map(\.lat).reduce(0, +) / Double(points.count) * .pi / 180
        let xy = points.map { (x: $0.lon * cos(lat0) * 111_320, y: $0.lat * 110_540) }
        var tolerance = 5.0
        var keep = simplify(xy, tolerance: tolerance)
        while keep.count > maxPoints {
            tolerance *= 1.6
            keep = simplify(xy, tolerance: tolerance)
        }
        return keep.map { points[$0] }
    }

    /// Returns the indices kept, in order.
    static func simplify(_ p: [(x: Double, y: Double)], tolerance: Double) -> [Int] {
        guard p.count > 2 else { return Array(p.indices) }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true
        keep[p.count - 1] = true
        var stack = [(0, p.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var maxD = 0.0, index = a
            for i in (a + 1)..<b {
                let d = distance(p[i], p[a], p[b])
                if d > maxD { maxD = d; index = i }
            }
            if maxD > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    static func distance(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
