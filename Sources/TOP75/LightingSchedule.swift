import Foundation
import Observation

struct LightingSchedule: Codable, Equatable, Sendable {
    var enabled = false
    var start = 23 * 60
    var end = 8 * 60

    var isValid: Bool { (0..<1440).contains(start) && (0..<1440).contains(end) && start != end }

    func interval(at date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard enabled, isValid else { return nil }
        let today = calendar.startOfDay(for: date)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        for day in [today, yesterday] {
            let endDay = start > end ? calendar.date(byAdding: .day, value: 1, to: day) : day
            guard let endDay, let begins = time(start, day: day, calendar: calendar),
                  let ends = time(end, day: endDay, calendar: calendar),
                  begins <= date, date < ends else { continue }
            return DateInterval(start: begins, end: ends)
        }
        return nil
    }

    private func time(_ minutes: Int, day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }
}

@MainActor
@Observable
final class LightingScheduler {
    static let shared = LightingScheduler()

    struct SavedLighting: Codable, Equatable, Sendable {
        let identifier: String
        let connection: KeyboardConnection
        let lighting: Lighting
        var applied = false
        var expected: Lighting? = nil
        var pending: Lighting? = nil
    }

    var schedule: LightingSchedule {
        didSet {
            if schedule != oldValue { skipUntil = nil }
            save(schedule, key: "lightingSchedule")
            scheduleChanged()
        }
    }
    enum BatteryAction: String, CaseIterable {
        case off, dim, dark
    }

