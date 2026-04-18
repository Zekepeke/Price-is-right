/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Parsed result for URLs delivered via `onOpenURL` (and cold launch).
enum AppIncomingURLKind: Equatable {
  /// OAuth / registration callback for the DAT SDK (`metaWearablesAction` query item).
  case metaWearablesCallback
  /// In-app shopping entry (`cameraaccess://start` and path/query variants).
  case startShopping(showConnect: Bool)
  case unrelated
}

/// Central routing for app-specific URLs vs Meta DAT callbacks.
///
/// Meta callbacks use the same custom scheme (`cameraaccess`) as in-app links; anything
/// carrying `metaWearablesAction` is delegated to `Wearables.shared.handleUrl(_:)` and
/// must not be interpreted as `startShopping`.
enum DeepLinkRouter {
  static func classify(_ url: URL) -> AppIncomingURLKind {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return .unrelated
    }

    let isMetaCallback =
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    if isMetaCallback {
      return .metaWearablesCallback
    }

    guard url.scheme?.lowercased() == "cameraaccess" else {
      return .unrelated
    }

    guard isStartShoppingURL(url) else {
      return .unrelated
    }

    let showRaw = components.queryItems?.first(where: { $0.name == "show" })?.value
    let showConnect = showRaw?.lowercased() == "connect"
    return .startShopping(showConnect: showConnect)
  }

  private static func isStartShoppingURL(_ url: URL) -> Bool {
    let host = (url.host ?? "").lowercased()
    if host == "start" {
      return true
    }

    let lastPath = url.path.split(separator: "/").last.map(String.init)?.lowercased()
    return lastPath == "start"
  }
}
