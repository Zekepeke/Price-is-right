import AVFoundation

enum AudioSessionManager {
  static func configure() {
    do {
      // .playAndRecord allows simultaneous mic input (speech recognition) and
      // speaker output (video audio). .defaultToSpeaker keeps audio on the
      // speaker rather than the earpiece.
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Non-fatal — video will still work
    }
  }
}
