import Foundation
import IOKit.hid

struct DeviceOptions: Codable, Equatable, Sendable {
    var debounce: UInt8
    var automaticOS: Bool
    var timers: [UInt16]

    var isValid: Bool {
        debounce <= 10 && timers.count == 4 && timers.allSatisfy { $0 <= 3600 }
    }
}

extension Keyboard {
    static func options() throws -> DeviceOptions {
        try withDevice { try readOptions($0) }
    }

    static func updateOptions(_ desired: DeviceOptions, previous: DeviceOptions) throws -> DeviceOptions {
        try withDevice { try updateOptions($0, desired: desired, previous: previous) }
    }

    static func updateOptions(_ device: IOHIDDevice, desired: DeviceOptions, previous: DeviceOptions) throws -> DeviceOptions {
        guard desired.isValid else { throw KeyboardError.invalidReply }
        guard try readOptions(device) == previous else { throw KeyboardError.mismatch }
        if desired.debounce != previous.debounce {
            try send(device, report([0x11, 0, desired.debounce], checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.5)
        }
        if desired.automaticOS != previous.automaticOS {
            try send(device, report([0x17, desired.automaticOS ? 1 : 0], checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.5)
        }
        if desired.timers != previous.timers {
            let timers = desired.timers.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
            try send(device, report([0x12, 0, 0, 0, 0, 0, 0, 0] + timers, checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.5)
        }
        let current = try readOptions(device)
        guard current == desired else { throw KeyboardError.mismatch }
        return current
    }

    static func readOptions(_ device: IOHIDDevice) throws -> DeviceOptions {
        let debounce = try request(device, opcode: 0x91)[2]
        let automaticOS = try request(device, opcode: 0x97)[1] != 0
        let reply = try request(device, opcode: 0x92)
        let timers = stride(from: 1, to: 9, by: 2).map { UInt16(reply[$0]) | UInt16(reply[$0 + 1]) << 8 }
        return DeviceOptions(debounce: debounce, automaticOS: automaticOS, timers: timers)
    }

    static func keyColors() throws -> [UInt32] {
        try withDevice { try readKeyColors($0) }
    }

    static func setKeyColors(_ changes: [UInt8: UInt32], previous: [UInt32]) throws -> [UInt32] {
        try withDevice { try setKeyColors($0, changes: changes, previous: previous) }
    }

    static func setKeyColors(_ device: IOHIDDevice, changes: [UInt8: UInt32], previous: [UInt32]) throws -> [UInt32] {
        guard previous.count == 128, changes.allSatisfy({ $0.key < 128 && $0.value <= 0xFFFFFF })
        else { throw KeyboardError.invalidReply }
        let observed = try readKeyColors(device)
        guard changes.keys.allSatisfy({ observed[Int($0)] == previous[Int($0)] }) else {
            throw KeyboardError.mismatch
        }
        for (slot, rgb) in changes.sorted(by: { $0.key < $1.key }) where observed[Int(slot)] != rgb {
            let bytes = [UInt8(rgb >> 16), UInt8(truncatingIfNeeded: rgb >> 8), UInt8(truncatingIfNeeded: rgb)]
            try send(device, report([0x14, 0, slot, 0, 0, 0, 0, 0] + bytes, checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.25)
        }
        let current = try readKeyColors(device)
        guard changes.allSatisfy({ current[Int($0.key)] == $0.value }) else { throw KeyboardError.mismatch }
        return current
    }

    static func readKeyColors(_ device: IOHIDDevice) throws -> [UInt32] {
        let bytes = try readPages(device, opcode: 0x8C, index: 0, count: 6)
        return stride(from: 0, to: bytes.count, by: 3).map {
            UInt32(bytes[$0]) << 16 | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2])
        }
    }

    static func macro(slot: UInt8) throws -> [UInt8] {
        guard slot < 50 else { throw KeyboardError.invalidReply }
        return try withDevice { try readPages($0, opcode: 0x8B, index: slot, count: 4) }
    }

    static func setMacro(slot: UInt8, bytes: [UInt8], previous: [UInt8]) throws -> [UInt8] {
        guard slot < 50, bytes.count == 256, bytes.suffix(34).allSatisfy({ $0 == 0 }) else { throw KeyboardError.invalidReply }
        let requiredBytes = try Macro.writeLength(bytes)
        return try withDevice { device in
            guard try readPages(device, opcode: 0x8B, index: slot, count: 4) == previous else {
                throw KeyboardError.mismatch
            }
            // Include the terminator even when the final event ends on a page boundary.
            let pageCount = (requiredBytes + 55) / 56
            let expected = bytes.prefix(requiredBytes)
            for _ in 0..<2 {
                for page in 0..<pageCount {
                    let start = 56 * page
                    let payload = Array(bytes[start..<start + 56])
                    let header: [UInt8] = [0x16, slot, UInt8(page), 56, page == pageCount - 1 ? 1 : 0, 0, 0, 0]
                    try send(device, report(header + payload, checksumIndex: 7))
                    // This TOP75 ignored multi-page macros at a 40 ms interval.
                    Thread.sleep(forTimeInterval: 0.15)
                }
                Thread.sleep(forTimeInterval: 0.70)
                var current = try readPages(device, opcode: 0x8B, index: slot, count: 4)
                for _ in 0..<2 where current.prefix(requiredBytes) != expected {
                    Thread.sleep(forTimeInterval: 0.20)
                    current = try readPages(device, opcode: 0x8B, index: slot, count: 4)
                }
                if current.prefix(requiredBytes) == expected { return current }
                // Retry only if the slot still contains the original data.
                guard current == previous else { throw KeyboardError.mismatch }
            }
            throw KeyboardError.mismatch
        }
    }

    private static func readPages(_ device: IOHIDDevice, opcode: UInt8, index: UInt8, count: UInt8) throws -> [UInt8] {
        try (0..<count).flatMap { page in
            try request(device, opcode: opcode, parameters: [index, page], checkEcho: false)
        }
    }
}


struct SettingsSnapshot: Codable, Sendable {
    struct Profile: Codable, Sendable {
        let base: [[UInt8]]
        let function: [[UInt8]]
    }

    static let model = "Darmoshark TOP75 (957)"
    let formatVersion: Int
    let device: String
    let recordedAt: Date
    let activeProfile: UInt8
    let firmware: UInt16
    let lighting: Lighting
    let options: DeviceOptions
    let keyColors: [UInt32]
    let profiles: [Profile]

    enum CodingKeys: String, CodingKey {
        case formatVersion, device, recordedAt, activeProfile, firmware, lighting, options, keyColors, profiles
    }
}

extension Keyboard {
    static func settingsSnapshot() throws -> Data {
        let snapshot = try withDevice { try readSnapshot($0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func snapshot() throws -> SettingsSnapshot {
        try withDevice { try readSnapshot($0) }
    }

    static func readSnapshot(_ device: IOHIDDevice) throws -> SettingsSnapshot {
        let active = try readProfile(device)
        let version = try request(device, opcode: 0x80)
        let profiles: [SettingsSnapshot.Profile] = try (UInt8(0)...2).map { index in
            let base = try readPages(device, opcode: 0x89, index: index, count: 8)
            let function = try readPages(device, opcode: 0x90, index: index, count: 8)
            return SettingsSnapshot.Profile(base: bindings(base), function: bindings(function))
        }
        let snapshot = SettingsSnapshot(
            formatVersion: 1, device: SettingsSnapshot.model, recordedAt: Date(), activeProfile: active,
            firmware: UInt16(version[1]) | UInt16(version[2]) << 8,
            lighting: try readLighting(device), options: try readOptions(device),
            keyColors: try readKeyColors(device), profiles: profiles
        )
        guard try readProfile(device) == active else { throw KeyboardError.mismatch }
        return snapshot
    }

    private static func bindings(_ bytes: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<$0 + 4]) }
    }
}
