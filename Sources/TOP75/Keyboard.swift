import Foundation
import IOKit.hid

enum KeyboardError: LocalizedError {
    case missing, wrongDevice(UInt32), transport(String, IOReturn), invalidReply, mismatch
    case missingBluetooth, bluetoothPermission, bluetoothTimeout

    var errorDescription: String? {
        switch self {
        case .missing: "TOP75’in USB ayar arayüzü bulunamadı. Klavyeyi veri kablosuyla bağlayıp mod anahtarını OFF konumuna al."
        case .missingBluetooth: "TOP75 BT3.0 bağlantısı bulunamadı."
        case .bluetoothPermission: "Bluetooth ayarları için TOP75’e Giriş İzleme izni ver."
        case .bluetoothTimeout: "TOP75, Bluetooth ayar sorgusuna yanıt vermedi. Klavyeyi uyandırıp tekrar dene."
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

enum KeyboardConnection: String, Codable, Sendable {
    case usb, bluetooth
}

struct KeyboardAccess {
    let deviceIdentifier: String
    let requestReport: (UInt8, [UInt8], Bool, TimeInterval) throws -> [UInt8]
    let sendReport: ([UInt8]) throws -> Void

    func request(
        _ opcode: UInt8, parameters: [UInt8] = [], checkEcho: Bool = true, delay: TimeInterval = 0.04
    ) throws -> [UInt8] {
        try requestReport(opcode, parameters, checkEcho, delay)
    }

    func send(_ bytes: [UInt8]) throws {
        try sendReport(bytes)
    }

    func writeSetting(_ bytes: [UInt8]) throws {
        try send(bytes)
        // Firmware 274 can accept a report while dropping the write during the previous commit.
        Thread.sleep(forTimeInterval: 0.6)
    }
}

enum Keyboard {
    private static let lock = NSLock()
    private static func usbDevices(in manager: IOHIDManager) -> Set<IOHIDDevice> {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x4015,
            kIOHIDPrimaryUsagePageKey: 0xFFFF, kIOHIDPrimaryUsageKey: 2,
            kIOHIDTransportKey: "USB"
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    }

    static func hasUSBInterface() -> Bool {
        usbDevices(in: IOHIDManagerCreate(kCFAllocatorDefault, 0)).count == 1
    }
    static func report(_ bytes: [UInt8], checksumIndex: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 64)
        result.replaceSubrange(bytes.indices, with: bytes)
        result[checksumIndex] = ~result.prefix(checksumIndex).reduce(0, &+)
        return result
    }

    static func lighting(connection: KeyboardConnection = .usb) throws -> Lighting {
        try withDevice(connection: connection, readLighting)
    }

    static func apply(
        _ lighting: Lighting, replacing previous: Lighting? = nil, connection: KeyboardConnection = .usb
    ) throws -> Lighting {
        try withDevice(connection: connection) { try apply($0, lighting: lighting, replacing: previous) }
    }

    static func apply(_ device: KeyboardAccess, lighting: Lighting, replacing previous: Lighting?) throws -> Lighting {
        if let previous {
            let current = try readLighting(device)
            guard current.matches(previous) else { throw KeyboardError.mismatch }
        }
        try device.writeSetting(lighting.report)
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            let current = try readLighting(device)
            if current.matches(lighting) { return current }
        }
        throw KeyboardError.mismatch
    }

    static func profileInfo(connection: KeyboardConnection = .usb) throws -> (profile: UInt8, firmware: UInt16) {
        try withDevice(connection: connection) { device in
            (try readProfile(device), try readFirmware(device))
        }
    }

    static func readFirmware(_ device: KeyboardAccess) throws -> UInt16 {
        let reply = try device.request(0x80)
        return UInt16(reply[1]) | UInt16(reply[2]) << 8
    }

    static func sharesFnLayer(_ firmware: UInt16) -> Bool {
        firmware == 274
    }

    static func selectProfile(_ profile: UInt8, connection: KeyboardConnection = .usb) throws -> UInt8 {
        try withDevice(connection: connection) { try selectProfile($0, profile: profile) }
    }

    static func selectProfile(_ device: KeyboardAccess, profile: UInt8) throws -> UInt8 {
        guard profile < 3 else { throw KeyboardError.invalidReply }
        try device.writeSetting(report([0x05, profile], checksumIndex: 7))
        let current = try readProfile(device)
        guard current == profile else { throw KeyboardError.mismatch }
        return current
    }

    static func readProfile(_ device: KeyboardAccess) throws -> UInt8 {
        let profile = try device.request(0x85)[1]
        guard profile < 3 else { throw KeyboardError.invalidReply }
        return profile
    }

    static func keyBinding(
        slot: UInt8, expectedProfile: UInt8, fn: Bool = false, connection: KeyboardConnection = .usb
    ) throws -> [UInt8] {
        try withDevice(connection: connection) { device in
            let profile = try readProfile(device)
            guard profile == expectedProfile else { throw KeyboardError.mismatch }
            return try readKey(device, profile: profile, slot: slot, fn: fn)
        }
    }

    static func assignKey(
        slot: UInt8, binding: [UInt8], expectedProfile: UInt8, previousBinding: [UInt8],
        fn: Bool = false, connection: KeyboardConnection = .usb
    ) throws -> [UInt8] {
        try withDevice(connection: connection) { try assignKey($0, slot: slot, binding: binding, expectedProfile: expectedProfile, previousBinding: previousBinding, fn: fn) }
    }

    static func assignKey(_ device: KeyboardAccess, slot: UInt8, binding: [UInt8], expectedProfile: UInt8, previousBinding: [UInt8], fn: Bool) throws -> [UInt8] {
        guard slot < 128, binding.count == 4 else { throw KeyboardError.invalidReply }
        let profile = try readProfile(device)
        guard profile == expectedProfile,
              try readKey(device, profile: profile, slot: slot, fn: fn) == previousBinding
        else { throw KeyboardError.mismatch }
        try device.writeSetting(report([fn ? 0x15 : 0x13, fn ? 0 : profile, slot, 0, 0, 0, 0, 0] + binding, checksumIndex: 7))
        let current = try readKey(device, profile: profile, slot: slot, fn: fn)
        guard current == binding else { throw KeyboardError.mismatch }
        return current
    }

    private static func readKey(_ device: KeyboardAccess, profile: UInt8, slot: UInt8, fn: Bool) throws -> [UInt8] {
        guard slot < 128 else { throw KeyboardError.invalidReply }
        let reply = try device.request(fn ? 0x90 : 0x89, parameters: [fn ? 0 : profile, slot / 16], checkEcho: false)
        guard !reply.allSatisfy({ $0 == 0xFF }) else { throw KeyboardError.invalidReply }
        let offset = Int(slot % 16) * 4
        return Array(reply[offset..<(offset + 4)])
    }

    static func withDevice<T>(
        connection: KeyboardConnection = .usb, _ operation: (KeyboardAccess) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        func verified(_ access: KeyboardAccess) throws -> T {
            try verifyIdentity(access.request(0x8F))
            return try operation(access)
        }
        switch connection {
        case .usb: return try withUSBDevice(verified)
        case .bluetooth: return try BluetoothKeyboard.withAccess(verified)
        }
    }

    private static func withUSBDevice<T>(_ operation: (KeyboardAccess) throws -> T) throws -> T {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let devices = usbDevices(in: manager)
        guard devices.count == 1, let device = devices.first else { throw KeyboardError.missing }
        let status = IOHIDDeviceOpen(device, 0)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("USB erişimi", status) }
        defer {
            IOHIDDeviceClose(device, 0)
            withExtendedLifetime(manager) {}
        }
        return try operation(KeyboardAccess(
            deviceIdentifier: deviceIdentifier(device, connection: .usb),
            requestReport: { try requestUSB(device, opcode: $0, parameters: $1, checkEcho: $2, delay: $3) },
            sendReport: { try sendUSB(device, $0) }
        ))
    }

