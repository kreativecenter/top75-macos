import Foundation

extension SettingsSnapshot {
    static func load(from url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = 256 * 1024
        guard properties.isRegularFile == true, let size = properties.fileSize, size <= limit else {
            throw SnapshotError.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw SnapshotError.invalidFile
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Self.self, from: data),
              [1, 2].contains(snapshot.formatVersion), snapshot.device == model,
              snapshot.hasExpectedShape, snapshot.options.isValid,
              snapshot.lighting.rgb <= 0xFFFFFF, snapshot.lighting.brightness <= 4,
              snapshot.lighting.speed <= 4, (snapshot.lighting.flags & 15) <= 8,
              (snapshot.lighting.flags >> 4) <= 3,
              (0...19).contains(snapshot.lighting.effect) || snapshot.lighting.effect == 66,
              snapshot.keyColors.allSatisfy({ $0 <= 0xFFFFFF }),
              snapshot.formatVersion == 1 || !Keyboard.sharesFnLayer(snapshot.firmware)
                || snapshot.profiles[1].function == snapshot.profiles[2].function
        else { throw SnapshotError.invalidFile }
        return snapshot
    }

    var hasExpectedShape: Bool {
        activeProfile < 3 && keyColors.count == 128 && profiles.count == 3 && options.timers.count == 4
            && profiles.allSatisfy { profile in
                [profile.base, profile.function].allSatisfy { keys in
                    keys.count == 128 && keys.allSatisfy { $0.count == 4 }
                }
            }
    }

    func binding(profile: UInt8, fn: Bool, slot: UInt8) -> [UInt8] {
        // Version 1 requested three Fn indices. Only index zero belonged to its active profile.
        let index = fn && formatVersion == 1 ? 0 : Int(profile)
        let layer = profiles[index]
        return (fn ? layer.function : layer.base)[Int(slot)]
    }
}

enum SnapshotError: LocalizedError {
    case invalidFile, differentFirmware, stale, profileRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Geçerli bir TOP75 (957) JSON ayar kaydı seç."
        case .differentFirmware: "Ayar kaydının firmware sürümü klavyeyle eşleşmiyor."
        case .stale: "Klavye ayarları değişti. Yeni bir geri yükleme önizlemesi aç."
        case .profileRecoveryFailed: "Önceki etkin profil geri seçilemedi. Klavyedeki etkin profili kontrol et."
        }
    }
}

struct SnapshotRestoreFailure: Error {
    let verifiedCount: Int
    let cause: any Error
}

struct SnapshotRestorePlan: Sendable {
    enum Group: Hashable, Sendable {
        case settings, colors, profile(UInt8), sharedFn
    }

    enum Item: Hashable, Sendable {
        case lighting, debounce, automaticOS, timer(Int), activeProfile
        case color(UInt8)
        case key(profile: UInt8, fn: Bool, slot: UInt8)
        case sharedFn(slot: UInt8)

        var group: Group {
            switch self {
            case .color: .colors
            case .key(let profile, _, _): .profile(profile)
            case .sharedFn: .sharedFn
            default: .settings
            }
        }

        var keyTarget: (profile: UInt8, fn: Bool, slot: UInt8)? {
            switch self {
            case .key(let profile, let fn, let slot): (profile, fn, slot)
            case .sharedFn(let slot): (1, true, slot)
            default: nil
            }
        }

        func differs(_ first: SettingsSnapshot, _ second: SettingsSnapshot) -> Bool {
            if let target = keyTarget {
                return first.binding(profile: target.profile, fn: target.fn, slot: target.slot)
                    != second.binding(profile: target.profile, fn: target.fn, slot: target.slot)
            }
            return switch self {
            case .lighting: !first.lighting.matches(second.lighting)
            case .debounce: first.options.debounce != second.options.debounce
            case .automaticOS: first.options.automaticOS != second.options.automaticOS
            case .timer(let index): first.options.timers[index] != second.options.timers[index]
            case .activeProfile: first.activeProfile != second.activeProfile
            case .color(let slot): first.keyColors[Int(slot)] != second.keyColors[Int(slot)]
            case .key, .sharedFn: false
            }
        }
    }

    static let timers = ["Bluetooth ışık", "2,4 GHz ışık", "Bluetooth derin uyku", "2,4 GHz derin uyku"]
    static let groups: [Group] = [.settings, .colors, .profile(0), .profile(1), .profile(2), .sharedFn]

    let current: SettingsSnapshot
    let backup: SettingsSnapshot
    let changes: [Item]

