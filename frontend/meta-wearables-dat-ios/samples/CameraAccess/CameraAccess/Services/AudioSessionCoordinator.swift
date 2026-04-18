/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Foundation

protocol AudioSessionCoordinating: AnyObject {
  /// Configure + activate the session for HFP microphone capture (wake-word listening).
  /// Waits briefly for an HFP input to appear when a Bluetooth accessory is connected.
  func prepareForSpeechRecording() async throws
  /// Configure + activate the session for speech playback through BT output.
  /// Does NOT wait for an HFP input; output-only callers don't need the mic route.
  func prepareForSpeechPlayback() async throws
  /// Tear down after we're done with recording/playback so the session releases the BT HFP
  /// profile back to A2DP.
  func tearDownAfterStreamSession() async throws
}

/// Lazily configures `AVAudioSession` for Bluetooth voice (HFP) capture and speech playback
/// through the glasses, and installs a process-wide interruption observer.
///
/// Important: we *do not* configure the session at app launch. Doing so forces iOS to
/// renegotiate the Ray-Ban glasses' BT profile from A2DP to HFP while DAT is still bringing
/// up its BLE data channel, which reliably fails `stream.start()` with
/// `ActivityManagerError 11`. Instead we activate lazily right before the first time we
/// need to record or speak.
@MainActor
final class AudioSessionCoordinator: AudioSessionCoordinating {
  /// `AVAudioSession` category options used whenever we activate for speech i/o.
  ///
  /// - `.allowBluetooth` routes through the Ray-Ban glasses over HFP (needed for wake-word
  ///   capture from the BT mic).
  /// - `.allowBluetoothA2DP` lets iOS still pick A2DP output when only that profile is live.
  /// - `.mixWithOthers` avoids stomping on MWDAT's own audio-session usage.
  /// - `.defaultToSpeaker` is a fallback when no BT route is available.
  static let sessionOptions: AVAudioSession.CategoryOptions = [
    .allowBluetooth,
    .allowBluetoothA2DP,
    .mixWithOthers,
    .defaultToSpeaker,
  ]

  // Set exactly once from `installInterruptionHandlingAtAppLaunch()` during
  // `CameraAccessApp.init()` on the main thread; NotificationCenter delivery is serialized
  // on the registered queue thereafter.
  nonisolated(unsafe) private static var interruptionObserver: NSObjectProtocol?

  private let hfpWaitTimeout: TimeInterval
  private let hfpPollInterval: UInt64

  /// Tracks whether our playAndRecord config is currently active. Used to serialize
  /// repeated `prepareForSpeech*` calls so we don't flap the session or redundantly wait
  /// for HFP when nothing has changed.
  private var isSessionConfigured = false

  #if DEBUG
  private let routeChangeObserver: NSObjectProtocol?
  #endif

  init(hfpWaitTimeout: TimeInterval = 2.0, hfpPollIntervalNanoseconds: UInt64 = 100_000_000) {
    self.hfpWaitTimeout = hfpWaitTimeout
    self.hfpPollInterval = hfpPollIntervalNanoseconds
    #if DEBUG
    routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { _ in
      Self.dbgSnapshot(prefix: "routeChange")
    }
    #endif
  }

  deinit {
    #if DEBUG
    if let routeChangeObserver {
      NotificationCenter.default.removeObserver(routeChangeObserver)
    }
    #endif
  }

  func prepareForSpeechRecording() async throws {
    #if DEBUG
    Self.dbgSnapshot(prefix: "prepareRecording(begin)")
    #endif
    try configureSessionIfNeeded()
    await waitForBluetoothHFPIfNeeded(session: AVAudioSession.sharedInstance())
    #if DEBUG
    Self.dbgSnapshot(prefix: "prepareRecording(end)")
    #endif
  }

  func prepareForSpeechPlayback() async throws {
    #if DEBUG
    Self.dbgSnapshot(prefix: "preparePlayback(begin)")
    #endif
    try configureSessionIfNeeded()
    #if DEBUG
    Self.dbgSnapshot(prefix: "preparePlayback(end)")
    #endif
  }

