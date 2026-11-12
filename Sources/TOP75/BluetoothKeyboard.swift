import Foundation
import IOKit.hid
import IOKit.hidsystem

enum BluetoothKeyboard {
    private static let reportID: UInt32 = 6
    private static let commandMarker: UInt8 = 0x55
    private static let packetSize = 66

    private static func matchingDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x3151,
            kIOHIDProductIDKey: 0x4012,
            kIOHIDTransportKey: "Bluetooth"
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              devices.count == 1, let device = devices.first,
              IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String == "TOP75 BT3.0"
        else { return nil }
        return device
    }

    static func isConnected() -> Bool {
        matchingDevice(in: IOHIDManagerCreate(kCFAllocatorDefault, 0)) != nil
    }

    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func packet(for report: [UInt8]) -> [UInt8] {
        [UInt8(reportID), commandMarker] + report
    }

    static func payload(report: UnsafeBufferPointer<UInt8>, id: UInt32) -> [UInt8]? {
        guard id == reportID, report.count == packetSize,
              report[0] == UInt8(reportID), report[1] == commandMarker else { return nil }
        return Array(report.dropFirst(2))
    }

    static func withAccess<T>(_ operation: (KeyboardAccess) throws -> T) throws -> T {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        guard let device = matchingDevice(in: manager) else { throw KeyboardError.missingBluetooth }
        let session = try Session(device)
        defer { withExtendedLifetime(manager) {} }

        return try operation(KeyboardAccess(
            deviceIdentifier: Keyboard.deviceIdentifier(device, connection: .bluetooth),
            requestReport: { opcode, parameters, checkEcho, _ in try session.request(opcode, parameters, checkEcho) },
            sendReport: session.send
        ))
    }

    private final class Session {
        private let device: IOHIDDevice
        private let runLoop: CFRunLoop
        private let buffer: UnsafeMutablePointer<UInt8>
        private var accepting = false
        private var expectedOpcode: UInt8?
        private var reply: [UInt8]?

        init(_ device: IOHIDDevice) throws {
            let status = IOHIDDeviceOpen(device, 0)
            guard status == kIOReturnSuccess else {
                if !BluetoothKeyboard.hasAccess { throw KeyboardError.bluetoothPermission }
                throw KeyboardError.transport("Bluetooth erişimi", status)
            }
            self.device = device
            runLoop = CFRunLoopGetCurrent()!
            buffer = .allocate(capacity: packetSize)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, packetSize, { context, status, _, _, id, bytes, length in
                guard status == kIOReturnSuccess, id == reportID, let context else { return }
                let session = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
                guard session.accepting, session.reply == nil,
                      let data = payload(report: UnsafeBufferPointer(start: bytes, count: length), id: id),
                      session.expectedOpcode == nil || data[0] == session.expectedOpcode
                else { return }
                session.reply = data
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }

        deinit {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0)
            buffer.deallocate()
        }

        func request(_ opcode: UInt8, _ parameters: [UInt8], _ checkEcho: Bool) throws -> [UInt8] {
            // Discard queued reports before arming the next request.
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, false)
            expectedOpcode = checkEcho ? opcode : nil
            reply = nil
            accepting = true
            defer { accepting = false }
            try send(Keyboard.report([opcode] + parameters, checksumIndex: 7))

            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
                if let reply { return reply }
            }
            throw KeyboardError.bluetoothTimeout
        }

        func send(_ report: [UInt8]) throws {
            let bytes = packet(for: report)
            let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, Int(reportID), bytes, bytes.count)
            guard status == kIOReturnSuccess else { throw KeyboardError.transport("Bluetooth komutu gönderme", status) }
        }
    }
}
