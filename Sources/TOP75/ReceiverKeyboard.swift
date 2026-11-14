import Foundation
import os
import IOKit.hid

/// Reads the receiver's cached status. Only the identification exchange reaches the keyboard.
enum ReceiverKeyboard {
    struct Status: Equatable, Sendable {
        let online: Bool
        let percent: Int?

        init?(reply: [UInt8]) {
            guard reply.count == 64, reply[0] <= 1, reply[3] <= 1,
                  reply[4] <= 1, reply[5] <= 1, reply[6] == 1 else { return nil }
            online = reply[3] == 0
            // An uninitialized receiver cache also reports zero.
            percent = online && (1...100).contains(reply[1]) ? Int(reply[1]) : nil
        }
    }

    struct Reading: Sendable {
        let receiverID: UInt64
        let status: Status
    }

    static func read(verifiedReceiver: UInt64?) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        return try? withDevice { device in
            try readStatus(Session(device), device: device, verifiedReceiver: verifiedReceiver)
        }
    }

    static func withAccess<T>(_ operation: (KeyboardAccess) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withDevice { device in
            let session = Session(device)
            return try operation(KeyboardAccess(
                deviceIdentifier: Keyboard.deviceIdentifier(device, connection: .receiver),
                requestReport: { opcode, parameters, echo, _ in try session.request(opcode, parameters, echo) },
                sendReport: session.send
            ))
        }
    }

    private static let lock = NSLock()
    private static let online = OSAllocatedUnfairLock(initialState: false)
    static var isOnline: Bool { online.withLock { $0 } }

    static func setOnline(_ value: Bool) { online.withLock { $0 = value } }

    private static func withDevice<T>(_ operation: (IOHIDDevice) throws -> T) throws -> T {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x4011,
            kIOHIDPrimaryUsagePageKey: 0xFFFF, kIOHIDPrimaryUsageKey: 2,
            kIOHIDTransportKey: "USB"
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              devices.count == 1, let device = devices.first,
              IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { throw KeyboardError.missingReceiver }
        defer {
            IOHIDDeviceClose(device, 0)
            withExtendedLifetime(manager) {}
        }
        return try operation(device)
    }

    private static func readStatus(_ session: Session, device: IOHIDDevice, verifiedReceiver: UInt64?) throws -> Reading? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS,
              let initial = Status(reply: try session.status()) else { return nil }
        if !initial.online || id == verifiedReceiver { return Reading(receiverID: id, status: initial) }

        try Keyboard.verifyIdentity(session.request(0x8F, [], true))
        guard let status = Status(reply: try session.status()), status.online else { return nil }
        return Reading(receiverID: id, status: status)
    }

    private struct Session {
        let device: IOHIDDevice

        init(_ device: IOHIDDevice) { self.device = device }

        func status() throws -> [UInt8] {
            try local([0xF7])
        }

        func request(_ opcode: UInt8, _ parameters: [UInt8], _ echo: Bool) throws -> [UInt8] {
            for _ in 0..<3 {
                try send(Keyboard.report([opcode] + parameters, checksumIndex: 7))
                var observedBusy = false
                for attempt in 0..<12 {
                    let state = try status()
                    guard Status(reply: state)?.online == true else { throw KeyboardError.missingReceiver }
                    if state[5] == 0 { observedBusy = true }
                    // This receiver can finish a request without setting the reply flag.
                    guard state[0] == 1 || (state[5] == 1 && (observedBusy || attempt >= 2)) else { continue }
                    // Give the receiver time to finish copying the relay buffer before releasing it.
                    Thread.sleep(forTimeInterval: 0.08)
                    let reply = try local([0xFC])
                    if !echo || reply[0] == opcode { return reply }
                    break
                }
            }
            throw KeyboardError.invalidReply
        }

        func send(_ report: [UInt8]) throws {
            for _ in 0..<5 {
                let reply = try status()
                guard Status(reply: reply)?.online == true else { throw KeyboardError.missingReceiver }
                if reply[5] == 1 {
                    try write(Keyboard.report([0xF6, 10], checksumIndex: 7))
                    Thread.sleep(forTimeInterval: 0.04)
                    try write(report)
                    return
                }
            }
            throw KeyboardError.invalidReply
        }

        private func local(_ command: [UInt8]) throws -> [UInt8] {
            try write(Keyboard.report(command, checksumIndex: 7))
            Thread.sleep(forTimeInterval: 0.08)
            var reply = [UInt8](repeating: 0, count: 64)
            var length = reply.count
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &reply, &length)
            guard result == kIOReturnSuccess, length == reply.count else { throw KeyboardError.invalidReply }
            return reply
        }

        private func write(_ report: [UInt8]) throws {
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, report, report.count)
            guard result == kIOReturnSuccess else { throw KeyboardError.transport("Komut gönderme", result) }
        }
    }
}
