import Foundation

struct Macro: Sendable {
    struct Stroke: Sendable {
        let key: UInt8
        let down: Bool
        let delay: UInt16
    }

    let repeats: UInt16
    let strokes: [Stroke]

    init(repeats: UInt16, strokes: [Stroke]) {
        self.repeats = repeats
        self.strokes = strokes
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == 256 else { throw MacroError.unsupported }
        repeats = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var cursor = 2
        var strokes: [Stroke] = []
        while cursor + 1 < bytes.count, bytes[cursor] != 0 {
            let key = bytes[cursor]
            let flags = bytes[cursor + 1]
            guard (4...231).contains(key) else { throw MacroError.unsupported }
            cursor += 2
            var delay = UInt16(flags & 0x7F)
            if delay == 0 {
                guard cursor + 1 < bytes.count else { throw MacroError.unsupported }
                delay = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
                cursor += 2
            }
            strokes.append(Stroke(key: key, down: flags & 0x80 != 0, delay: delay))
        }
        self.strokes = strokes
    }

    func encoded() throws -> [UInt8] {
        if strokes.isEmpty { return [UInt8](repeating: 0, count: 256) }
        var bytes = [UInt8(truncatingIfNeeded: repeats), UInt8(repeats >> 8)]
        var held: Set<UInt8> = []
        for stroke in strokes {
            if stroke.down { held.insert(stroke.key) } else { held.remove(stroke.key) }
            let action: UInt8 = stroke.down ? 0x80 : 0
            if (1...127).contains(stroke.delay) {
                bytes += [stroke.key, action | UInt8(stroke.delay)]
            } else {
                bytes += [stroke.key, action, UInt8(truncatingIfNeeded: stroke.delay), UInt8(stroke.delay >> 8)]
            }
        }
        guard held.isEmpty else { throw MacroError.unreleasedKeys }
        guard bytes.count <= 222 else { throw MacroError.tooLong }
        return bytes + [UInt8](repeating: 0, count: 256 - bytes.count)
    }
}

enum MacroError: LocalizedError {
    case unsupported, unreleasedKeys, tooLong

    var errorDescription: String? {
        switch self {
        case .unsupported: "Bu makro, bu düzenleyicinin desteklemediği olaylar içeriyor."
        case .unreleasedKeys: "Her basma olayı için ilgili tuşu bırakma olayı ekle."
        case .tooLong: "Makro cihaz için çok uzun. Olay sayısını azalt."
        }
    }
}