    var batteryAction = BatteryAction(rawValue: UserDefaults.standard.string(forKey: "batteryLightingAction") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(batteryAction.rawValue, forKey: "batteryLightingAction")
            batteryOverride = false
            scheduleChanged()
        }
    }
    var batteryThreshold = (UserDefaults.standard.object(forKey: "batteryLightingThreshold") as? Int) ?? 20 {
        didSet {
            UserDefaults.standard.set(batteryThreshold, forKey: "batteryLightingThreshold")
            batteryOverride = false
            scheduleChanged()
        }
    }
    private(set) var batterySaving = false
    private(set) var status = "Zamanlama kapalı"
    private(set) var revision = 0
    private(set) var canSkip = false
    @ObservationIgnored private var saved: SavedLighting? {
        didSet { save(saved, key: "scheduledPreviousLighting") }
    }
    @ObservationIgnored private var skipUntil: Date? {
        didSet { UserDefaults.standard.set(skipUntil, forKey: "lightingScheduleSkipUntil") }
    }
    @ObservationIgnored private var batteryOverride = false
    @ObservationIgnored private var batteryLow = false
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var checked: Mode?

    private init() {
        let defaults = UserDefaults.standard
        schedule = Self.read(LightingSchedule.self, key: "lightingSchedule") ?? LightingSchedule()
        saved = Self.read(SavedLighting.self, key: "scheduledPreviousLighting")
        skipUntil = defaults.object(forKey: "lightingScheduleSkipUntil") as? Date
    }

    func start() {
        guard monitoring == nil else { return }
        monitoring = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func skipCurrentInterval() {
        guard let interval = schedule.interval(at: .now) else { return }
        skipUntil = interval.end
        scheduleChanged()
    }

    func manualLightingChanged() {
        if let interval = schedule.interval(at: .now) { skipUntil = interval.end }
        batteryOverride = batteryLow
        batterySaving = false
        saved = nil
        checked = nil
        canSkip = false
    }

    func quickToggle(connection: KeyboardConnection, power: Bool? = nil) async throws {
        guard !busy else { throw KeyboardError.mismatch }
        busy = true
        defer { busy = false }
        let automatic = saved
        try await Task.detached {
            try Keyboard.withDevice(connection: connection) { device in
                let current = try Keyboard.readLighting(device)
                if let power, power == (current.effect != 0) { return }
                let key = "quickPreviousLighting-" + device.deviceIdentifier
                let defaults = UserDefaults.standard
                if current.effect == 0 {
                    let previous = automatic.flatMap { $0.identifier == device.deviceIdentifier ? $0.lighting : nil }
                        ?? defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Lighting.self, from: $0) }
                    let target = previous ?? Lighting(effect: 1, speed: 0, brightness: 2, flags: 7, rgb: 0x739BFF)
                    _ = try Keyboard.apply(device, lighting: target, replacing: current)
                } else {
                    defaults.set(try JSONEncoder().encode(current), forKey: key)
                    _ = try Keyboard.apply(device, lighting: Self.off, replacing: current)
                }
            }
        }.value
        manualLightingChanged()
        revision += 1
    }

    nonisolated private static let off = Lighting(effect: 0, speed: 0, brightness: 0, flags: 7, rgb: 0)

    enum Mode: Equatable, Sendable {
        case quiet, dim, dark

        func target(from current: Lighting) -> Lighting {
            guard current.effect != 0 else { return current }
            if self != .dim { return LightingScheduler.off }
            // Per-key colors have no known brightness setting on this firmware.
            if current.effect == 66 { return LightingScheduler.off }
            var target = current
            target.brightness = 0
            return target
        }
    }

    private func scheduleChanged() {
        checked = nil
        Task { await refresh() }
    }

    private func refresh() async {
        guard !busy, !WorkspaceTransfer.shared.isBusy else { return }
        let now = Date.now
        let interval = schedule.interval(at: now)
        if let skipUntil, skipUntil <= now { self.skipUntil = nil }
        let quiet = interval != nil && skipUntil == nil
        canSkip = quiet

        if let percent = BatteryMonitor.shared.percent {
            if percent <= batteryThreshold { batteryLow = true }
            if percent >= batteryThreshold + 5 {
                batteryLow = false
                batteryOverride = false
            }
        }
        let savesBattery = batteryAction != .off && batteryLow && !batteryOverride
        // Keep a verified restriction in place while the battery source is temporarily unavailable.
        let hasBatteryEvidence = BatteryMonitor.shared.percent != nil || batterySaving
        let mode: Mode? = quiet ? .quiet : savesBattery && hasBatteryEvidence
            ? (batteryAction == .dim ? .dim : .dark) : nil
        status = quiet ? "Işık kapatma aralığı etkin" : interval != nil ? "Bu aralık atlandı"
            : schedule.enabled ? (schedule.isValid ? "Sonraki aralık bekleniyor" : "Başlangıç ve bitiş farklı olmalı")
            : "Zamanlama kapalı"
        guard mode != nil || saved != nil else {
            checked = nil
            batterySaving = false
            return
        }
        let connection = saved?.connection ?? Keyboard.availableConnection()
        guard let connection, Keyboard.isAvailable(connection) else {
            status = saved == nil ? "Klavye bağlantısı bekleniyor" : "Önceki klavye bağlantısı bekleniyor"
            checked = nil
            return
        }
        if let mode, checked == mode { return }

        busy = true
        defer { busy = false }
        do {
            if let mode {
                try await restrict(connection, mode: mode)
                batterySaving = mode != .quiet
            } else if let previous = saved {
                try await restore(previous)
                batterySaving = false
            }
        } catch {
            status = "Zamanlama için klavye yanıtı bekleniyor"
        }
    }

    private func restrict(_ connection: KeyboardConnection, mode: Mode) async throws {
        if saved == nil {
            let previous = try await Task.detached {
                try Keyboard.withDevice(connection: connection) { device in
                    SavedLighting(identifier: device.deviceIdentifier, connection: connection,
                                  lighting: try Keyboard.readLighting(device))
                }
            }.value
            let target = mode.target(from: previous.lighting)
            if previous.lighting.matches(target) {
                checked = mode
                return
            }
            saved = previous
        }
        guard let previous = saved else { return }
        let target = mode.target(from: previous.lighting)
        // Keep both the last applied state and the pending target recoverable across interruptions.
        let expected = previous.expected ?? (previous.applied ? Self.off : previous.lighting)
        saved?.pending = target
        let changed = try await Task.detached {
            try Keyboard.withDevice(connection: connection) { device in
                guard device.deviceIdentifier == previous.identifier else { throw KeyboardError.mismatch }
                let actual = try Keyboard.readLighting(device)
                if actual.matches(target) { return false }
                guard actual.matches(expected) || previous.pending.map(actual.matches) == true else { throw KeyboardError.mismatch }
                _ = try Keyboard.apply(device, lighting: target, replacing: actual)
                return true
            }
        }.value
        if saved?.identifier == previous.identifier, saved?.pending == target {
            saved?.applied = true
            saved?.expected = target
            saved?.pending = nil
            checked = mode
        }
        if changed { revision += 1 }
    }

    private func restore(_ previous: SavedLighting) async throws {
        let expected = previous.expected ?? (previous.applied ? Self.off : previous.lighting)
        let changed = try await Task.detached {
            try Keyboard.withDevice(connection: previous.connection) { device in
                guard device.deviceIdentifier == previous.identifier else { throw KeyboardError.mismatch }
                let actual = try Keyboard.readLighting(device)
                guard actual.matches(expected) || previous.pending.map(actual.matches) == true,
                      !actual.matches(previous.lighting) else { return false }
                _ = try Keyboard.apply(device, lighting: previous.lighting, replacing: actual)
                return true
            }
        }.value
        if saved == previous { saved = nil }
        checked = nil
        if changed { revision += 1 }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
