import SwiftUI
import UIKit

/// TeslaLink design tokens. Mirrors the "TeslaLink" design system (tokens.json):
/// stainless steel surfaces, cut corners, and light used only where something is live.
enum TL {
    // MARK: Color (Night / Daylight)

    enum Palette {
        static let ground = dyn(0x0A0C0E, 0xE6E9EC)
        static let surface1 = dyn(0x121518, 0xF4F6F7)
        static let surface2 = dyn(0x1A1E22, 0xFFFFFF)
        static let steel = dyn(0xAEB6BD, 0x8A939B)
        static let steelDeep = dyn(0x3A4148, 0x5B646C)
        static let edge = dyn(0x262C31, 0xC9CFD4)
        static let edgeStrong = dyn(0x66707A, 0x7F8890)
        static let ink = dyn(0xEEF1F3, 0x0D1114)
        static let inkMuted = dyn(0x8D97A0, 0x4C555D)
        static let lightbar = dyn(0xE9F8FF, 0x4CC9FF)
        static let ion = dyn(0x4CC9FF, 0x006B9C)
        static let onIon = dyn(0x04121A, 0xFFFFFF)
        static let charge = dyn(0x5CF2A6, 0x065F35)
        static let taillight = dyn(0xFF5A3C, 0xB8280F)
        static let amber = dyn(0xFFB020, 0x7D5200)
        static let sleep = dyn(0x9AA6FF, 0x3E4CC4)

        private static func dyn(_ night: UInt32, _ day: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: day) : UIColor(hex: night) })
        }
    }

    // MARK: Type

    enum Typeface {
        static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
            .custom(weight == .medium ? "ChakraPetch-Medium" : "ChakraPetch-SemiBold", size: size)
        }
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let name = switch weight {
            case .semibold, .bold, .heavy, .black: "Barlow-SemiBold"
            case .medium: "Barlow-Medium"
            default: "Barlow-Regular"
            }
            return .custom(name, size: size)
        }
        static func mono(_ size: CGFloat) -> Font { .custom("IBMPlexMono-Medium", size: size) }

        static let readoutXL = display(64)
        static let display = display(34)
        static let title = display(22)
        static let readout = display(28, .medium)
        static let body = sans(16)
        static let bodyStrong = sans(16, .semibold)
        static let caption = sans(13, .medium)
        static let label = sans(11, .semibold)
        static let data = mono(15)
        static let dataSmall = mono(12)
    }

    // MARK: Space & shape

    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48
    }

    enum Chamfer {
        static let sm: CGFloat = 6, md: CGFloat = 12, lg: CGFloat = 20
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A rectangle with its top-left and bottom-right corners cut. TeslaLink has no rounded rectangles.
struct ChamferedRectangle: InsettableShape {
    var cut: CGFloat = TL.Chamfer.md
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(cut - inset * 0.4, min(r.width, r.height) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> ChamferedRectangle {
        var s = self
        s.inset += amount
        return s
    }
}

/// The 1px light line along a panel's top edge, with its glow.
struct LightbarLine: View {
    var color: Color = TL.Palette.lightbar

    var body: some View {
        LinearGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.18),
                               .init(color: color, location: 0.82), .init(color: color.opacity(0), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .shadow(color: color.opacity(0.6), radius: 6)
            .shadow(color: color.opacity(0.9), radius: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Chamfered surface with a 1px border.
    func tlSurface(_ fill: Color = TL.Palette.surface1, border: Color = TL.Palette.edge, cut: CGFloat = TL.Chamfer.md) -> some View {
        background(ChamferedRectangle(cut: cut).fill(fill))
            .overlay(ChamferedRectangle(cut: cut).strokeBorder(border, lineWidth: 1))
            .clipShape(ChamferedRectangle(cut: cut))
    }

    /// Ion focus/selection glow.
    func tlGlow(_ color: Color = TL.Palette.ion, radius: CGFloat = 10) -> some View {
        shadow(color: color.opacity(0.45), radius: radius)
    }

    /// Uppercase label style.
    func tlLabel() -> some View {
        font(TL.Typeface.label).tracking(1.5).textCase(.uppercase).foregroundStyle(TL.Palette.inkMuted)
    }
}
