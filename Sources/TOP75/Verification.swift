import CoreServices
import Foundation
import ImageIO

enum Verification {
    @MainActor
    static func verifySystemQuit() {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEQuitApplication, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        precondition(!TOP75AppDelegate.isSystemQuit(nil))
        precondition(!TOP75AppDelegate.isSystemQuit(event))
        event.setParam(NSAppleEventDescriptor(enumCode: kAEQuitAll), forKeyword: kAEQuitReason)
        precondition(!TOP75AppDelegate.isSystemQuit(event))
        for reason in [kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut] {
            event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: kAEQuitReason)
            precondition(TOP75AppDelegate.isSystemQuit(event))
        }
    }

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

    static func verifyBluetoothBattery() {
        let report = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=42) 80%; AC attached
         -TOP75 BT5.0  (id=87)\t23%;
         -TOP75 BT3.0 (id=88) 38%;
        """
        precondition(BluetoothBattery.percent(in: report) == 23)
        precondition(BluetoothBattery.percent(in: "-TOP75 BT5.0 (id=87) 0%;") == 0)
        precondition(BluetoothBattery.percent(in: "-TOP75 BT5.0 (id=87) 101%;") == nil)
        precondition(BluetoothBattery.percent(in: "-Other TOP75 BT5.0 (id=87) 25%;") == nil)
        precondition(BluetoothBattery.percent(in: report + "\n-TOP75 BT5.0 (id=89) 52%;") == nil)
    }

    static func verifyReceiverBattery() {
        var reply: [UInt8] = [0, 3, 0, 0, 1, 1, 1, 0x70]
        reply += Array(repeating: 0, count: 56)
        precondition(ReceiverKeyboard.Status(reply: reply)?.percent == 3)
        reply[3] = 1
        precondition(ReceiverKeyboard.Status(reply: reply)?.online == false)
        precondition(ReceiverKeyboard.Status(reply: reply)?.percent == nil)
        reply[3] = 0
        for invalid: UInt8 in [0, 101, 255] {
            reply[1] = invalid
            precondition(ReceiverKeyboard.Status(reply: reply)?.percent == nil)
        }
        precondition(ReceiverKeyboard.Status(reply: Array(reply.prefix(8))) == nil)
        reply[6] = 0
        precondition(ReceiverKeyboard.Status(reply: reply) == nil)

        var warning = LowBatteryWarning(notified: false)
        precondition(warning.shouldNotify(percent: 20))
        warning.didNotify()
        precondition(!warning.shouldNotify(percent: 3))
        precondition(!warning.shouldNotify(percent: 23))
        precondition(!warning.shouldNotify(percent: 20))
        precondition(!warning.shouldNotify(percent: 25))
        precondition(warning.shouldNotify(percent: 20))
    }

    static func verifyLightingSchedule() {
        let lighting = Lighting(effect: 4, speed: 3, brightness: 4, flags: 7, rgb: 0x234567)
        let dimmed = LightingScheduler.Mode.dim.target(from: lighting)
        precondition(dimmed.effect == lighting.effect && dimmed.rgb == lighting.rgb && dimmed.brightness == 0)
        precondition(LightingScheduler.Mode.quiet.target(from: dimmed).effect == 0)
        precondition(LightingScheduler.Mode.dark.target(from: dimmed).effect == 0)
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
        var currentWithMacros = current
        currentWithMacros.macros = [49: Data(repeating: 0, count: 256), 48: Data(repeating: 0, count: 256)]
        let tap = try Macro(repeats: 1, strokes: [
            .init(key: 4, down: true, delay: 35), .init(key: 4, down: false, delay: 35)
        ]).encoded()
        var unsupported = tap
        unsupported[2] = 0xF9
        let macroBackup = SettingsSnapshot(
            formatVersion: 3, device: SettingsSnapshot.model, recordedAt: Date(),
            activeProfile: 0, firmware: 123, lighting: lighting, options: options,
            keyColors: colors, profiles: profiles, macros: [49: Data(tap), 48: Data(unsupported)]
        )
        let parsedMacros = try SettingsSnapshot.decode(encoder.encode(macroBackup))
        let macroPlan = try SnapshotRestorePlan(current: currentWithMacros, backup: parsedMacros)
        precondition(macroPlan.changes == [.macro(49)] && macroPlan.unsupportedMacros == [48])
        var invalidMacros = macroBackup
        invalidMacros.macros = [50: Data(tap)]
        precondition((try? SettingsSnapshot.decode(encoder.encode(invalidMacros))) == nil)
        var invalid = data
        let modelRange = invalid.range(of: Data(SettingsSnapshot.model.utf8))!
        invalid.replaceSubrange(modelRange, with: "Another keyboard".utf8)
        precondition((try? SettingsSnapshot.decode(invalid)) == nil)
    }

    static func verifyKeyboardTools() throws {
        var capture = MacroCapture()
        capture.add(4, down: true, time: 0, timing: true)
        capture.add(4, down: true, time: 0.1, timing: true)
        capture.add(225, down: true, time: 0.25, timing: true)
        let strokes = capture.balanced
        precondition(strokes.count == 4 && strokes[0].delay == 250 && !strokes[3].down)
        let encoded = try Macro(repeats: 1, strokes: strokes).encoded()
        let required = try Macro.writeLength(encoded)
        precondition(Macro.requiredBytes(strokes) == required)

        let settings = SettingsSnapshot.model
        let pages = Array(repeating: [UInt8](repeating: 0, count: 4), count: 128)
        let current = SettingsSnapshot(
            formatVersion: 2, device: settings, recordedAt: Date(), activeProfile: 2, firmware: 274,
            lighting: Lighting(effect: 1, speed: 0, brightness: 2, flags: 7, rgb: 0x739BFF),
            options: DeviceOptions(debounce: 0, automaticOS: false, timers: [0, 0, 0, 0]),
            keyColors: Array(repeating: 0, count: 128),
            profiles: Array(repeating: .init(base: pages, function: pages), count: 3)
        )
        let slot: UInt8 = 9
        let preset = SharedPreset(version: 1, device: settings, firmware: 274, payload: .keys(fn: true, bindings: [slot: KeyAssignment.key(6).bytes]))
        let decoded = try SharedPreset.decode(preset.encode())
        let plan = try SnapshotRestorePlan(current: current, backup: decoded.desired(from: current), presetScope: decoded.scope)
        precondition(plan.changes == [.sharedFn(slot: slot)])
        precondition(plan.backup.binding(profile: 2, fn: true, slot: slot) == KeyAssignment.key(6).bytes)
        precondition(plan.backup.binding(profile: 0, fn: true, slot: slot) == [0, 0, 0, 0])
        let invalid = SharedPreset(version: 1, device: settings, firmware: 274, payload: .keys(fn: false, bindings: [slot: KeyAssignment.macro(slot: 0, playback: 0).bytes]))
        precondition((try? invalid.encode()) == nil)

        let template = ScreenTemplate(kind: .pixel, background: 0, pixels: [0: 0xFF0000, 255: 0x0000FF])
        let art = try template.artwork()
        precondition(art.frames.count == 1 && art.delay == 0)
        precondition(art.frames[0].prefix(2) == [248, 0] && art.frames[0].suffix(2) == [0, 31])
        for kind: ScreenTemplate.Kind in [.name, .monogram] {
            let still = try ScreenTemplate(kind: kind, background: 0).artwork()
            precondition(still.frames[0].contains { $0 != 0 })
        }
    }

    static func verifyUsageLimits() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let codexJSON = Data("""
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
        "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":5000},
        "secondary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000}}}}}
        """.utf8)
        let codex = try CodexUsage.decode(codexJSON, now: now)
        precondition(codex.fiveHour?.usedPercentage == 25 && codex.weekly?.usedPercentage == 63)
        let claude = try ClaudeUsage.decode(Data("""
        {"five_hour":{"used_percentage":5,"resets_at":900},"seven_day":{"used_percentage":33.2,"resets_at":5000}}
        """.utf8), now: now)
        precondition(claude.fiveHour == nil && claude.weekly?.usedPercentage == 33.2)
        let used = UsageLCD(codex: codex, claude: claude)
        precondition(used.numbers == [25, 63, nil, 33])
        let card = UsageLCD(codex: codex, claude: claude, metric: .remaining)
        precondition(card.numbers == [75, 37, nil, 66])
        for (value, remaining) in [(99.0, 1), (100.0, 0)] {
            let window = UsageLimits.Window(value, reset: nil, now: now)
            precondition(UsageMetric.used.displayNumber(window) == Int(value))
            precondition(UsageMetric.remaining.displayNumber(window) == remaining)
        }
        let artwork = try card.artwork(turkish: true)
        precondition(artwork.previews.first?.width == 128 && artwork.frames.count == 1)
        precondition(Set(artwork.frames[0]).count > 20)
    }

    static func verifyUpdateCheck() throws {
        let installed = AppVersion("0.12.3")!
        precondition(AppVersion("v0.13.0")! > installed && AppVersion("0.12.10")! > AppVersion("0.12.9")!)
        precondition(AppVersion("0.13")! == AppVersion("v0.13.0")! && !(AppVersion("0.13")! < AppVersion("0.13.0")!))
        for invalid in ["", "v", "1.0.0-beta", "1..0", "0.13.x"] { precondition(AppVersion(invalid) == nil) }
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> UpdateChecker.GitHubRelease {
            try JSONDecoder().decode(UpdateChecker.GitHubRelease.self, from: Data("""
            {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),"html_url":"https://example.com"}
            """.utf8))
        }
        let newer = UpdateChecker.newer(try release("v0.13.0"), than: installed)
        precondition(newer?.page.absoluteString == "https://github.com/kreativecenter/top75-macos/releases/tag/v0.13.0")
        for skipped in [try release("v0.12.3"), try release("v0.12.2"),
                        try release("v0.14.0", prerelease: true), try release("v0.14.0", draft: true)] {
            precondition(UpdateChecker.newer(skipped, than: installed) == nil)
        }
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
