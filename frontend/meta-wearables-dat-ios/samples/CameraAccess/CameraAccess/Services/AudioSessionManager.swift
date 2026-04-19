import AVFoundation

enum AudioSessionManager {
  static func configure() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Non-fatal — video will still work
    }
  }
}
