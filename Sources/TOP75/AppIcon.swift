import AppKit

@MainActor
enum AppIcon {
    static func image() -> NSImage? {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        #else
        guard let file = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: file, withExtension: nil) else { return nil }
        #endif
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }
}

#if SWIFT_PACKAGE
@MainActor
final class DevelopmentAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIcon.image() {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
#endif
