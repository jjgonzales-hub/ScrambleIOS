import UIKit

/// Haptics are the soul of the swing meter. Light tap when power locks,
/// heavy snap when accuracy locks, rumble on mishits, success on pure shots.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()

    static func prepare() {
        light.prepare()
        heavy.prepare()
    }

    static func powerLock() { light.impactOccurred() }

    static func accuracyLock() { heavy.impactOccurred() }

    static func tick() { rigid.impactOccurred(intensity: 0.5) }

    static func pure() { notify.notificationOccurred(.success) }

    /// The mishit rumble — three descending thuds.
    static func rumble() {
        notify.notificationOccurred(.error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            heavy.impactOccurred(intensity: 0.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            heavy.impactOccurred(intensity: 0.5)
        }
    }

    static func celebration() {
        notify.notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            light.impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            heavy.impactOccurred()
        }
    }
}
