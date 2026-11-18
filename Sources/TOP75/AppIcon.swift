import AppKit
import CoreServices

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

@MainActor
final class TOP75AppDelegate: NSObject, NSApplicationDelegate {
    private var quittingFromMenuBar = false

    func quitFromMenuBar() {
        quittingFromMenuBar = true
        defer { quittingFromMenuBar = false }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let showMenuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard showMenuBar, !quittingFromMenuBar, !Self.isSystemQuit(event) else {
            return .terminateNow
        }
        sender.hide(nil)
        return .terminateCancel
    }

    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEQuitApplication,
              let reason = event.paramDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].contains(reason)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    #if SWIFT_PACKAGE
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIcon.image() {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    #endif
}
