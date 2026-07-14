import SwiftUI
import SpriteKit

/// Muted, earthy cartoon palette — dark forest greens, olive, cream, tan.
/// Cartoony shapes, understated colors. Nothing neon.
enum Palette {
    static let ink = Color(hex: 0x171B12)       // near-black, green cast
    static let card = Color(hex: 0x232B1C)      // dark olive surface
    static let accent = Color(hex: 0x4CAF50)    // scramble green (style board)
    static let cream = Color(hex: 0xF0EDE0)
    static let fairway = Color(hex: 0x8FB35A)
    static let sand = Color(hex: 0xC7A16B)
    static let water = Color(hex: 0x6E97AC)
    static let danger = Color(hex: 0xFF6B6B)   // coral (style board)
}

enum SceneColors {
    static let ink = SKColor(hex: 0x171B12)
    static let rough = SKColor(hex: 0x4F6B33)
    static let deepRough = SKColor(hex: 0x3A5226)
    static let fairway = SKColor(hex: 0x8FB35A)
    static let fringe = SKColor(hex: 0x9CBE63)
    static let green = SKColor(hex: 0xA9C871)
    static let sand = SKColor(hex: 0xC7A16B)
    static let water = SKColor(hex: 0x6E97AC)
    static let outline = SKColor(hex: 0x2A3A1C)
    static let ball = SKColor(hex: 0xF0EDE0)
    static let accent = SKColor(hex: 0xEDE8D4)  // aim preview / highlights
    static let flagRed = SKColor(hex: 0xB5533C)
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

extension SKColor {
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
