/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  @Environment(\.scenePhase) private var scenePhase

  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      // Stay on the pre-stream view until we have an actual frame. Otherwise the
      // user sees a black screen with a bare spinner for 5-10s during the
      // glasses-side warmup on cold launch (and again during any recovery).
      if viewModel.isStreaming && viewModel.hasReceivedFirstFrame {
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      viewModel.handleScenePhase(phase)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Photo capture failed", isPresented: $viewModel.showPhotoCaptureError) {
      Button("OK") {
        viewModel.dismissPhotoCaptureError()
      }
    } message: {
      Text("Unable to capture photo. This may be due to low storage on device or another capture already in progress. Please try again in a few moments.")
    }
  }
}
