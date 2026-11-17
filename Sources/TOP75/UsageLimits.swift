import Darwin
import Foundation

struct UsageLimits: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercentage: Double
        let resetsAt: Date?

        init?(_ used: Double, reset: Double?, now: Date) {
            guard used.isFinite, (0...100).contains(used) else { return nil }
            let date = reset.flatMap { value in
                value.isFinite && value > 0 ? Date(timeIntervalSince1970: value) : nil
            }
            guard date.map({ $0 > now }) ?? true else { return nil }
            usedPercentage = used
            resetsAt = date
        }

        var remaining: Int { Int((100 - usedPercentage).rounded(.down)) }
    }

    var fiveHour: Window?
    var weekly: Window?

    var isEmpty: Bool { fiveHour == nil && weekly == nil }
}

enum UsageSourceError: LocalizedError {
    case cliMissing, noResponse, unavailable, statusLineUnsupported, settingsChanged

    var errorDescription: String? {
        switch self {
        case .cliMissing: "Codex CLI bulunamadı. CLI’ı yükleyip ChatGPT hesabınla giriş yap."
        case .noResponse: "Codex CLI zamanında yanıt vermedi."
        case .unavailable: "Codex limitleri alınamadı. Codex CLI’da ChatGPT hesabınla giriş yap."
        case .statusLineUnsupported: "Claude Code status line ayarı desteklenen komut biçiminde değil."
        case .settingsChanged: "Claude Code ayarları değişti. Tekrar dene."
        }
    }
}

enum CodexUsage {
    private struct Reply: Decodable {
        struct Result: Decodable {
            struct Bucket: Decodable {
                struct Window: Decodable {
                    let usedPercent: Double
                    let windowDurationMins: Int?
                    let resetsAt: Double?
                }
                let primary: Window?
                let secondary: Window?
            }
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        let id: Int?
        let result: Result?
    }

    static func decode(_ bytes: Data, now: Date = Date()) throws -> UsageLimits {
        let reply = try JSONDecoder().decode(Reply.self, from: bytes)
        guard reply.id == 2, let result = reply.result,
              let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        else { throw UsageSourceError.unavailable }
        var limits = UsageLimits()
        for window in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
            let value = UsageLimits.Window(window.usedPercent, reset: window.resetsAt, now: now)
            switch window.windowDurationMins {
            case 300: limits.fiveHour = value
            case 10080: limits.weekly = value
            default: break
            }
        }
        return limits
    }

    static func read() throws -> UsageLimits {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }

        let toServer = input.fileHandleForWriting
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let initialize = try JSONSerialization.data(withJSONObject: [
            "method": "initialize", "id": 1, "params": ["clientInfo": ["name": "top75", "version": version]]
        ])
        try toServer.write(contentsOf: initialize + Data([10]))

        var remaining = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let fromServer = output.fileHandleForReading.fileDescriptor
        var pollDescriptor = pollfd(fd: fromServer, events: Int16(POLLIN), revents: 0)
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline && total < 1_048_576 {
            let wait = max(0, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&pollDescriptor, 1, wait)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            // Read one available chunk. Buffered reads can wait for a full block from the live server.
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fromServer, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
            remaining.append(contentsOf: chunk.prefix(count))
            while let newline = remaining.firstIndex(of: 10) {
                let record = Data(remaining[..<newline])
                remaining.removeSubrange(...newline)
                guard let reply = try? JSONDecoder().decode(Reply.self, from: record) else { continue }
                switch reply.id {
                case 1:
                    guard reply.result != nil else { throw UsageSourceError.unavailable }
                    try toServer.write(contentsOf: Data("""
                    {"method":"initialized"}
                    {"method":"account/rateLimits/read","id":2}

                    """.utf8))
                case 2:
                    return try decode(record)
                default: continue
                }
            }
        }
        throw UsageSourceError.noResponse
    }

    private static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".local/bin/codex").path]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw UsageSourceError.cliMissing
    }
}

enum ClaudeUsage {
    struct Reading: Sendable {
        let limits: UsageLimits
        let observedAt: Date
    }

    private struct Payload: Decodable {
        struct Window: Decodable {
            let usedPercentage: Double
            let resetsAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: Window?
        let weekly: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case weekly = "seven_day"
        }
    }

