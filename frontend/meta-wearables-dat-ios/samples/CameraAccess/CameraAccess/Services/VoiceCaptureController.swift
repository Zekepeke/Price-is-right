/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Foundation
import Speech

protocol VoiceCaptureControlling: AnyObject {
  func startContinuousPhraseListening(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async
  func stopContinuousPhraseListening()
  func pauseForAppBackground()
  func resumeAfterAppForeground(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async
}

/// Listens for the in-app phrase “Computa, how much is this worth?” and triggers photo capture.
/// Runs only while streaming is active; pauses when the app is backgrounded.
@MainActor
final class VoiceCaptureController: VoiceCaptureControlling {
  /// Normalized phrase without trailing punctuation (ASR rarely emits `?`).
  private static let triggerNormalized = VoiceCaptureController.normalize(
    "Computa, how much is this worth"
  )

  private let audioSessionCoordinator: AudioSessionCoordinating

  private var listenTask: Task<Void, Never>?
  private var isSessionEnabled = false
  private var pausedForBackground = false

  private var shouldListen: (@MainActor () -> Bool)?
  private var onPhraseMatched: (@MainActor () -> Void)?

  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine: AVAudioEngine?
  private var recognitionCycleContinuation: CheckedContinuation<Void, Never>?
  private var cycleWatchdogTask: Task<Void, Never>?

  private var lastPhraseFire: Date = .distantPast
  private let phraseDebounce: TimeInterval = 2.0
  private let maxCycleDuration: UInt64 = 55_000_000_000

  init(audioSessionCoordinator: AudioSessionCoordinating) {
    self.audioSessionCoordinator = audioSessionCoordinator
  }

  #if DEBUG
  private func dbg(_ msg: String) {
    NSLog("[VoiceCapture] \(msg)")
  }
  #endif

  func startContinuousPhraseListening(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async {
    stopContinuousPhraseListening()
    pausedForBackground = false
    self.shouldListen = shouldListen
    self.onPhraseMatched = onPhraseMatched

    // Mic + speech recognition permission requested lazily here (not at app launch /
    // stream start) so neither prompt stalls the first-frame path. If the user denies
    // either, we silently stand down — streaming still works via the capture button.
    let micGranted = await MicrophonePermission.requestIfNeeded()
    #if DEBUG
    dbg("mic permission \(micGranted ? "granted" : "denied")")
    #endif
    guard micGranted else {
      self.shouldListen = nil
      self.onPhraseMatched = nil
      return
    }
    let auth = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    #if DEBUG
    dbg("Speech auth=\(auth.rawValue)")
    #endif
    guard auth == .authorized else {
      self.shouldListen = nil
      self.onPhraseMatched = nil
      return
    }
    do {
      try await audioSessionCoordinator.prepareForSpeechRecording()
    } catch {
      #if DEBUG
      dbg("initial prepareForSpeechRecording failed: \(error.localizedDescription)")
      #endif
    }

    isSessionEnabled = true
    listenTask = Task { @MainActor [weak self] in
      await self?.listenLoop()
    }
  }

  func stopContinuousPhraseListening() {
    // Only log when we were actually listening. Callers (stream state changes,
    // scene background) invoke this speculatively on every transition and would
    // otherwise bury real events under repeated no-op log lines.
    let wasActive = isSessionEnabled || listenTask != nil
    #if DEBUG
    if wasActive {
      dbg("stopContinuousPhraseListening()")
    }
    #endif
    isSessionEnabled = false
    pausedForBackground = false
    listenTask?.cancel()
    listenTask = nil
    shouldListen = nil
    onPhraseMatched = nil
    teardownRecognition()
  }

  func pauseForAppBackground() {
    #if DEBUG
    dbg("pauseForAppBackground()")
    #endif
    pausedForBackground = true
    teardownRecognition()
  }

  func resumeAfterAppForeground(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async {
    guard isSessionEnabled else { return }
    #if DEBUG
    dbg("resumeAfterAppForeground()")
    #endif
    pausedForBackground = false
    self.shouldListen = shouldListen
    self.onPhraseMatched = onPhraseMatched
    do {
      try await audioSessionCoordinator.prepareForSpeechRecording()
    } catch {
      #if DEBUG
      dbg("foreground prepareForSpeechRecording failed: \(error.localizedDescription)")
      #endif
    }
    listenTask?.cancel()
    listenTask = Task { @MainActor [weak self] in
      await self?.listenLoop()
    }
  }

  private func listenLoop() async {
    #if DEBUG
    dbg("listenLoop start")
    #endif
    while !Task.isCancelled, isSessionEnabled, !pausedForBackground {
      guard let shouldListen, let onPhraseMatched else { break }

      if !shouldListen() {
        teardownRecognition()
        try? await Task.sleep(nanoseconds: 200_000_000)
        continue
      }

      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        recognitionCycleContinuation = continuation
        let watchdogNanos = maxCycleDuration
        cycleWatchdogTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: watchdogNanos)
          await MainActor.run {
            self?.teardownRecognition()
          }
        }

        Task { @MainActor [weak self] in
          guard let self else { return }
          let started = self.startEngineAndRecognition(
            shouldListen: shouldListen,
            onPhraseMatched: onPhraseMatched
          )
          if !started {
            self.finishRecognitionCycle()
          }
        }
      }

      recognitionCycleContinuation = nil
      teardownRecognition()
      try? await Task.sleep(nanoseconds: 150_000_000)
    }
    teardownRecognition()
    #if DEBUG
    dbg("listenLoop end")
    #endif
  }

  private func finishRecognitionCycle() {
    cycleWatchdogTask?.cancel()
    cycleWatchdogTask = nil
    recognitionCycleContinuation?.resume()
    recognitionCycleContinuation = nil
  }

  private func startEngineAndRecognition(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) -> Bool {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
      recognizer.isAvailable
    else {
      #if DEBUG
      NSLog("[VoiceCapture] SFSpeechRecognizer unavailable for en_US")
      #endif
      return false
    }

    recognitionTask?.cancel()
    recognitionTask = nil
    if let engine = audioEngine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
    }
    audioEngine = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true

    let engine = AVAudioEngine()
    audioEngine = engine
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)

