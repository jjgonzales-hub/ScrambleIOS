import SwiftUI
import UIKit

/// Standard share sheet pre-populated with the auto-generated trash talk,
/// ready to paste into any group chat.
/// v0.2: iMessage extension so results post directly into the thread.
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
