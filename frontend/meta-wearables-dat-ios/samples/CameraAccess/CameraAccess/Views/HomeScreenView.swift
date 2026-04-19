import MWDATCore
import SwiftUI

struct ContentView: View {
    @StateObject private var manager: GlassesManager

    init(wearables: WearablesInterface) {
        _manager = StateObject(wrappedValue: GlassesManager(wearables: wearables))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = manager.currentFrame {
                GeometryReader { geo in
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text(manager.statusMessage)
                        .foregroundColor(.white)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            VStack {
                Spacer()
                HStack(spacing: 20) {
                    Button(action: {
                        if manager.isStreaming {
                            manager.stopStreaming()
                        } else {
                            manager.startStreaming()
                        }
                    }) {
                        Text(manager.isStreaming ? "Stop" : "Start")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                            .background(manager.isStreaming ? Color.red : Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    Button(action: { manager.capturePhoto() }) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 22))
                            .padding(16)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                            .foregroundColor(.white)
                    }
                    .disabled(!manager.isStreaming)
                    .opacity(manager.isStreaming ? 1 : 0.4)
                }
                .padding(.bottom, 48)
            }
        }
    }
}
