/*
 * AudioSessionManager.swift
 *
 * Standalone singleton that manages AVAudioSession configuration for
 * Bluetooth A2DP output (Meta Ray-Ban glasses speaker) and plays back
 * MP3 data received from the /scan endpoint.
 *
 * Design decisions:
 * - NSObject subclass required for AVAudioPlayerDelegate conformance.
 * - Uses CheckedContinuation to bridge delegate callbacks into async/await.
 * - NOT @MainActor — audio session work runs on whatever queue the system
 *   delivers notifications on; only the public `play()` result flows back
 *   to the caller's actor context.
 * - The AVAudioPlayer is stored as a strong property to prevent deallocation
 *   before playback completes (a common bug when using local variables).
 */

import AVFoundation
import os

// MARK: - Error Types

enum AudioError: LocalizedError {
  case playerInitFailed(Error)
  case sessionConfigFailed(Error)
  case playbackInterrupted
  case decodingFailed

  var errorDescription: String? {
    switch self {
    case .playerInitFailed(let error):
      return "Failed to create audio player: \(error.localizedDescription)"
    case .sessionConfigFailed(let error):
      return "Audio session setup failed: \(error.localizedDescription)"
    case .playbackInterrupted:
      return "Audio playback was interrupted."
    case .decodingFailed:
      return "Failed to decode MP3 audio data."
    }
  }
}

// MARK: - Manager

final class AudioSessionManager: NSObject, AVAudioPlayerDelegate, Sendable {
  static let shared = AudioSessionManager()

  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.price-is-right",
    category: "Audio"
  )

  // nonisolated(unsafe) because AVAudioPlayer is not Sendable, but we
  // guarantee serial access through the continuation pattern below.
  nonisolated(unsafe) private var currentPlayer: AVAudioPlayer?
  nonisolated(unsafe) private var playbackContinuation: CheckedContinuation<Void, Error>?

  // MARK: - Init

  override init() {
    super.init()
    configureSession()
    registerForInterruptions()
  }

  // MARK: - Session Configuration

  /// Configures AVAudioSession for Bluetooth A2DP output so audio routes
  /// through the Meta Ray-Ban glasses speaker instead of the iPhone speaker.
  private func configureSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback category ensures audio plays even when the phone is silent.
      // .allowBluetooth enables HFP (hands-free profile) for older devices.
      // .allowBluetoothA2DP enables high-quality stereo Bluetooth output,
      // which is the profile Meta Ray-Ban glasses use for speaker output.
      try session.setCategory(
        .playback,
        mode: .spokenAudio,  // Optimized for speech; ducks other audio appropriately
        options: [.allowBluetooth, .allowBluetoothA2DP]
      )
      try session.setActive(true)
      Self.logger.info("Audio session configured: category=playback, mode=spokenAudio, BT A2DP enabled")
    } catch {
      Self.logger.error("Failed to configure audio session: \(error.localizedDescription)")
    }
  }

  // MARK: - Interruption Handling

  /// Registers for system audio interruptions (phone calls, Siri, etc.)
  /// and resumes playback when the interruption ends if the system indicates
  /// it's safe to do so.
  private func registerForInterruptions() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began:
      // System paused our audio (phone call, Siri, etc.)
      // AVAudioPlayer auto-pauses; we just log it.
      Self.logger.info("Audio interruption began — playback paused by system")

    case .ended:
      // Check if the system says we should resume
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) {
          Self.logger.info("Audio interruption ended with shouldResume — resuming playback")
          // Re-activate the session and resume the player
          do {
            try AVAudioSession.sharedInstance().setActive(true)
            currentPlayer?.play()
          } catch {
            Self.logger.error("Failed to resume after interruption: \(error.localizedDescription)")
            // Signal the continuation that playback was interrupted
            playbackContinuation?.resume(throwing: AudioError.playbackInterrupted)
            playbackContinuation = nil
          }
        } else {
          Self.logger.info("Audio interruption ended — system did not request resume")
        }
      }

    @unknown default:
      Self.logger.warning("Unknown audio interruption type: \(typeValue)")
    }
  }

  // MARK: - Playback

  /// Plays MP3 data through the current audio route (Bluetooth A2DP if
  /// glasses are connected, otherwise iPhone speaker).
  ///
  /// This method is async — it suspends until playback completes or an error
  /// occurs. The AVAudioPlayer is stored as a strong reference on this
  /// singleton, so it won't be deallocated mid-playback.
  ///
  /// - Parameter mp3Data: Raw MP3 bytes (decoded from base64 before calling).
  func play(mp3Data: Data) async throws {
    // Stop any currently playing audio
    stop()

    // Re-activate the session in case it was deactivated
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      throw AudioError.sessionConfigFailed(error)
    }

    // Create the player
    let player: AVAudioPlayer
    do {
      player = try AVAudioPlayer(data: mp3Data)
    } catch {
      throw AudioError.playerInitFailed(error)
    }

    player.delegate = self
    player.prepareToPlay()
    currentPlayer = player

    Self.logger.info("Starting MP3 playback (\(mp3Data.count) bytes, duration: \(player.duration, format: .fixed(precision: 1))s)")

    // Bridge the delegate callback into async/await using CheckedContinuation.
    // The continuation is resumed in audioPlayerDidFinishPlaying or
    // audioPlayerDecodeErrorDidOccur.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.playbackContinuation = continuation
      let started = player.play()
      if !started {
        self.playbackContinuation = nil
        self.currentPlayer = nil
        continuation.resume(throwing: AudioError.playerInitFailed(
          NSError(domain: "AudioSessionManager", code: -1,
                  userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"])
        ))
      }
    }
  }

  /// Stops any in-flight playback immediately.
  func stop() {
    currentPlayer?.stop()
    currentPlayer = nil
    // If there's a pending continuation, cancel it gracefully
    playbackContinuation?.resume(throwing: CancellationError())
    playbackContinuation = nil
  }

  // MARK: - AVAudioPlayerDelegate

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Self.logger.info("Audio playback finished (success: \(flag))")
    currentPlayer = nil
    if flag {
      playbackContinuation?.resume()
    } else {
      playbackContinuation?.resume(throwing: AudioError.playbackInterrupted)
    }
    playbackContinuation = nil
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Self.logger.error("Audio decode error: \(error?.localizedDescription ?? "unknown")")
    currentPlayer = nil
    playbackContinuation?.resume(
      throwing: error.map { AudioError.playerInitFailed($0) } ?? AudioError.decodingFailed
    )
    playbackContinuation = nil
  }
}