  private func configureSessionIfNeeded() throws {
    let session = AVAudioSession.sharedInstance()
    // Short-circuit when our category/mode is already live AND we believe the session is
    // active. Re-applying flaps the BT route (HFP<->A2DP) for no reason.
    if
      isSessionConfigured,
      session.category == .playAndRecord,
      session.mode == .default,
      session.categoryOptions == Self.sessionOptions
    {
      #if DEBUG
      NSLog("[AudioSession] configure(skip: already-configured)")
      #endif
      return
    }
    #if DEBUG
    NSLog("[AudioSession] configure(apply) playAndRecord+default")
    #endif
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: Self.sessionOptions
    )
    try session.setActive(true, options: [])
    isSessionConfigured = true
  }

  /// Install the process-lifetime interruption observer. Call once from
  /// `CameraAccessApp.init()`. This does NOT configure `AVAudioSession` (deliberately —
  /// see class-level comment).
  nonisolated static func installInterruptionHandlingAtAppLaunch() {
    installInterruptionHandlingIfNeeded()
    #if DEBUG
    // Tell the reader, plainly, that we are *not* touching the audio session at
    // launch. The absence of the old "activateAtAppLaunch" + routeChange-to-HFP
    // pair is the regression test for the startup fix.
    NSLog("[AudioSession] launch: interruption handler installed; audio session NOT configured")
    Self.dbgSnapshot(prefix: "launch(post)")
    #endif
  }

  nonisolated private static func reapplySessionConfigOnInterruption(logTag: String) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: sessionOptions
      )
      try session.setActive(true, options: [])
      #if DEBUG
      NSLog("[AudioSession] \(logTag) ok")
      #endif
    } catch {
      #if DEBUG
      NSLog("[AudioSession] \(logTag) failed: \(error.localizedDescription)")
      #endif
    }
  }

  /// Installs a single process-lifetime observer that re-applies our category and calls
  /// `setActive(true)` after an interruption ends. Without this the first interruption
  /// (MWDAT stream start, phone call, Siri, AVAudioEngine restart inside VoiceCapture)
  /// silently deactivates the session and all subsequent `AVSpeechSynthesizer.speak` calls
  /// produce no audio.
  ///
  /// The observer only fires AFTER an interruption we actually experienced, so at cold
  /// launch (before anything has configured audio) it's a no-op.
  nonisolated private static func installInterruptionHandlingIfNeeded() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { note in
      guard
        let info = note.userInfo,
        let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: rawType)
      else { return }

      switch type {
      case .began:
        #if DEBUG
        NSLog("[AudioSession] interruption began")
        #endif
      case .ended:
        let shouldResume: Bool
        if let raw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
          shouldResume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
        } else {
          shouldResume = true
        }
        guard shouldResume else { return }
        reapplySessionConfigOnInterruption(logTag: "interruption(ended)")
      @unknown default:
        break
      }
    }
  }

  func tearDownAfterStreamSession() async throws {
    guard isSessionConfigured else { return }
    #if DEBUG
    Self.dbgSnapshot(prefix: "teardown(begin)")
    #endif
    let session = AVAudioSession.sharedInstance()
    try session.setActive(false, options: [.notifyOthersOnDeactivation])
    isSessionConfigured = false
    #if DEBUG
    Self.dbgSnapshot(prefix: "teardown(end)")
    #endif
  }

  private func waitForBluetoothHFPIfNeeded(session: AVAudioSession) async {
    let outputs = session.currentRoute.outputs
    let hasBluetoothAccessory = outputs.contains { port in
      port.portType == .bluetoothHFP
        || port.portType == .bluetoothA2DP
        || port.portType == .bluetoothLE
    }
    guard hasBluetoothAccessory else { return }

    if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
      return
    }

    #if DEBUG
    Self.dbgSnapshot(prefix: "waitHFP(begin)")
    #endif
    let deadline = Date().addingTimeInterval(hfpWaitTimeout)
    while Date() < deadline {
      if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
        #if DEBUG
        Self.dbgSnapshot(prefix: "waitHFP(success)")
        #endif
        return
      }
      try? await Task.sleep(nanoseconds: hfpPollInterval)
    }
    #if DEBUG
    Self.dbgSnapshot(prefix: "waitHFP(timeout)")
    #endif
  }

  #if DEBUG
  nonisolated private static func dbgSnapshot(prefix: String) {
    let s = AVAudioSession.sharedInstance()
    let cat = s.category.rawValue
    let mode = s.mode.rawValue
    let inputs = s.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
    let outputs = s.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
    NSLog("[AudioSession] \(prefix) cat=\(cat) mode=\(mode) inputs=[\(inputs)] outputs=[\(outputs)]")
  }
  #endif
}