    static func deviceIdentifier(_ device: IOHIDDevice, connection: KeyboardConnection) -> String {
        for key in [kIOHIDUniqueIDKey, kIOHIDSerialNumberKey, kIOHIDLocationIDKey] {
            let value = IOHIDDeviceGetProperty(device, key as CFString)
            if let string = value as? String, !string.isEmpty {
                return "\(connection.rawValue):\(key):\(string)"
            }
            if let number = value as? NSNumber, number.uint64Value != 0 {
                return "\(connection.rawValue):\(key):\(number.uint64Value)"
            }
        }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        return "\(connection.rawValue):registry:\(registryID)"
    }

    static func isAvailable(_ connection: KeyboardConnection) -> Bool {
        switch connection {
        case .usb: hasUSBInterface()
        case .bluetooth: BluetoothKeyboard.isConnected() && BluetoothKeyboard.hasAccess
        }
    }

    static func availableConnection() -> KeyboardConnection? {
        if isAvailable(.usb) { return .usb }
        return isAvailable(.bluetooth) ? .bluetooth : nil
    }

    static func verifyIdentity(_ reply: [UInt8]) throws {
        guard reply.count == 64, reply[0] == 0x8F else { throw KeyboardError.invalidReply }
        let id = reply[1...4].enumerated().reduce(UInt32(0)) { id, byte in
            id | UInt32(byte.element) << (8 * byte.offset)
        }
        guard id == 957 else { throw KeyboardError.wrongDevice(id) }
    }

    static func readLighting(_ device: KeyboardAccess) throws -> Lighting {
        try Lighting(reply: device.request(0x87))
    }

    private static func sendUSB(_ device: IOHIDDevice, _ bytes: [UInt8]) throws {
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, bytes, bytes.count)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("Komut gönderme", status) }
    }

    private static func requestUSB(_ device: IOHIDDevice, opcode: UInt8, parameters: [UInt8] = [], checkEcho: Bool = true, delay: TimeInterval = 0.04) throws -> [UInt8] {
        try sendUSB(device, report([opcode] + parameters, checksumIndex: 7))
        Thread.sleep(forTimeInterval: delay)
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = bytes.count
        let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &bytes, &length)
        guard status == kIOReturnSuccess else { throw KeyboardError.transport("Ayar okuma", status) }
        guard length == bytes.count, !checkEcho || bytes.first == opcode else { throw KeyboardError.invalidReply }
        return bytes
    }
}
