import Foundation
import ImageIO

enum Verification {
    static func verifyBluetoothKeyboard() {
        let identity = Keyboard.report([0x8F], checksumIndex: 7)
        let packet = BluetoothKeyboard.packet(for: identity)
        precondition(packet.count == 66 && Array(packet.prefix(3)) == [6, 0x55, 0x8F] && packet[9] == 0x70)
        precondition(packet.withUnsafeBufferPointer { BluetoothKeyboard.payload(report: $0, id: 6) } == identity)
        precondition(packet.withUnsafeBufferPointer { BluetoothKeyboard.payload(report: $0, id: 1) } == nil)
        var event = packet
        event[1] = 0x66
        precondition(event.withUnsafeBufferPointer { BluetoothKeyboard.payload(report: $0, id: 6) } == nil)
    }

    static func verifyLightingSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        var schedule = LightingSchedule(enabled: true, start: 23 * 60, end: 8 * 60)
        let overnight = DateInterval(start: date(11, 23), end: date(12, 8))
        precondition(schedule.interval(at: date(11, 22, 59), calendar: calendar) == nil)
        precondition(schedule.interval(at: date(11, 23), calendar: calendar) == overnight)
        precondition(schedule.interval(at: date(12, 7, 59), calendar: calendar) == overnight)
        precondition(schedule.interval(at: date(12, 8), calendar: calendar) == nil)
        schedule.start = 7 * 60
        precondition(schedule.interval(at: date(12, 7), calendar: calendar)?.end == date(12, 8))
        schedule.end = schedule.start
        precondition(schedule.interval(at: date(12, 7), calendar: calendar) == nil)
        schedule.end += 60
        schedule.enabled = false
        precondition(schedule.interval(at: date(12, 7), calendar: calendar) == nil)
    }

    static func verifyRestore() throws {
        let blank = Array(repeating: [UInt8](repeating: 0, count: 4), count: 128)
        let lighting = Lighting(effect: 1, speed: 2, brightness: 3, flags: 7, rgb: 0x10A0FF)
        let options = DeviceOptions(debounce: 2, automaticOS: false, timers: [60, 60, 120, 120])
        let profiles = Array(repeating: SettingsSnapshot.Profile(base: blank, function: blank), count: 3)
        let colors = Array(repeating: UInt32(0), count: 128)
        let current = SettingsSnapshot(
            formatVersion: 2, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 0, firmware: 123, lighting: lighting, options: options, keyColors: colors, profiles: profiles
        )
        var changedOptions = options
        changedOptions.debounce = 4
        changedOptions.timers[2] = 240
        var changedColors = colors
        changedColors[9] = 0xFF00FF
        var fn = blank
        fn[78] = [3, 0, 233, 0]
        var changedProfiles = profiles
        changedProfiles[2] = .init(base: blank, function: fn)
        let backup = SettingsSnapshot(
            formatVersion: 2, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 1, firmware: 123, lighting: lighting, options: changedOptions,
            keyColors: changedColors, profiles: changedProfiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let parsed = try SettingsSnapshot.decode(data)
        let plan = try SnapshotRestorePlan(current: current, backup: parsed)
        precondition(Set(plan.changes) == [.debounce, .timer(2), .color(9), .key(profile: 2, fn: true, slot: 78), .activeProfile])
        let selected = plan.selectedOptions([.timer(2)], from: current.options)
        precondition(selected.debounce == 2 && selected.timers == [60, 60, 240, 120])
        let sharedCurrent = SettingsSnapshot(
            formatVersion: 2, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 0, firmware: 274, lighting: lighting, options: options, keyColors: colors, profiles: profiles
        )
        changedProfiles[1] = changedProfiles[2]
        let sharedBackup = SettingsSnapshot(
            formatVersion: 2, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 0, firmware: 274, lighting: lighting, options: options, keyColors: colors, profiles: changedProfiles
        )
        let sharedPlan = try SnapshotRestorePlan(current: sharedCurrent, backup: SettingsSnapshot.decode(encoder.encode(sharedBackup)))
        precondition(sharedPlan.changes == [.sharedFn(slot: 78)])
        let legacy = SettingsSnapshot(
            formatVersion: 1, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 2, firmware: 274, lighting: lighting, options: options, keyColors: colors,
            profiles: [changedProfiles[2], profiles[1], profiles[2]]
        )
        let legacyPlan = try SnapshotRestorePlan(current: sharedCurrent, backup: SettingsSnapshot.decode(encoder.encode(legacy)))
        precondition(Set(legacyPlan.changes) == [.activeProfile, .sharedFn(slot: 78)])
        var invalid = data
        let modelRange = invalid.range(of: Data(SettingsSnapshot.model.utf8))!
        invalid.replaceSubrange(modelRange, with: "Another keyboard".utf8)
        precondition((try? SettingsSnapshot.decode(invalid)) == nil)
    }

    static func verifyArtwork() throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil)!
        let canvas = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for (red, delay) in [(true, 0.08), (false, 0.12)] {
            canvas.setFillColor(red: red ? 1 : 0, green: red ? 0 : 1, blue: 0, alpha: 1)
            canvas.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            let options = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(destination, canvas.makeImage()!, options as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        let fit = try ScreenArtwork(data: data as Data, sizing: .fit)
        let crop = try ScreenArtwork(data: data as Data, sizing: .crop)
        precondition(fit.frames.count == 2 && fit.delay == 100 && crop.delay == 100)
        precondition(crop.previews.allSatisfy { $0.width == 128 && $0.height == 128 })
        precondition(fit.frames[0].prefix(2) == [0, 0])
        precondition(crop.frames[0].prefix(2) == [0xF8, 0] && crop.frames[1].prefix(2) == [0x07, 0xE0])
        let pixels = crop.previews[0].dataProvider!.data! as Data
        precondition(pixels.prefix(4) == Data([255, 0, 0, 255]))
    }
}
