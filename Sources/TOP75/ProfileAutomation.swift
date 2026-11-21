import AppKit
import Observation
import os
import UniformTypeIdentifiers
import SwiftUI

let automationLog = Logger(subsystem: "center.kreative.top75", category: "automation")

@MainActor
@Observable
final class ProfileAutomation {
    static let shared = ProfileAutomation()

    struct Rule: Codable, Identifiable {
        let id: String
        let name: String
        var profile: UInt8
    }

    static func target(app: String, rules: [Rule], fallback: UInt8) -> UInt8 {
        rules.first { $0.id == app }?.profile ?? fallback
    }

    var enabled = UserDefaults.standard.bool(forKey: "automaticProfiles") {
        didSet { UserDefaults.standard.set(enabled, forKey: "automaticProfiles"); refresh() }
    }
    var fallback = UInt8(clamping: UserDefaults.standard.integer(forKey: "defaultAutomaticProfile")) {
        didSet { UserDefaults.standard.set(fallback, forKey: "defaultAutomaticProfile"); refresh() }
    }
    var rules = (try? JSONDecoder().decode([Rule].self, from: UserDefaults.standard.data(forKey: "profileRules") ?? Data())) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "profileRules"); refresh() }
    }
    private(set) var profile: UInt8?
    private(set) var status = ""
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastFrontmost = ""
    @ObservationIgnored private var lastConnection: KeyboardConnection?
    @ObservationIgnored private var manuallySelectedFor: String?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func connectionChanged() {
        if Keyboard.availableConnection() != lastConnection || profile == nil { refresh() }
    }

    func manualSelection(_ target: UInt8) {
        manuallySelectedFor = lastFrontmost
        select(target, manual: true)
    }

    func noteObservedProfile(_ current: UInt8) { profile = current }

    func noteManualSelection(_ current: UInt8) {
        manuallySelectedFor = lastFrontmost
        profile = current
        pending?.cancel()
    }

    private func refresh() {
        let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let app = identifier == Bundle.main.bundleIdentifier ? lastFrontmost : identifier ?? ""
        if app != lastFrontmost { manuallySelectedFor = nil }
        guard !app.isEmpty else { return }
        let connection = Keyboard.availableConnection()
        let changed = lastConnection != connection
        lastConnection = connection
        lastFrontmost = app
        if changed { profile = nil }
        guard enabled, manuallySelectedFor != app, connection != nil else {
            pending?.cancel()
            if profile == nil, connection != nil { refreshActiveProfile() }
            return
        }
        let target = Self.target(app: app, rules: rules, fallback: fallback)
        select(target, manual: false)
    }

    private func select(_ target: UInt8, manual: Bool) {
        guard target < 3, let connection = Keyboard.availableConnection() else { return }
        pending?.cancel()
        pending = Task {
            if !manual { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            while WorkspaceTransfer.shared.isBusy {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            guard Keyboard.availableConnection() == connection,
                  let id = WorkspaceTransfer.shared.start(.keys, title: "Profil değiştiriliyor", determinate: false) else { return }
            do {
                let result = try await Task.detached {
                    try Keyboard.withDevice(connection: connection) { device in
                        let current = try Keyboard.readProfile(device)
                        return (current == target ? current : try Keyboard.selectProfile(device, profile: target), current != target)
                    }
                }.value
                profile = result.0
                status = ""
                automationLog.info("Profile \(result.0 + 1) active for \(self.lastFrontmost, privacy: .public), changed: \(result.1)")
                WorkspaceTransfer.shared.finish(id, settingsChanged: result.1)
            } catch {
                status = error.localizedDescription
                WorkspaceTransfer.shared.finish(id)
            }
        }
    }

    func refreshActiveProfile() {
        Task { await readProfile() }
    }

    private func readProfile() async {
        guard !WorkspaceTransfer.shared.isBusy, let connection = Keyboard.availableConnection() else { return }
        let value = try? await Task.detached {
            try Keyboard.withDevice(connection: connection, Keyboard.readProfile)
        }.value
        if Keyboard.availableConnection() == connection { profile = value }
    }
}

struct AppProfilesView: View {
    @Environment(\.appLanguage) private var l
    @Bindable private var automation = ProfileAutomation.shared
    @AppStorage("profileNames") private var names = Data()
    @State private var choosing = false

    var body: some View {
        Section(l("Uygulamaya göre profil")) {
            Toggle(l("Profil otomasyonunu aç"), isOn: $automation.enabled)
            Picker(l("Varsayılan profil"), selection: $automation.fallback) { profiles }
            ForEach($automation.rules) { $rule in
                HStack {
                    Picker(rule.name, selection: $rule.profile) { profiles }
                    Button(l("Kuralı kaldır"), systemImage: "minus.circle") {
                        automation.rules.removeAll { $0.id == rule.id }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            Button(l("Uygulama ekle"), systemImage: "plus") { choosing = true }
            if !automation.status.isEmpty { Text(l(automation.status)).foregroundStyle(.secondary) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            guard let url = try? result.get(), let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !automation.rules.contains(where: { $0.id == id }) else { return }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            automation.rules.append(.init(id: id, name: name, profile: automation.fallback))
        }
    }

    private var profiles: some View {
        ForEach(0..<3) { profile in
            Text(profileName(UInt8(profile), stored: names, language: l)).tag(UInt8(profile))
        }
    }
}

func profileName(_ profile: UInt8, stored: Data, language: AppLanguage) -> String {
    let names = (try? JSONDecoder().decode([UInt8: String].self, from: stored)) ?? [:]
    let name = names[profile, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? language.format("Profil %@", String(Int(profile) + 1)) : name
}
