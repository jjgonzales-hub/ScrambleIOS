import SwiftUI
import UIKit

/// Scramble palette: bright, friendly golf-course greens with a deep
/// clubhouse green for surfaces, a warm gold for wins, coral for trouble.
enum Palette {
    static let ink = Color(hex: 0x14241A)       // text on light surfaces
    static let deep = Color(hex: 0x0E2419)      // app background
    static let card = Color(hex: 0x17382A)      // raised surfaces
    static let cardHi = Color(hex: 0x1F4A37)
    static let accent = Color(hex: 0x7ED957)    // primary action
    static let gold = Color(hex: 0xFFD27A)
    static let cream = Color(hex: 0xF7F4EA)
    static let fairway = Color(hex: 0x78BE55)
    static let sand = Color(hex: 0xEBD29C)
    static let water = Color(hex: 0x4F9BE0)
    static let danger = Color(hex: 0xF0705E)
}

/// Dark rounded card used across menus and overlays.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(Palette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// Frosted overlay card for things drawn on top of the 3D course.
struct OverlayCard: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: radius))
            .background(Palette.deep.opacity(0.55), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

extension View {
    func card(radius: CGFloat = 22) -> some View { modifier(CardBackground(radius: radius)) }
    func overlayCard(radius: CGFloat = 24) -> some View { modifier(OverlayCard(radius: radius)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Palette.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.heavy))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(color, in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.12),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Geometry helpers

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        hypot(p.x - x, p.y - y)
    }
    static func + (l: CGPoint, r: CGVector) -> CGPoint {
        CGPoint(x: l.x + r.dx, y: l.y + r.dy)
    }
}

extension CGVector {
    init(from: CGPoint, to: CGPoint) {
        self.init(dx: to.x - from.x, dy: to.y - from.y)
    }
    var length: CGFloat { hypot(dx, dy) }
    var normalized: CGVector {
        let l = length
        guard l > 0.0001 else { return CGVector(dx: 0, dy: 1) }
        return CGVector(dx: dx / l, dy: dy / l)
    }
    /// Perpendicular pointing to the right of this vector.
    var perpendicularRight: CGVector { CGVector(dx: dy, dy: -dx) }
    static func * (v: CGVector, s: CGFloat) -> CGVector {
        CGVector(dx: v.dx * s, dy: v.dy * s)
    }
    static func + (l: CGVector, r: CGVector) -> CGVector {
        CGVector(dx: l.dx + r.dx, dy: l.dy + r.dy)
    }
    func dot(_ o: CGVector) -> CGFloat { dx * o.dx + dy * o.dy }
    func rotated(by radians: CGFloat) -> CGVector {
        CGVector(
            dx: dx * cos(radians) - dy * sin(radians),
            dy: dx * sin(radians) + dy * cos(radians)
        )
    }
}
