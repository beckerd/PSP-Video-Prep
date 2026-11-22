import SwiftUI

@main
struct PSPVideoPrepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("PSP Video Prep", id: "main") {
            ContentView()
        }
        .defaultSize(width: 520, height: 520)
    }
}

/// Receives videos opened with the app from Finder ("Open With", or dropped on
/// its Dock icon) and passes them to the window. All files of one open request
/// arrive together here, which SwiftUI's `onOpenURL` doesn't guarantee.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let didOpenFiles = Notification.Name("PSPVideoPrepDidOpenFiles")

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: Self.didOpenFiles, object: urls)
    }
}
