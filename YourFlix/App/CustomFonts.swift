import AppKit
import CoreText
import Foundation

/// Registers any custom fonts bundled with the app so SwiftUI's
/// `Font.custom(...)` can find them by name. Call once, early — see
/// `YourFlixApp.init()`.
///
/// Searches the whole bundle recursively rather than assuming a fixed
/// path, since this project's Xcode setup has been observed to sometimes
/// flatten bundled resources and sometimes preserve subfolders (same
/// reason AlbumLoader.swift checks multiple locations).
enum CustomFonts {
    static func registerAll() {
        register(fileNamed: "BebasNeue-Bold.otf")
    }

    private static func register(fileNamed targetName: String) {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: resourceURL, includingPropertiesForKeys: nil) else { return }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == targetName else { continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                if let error = error?.takeRetainedValue() {
                    print("CustomFonts: failed to register \(targetName): \(error)")
                }
            }
            return
        }
        print("CustomFonts: \(targetName) not found in bundle — falling back to the system font.")
    }
}
