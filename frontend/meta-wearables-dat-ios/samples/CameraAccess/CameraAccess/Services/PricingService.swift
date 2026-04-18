/*
 * PricingService.swift
 *
 * Bridges captured JPEGs from the Meta wearable to the Price-Is-Right backend.
 * All backend-specific Codable types live here so a schema change surfaces in
 * exactly one file.
 */

import Foundation

struct ScanResult: Codable, Equatable {
  let item: Item
  let pricing: Pricing
  let verdict: String
}

struct Item: Codable, Equatable {
  let category: String
  let brand: String?
  let condition: String
  let ebay_search: String
}

struct Pricing: Codable, Equatable {
  let low: Double
  let high: Double
  let median: Double
  let count: Int
}

private struct BackendErrorResponse: Codable {
  let detail: String?
}

enum PricingError: LocalizedError {
  case invalidURL
  case badStatus(Int, String?)
  case decodingFailed(Error)
  case transport(Error)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Backend URL is not configured correctly."
    case .badStatus(let code, let detail):
      let normalized = (detail ?? "").lowercased()
      if normalized.contains("quota") || normalized.contains("resource_exhausted") {
        return "Gemini quota reached. Check billing/quota and retry in about a minute."
      }
      if normalized.contains("api key") || normalized.contains("invalid_argument") {
        return "Gemini API key looks invalid. Check GOOGLE_API_KEY in .env."
      }
      if let detail, !detail.isEmpty {
        return "Server responded \(code): \(detail)"
      }
      return "Server responded \(code)."
    case .decodingFailed(let err):
      return "Couldn't read server response: \(err.localizedDescription)"
    case .transport(let err):
      return "Network error: \(err.localizedDescription)"
    }
  }
}

final class PricingService {
  static let shared = PricingService()

  // Hardcoded ngrok URL. Replace with the https://*.ngrok-free.app value
  // printed by `ngrok http 8000` before each run. For simulator-only
  // testing you can also point this at http://localhost:8000, but that
  // will require an App Transport Security exception on a physical device.
  static let baseURL: String = "https://probiotic-wisplike-lizard.ngrok-free.dev"

  private let session: URLSession
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  init(session: URLSession = .shared) {
    self.session = session
    self.decoder = JSONDecoder()
    self.encoder = JSONEncoder()
  }

  func scan(jpegData: Data) async throws -> ScanResult {
    guard let url = URL(string: "\(Self.baseURL)/scan") else {
      throw PricingError.invalidURL
    }

    let base64 = jpegData.base64EncodedString()
    let body: [String: String] = ["image_base64": base64]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // ngrok-free sometimes injects a browser warning interstitial for non-browser
    // clients; this header asks it to pass traffic through verbatim.
    request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.timeoutInterval = 60

    do {
      request.httpBody = try encoder.encode(body)
    } catch {
      throw PricingError.transport(error)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PricingError.transport(error)
    }

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      var detail: String? = nil
      if let parsed = try? decoder.decode(BackendErrorResponse.self, from: data) {
        detail = parsed.detail
      } else {
        detail = String(data: data, encoding: .utf8)
      }
      throw PricingError.badStatus(http.statusCode, detail)
    }

    do {
      return try decoder.decode(ScanResult.self, from: data)
    } catch {
      throw PricingError.decodingFailed(error)
    }
  }
}
