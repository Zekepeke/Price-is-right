/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import SwiftUI

/// Manages DeviceSession lifecycle with 1:1 device-to-session mapping.
/// Handles device availability monitoring, session creation, and the glasses-side bug workaround.
@MainActor
final class DeviceSessionManager: ObservableObject {
  @Published private(set) var isReady: Bool = false
  @Published private(set) var hasActiveDevice: Bool = false

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var deviceMonitorTask: Task<Void, Never>?
  private var stateObserverTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    startDeviceMonitoring()
  }

  deinit {
    deviceMonitorTask?.cancel()
    stateObserverTask?.cancel()
  }

  /// Returns a ready DeviceSession, creating one if needed.
  /// Waits for the session to reach .started state before returning.
  func getSession() async -> DeviceSession? {
    if let session = deviceSession, session.state == .started {
      print("[PIR] DeviceSessionManager.getSession: reusing existing started session")
      isReady = true
      return session
    }

    if let existing = deviceSession {
      print("[PIR] DeviceSessionManager.getSession: existing session state = \(existing.state)")
    }

    if deviceSession?.state == .stopped {
      print("[PIR] DeviceSessionManager.getSession: clearing stopped session")
      deviceSession = nil
    }

    guard deviceSession == nil else {
      print("[PIR] DeviceSessionManager.getSession: session exists but not started — returning nil")
      return nil
    }

    print("[PIR] DeviceSessionManager.getSession: creating new DeviceSession")
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session

      let stateStream = session.stateStream()
      print("[PIR] DeviceSessionManager.getSession: calling session.start()")
      try session.start()

      for await state in stateStream {
        print("[PIR] DeviceSession state → \(state)")
        if state == .started {
          isReady = true
          startStateObserver(for: session)
          return session
        } else if state == .stopped {
          print("[PIR] DeviceSessionManager.getSession: session stopped before reaching .started")
          isReady = false
          deviceSession = nil
          return nil
        }
      }
    } catch {
      print("[PIR] DeviceSessionManager.getSession: error — \(error)")
      isReady = false
      deviceSession = nil
    }
    return nil
  }

  // MARK: - Private

  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        if let device {
          print("[PIR] DeviceSessionManager: active device appeared — \(device)")
          hasActiveDevice = true
          // Retry with backoff — BLE stack may not be fully ready on first fire
          for attempt in 1...3 {
            if await getSession() != nil {
              print("[PIR] DeviceSessionManager: session ready on attempt \(attempt)")
              break
            }
            print("[PIR] DeviceSessionManager: session attempt \(attempt) failed, retrying in 2s")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
          }
        } else {
          print("[PIR] DeviceSessionManager: active device lost")
          hasActiveDevice = false
          handleDeviceLost()
        }
      }
    }
  }

  private func startStateObserver(for session: DeviceSession) {
    stateObserverTask?.cancel()
    stateObserverTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        print("[PIR] DeviceSession (observer) state → \(state)")
        if state == .started {
          isReady = true
        } else if state == .stopped {
          print("[PIR] DeviceSessionManager: DeviceSession stopped — clearing")
          isReady = false
          deviceSession = nil
          return
        }
      }
    }
  }

  private func handleDeviceLost() {
    print("[PIR] DeviceSessionManager.handleDeviceLost: stopping session")
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
    isReady = false
  }
}
