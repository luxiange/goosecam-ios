import SwiftUI

@main
struct GooseCamApp: App {
    init() {
        Diag.installExceptionLogger()
        Diag.mark("app.launch v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") b\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
