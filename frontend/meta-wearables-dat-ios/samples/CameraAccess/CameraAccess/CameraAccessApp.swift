import MWDATCore
import SwiftUI

@main
struct CameraAccessApp: App {
    init() {
        try? Wearables.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(wearables: Wearables.shared)
        }
    }
}
