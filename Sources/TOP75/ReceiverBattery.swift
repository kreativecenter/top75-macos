import Foundation
import IOKit.hid

/// Reads the receiver's cached status. Only the identification exchange reaches the keyboard.
enum ReceiverBattery {
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
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x4011,
            kIOHIDPrimaryUsagePageKey: 0xFFFF, kIOHIDPrimaryUsageKey: 2,
            kIOHIDTransportKey: "USB"
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              devices.count == 1, let device = devices.first,
              IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { return nil }
        defer {
            IOHIDDeviceClose(device, 0)
            withExtendedLifetime(manager) {}
        }

        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS,
              let initialReply = request([0xF7], device),
              let initial = Status(reply: initialReply) else { return nil }
        if !initial.online || id == verifiedReceiver { return Reading(receiverID: id, status: initial) }

        // 3151:4011 is shared by several boards. Verify the keyboard behind the receiver.
        guard initialReply[5] == 1, send([0xF6, 10], device),
              send([0x8F], device) else { return nil }
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<4 {
            guard let identity = request([0xFC], device) else { continue }
            if (try? Keyboard.verifyIdentity(identity)) != nil,
               let reply = request([0xF7], device),
               let status = Status(reply: reply), status.online {
                return Reading(receiverID: id, status: status)
            }
        }
        return nil
    }

    private static func send(_ command: [UInt8], _ device: IOHIDDevice) -> Bool {
        let report = Keyboard.report(command, checksumIndex: 7)
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, report, report.count) == kIOReturnSuccess
    }

    private static func request(_ command: [UInt8], _ device: IOHIDDevice) -> [UInt8]? {
        guard send(command, device) else { return nil }
        Thread.sleep(forTimeInterval: 0.1)
        var reply = [UInt8](repeating: 0, count: 64)
        var length = reply.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &reply, &length) == kIOReturnSuccess,
              length == reply.count else { return nil }
        return reply
    }
}
