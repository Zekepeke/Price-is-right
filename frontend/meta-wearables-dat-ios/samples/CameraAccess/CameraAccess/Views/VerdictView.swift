/*
 * VerdictView.swift
 *
 * Presented after a photo is captured from the Meta wearable. Shows the
 * captured image, item identification, pricing, and a color-coded verdict
 * pill. Handles the loading and error states of the /scan request.
 */

import SwiftUI

struct VerdictView: View {
  let photo: UIImage
  let isScanning: Bool
  let scanResult: ScanResult?
  let scanError: String?
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

  private func resultCard(_ result: ScanResult) -> some View {
    VStack(spacing: 14) {
      itemRow(result.item)
      Divider().background(Color.white.opacity(0.2))
      pricingRow(result.pricing)
      verdictPill(result.verdict)
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private func itemRow(_ item: Item) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(displayTitle(for: item))
        .font(.title3.bold())
        .foregroundColor(.white)
      HStack(spacing: 8) {
        Text(item.category.capitalized)
        Text("·")
        Text(item.condition.capitalized)
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
      return "\(brand) \(item.category.capitalized)"
    }
    return item.category.capitalized
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
