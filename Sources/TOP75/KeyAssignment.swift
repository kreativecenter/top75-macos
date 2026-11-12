import Foundation

enum KeyAssignment: Equatable, Sendable {
    enum Kind: CaseIterable, Hashable {
        case key, macro, media, disabled, custom
    }

    case key(UInt8)
    case macro(slot: UInt8, playback: UInt8)
    case media(UInt16)
    case disabled
    case custom([UInt8])

    static let mediaOptions: [(UInt16, String)] = [
        (233, "Sesi artır"), (234, "Sesi azalt"), (226, "Sesi kapat"),
        (205, "Oynat / duraklat"), (181, "Sonraki parça"), (182, "Önceki parça")
    ]

    init(bytes: [UInt8]) {
        guard bytes.count == 4 else { self = .custom(bytes); return }
        switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
        case (0, 0, 0, 0): self = .disabled
        case (0, 0, let usage, 0): self = .key(usage)
        case (9, let playback, let slot, 0) where playback < 3 && slot < 50:
            self = .macro(slot: slot, playback: playback)
        case (3, 0, let low, let high):
            self = .media(UInt16(low) | UInt16(high) << 8)
        default:
            self = .custom(bytes)
        }
    }

    var kind: Kind {
        switch self {
        case .key: .key
        case .macro: .macro
        case .media: .media
        case .disabled: .disabled
        case .custom: .custom
        }
    }

    @MainActor
    func displayName(fn: Bool, language l: AppLanguage) -> String {
        switch self {
        case .key(let usage):
            if let key = KeySettingsView.keys.first(where: { $0.0 == usage }) { return l(key.1) }
            return String(format: "HID 0x%02X", usage)
        case .macro(let slot, _):
            return l.format("Makro %@", String(Int(slot) + 1))
        case .media(let usage):
            if let option = KeyAssignment.mediaOptions.first(where: { $0.0 == usage }) { return l(option.1) }
            return String(format: "HID 0x%04X", usage)
        case .disabled:
            return l(fn ? "Temel katman" : "Devre dışı")
        case .custom:
            return l("Özel atama")
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .key(let key): [0, 0, key, 0]
        case .macro(let slot, let playback): [9, playback, slot, 0]
        case .media(let usage): [3, 0, UInt8(truncatingIfNeeded: usage), UInt8(usage >> 8)]
        case .disabled: [0, 0, 0, 0]
        case .custom(let raw): raw
        }
    }
}
