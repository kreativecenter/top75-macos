import AppKit
import SwiftUI

struct QuickControls: View {
    @Environment(\.openWindow) private var openWindow
    let language: AppLanguage
    @AppStorage("profileNames") private var names = Data()
    private let battery = BatteryMonitor.shared
    private let profiles = ProfileAutomation.shared
    private let scheduler = LightingScheduler.shared
    private let transfer = WorkspaceTransfer.shared
    @State private var failure = ""

    var body: some View {
        Text(connectionLabel)
        if let percent = battery.percent {
            Text(language.format("Pil %@", (Double(percent) / 100).formatted(.percent.locale(Locale(identifier: language.code)))))
        }
        if let profile = profiles.profile {
            Text(language.format("Etkin profil: %@", profileName(profile, stored: names, language: language)))
        }
        if !failure.isEmpty { Text(failure) }
        Divider()
        Menu(language("Profil değiştir")) {
            ForEach(0..<3) { index in
                let profile = UInt8(index)
                Button(profileName(profile, stored: names, language: language)) { profiles.manualSelection(profile) }
                    .disabled(profiles.profile == profile)
            }
        }
        .disabled(Keyboard.availableConnection() == nil || transfer.isBusy)
        Button(language("Işığı aç veya kapat")) { toggleLighting() }
            .disabled(Keyboard.availableConnection() == nil || transfer.isBusy)
        if scheduler.canSkip {
            Button(language("Bu aralığı atla"), action: scheduler.skipCurrentInterval)
        }
        Divider()
        Button(language("TOP75’i aç")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(language("TOP75’ten çık")) { NSApp.terminate(nil) }
    }

    private var connectionLabel: String {
        if Keyboard.hasUSBInterface() { return language("USB bağlı") }
        switch BluetoothKeyboard.detectedConnection() {
        case .bluetoothLowEnergy: return language("Bluetooth 5.0 bağlı")
        case .bluetooth: return language("Bluetooth bağlı")
        default: return language(battery.receiverOnline ? "2,4 GHz bağlı" : "Klavye bağlantısı yok")
        }
    }

    private func toggleLighting() {
        guard let connection = Keyboard.availableConnection(),
              let id = transfer.start(.lighting, title: "Aydınlatma", determinate: false) else { return }
        Task {
            do { try await scheduler.quickToggle(connection: connection); failure = "" }
            catch { failure = language.message(error) }
            transfer.finish(id)
        }
    }
}
