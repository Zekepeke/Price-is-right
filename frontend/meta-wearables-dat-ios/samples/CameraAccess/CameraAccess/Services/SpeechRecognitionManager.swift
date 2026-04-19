import AVFoundation
import Speech

final class SpeechRecognitionManager: ObservableObject {

  @Published private(set) var isListening = false

  var onTriggerDetected: (() -> Void)?

  /// Everything the user said before the trigger phrase fired, within the current session window.
  private(set) var lastContext: String?

  private let corePatterns = [
    "how much is this worth",
    "how much is it worth",
    "how much does this cost",
    "computa how much",
    "computer how much",
  ]

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var tapInstalled = false
  private var isActive = false
  private var isPaused = false
  private var lastTriggerDate: Date = .distantPast
  private var lastRawResultDate: Date = .distantPast
  private var watchdogWorkItem: DispatchWorkItem?
  private var sessionRestartWorkItem: DispatchWorkItem?
  private var isRestarting = false
  private var currentSessionID = 0

  func startListening() {
    guard !isActive else { return }
    isActive = true
    isPaused = false
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else {
        print("[PIR] SpeechRecognitionManager: authorization denied — \(status.rawValue)")
        return
      }
      self?.beginSession()
    }
  }

  func stopListening() {
    isActive = false
    isPaused = false
    cancelWatchdog()
    cancelSessionRestart()
    endFullSession()
    DispatchQueue.main.async { self.isListening = false }
  }

  func pauseListening() {
    guard isActive, !isPaused else { return }
    isPaused = true
    cancelWatchdog()
    cancelSessionRestart()
    endFullSession()
    DispatchQueue.main.async { self.isListening = false }
    print("[PIR] Speech: PAUSED")
  }

  func resumeListening() {
    guard isActive, isPaused else { return }
    isPaused = false
    beginSession()
    print("[PIR] Speech: RESUMED")
  }

  // MARK: - Private

  private func beginSession() {
    guard !isRestarting else {
      print("[PIR] Speech: beginSession() skipped — restart already in progress")
      return
    }
    guard isActive, !isPaused, let recognizer, recognizer.isAvailable else { return }
    isRestarting = true
    cancelSessionRestart()

    // Increment session ID so any callbacks from the previous task become no-ops.
    // This prevents the cascade where cancelling the old task triggers its error
    // callback, which would otherwise queue yet another beginSession() call.
    currentSessionID += 1
    let sessionID = currentSessionID

    // Cancel only the recognition task/request — do NOT touch the audio engine or tap.
    // Stopping and reinstalling the tap causes a "format mismatch" crash on restart
    // because iOS reports a different sample rate after the engine is stopped.
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, self.currentSessionID == sessionID else { return }
      if let result {
        let transcript = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        self.lastRawResultDate = Date()
        print("[PIR] Speech: raw result — \"\(transcript)\" isFinal=\(isFinal)")
        self.checkTranscript(transcript)
      }
      // iOS terminates sessions after ~1 minute — restart automatically
      if error != nil || result?.isFinal == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          guard let self, self.currentSessionID == sessionID else { return }
          guard self.isActive, !self.isPaused else { return }
          self.beginSession()
        }
      }
    }

    // Start the audio engine only on the first call (or after a full stop/pause).
    // Reusing the running engine avoids reinstalling the tap and the format mismatch.
    if !audioEngine.isRunning {
      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      if !tapInstalled {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
          self?.recognitionRequest?.append(buffer)
        }
        tapInstalled = true
      }
      audioEngine.prepare()
      do {
        try audioEngine.start()
        DispatchQueue.main.async { self.isListening = true }
      } catch {
        print("[PIR] SpeechRecognitionManager: audio engine failed to start — \(error)")
        isRestarting = false
        endFullSession()
        return
      }
    }

    isRestarting = false
    print("[PIR] SpeechRecognitionManager: listening for trigger phrase (session \(sessionID))")
    scheduleWatchdog()
    scheduleSessionRestart()
  }

  private func checkTranscript(_ transcript: String) {
    let lower = transcript.lowercased()
    guard let matchedPattern = corePatterns.first(where: { lower.contains($0) }) else {
      print("[PIR] SpeechRecognitionManager: heard — \"\(transcript)\" | triggered: false")
      return
    }

    print("[PIR] SpeechRecognitionManager: heard — \"\(transcript)\" | triggered: true")

    // Cooldown — prevents firing multiple times on the same utterance
    let now = Date()
    guard now.timeIntervalSince(lastTriggerDate) > 10 else { return }
    lastTriggerDate = now

    // Capture everything said before the trigger phrase as context
    if let range = lower.range(of: matchedPattern) {
      let before = String(lower[lower.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
      lastContext = before.isEmpty ? nil : before
    } else {
      lastContext = nil
    }
    print("[PIR] SpeechRecognitionManager: lastContext = \(lastContext ?? "<none>")")

    DispatchQueue.main.async { [weak self] in
      self?.onTriggerDetected?()
    }
  }

  private func scheduleWatchdog() {
    cancelWatchdog()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isActive, !self.isPaused else { return }
      if Date().timeIntervalSince(self.lastRawResultDate) > 30 {
        print("[PIR] Speech: watchdog — no transcript in 30s, restarting session")
        self.beginSession()
      } else {
        self.scheduleWatchdog()
      }
    }
    watchdogWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
  }

  private func cancelWatchdog() {
    watchdogWorkItem?.cancel()
    watchdogWorkItem = nil
  }

  private func scheduleSessionRestart() {
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isActive, !self.isPaused else { return }
      print("[PIR] Speech: 12s restart — clearing transcript buffer")
      self.beginSession()
    }
    sessionRestartWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
  }

  private func cancelSessionRestart() {
    sessionRestartWorkItem?.cancel()
    sessionRestartWorkItem = nil
  }

  // Full teardown — stops the audio engine and removes the tap.
  // Only called from pauseListening() / stopListening().
  private func endFullSession() {
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
  }
}
