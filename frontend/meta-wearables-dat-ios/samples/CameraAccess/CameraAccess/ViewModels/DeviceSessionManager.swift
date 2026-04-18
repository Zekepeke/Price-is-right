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
  #if DEBUG
  private func dbg(_ msg: String) {
    NSLog("[DeviceSessionManager] \(msg)")
  }
  #endif

  @Published private(set) var isReady: Bool = false
  @Published private(set) var hasActiveDevice: Bool = false
  /// Timestamp at which the current DeviceSession reached `.started`.
  /// Used by the ViewModel to enforce a warmup period before calling `addStream`.
  @Published private(set) var sessionReadyAt: Date?

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
    #if DEBUG
    dbg("getSession called currentSessionState=\(String(describing: deviceSession?.state)) isReady=\(isReady)")
    #endif
    if let session = deviceSession, session.state == .started {
      if !isReady { isReady = true }
      if sessionReadyAt == nil { sessionReadyAt = Date() }
      #if DEBUG
      dbg("reusing started session (readyAt=\(String(describing: sessionReadyAt)))")
      #endif
      return session
    }

    // Session needs to be created or is stopped
    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    guard deviceSession == nil else {
      // Session exists but not in .started state - wait or return nil
      #if DEBUG
      dbg("session exists but not started (state=\(String(describing: deviceSession?.state))); returning nil")
      #endif
      return nil
    }

    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      #if DEBUG
      dbg("created new session; initial state=\(session.state)")
      #endif
      deviceSession = session

      let stateStream = session.stateStream()
      try session.start()
      #if DEBUG
      dbg("session.start called")
      #endif

      // Wait for .started state
      for await state in stateStream {
        #if DEBUG
        dbg("stateStream event during start wait: \(state)")
        #endif
        if state == .started {
          isReady = true
          sessionReadyAt = Date()
          startStateObserver(for: session)
          #if DEBUG
          dbg("session reached started (readyAt=\(String(describing: sessionReadyAt)))")
          #endif
          return session
        } else if state == .stopped {
          isReady = false
          sessionReadyAt = nil
          deviceSession = nil
          #if DEBUG
          dbg("session stopped before ready")
          #endif
          return nil
        }
      }
    } catch {
      #if DEBUG
      dbg("getSession error: \(String(describing: error))")
      #endif
      isReady = false
      deviceSession = nil
    }
    return nil
  }

  /// Tears down the current DeviceSession and creates a brand new one.
  /// Use this when the SDK reports a non-recoverable start error (e.g. ActivityManagerError 11)
  /// that typically means the glasses-side activity state is poisoned. A fresh session
  /// forces the glasses to release the previous activity before retrying.
  func recreateSession() async -> DeviceSession? {
    #if DEBUG
    dbg("recreateSession: begin (current state=\(String(describing: deviceSession?.state)))")
    #endif
    stateObserverTask?.cancel()
    stateObserverTask = nil
    isReady = false
    sessionReadyAt = nil
    if let old = deviceSession {
      old.stop()
      #if DEBUG
      dbg("recreateSession: stop() called on old session")
      #endif
    }
    deviceSession = nil
    // Short cooldown so the glasses-side activity manager can release before we reconnect.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    #if DEBUG
    dbg("recreateSession: cooldown elapsed; acquiring fresh session")
    #endif
    return await getSession()
  }

  // MARK: - Private

  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        hasActiveDevice = device != nil
        #if DEBUG
        let id = device ?? "nil"
        dbg("activeDeviceStream -> \(id)")
        #endif
        if device != nil {
          _ = await getSession()
        } else {
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
        #if DEBUG
        dbg("stateObserver event: \(state)")
        #endif
        if state == .started {
          if !isReady { isReady = true }
          if sessionReadyAt == nil { sessionReadyAt = Date() }
        } else if state == .stopped {
          isReady = false
          sessionReadyAt = nil
          deviceSession = nil
          return
        } else {
          sessionReadyAt = nil
        }
      }
    }
  }

  private func handleDeviceLost() {
    #if DEBUG
    dbg("handleDeviceLost")
    #endif
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
    isReady = false
    sessionReadyAt = nil
  }
}