    init(current: SettingsSnapshot, backup: SettingsSnapshot) throws {
        guard current.hasExpectedShape, backup.hasExpectedShape else { throw SnapshotError.invalidFile }
        guard current.firmware == backup.firmware else { throw SnapshotError.differentFirmware }
        self.current = current
        self.backup = backup
        var items: [Item] = [.lighting, .debounce, .automaticOS, .activeProfile]
        items += Self.timers.indices.map(Item.timer)
        items += (0..<128).map(Item.color)
        for profile: UInt8 in 0..<3 {
            items += (0..<128).map { .key(profile: profile, fn: false, slot: $0) }
        }
        let fnProfiles = backup.formatVersion == 1 ? [backup.activeProfile] : [0, 1, 2]
        let sharedFn = Keyboard.sharesFnLayer(backup.firmware)
        for profile in fnProfiles where !sharedFn || profile == 0 {
            items += (0..<128).map { .key(profile: profile, fn: true, slot: $0) }
        }
        if sharedFn && fnProfiles.contains(where: { $0 > 0 }) {
            items += (0..<128).map(Item.sharedFn)
        }
        changes = items.filter { $0.differs(current, backup) }
    }

    func selectedOptions(_ selection: Set<Item>, from observed: DeviceOptions) -> DeviceOptions {
        var options = observed
        if selection.contains(.debounce) { options.debounce = backup.options.debounce }
        if selection.contains(.automaticOS) { options.automaticOS = backup.options.automaticOS }
        for index in Self.timers.indices where selection.contains(.timer(index)) {
            options.timers[index] = backup.options.timers[index]
        }
        return options
    }
}

extension Keyboard {
    static func restore(
        _ plan: SnapshotRestorePlan, selection: Set<SnapshotRestorePlan.Item>,
        connection: KeyboardConnection = .usb, progress: @Sendable (Double) -> Void
    ) throws {
        guard !selection.isEmpty, selection.isSubset(of: Set(plan.changes)) else { throw SnapshotError.invalidFile }
        try withDevice(connection: connection) { device in
            let observed = try readSnapshot(device)
            guard observed.firmware == plan.current.firmware, observed.hasExpectedShape,
                  observed.activeProfile == plan.current.activeProfile,
                  !selection.contains(where: { $0.differs(observed, plan.current) })
            else { throw SnapshotError.stale }

            var verified = 0
            var attemptedProfileChange = false
            var active = observed.activeProfile
            func advance(_ count: Int) {
                verified += count
                progress(Double(verified) / Double(selection.count))
            }
            do {
                for item in plan.changes where selection.contains(item) {
                    guard let target = item.keyTarget else { continue }
                    let (profile, fn, slot) = target
                    if active != profile {
                        attemptedProfileChange = true
                        active = try selectProfile(device, profile: profile)
                    }
                    _ = try assignKey(device, slot: slot,
                                      binding: plan.backup.binding(profile: profile, fn: fn, slot: slot),
                                      expectedProfile: profile,
                                      previousBinding: observed.binding(profile: profile, fn: fn, slot: slot), fn: fn)
                    advance(1)
                }
                // Restore the entry profile before writing device-wide settings.
                if active != observed.activeProfile {
                    _ = try selectProfile(device, profile: observed.activeProfile)
                }
                if selection.contains(.lighting) {
                    _ = try apply(device, lighting: plan.backup.lighting, replacing: observed.lighting)
                    advance(1)
                }
                let options = plan.selectedOptions(selection, from: observed.options)
                if options != observed.options {
                    _ = try updateOptions(device, desired: options, previous: observed.options)
                    let optionCount = selection.filter {
                        switch $0 {
                        case .debounce, .automaticOS, .timer: true
                        default: false
                        }
                    }.count
                    advance(optionCount)
                }
                let colors = selection.reduce(into: [UInt8: UInt32]()) { result, item in
                    if case .color(let slot) = item { result[slot] = plan.backup.keyColors[Int(slot)] }
                }
                if !colors.isEmpty {
                    _ = try setKeyColors(device, changes: colors, previous: observed.keyColors) { fraction in
                        progress((Double(verified) + Double(colors.count) * fraction) / Double(selection.count))
                    }
                    verified += colors.count
                }
                if selection.contains(.activeProfile) {
                    attemptedProfileChange = true
                    _ = try selectProfile(device, profile: plan.backup.activeProfile)
                    advance(1)
                }
            } catch {
                var cause: any Error = error
                if attemptedProfileChange {
                    do { try recoverProfile(device, profile: observed.activeProfile) }
                    catch { cause = error }
                }
                throw SnapshotRestoreFailure(verifiedCount: verified, cause: cause)
            }
        }
    }
}
