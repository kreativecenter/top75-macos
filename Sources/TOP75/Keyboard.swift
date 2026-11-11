import Foundation
import IOKit.hid

enum KeyboardError: LocalizedError {
    case missing, wrongDevice(UInt32), transport(String, IOReturn), invalidReply, mismatch

    var errorDescription: String? {
        switch self {
        case .missing: "TOP75’in USB ayar arayüzü bulunamadı. Klavyeyi veri kablosuyla bağlayıp mod anahtarını OFF konumuna al."
        case .wrongDevice(let id): "Cihaz kimliği eşleşmedi (\(id))."
        case .transport(let operation, let code): "\(operation) başarısız (\(String(format: "0x%08X", UInt32(bitPattern: code))))."
        case .invalidReply: "Klavyeden beklenen ayar yanıtı gelmedi."
        case .mismatch: "Klavye, gönderilen ayarla eşleşen bir yanıt döndürmedi."
        }
    }
}

struct Lighting: Codable, Sendable, Equatable {
    var effect: UInt8
    var speed: UInt8
    var brightness: UInt8
    var flags: UInt8
    var rgb: UInt32

    var report: [UInt8] {
        let color = rgb == 0xFFFFFF ? 0xFAFFFA : rgb
        return Keyboard.report([
            0x07, effect, 4 - min(speed, 4), min(brightness, 4), flags,
            UInt8(truncatingIfNeeded: color >> 16),
            UInt8(truncatingIfNeeded: color >> 8),
            UInt8(truncatingIfNeeded: color)
        ], checksumIndex: 8)
    }

    init(effect: UInt8, speed: UInt8, brightness: UInt8, flags: UInt8, rgb: UInt32) {
        self.effect = effect
        self.speed = speed
        self.brightness = brightness
        self.flags = flags
        self.rgb = rgb
    }

    init(reply: [UInt8]) throws {
        guard reply.count == 64, reply[0] == 0x87 else { throw KeyboardError.invalidReply }
        effect = reply[1]
        speed = 4 - min(reply[2], 4)
        brightness = reply[3]
        flags = reply[4]
        let color = UInt32(reply[5]) << 16 | UInt32(reply[6]) << 8 | UInt32(reply[7])
        rgb = color == 0xFAFFFA ? 0xFFFFFF : color
    }

    func matches(_ requested: Lighting) -> Bool {
        guard effect == requested.effect else { return false }
        if effect == 0 || effect == 66 { return true }
        guard brightness == requested.brightness, flags == requested.flags else { return false }
        return (effect == 3 || (flags & 0x0F) != 7 || rgb == requested.rgb)
            && (effect == 1 || speed == requested.speed)
    }
}

enum Keyboard {
    private static let lock = NSLock()
    static func report(_ bytes: [UInt8], checksumIndex: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 64)
        result.replaceSubrange(bytes.indices, with: bytes)
        result[checksumIndex] = ~result.prefix(checksumIndex).reduce(0, &+)
        return result
    }

    static func lighting() throws -> Lighting {
        try withDevice { try readLighting($0) }
    }

    static func apply(_ lighting: Lighting) throws -> Lighting {
        try withDevice { device in
            try send(device, lighting.report)
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.25)
                let current = try readLighting(device)

                if current.matches(lighting) { return current }
            }
            throw KeyboardError.mismatch
        }
    }

    static func profile() throws -> UInt8 {
        try withDevice { try readProfile($0) }
    }

    static func selectProfile(_ profile: UInt8) throws -> UInt8 {
        guard profile < 3 else { throw KeyboardError.invalidReply }
        return try withDevice { device in
            try send(device, report([0x05, profile], checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.25)
            let current = try readProfile(device)
            guard current == profile else { throw KeyboardError.mismatch }
            return current
        }
    }

    static func readProfile(_ device: IOHIDDevice) throws -> UInt8 {
        let profile = try request(device, opcode: 0x85)[1]
        guard profile < 3 else { throw KeyboardError.invalidReply }
        return profile
    }

    static func keyBinding(slot: UInt8, expectedProfile: UInt8, fn: Bool = false) throws -> [UInt8] {
        try withDevice { device in
            let profile = try readProfile(device)
            guard profile == expectedProfile else { throw KeyboardError.mismatch }
            return try readKey(device, profile: profile, slot: slot, fn: fn)
        }
    }

    static func assignKey(slot: UInt8, binding: [UInt8], expectedProfile: UInt8, previousBinding: [UInt8], fn: Bool = false) throws -> [UInt8] {
        guard slot < 128, binding.count == 4 else { throw KeyboardError.invalidReply }
        return try withDevice { device in
            let profile = try readProfile(device)
            guard profile == expectedProfile,
                  try readKey(device, profile: profile, slot: slot, fn: fn) == previousBinding
            else { throw KeyboardError.mismatch }
            try send(device, report([fn ? 0x15 : 0x13, profile, slot, 0, 0, 0, 0, 0] + binding, checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.25)
            let current = try readKey(device, profile: profile, slot: slot, fn: fn)
            guard current == binding else { throw KeyboardError.mismatch }
            return current
        }
    }

    private static func readKey(_ device: IOHIDDevice, profile: UInt8, slot: UInt8, fn: Bool) throws -> [UInt8] {
        guard slot < 128 else { throw KeyboardError.invalidReply }
        let reply = try request(device, opcode: fn ? 0x90 : 0x89, parameters: [profile, slot / 16], checkEcho: false)
        guard !reply.allSatisfy({ $0 == 0xFF }) else { throw KeyboardError.invalidReply }
        let offset = Int(slot % 16) * 4
        return Array(reply[offset..<(offset + 4)])
    }

    static func withDevice<T>(_ operation: (IOHIDDevice) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x4015,
            kIOHIDPrimaryUsagePageKey: 0xFFFF, kIOHIDPrimaryUsageKey: 2,
            kIOHIDTransportKey: "USB"
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              devices.count == 1, let device = devices.first else { throw KeyboardError.missing }
        let status = IOHIDDeviceOpen(device, 0)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("USB erişimi", status) }
        defer { IOHIDDeviceClose(device, 0) }
        let identity = try request(device, opcode: 0x8F)
        let id = identity[1...4].enumerated().reduce(UInt32(0)) { id, byte in
            id | UInt32(byte.element) << (8 * byte.offset)
        }
        guard id == 957 else { throw KeyboardError.wrongDevice(id) }
        return try operation(device)
    }

    static func readLighting(_ device: IOHIDDevice) throws -> Lighting {
        try Lighting(reply: request(device, opcode: 0x87))
    }

    static func send(_ device: IOHIDDevice, _ bytes: [UInt8]) throws {
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, bytes, bytes.count)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("Komut gönderme", status) }
    }

    static func request(_ device: IOHIDDevice, opcode: UInt8, parameters: [UInt8] = [], checkEcho: Bool = true, delay: TimeInterval = 0.04) throws -> [UInt8] {
        try send(device, report([opcode] + parameters, checksumIndex: 7))
        Thread.sleep(forTimeInterval: delay)
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = bytes.count
        let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &bytes, &length)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("Ayar okuma", status) }
        guard length == bytes.count, !checkEcho || bytes.first == opcode else { throw KeyboardError.invalidReply }
        return bytes
    }
}
