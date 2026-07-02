import AVFoundation

/// Playback for the procedurally generated WAVs in Scramble/Sounds.
/// Ambient category so the game never interrupts the player's music, and
/// the mix respects the silent switch. Volumes are tuned soft — the sound
/// design is understated, like the art.
enum SoundFX {
    private static var players: [String: AVAudioPlayer] = [:]
    private static var configured = false

    static let allSounds = ["hit_driver", "hit_iron", "hit_chip", "hit_putt",
                            "mishit", "whoosh", "cup_drop", "splash",
                            "ui_lock", "pure_chime"]

    static func prepare() {
        guard !configured else { return }
        configured = true
        try? AVAudioSession.sharedInstance()
            .setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for name in allSounds {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[name] = player
            }
        }
    }

    static func play(_ name: String, volume: Float = 1.0) {
        guard let player = players[name] else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    static func play(_ name: String, volume: Float, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            play(name, volume: volume)
        }
    }
}
