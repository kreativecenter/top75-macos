import AppIntents
import Foundation

enum TOP75LightingCommand: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lighting action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .on: "Turn on", .off: "Turn off", .toggle: "Toggle"
    ]

    var power: Bool? {
        switch self {
        case .on: true
        case .off: false
        case .toggle: nil
        }
    }
}

enum TOP75Profile: String, AppEnum {
    case first, second, third

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Keyboard profile"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .first: "Profile 1", .second: "Profile 2", .third: "Profile 3"
    ]

    var index: UInt8 {
        switch self {
        case .first: 0
        case .second: 1
        case .third: 2
        }
    }
}

struct SetTOP75Lighting: AppIntent {
    static let title: LocalizedStringResource = "Set TOP75 Lighting"
    static let description = IntentDescription("Turn the keyboard lighting on or off, or toggle it.")
    static let openAppWhenRun = true

    @Parameter(title: "Lighting action", default: .toggle)
    var action: TOP75LightingCommand

    static var parameterSummary: some ParameterSummary {
        Summary("Set TOP75 lighting to \(\.$action)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let connection = Keyboard.availableConnection() else { throw ShortcutError.disconnected }
        let transfer = WorkspaceTransfer.shared
        guard let id = transfer.start(.lighting, title: "Aydınlatma", determinate: false)
        else { throw ShortcutError.busy }
        defer { transfer.finish(id) }
        try await LightingScheduler.shared.quickToggle(connection: connection, power: action.power)
        return .result()
    }
}

struct SelectTOP75Profile: AppIntent {
    static let title: LocalizedStringResource = "Select TOP75 Profile"
    static let description = IntentDescription("Switch to one of the three profiles stored on the keyboard.")
    static let openAppWhenRun = true

    @Parameter(title: "Keyboard profile", default: .first)
    var profile: TOP75Profile

    static var parameterSummary: some ParameterSummary {
        Summary("Select TOP75 \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let connection = Keyboard.availableConnection() else { throw ShortcutError.disconnected }
        let transfer = WorkspaceTransfer.shared
        guard let id = transfer.start(.keys, title: "Profil değiştiriliyor", determinate: false)
        else { throw ShortcutError.busy }

        let target = profile.index
        do {
            let changed = try await Task.detached {
                try Keyboard.withDevice(connection: connection) { device in
                    guard try Keyboard.readProfile(device) != target else { return false }
                    _ = try Keyboard.selectProfile(device, profile: target)
                    return true
                }
            }.value
            ProfileAutomation.shared.noteManualSelection(target)
            transfer.finish(id, settingsChanged: changed)
        } catch {
            transfer.finish(id)
            throw error
        }
        return .result()
    }
}

struct TOP75Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetTOP75Lighting(), phrases: ["Change lighting in \(.applicationName)"],
                    shortTitle: "Set Lighting", systemImageName: "lightbulb")
        AppShortcut(intent: SelectTOP75Profile(), phrases: ["Select a profile in \(.applicationName)"],
                    shortTitle: "Select Profile", systemImageName: "keyboard")
    }
}

private enum ShortcutError: LocalizedError {
    case disconnected, busy

    var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "Connect your TOP75 before running this shortcut.")
        case .busy: String(localized: "Wait for the current keyboard operation to finish.")
        }
    }
}
