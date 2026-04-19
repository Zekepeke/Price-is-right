import AVFoundation
import Speech

final class SpeechRecognitionManager: ObservableObject {

  @Published private(set) var isListening = false

  var onTriggerDetected: (() -> Void)?

  private let triggerPhrase = "computa how much is this worth"
  private let triggerAlternates = [
    "computer how much is this worth",
    "compute how much is this worth",
    "computa how much is it worth",
    "computer how much is it worth",
  ]

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var tapInstalled = false
  private var isActive = false
  private var lastTriggerDate: Date = .distantPast

  func startListening() {
    guard !isActive else { return }
    isActive = true
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
    endSession()
    DispatchQueue.main.async { self.isListening = false }
  }

  // MARK: - Private

  private func beginSession() {
    guard isActive, let recognizer, recognizer.isAvailable else { return }
    endSession()

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let transcript = result?.bestTranscription.formattedString {
        self.checkTranscript(transcript)
      }
      // iOS terminates sessions after ~1 minute — restart automatically
      if error != nil || result?.isFinal == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          guard self?.isActive == true else { return }
          self?.beginSession()
        }
      }
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }
    tapInstalled = true

    audioEngine.prepare()
    do {
      try audioEngine.start()
      DispatchQueue.main.async { self.isListening = true }
      print("[PIR] SpeechRecognitionManager: listening for trigger phrase")
    } catch {
      print("[PIR] SpeechRecognitionManager: audio engine failed to start — \(error)")
      endSession()
    }
  }

  private func checkTranscript(_ transcript: String) {
    let lower = transcript.lowercased()
    let matched = lower.contains(triggerPhrase) ||
      triggerAlternates.contains(where: { lower.contains($0) })
    guard matched else { return }

    // Cooldown — prevents firing multiple times on the same utterance
    let now = Date()
    guard now.timeIntervalSince(lastTriggerDate) > 5 else { return }
    lastTriggerDate = now

    print("[PIR] SpeechRecognitionManager: trigger detected — \"\(transcript)\"")
    DispatchQueue.main.async { [weak self] in
      self?.onTriggerDetected?()
    }
  }

  private func endSession() {
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
  }
}
