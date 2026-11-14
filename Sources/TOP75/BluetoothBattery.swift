import Foundation

enum BluetoothBattery {
    static func readPercent() -> Int? {
        // The standard IOKit power source list omits these Bluetooth accessories.
        // pmset reads the accessory values macOS already holds.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        process.environment = ["LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return percent(in: String(decoding: data, as: UTF8.self))
    }

    static func percent(in output: String) -> Int? {
        let values = output.split(separator: "\n").compactMap { line -> Int? in
            guard let id = line.range(of: " (id="),
                  line[..<id.lowerBound].trimmingCharacters(in: .whitespaces) == "-TOP75 BT5.0",
                  let end = line[id.upperBound...].firstIndex(of: ")") else { return nil }
            let charge = line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard let marker = charge.firstIndex(of: "%"),
                  let value = Int(charge[..<marker]), (0...100).contains(value) else { return nil }
            return value
        }
        return values.count == 1 ? values[0] : nil
    }
}