    guard format.sampleRate > 0 else {
      #if DEBUG
      NSLog("[VoiceCapture] input format invalid (sampleRate=0); session may not be ready")
      #endif
      return false
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }

    do {
      try engine.start()
    } catch {
      #if DEBUG
      NSLog("[VoiceCapture] AVAudioEngine.start failed: \(error.localizedDescription)")
      #endif
      return false
    }

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self else { return }

        if !shouldListen() {
          self.teardownRecognition()
          return
        }

        if let result {
          let text = result.bestTranscription.formattedString
          if self.transcriptContainsPhrase(text), shouldListen() {
            self.firePhraseIfAllowed(onPhraseMatched: onPhraseMatched)
          }
        }

        if let error {
          #if DEBUG
          NSLog("[VoiceCapture] recognition error: \(error.localizedDescription)")
          #endif
          self.teardownRecognition()
        }
      }
    }

    return true
  }

  private func firePhraseIfAllowed(onPhraseMatched: @escaping @MainActor () -> Void) {
    let now = Date()
    guard now.timeIntervalSince(lastPhraseFire) >= phraseDebounce else { return }
    lastPhraseFire = now
    #if DEBUG
    dbg("phrase matched; firing")
    #endif
    // Trigger capture first; tear down Speech on the next main run-loop turn so we do not
    // resume the listen-loop continuation while still inside the recognition callback.
    onPhraseMatched()
    DispatchQueue.main.async { [weak self] in
      self?.teardownRecognition()
    }
  }

  private func teardownRecognition() {
    #if DEBUG
    if recognitionTask != nil || audioEngine != nil {
      dbg("teardownRecognition()")
    }
    #endif
    recognitionTask?.cancel()
    recognitionTask = nil
    if let engine = audioEngine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
    }
    audioEngine = nil
    finishRecognitionCycle()
  }

  private func transcriptContainsPhrase(_ text: String) -> Bool {
    let n = Self.normalize(text)
    if n.contains(Self.triggerNormalized) { return true }
    // Comma / final punctuation often omitted by ASR.
    let commaRelaxed = n.replacingOccurrences(of: ",", with: " ")
    if commaRelaxed.contains("computa how much is this worth") { return true }
    if commaRelaxed.contains("computa how much is it worth") { return true }
    if commaRelaxed.contains("computer how much is this worth") { return true }
    if commaRelaxed.contains("computer how much is it worth") { return true }

    // Noisy Bluetooth HFP: require wake word, then “how much” … “worth”.
    guard let wakeEnd = Self.rangeAfterWakeWord(in: n) else { return false }
    let tail = n[wakeEnd...]
    guard let rangeHowMuch = tail.range(of: "how much") else { return false }
    return tail[rangeHowMuch.lowerBound...].contains("worth")
  }

  /// Returns the index after the earliest wake token (Computa / Computer / common ASR variants).
  private static func rangeAfterWakeWord(in n: String) -> String.Index? {
    let wakeWords = ["computa", "computer", "compta"]
    var best: Range<String.Index>?
    for w in wakeWords {
      if let r = n.range(of: w) {
        if best == nil || r.lowerBound < best!.lowerBound {
          best = r
        }
      }
    }
    return best?.upperBound
  }

  private static func normalize(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
  }
}
