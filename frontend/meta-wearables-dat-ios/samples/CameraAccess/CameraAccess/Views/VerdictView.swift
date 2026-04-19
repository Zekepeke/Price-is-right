/*
 * VerdictView.swift
 *
 * Presented after a photo is captured from the Meta wearable. Shows the
 * captured image, item identification, pricing, and a color-coded verdict
 * pill. Handles the loading and error states of the /scan request.
 *
 * Also displays the LLM-generated summary text and an audio playback
 * indicator when the TTS verdict is playing through the glasses speaker.
 */

import SwiftUI

struct VerdictView: View {
  let photo: UIImage
  let isScanning: Bool
  let scanResult: ScanResult?
  let scanError: String?
  let isPlayingAudio: Bool
  let onRetry: () -> Void
  let onDismiss: () -> Void

  @State private var dragOffset = CGSize.zero

  var body: some View {
    ZStack {
      Color.black.opacity(0.9)
        .ignoresSafeArea()
        .onTapGesture { dismissWithAnimation() }

      VStack(spacing: 16) {
        photoView
          .frame(maxHeight: 260)

        if isScanning {
          loadingCard
        } else if let error = scanError {
          errorCard(error)
        } else if let result = scanResult {
          resultCard(result)
        }
      }
      .padding(.horizontal, 20)
      .offset(dragOffset)
      .animation(.spring(response: 0.6, dampingFraction: 0.8), value: dragOffset)

      VStack {
        HStack {
          Spacer()
          CircleButton(icon: "xmark", text: nil) {
            dismissWithAnimation()
          }
          .accessibilityIdentifier("close_verdict_button")
          .padding(.trailing, 20)
          .padding(.top, 50)
        }
        Spacer()
      }
    }
  }

  private var photoView: some View {
    Image(uiImage: photo)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .cornerRadius(12)
      .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
      .gesture(
        DragGesture()
          .onChanged { value in
            dragOffset = value.translation
          }
          .onEnded { value in
            if abs(value.translation.height) > 100 {
              dismissWithAnimation()
            } else {
              withAnimation(.spring()) {
                dragOffset = .zero
              }
            }
          }
      )
  }

  private var loadingCard: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(1.2)
        .tint(.white)
      Text("Checking the price")
        .font(.headline)
        .foregroundColor(.white)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private func errorCard(_ message: String) -> some View {
    VStack(spacing: 12) {
      Label("Scan failed", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundColor(.yellow)
      Text(message)
        .font(.subheadline)
        .foregroundColor(.white.opacity(0.85))
        .multilineTextAlignment(.center)
      Text(recoveryHint(for: message))
        .font(.caption)
        .foregroundColor(.white.opacity(0.7))
        .multilineTextAlignment(.center)
      Button(action: onRetry) {
        Label("Retry", systemImage: "arrow.clockwise")
          .font(.headline)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .background(Color.white.opacity(0.15), in: Capsule())
          .foregroundColor(.white)
      }
      .accessibilityIdentifier("retry_scan_button")
    }
    .frame(maxWidth: .infinity)
    .padding(20)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private func recoveryHint(for message: String) -> String {
    let normalized = message.lowercased()
    if normalized.contains("quota") {
      return "Gemini quota may be exhausted. Wait about a minute or check billing/quota, then retry."
    }
    if normalized.contains("api key") {
      return "Check GOOGLE_API_KEY in your backend .env and restart the server."
    }
    if normalized.contains("network") {
      return "Confirm ngrok and backend are both running, then retry."
    }
    return "If this keeps happening, verify your backend keys and retry."
  }

  private func resultCard(_ result: ScanResult) -> some View {
    VStack(spacing: 14) {
      itemRow(result.item)

      Divider().background(Color.white.opacity(0.2))

      pricingRow(result.pricing)

      // LLM-generated summary text (conversational verdict explanation)
      if let summary = result.summary, !summary.isEmpty {
        Text(summary)
          .font(.subheadline)
          .foregroundColor(.white.opacity(0.9))
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
      }

      verdictPill(result.verdict)

      // Audio playback indicator — shows when TTS is playing through glasses
      if isPlayingAudio {
        audioIndicator
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  /// Animated speaker icon indicating TTS is playing through the glasses.
  private var audioIndicator: some View {
    HStack(spacing: 6) {
      Image(systemName: "speaker.wave.2.fill")
        .foregroundColor(.white.opacity(0.7))
        .symbolEffect(.variableColor.iterative, options: .repeating)
      Text("Playing through glasses")
        .font(.caption)
        .foregroundColor(.white.opacity(0.7))
    }
    .padding(.top, 4)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
    .animation(.easeInOut(duration: 0.3), value: isPlayingAudio)
  }

  private func itemRow(_ item: Item) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(displayTitle(for: item))
        .font(.title3.bold())
        .foregroundColor(.white)
      HStack(spacing: 8) {
        // Safely handle nullable category and condition
        Text((item.category ?? "Unknown").capitalized)
        Text("·")
        Text((item.condition ?? "Unknown").capitalized)
      }
      .font(.subheadline)
      .foregroundColor(.white.opacity(0.75))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pricingRow(_ pricing: Pricing) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Median")
          .font(.caption)
          .foregroundColor(.white.opacity(0.6))
        Text(formatPrice(pricing.median))
          .font(.title2.bold())
          .foregroundColor(.white)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("Range (\(pricing.count) listings)")
          .font(.caption)
          .foregroundColor(.white.opacity(0.6))
        Text("\(formatPrice(pricing.low)) – \(formatPrice(pricing.high))")
          .font(.subheadline)
          .foregroundColor(.white.opacity(0.85))
      }
    }
  }

  private func verdictPill(_ verdict: String) -> some View {
    let color = verdictColor(verdict)
    return Text(verdict)
      .font(.title3.bold())
      .foregroundColor(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(color, in: Capsule())
      .accessibilityIdentifier("verdict_pill")
  }

  private func displayTitle(for item: Item) -> String {
    if let brand = item.brand, !brand.isEmpty, brand.lowercased() != "null" {
      let category = (item.category ?? "Item").capitalized
      return "\(brand) \(category)"
    }
    return (item.category ?? "Unknown Item").capitalized
  }

  private func formatPrice(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
  }

  private func verdictColor(_ verdict: String) -> Color {
    switch verdict.lowercased() {
    case let s where s.contains("great"):
      return Color.green.opacity(0.85)
    case let s where s.contains("overpriced"):
      return Color.red.opacity(0.85)
    default:
      return Color.orange.opacity(0.85)
    }
  }

  private func dismissWithAnimation() {
    withAnimation(.easeInOut(duration: 0.3)) {
      dragOffset = CGSize(width: 0, height: UIScreen.main.bounds.height)
    }
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      onDismiss()
    }
  }
}
