import SwiftUI

@main
struct LincodeFieldOneApp: App {
    @State private var settings = AppSettings()
    @State private var modelStore = ModelStore()
    @State private var captureStore = CaptureStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(modelStore)
                .environment(captureStore)
                .preferredColorScheme(.dark)
                .tint(Carbon.interactive)
        }
    }
}
