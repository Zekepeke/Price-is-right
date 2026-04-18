/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RegistrationView.swift
//
// Invisible background view that owns `.onOpenURL` for the app. It forwards every
// incoming URL to `WearablesViewModel.handleOpenURL`, which routes Meta AI callbacks
// (carrying `metaWearablesAction`) into `Wearables.shared.handleUrl(_:)` and
// in-app `cameraaccess://start` links into the streaming flow.
//
// Without a live `.onOpenURL` somewhere in the view tree, the DAT SDK never sees
// the OAuth / permission callbacks from Meta AI, so registration appears to
// "succeed" but the glasses-side activity refuses later stream starts with
// errors like `ActivityManagerError 11`.
//

import MWDATCore
import SwiftUI

struct RegistrationView: View {
  @ObservedObject var viewModel: WearablesViewModel

  var body: some View {
    EmptyView()
      .onOpenURL { url in
        viewModel.handleOpenURL(url)
      }
  }
}
