/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@MainActor
final class StreamSessionViewModel: ObservableObject {
  #if DEBUG
  private func dbg(_ msg: String) {
    NSLog("[StreamSessionVM] \(msg)")
  }
  #endif

  // MARK: - Published State

  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showPhotoCaptureError: Bool = false
  @Published var isCapturingPhoto: Bool = false

  @Published var scanResult: ScanResult?
  @Published var isScanning: Bool = false
  @Published var scanError: String?

  @Published var hasActiveDevice: Bool = false
  @Published var isDeviceSessionReady: Bool = false

  @Published private(set) var isStartingStream: Bool = false

  private var lastPhotoData: Data?
  private let pricingService: PricingService

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private let audioCoordinator: AudioSessionCoordinating
  private let voiceCapture: VoiceCaptureControlling
  private var streamSession: StreamSession?
  private var cancellables = Set<AnyCancellable>()
  private var didStartVoiceForCurrentStream = false
  private let resultSpeechSynthesizer = AVSpeechSynthesizer()
  private var currentStartAttemptId: Int = 0

  #if DEBUG
  /// Set when `handleStartStreaming` begins; cleared when we see the first frame.
  /// Lets us log user-visible "tap-to-first-frame" latency to verify the startup fix.
  private var startAttemptBeganAt: Date?
  #endif

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    pricingService: PricingService = .shared,
    audioCoordinator: AudioSessionCoordinating? = nil,
    voiceCapture: VoiceCaptureControlling? = nil
  ) {
    let coordinator = audioCoordinator ?? AudioSessionCoordinator()
    self.wearables = wearables
    self.pricingService = pricingService
    self.audioCoordinator = coordinator
    self.voiceCapture = voiceCapture ?? VoiceCaptureController(audioSessionCoordinator: coordinator)
    self.sessionManager = DeviceSessionManager(wearables: wearables)

    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$hasActiveDevice)
    sessionManager.$isReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$isDeviceSessionReady)
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    guard !isStartingStream else {
      #if DEBUG
      dbg("handleStartStreaming ignored (already starting)")
      #endif
      return
    }
    isStartingStream = true
    defer { isStartingStream = false }
    currentStartAttemptId += 1
    let attemptId = currentStartAttemptId

    let permission = Permission.camera
    do {
      #if DEBUG
      startAttemptBeganAt = Date()
      dbg("attempt=\(attemptId) handleStartStreaming begin (hasActiveDevice=\(hasActiveDevice) isReady=\(isDeviceSessionReady))")
      #endif
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      // Mic + speech-recognition permissions are deliberately NOT requested here —
      // they're handled lazily by VoiceCaptureController the first time we actually
      // start listening (after streaming is up), so neither prompt delays the
      // first-frame path.
      await startSession(attemptId: attemptId)
    } catch {
      #if DEBUG
      dbg("attempt=\(attemptId) handleStartStreaming error: \(String(describing: error))")
      #endif
      showError("Permission error: \(error.description)")
    }
  }

  func stopSession() async {
    resultSpeechSynthesizer.stopSpeaking(at: .immediate)
    didStartVoiceForCurrentStream = false
    voiceCapture.stopContinuousPhraseListening()
    guard let stream = streamSession else {
      try? await audioCoordinator.tearDownAfterStreamSession()
      return
    }
    streamSession = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    await stream.stop()
    try? await audioCoordinator.tearDownAfterStreamSession()
  }

  func handleScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .background:
      voiceCapture.pauseForAppBackground()
    case .active:
      guard streamingStatus == .streaming else { return }
      Task { [weak self] in
        guard let self else { return }
        await self.voiceCapture.resumeAfterAppForeground(
          shouldListen: { [weak self] in self?.shouldRunVoiceCapture ?? false },
          onPhraseMatched: { [weak self] in
            self?.capturePhoto()
          }
        )
      }
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = streamSession?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    resultSpeechSynthesizer.stopSpeaking(at: .immediate)
    showPhotoPreview = false
    capturedPhoto = nil
    scanResult = nil
    scanError = nil
    lastPhotoData = nil
  }

  func retryScan() {
    guard let jpegData = lastPhotoData else { return }
    runScan(jpegData: jpegData)
  }

  private func runScan(jpegData: Data) {
    scanError = nil
    isScanning = true
    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.pricingService.scan(jpegData: jpegData)
        await MainActor.run {
          self.scanResult = result
          self.isScanning = false
          self.speakPriceResult(for: result)
        }
      } catch {
        await MainActor.run {
          let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
          self.scanError = message
          self.isScanning = false
        }
      }
    }
  }

  private func priceSpeechText(for result: ScanResult) -> String {
    let title = displayTitle(for: result.item)
    let median = formatCurrency(result.pricing.median)
    let low = formatCurrency(result.pricing.low)
    let high = formatCurrency(result.pricing.high)
    return "\(title). Median \(median). Range \(low) to \(high). Verdict: \(result.verdict)."
  }

  private func speakPriceResult(for result: ScanResult) {
    let text = priceSpeechText(for: result)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    resultSpeechSynthesizer.stopSpeaking(at: .immediate)
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.audioCoordinator.prepareForSpeechPlayback()
      } catch {
        #if DEBUG
        self.dbg("prepareForSpeechPlayback failed before result speech: \(error.localizedDescription)")
        #endif
      }
      await MainActor.run {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        utterance.volume = 1.0
        self.resultSpeechSynthesizer.speak(utterance)
      }
    }
  }

  private func displayTitle(for item: Item) -> String {
    if let brand = item.brand, !brand.isEmpty, brand.lowercased() != "null" {
      return "\(brand) \(item.category)"
    }
    return item.category
  }

  private func formatCurrency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
  }

  // MARK: - Private

  private func startSession(attemptId: Int) async {
    guard let deviceSession = await sessionManager.getSession() else { return }
    guard deviceSession.state == .started else { return }

    #if DEBUG
    dbg("attempt=\(attemptId) startSession deviceSession.state=\(deviceSession.state)")
    #endif

    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    let stream: StreamSession
    do {
      guard let created = try deviceSession.addStream(config: config) else {
        #if DEBUG
        dbg("attempt=\(attemptId) deviceSession.addStream returned nil")
        #endif
        showError("Could not attach stream (returned nil)")
        return
      }
      stream = created
    } catch {
      #if DEBUG
      dbg("attempt=\(attemptId) deviceSession.addStream threw: \(String(describing: error))")
      #endif
      showError("Could not attach stream: \(String(describing: error))")
      return
    }
    #if DEBUG
    dbg("attempt=\(attemptId) deviceSession.addStream ok; calling stream.start()")
    #endif
    streamSession = stream
    streamingStatus = .waiting
    setupListeners(for: stream)
    await stream.start()
    #if DEBUG
    dbg("attempt=\(attemptId) stream.start() returned")
    #endif
  }

  private func setupListeners(for stream: StreamSession) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamSessionState) {
    #if DEBUG
    dbg("attempt=\(currentStartAttemptId) stream state -> \(state)")
    #endif
    switch state {
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      didStartVoiceForCurrentStream = false
      voiceCapture.stopContinuousPhraseListening()
      #if DEBUG
      dbg("attempt=\(currentStartAttemptId) stopped: releasing streamSession and listeners")
      #endif
      streamSession = nil
      clearListeners()
      Task { [weak self] in
        try? await self?.audioCoordinator.tearDownAfterStreamSession()
        #if DEBUG
        await MainActor.run { self?.dbg("attempt=\(self?.currentStartAttemptId ?? -1) stopped: audio torn down") }
        #endif
      }
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
      didStartVoiceForCurrentStream = false
      voiceCapture.stopContinuousPhraseListening()
    case .streaming:
      streamingStatus = .streaming
      if !didStartVoiceForCurrentStream {
        didStartVoiceForCurrentStream = true
        Task { [weak self] in
          guard let self else { return }
          try? await Task.sleep(nanoseconds: 700_000_000)
          guard self.streamingStatus == .streaming else { return }
          await self.voiceCapture.startContinuousPhraseListening(
            shouldListen: { [weak self] in self?.shouldRunVoiceCapture ?? false },
            onPhraseMatched: { [weak self] in
              self?.capturePhoto()
            }
          )
        }
      }
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
        #if DEBUG
        if let began = startAttemptBeganAt {
          let elapsed = Date().timeIntervalSince(began)
          dbg("attempt=\(currentStartAttemptId) FIRST FRAME received after \(String(format: "%.2f", elapsed))s")
          startAttemptBeganAt = nil
        } else {
          dbg("attempt=\(currentStartAttemptId) FIRST FRAME received")
        }
        #endif
      }
    }
  }

  private func handleError(_ error: StreamSessionError) {
    #if DEBUG
    dbg("attempt=\(currentStartAttemptId) stream error event: \(error)")
    #endif
    let message = formatError(error)
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
      lastPhotoData = data.data
      runScan(jpegData: data.data)
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private var shouldRunVoiceCapture: Bool {
    streamingStatus == .streaming && !isCapturingPhoto && !isScanning && !showPhotoPreview
  }

  private func formatError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