    static func decode(_ bytes: Data, now: Date = Date()) throws -> UsageLimits {
        let payload = try JSONDecoder().decode(Payload.self, from: bytes)
        func window(_ value: Payload.Window?) -> UsageLimits.Window? {
            value.flatMap { .init($0.usedPercentage, reset: $0.resetsAt, now: now) }
        }
        return UsageLimits(fiveHour: window(payload.fiveHour), weekly: window(payload.weekly))
    }

    static func read() -> Reading? {
        let url = support.appendingPathComponent("claude-limits.json")
        guard let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              properties.isRegularFile == true, let size = properties.fileSize, size <= 4096,
              let date = properties.contentModificationDate, date <= Date(),
              let data = try? Data(contentsOf: url), let limits = try? decode(data),
              !limits.isEmpty else { return nil }
        return Reading(limits: limits, observedAt: date)
    }

    static var isConfigured: Bool {
        guard let settings = try? readSettings(), let line = settings.json["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return unwrap(command) != nil
    }

    static func configure(enabled: Bool) throws {
        let previous = try readSettings()
        var object = previous.json
        var status = object["statusLine"] as? [String: Any] ?? [:]
        if enabled {
            if object["statusLine"] != nil {
                guard status["type"] as? String == "command", status["command"] is String else {
                    throw UsageSourceError.statusLineUnsupported
                }
            }
            let command = status["command"] as? String ?? ""
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(bridgeScript.utf8).write(to: bridge, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
            if unwrap(command) != nil { return }
            status["type"] = "command"
            status["command"] = commandPrefix + quote(command)
            object["statusLine"] = status
        } else {
            guard let command = status["command"] as? String, let original = unwrap(command)
            else { throw UsageSourceError.settingsChanged }
            if original.isEmpty {
                object.removeValue(forKey: "statusLine")
            } else {
                status["command"] = original
                object["statusLine"] = status
            }
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = settingsURL.deletingLastPathComponent().appendingPathComponent(".top75-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: encoded + Data([10]))
        try handle.close()
        guard try readSettings().raw == previous.raw else { throw UsageSourceError.settingsChanged }
        if rename(temporary.path, settingsURL.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func unwrap(_ value: String) -> String? {
        guard value.hasPrefix(commandPrefix) else { return nil }
        let wrapped = String(value.dropFirst(commandPrefix.count))
        guard wrapped.count >= 2, wrapped.first == "'", wrapped.last == "'" else { return nil }
        let original = wrapped.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        return quote(original) == wrapped ? original : nil
    }

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TOP75", isDirectory: true)
    }
    private static var bridge: URL { support.appendingPathComponent("claude-statusline.sh") }
    private static var commandPrefix: String { quote(bridge.path) + " " }
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private static func readSettings() throws -> (raw: Data?, json: [String: Any]) {
        do {
            let raw = try Data(contentsOf: settingsURL)
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw UsageSourceError.statusLineUnsupported
            }
            return (raw, object)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (nil, [:])
        }
    }

    static let bridgeScript = #"""
    #!/bin/sh
    input=$(/bin/cat)
    read_limit() {
        /usr/bin/printf '%s\n' "$input" | /usr/bin/plutil -extract "rate_limits.$1.$2" raw -o - -- - 2>/dev/null
    }
    window() {
        percent=$(read_limit "$1" used_percentage) || return
        case "$percent" in ''|*[!0-9.]*) return;; esac
        reset=$(read_limit "$1" resets_at)
        case "$reset" in ''|*[!0-9]*) reset=null;; esac
        /usr/bin/printf '"%s":{"used_percentage":%s,"resets_at":%s}' "$1" "$percent" "$reset"
    }
    five=$(window five_hour)
    week=$(window seven_day)
    if [ -n "$five$week" ]; then (
        umask 077
        root=$(/usr/bin/dirname "$0")
        tmp=$(/usr/bin/mktemp "$root/.claude-limits.XXXXXXXX")
        if [ -n "$tmp" ]; then
            comma=
            [ -n "$five" ] && [ -n "$week" ] && comma=,
            /usr/bin/printf '{%s%s%s}\n' "$five" "$comma" "$week" > "$tmp" &&
                /bin/mv -f "$tmp" "$root/claude-limits.json"
            [ ! -e "$tmp" ] || /bin/rm -f "$tmp"
        fi
    ); fi
    [ -z "$1" ] || /usr/bin/printf '%s\n' "$input" | /bin/sh -c "$1"
    """#
}
