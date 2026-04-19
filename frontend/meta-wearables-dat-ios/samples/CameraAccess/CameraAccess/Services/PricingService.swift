/*
 * PricingService.swift
 *
 * Bridges captured JPEGs from the Meta wearable to the Price-Is-Right backend.
 * All backend-specific Codable types live here so a schema change surfaces in
 * exactly one file.
 */

import Foundation

// MARK: - Response Models

/// Top-level response from POST /scan.
/// Every field matches the backend JSON schema; optional fields gracefully
/// degrade when the backend omits them.
struct ScanResult: Codable, Equatable {
  let scanId: String
  let item: Item
  let pricing: Pricing
  let verdict: String
  let imageUrl: String?
  let summary: String?
  let audio: AudioPayload?
  let netProfit: Double?

  // Backend uses snake_case; Swift uses camelCase.
  enum CodingKeys: String, CodingKey {
    case scanId = "scan_id"
    case item, pricing, verdict
    case imageUrl = "image_url"
    case summary, audio
    case netProfit = "net_profit"
  }

  /// Convenience: decodes `audio.data` (base64 string) into raw MP3 bytes.
  /// Returns nil if no audio payload or if base64 decoding fails.
  var audioData: Data? {
    guard let base64String = audio?.data else { return nil }
    return Data(base64Encoded: base64String)
  }
}

/// Audio payload embedded in the scan response.
struct AudioPayload: Codable, Equatable {
  let data: String          // base64-encoded MP3 bytes
  let contentType: String   // e.g. "audio/mpeg"

  enum CodingKeys: String, CodingKey {
    case data
    case contentType = "content_type"
  }
}

struct Item: Codable, Equatable {
  let category: String?
  let brand: String?
  let condition: String?
  let confidence: Double?
  let pricingSource: String?
  let searchQuery: String?
  let ebaySearch: String?

  enum CodingKeys: String, CodingKey {
    case category, brand, condition, confidence
    case pricingSource = "pricing_source"
    case searchQuery = "search_query"
    case ebaySearch = "ebay_search"
  }
}

struct Pricing: Codable, Equatable {
  let low: Double
  let high: Double
  let median: Double
  let count: Int
  let requestedSource: String?
  let actualSource: String?
  let usedFallback: Bool?

  enum CodingKeys: String, CodingKey {
    case low, high, median, count
    case requestedSource = "requested_source"
    case actualSource = "actual_source"
    case usedFallback = "used_fallback"
  }
}

// MARK: - Request Model

/// JSON body sent to POST /scan.
private struct ScanRequestBody: Encodable {
  let imageBase64: String
  let userId: String?

  enum CodingKeys: String, CodingKey {
    case imageBase64 = "image_base64"
    case userId = "user_id"
  }
}

// MARK: - Error Types

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

// MARK: - Service

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

  /// Sends a captured JPEG to the backend and returns the full scan result
  /// including verdict, pricing, summary text, and optional TTS audio.
  ///
  /// - Parameters:
  ///   - jpegData: Raw JPEG image bytes from the glasses camera.
  ///   - userId: Optional Supabase user UUID. Pass nil if not authenticated.
  func scan(jpegData: Data, userId: String? = nil) async throws -> ScanResult {
    guard let url = URL(string: "\(Self.baseURL)/scan") else {
      throw PricingError.invalidURL
    }

    let body = ScanRequestBody(
      imageBase64: jpegData.base64EncodedString(),
      userId: userId
    )

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
