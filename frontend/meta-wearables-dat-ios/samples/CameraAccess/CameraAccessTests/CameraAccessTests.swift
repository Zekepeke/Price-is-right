/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import MWDATMockDevice
import SwiftUI
import XCTest

@testable import CameraAccess

final class NoOpAudioSessionCoordinator: AudioSessionCoordinating {
  func prepareForSpeechRecording() async throws {}
  func prepareForSpeechPlayback() async throws {}
  func tearDownAfterStreamSession() async throws {}
}

final class NoOpVoiceCaptureController: VoiceCaptureControlling {
  func startContinuousPhraseListening(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async {}

  func stopContinuousPhraseListening() {}

  func pauseForAppBackground() {}

  func resumeAfterAppForeground(
    shouldListen: @escaping @MainActor () -> Bool,
    onPhraseMatched: @escaping @MainActor () -> Void
  ) async {}
}

class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    MockDeviceKit.shared.enable()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.disable()
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(
      wearables: Wearables.shared,
      audioCoordinator: NoOpAudioSessionCoordinator(),
      voiceCapture: NoOpVoiceCaptureController()
    )

    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    await viewModel.handleStartStreaming()

    try await Task.sleep(nanoseconds: 10_000_000_000)

    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    await viewModel.stopSession()

    // Wait for session to stop
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
      let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(
      wearables: Wearables.shared,
      audioCoordinator: NoOpAudioSessionCoordinator(),
      voiceCapture: NoOpVoiceCaptureController()
    )

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }
}

// MARK: - Deep link routing

final class DeepLinkRouterTests: XCTestCase {

  func testMetaWearablesQueryTakesPrecedenceOverStartHost() {
    let url = URL(string: "cameraaccess://start?metaWearablesAction=foo")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .metaWearablesCallback)
  }

  func testStartHost() {
    let url = URL(string: "cameraaccess://start")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .startShopping(showConnect: false))
  }

  func testStartHostWithShowConnect() {
    let url = URL(string: "cameraaccess://start?show=connect")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .startShopping(showConnect: true))
  }

  func testStartPathOnHost() {
    let url = URL(string: "cameraaccess://app.example/foo/start")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .startShopping(showConnect: false))
  }

  func testStartPathOnly() {
    let url = URL(string: "cameraaccess:///start")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .startShopping(showConnect: false))
  }

  func testUnrelatedScheme() {
    let url = URL(string: "https://example.com/start")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .unrelated)
  }

  func testCameraAccessUnrelatedPath() {
    let url = URL(string: "cameraaccess://settings")!
    XCTAssertEqual(DeepLinkRouter.classify(url), .unrelated)
  }
}
