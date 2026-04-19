/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

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

  private var lastPhotoData: Data?
  private let pricingService: PricingService

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var streamSession: StreamSession?
  private var cancellables = Set<AnyCancellable>()

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    pricingService: PricingService = .shared
  ) {
    self.wearables = wearables
    self.pricingService = pricingService
    self.sessionManager = DeviceSessionManager(wearables: wearables)

    // Forward session manager state to this ViewModel for SwiftUI binding
    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$hasActiveDevice)
    sessionManager.$isReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$isDeviceSessionReady)
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    guard streamingStatus == .stopped else {
      print("[PIR] handleStartStreaming: skipped — already in status \(streamingStatus)")
      return
    }
    print("[PIR] handleStartStreaming: checking camera permission")
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      print("[PIR] handleStartStreaming: permission status = \(status)")
      if status != .granted {
        status = try await wearables.requestPermission(permission)
        print("[PIR] handleStartStreaming: after request, permission status = \(status)")
      }
      guard status == .granted else {
        print("[PIR] handleStartStreaming: permission denied, aborting")
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      print("[PIR] handleStartStreaming: permission error — \(error)")
      showError("Permission error: \(error.description)")
    }
  }

  func stopSession() async {
    guard let stream = streamSession else { return }
    streamSession = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    await stream.stop()
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
    showPhotoPreview = false
    capturedPhoto = nil
    scanResult = nil
    scanError = nil
    lastPhotoData = nil
  }

  func retryScan() {
    guard let jpegData = lastPhotoData else { return }
    Task {
      await runScan(jpegData: jpegData)
    }
  }

  // MARK: - Scan Pipeline

  /// Runs the full scan → UI update pipeline.
  private func runScan(jpegData: Data) async {
    scanError = nil
    isScanning = true

    do {
      let result = try await pricingService.scan(jpegData: jpegData)

      // Update UI state
      scanResult = result
      isScanning = false
    } catch {
      scanResult = nil
      isScanning = false
      scanError = (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
    }
  }

  // MARK: - Private

  private func startSession() async {
    print("[PIR] startSession: entered")
    guard streamSession == nil else {
      print("[PIR] startSession: skipped — streamSession already exists")
      return
    }
    print("[PIR] startSession: requesting DeviceSession")
    guard let deviceSession = await sessionManager.getSession() else {
      print("[PIR] startSession: getSession returned nil")
      return
    }
    print("[PIR] startSession: DeviceSession state = \(deviceSession.state)")
    guard deviceSession.state == .started else {
      print("[PIR] startSession: DeviceSession not started, aborting")
      return
    }

    let config = StreamSessionConfig(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.medium,
      frameRate: 30
    )
    print("[PIR] startSession: calling addStream (codec=raw, res=medium, fps=30)")

    guard let stream = try? deviceSession.addStream(config: config) else {
      print("[PIR] startSession: addStream failed")
      return
    }
    print("[PIR] startSession: stream created, setting up listeners")
    streamSession = stream
    streamingStatus = .waiting
    setupListeners(for: stream)
    print("[PIR] startSession: calling stream.start()")
    await stream.start()
    print("[PIR] startSession: stream.start() returned")
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
    print("[PIR] StreamSession state → \(state)")
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private var frameCount = 0
  private func handleVideoFrame(_ frame: VideoFrame) {
    frameCount += 1
    if frameCount == 1 {
      print("[PIR] first video frame received")
    } else if frameCount % 30 == 0 {
      print("[PIR] video frame #\(frameCount)")
    }
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
        print("[PIR] hasReceivedFirstFrame set to true")
      }
    } else if frameCount == 1 {
      print("[PIR] first frame: makeUIImage() returned nil")
    }
  }

  private func handleError(_ error: StreamSessionError) {
    print("[PIR] StreamSession error: \(error)")
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
      // Kick off the scan → verdict → audio pipeline
      Task {
        await runScan(jpegData: data.data)
      }
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
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
