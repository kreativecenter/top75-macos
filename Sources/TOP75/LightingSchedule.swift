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
    }

    var schedule: LightingSchedule {
        didSet {
            if schedule != oldValue { skipUntil = nil }
            save(schedule, key: "lightingSchedule")
            scheduleChanged()
        }
    }
    private(set) var status = "Zamanlama kapalı"
    private(set) var revision = 0
    private(set) var canSkip = false
    @ObservationIgnored private var saved: SavedLighting? {
        didSet { save(saved, key: "scheduledPreviousLighting") }
    }
    @ObservationIgnored private var skipUntil: Date? {
        didSet { UserDefaults.standard.set(skipUntil, forKey: "lightingScheduleSkipUntil") }
    }
    @ObservationIgnored private var checkedInterval: Date?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var busy = false

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
        guard let interval = schedule.interval(at: .now) else { return }
        skipUntil = interval.end
        saved = nil
        status = "Bu aralık atlandı"
        canSkip = false
    }

    private func scheduleChanged() {
        checkedInterval = nil
        Task { await refresh() }
    }

    private func refresh() async {
        guard !busy, !WorkspaceTransfer.shared.isBusy else { return }
        let now = Date.now
        let interval = schedule.interval(at: now)
        if let skipUntil, skipUntil <= now { self.skipUntil = nil }
        let quiet = interval != nil && skipUntil == nil
        canSkip = quiet

        if !quiet && saved == nil {
            status = interval != nil ? "Bu aralık atlandı" : schedule.enabled
                ? (schedule.isValid ? "Sonraki aralık bekleniyor" : "Başlangıç ve bitiş farklı olmalı")
                : "Zamanlama kapalı"
            return
        }

        let available: KeyboardConnection?
        if let saved {
            available = Keyboard.isAvailable(saved.connection) ? saved.connection : nil
        } else {
            available = Keyboard.availableConnection()
        }
        guard let connection = available else {
            status = saved == nil ? "Klavye bağlantısı bekleniyor" : "Önceki klavye bağlantısı bekleniyor"
            checkedInterval = nil
            return
        }
        if quiet && (saved?.applied == true || checkedInterval == interval?.start) {
            status = "Işık kapatma aralığı etkin"
            return
        }

        busy = true
        defer { busy = false }
        do {
            if quiet, let interval {
                try await dim(connection, interval: interval)
            } else if let previous = saved {
                try await restore(previous)
                status = interval != nil ? "Bu aralık atlandı" : schedule.enabled
                    ? "Sonraki aralık bekleniyor" : "Zamanlama kapalı"
            }
        } catch {
            status = "Zamanlama için klavye yanıtı bekleniyor"
        }
    }

    private func dim(_ connection: KeyboardConnection, interval: DateInterval) async throws {
        if saved == nil {
            let previous = try await Task.detached {
                try Keyboard.withDevice(connection: connection) { device in
                    SavedLighting(identifier: device.deviceIdentifier, connection: connection,
                                  lighting: try Keyboard.readLighting(device))
                }
            }.value
            guard schedule.interval(at: .now)?.start == interval.start, skipUntil == nil else { return }
            if previous.lighting.effect == 0 {
                checkedInterval = interval.start
                status = "Işık kapatma aralığı etkin"
                return
            }
            // Save before sending the command so a restart can restore the previous effect.
            saved = previous
        }
        guard let previous = saved else { return }
        let changed = try await Task.detached {
            try Keyboard.withDevice(connection: connection) { device in
                guard device.deviceIdentifier == previous.identifier else { throw KeyboardError.mismatch }
                let actual = try Keyboard.readLighting(device)
                if actual.effect == 0 { return false }
                guard actual.matches(previous.lighting) else { throw KeyboardError.mismatch }
                let off = Lighting(effect: 0, speed: 0, brightness: 0, flags: 7, rgb: 0)
                _ = try Keyboard.apply(device, lighting: off, replacing: actual)
                return true
            }
        }.value
        if saved == previous {
            saved?.applied = true
            status = "Işık kapatma aralığı etkin"
        }
        if changed { revision += 1 }
    }

    private func restore(_ previous: SavedLighting) async throws {
        let changed = try await Task.detached {
            try Keyboard.withDevice(connection: previous.connection) { device in
                guard device.deviceIdentifier == previous.identifier else { throw KeyboardError.mismatch }
                let actual = try Keyboard.readLighting(device)
                guard actual.effect == 0 else { return false }
                _ = try Keyboard.apply(device, lighting: previous.lighting, replacing: actual)
                return true
            }
        }.value
        if saved == previous { saved = nil }
        checkedInterval = nil
        if changed { revision += 1 }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
