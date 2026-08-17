import SwiftUI

@main
struct YourFlixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CustomFonts.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1024, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentSize)
    }
}

/// Without this, a plain SwiftUI `WindowGroup` app follows the standard
/// macOS "document app" convention: closing the one and only window does
/// NOT quit the app -- it just keeps running in the background with no
/// window (and, notably, anything still playing -- like the splash
/// screen's "tudum" sound -- keeps right on playing). YourFlix is a
/// single-window, no-background-purpose app, so closing its window
/// should actually end the app, the way most people expect a simple Mac
/// app like this to behave.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
