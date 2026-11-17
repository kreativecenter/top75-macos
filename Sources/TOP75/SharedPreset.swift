import SwiftUI
import UniformTypeIdentifiers

struct SharedPreset: Codable, Sendable {
    enum Payload: Codable, Sendable {
        case lighting(Lighting, colors: [UInt32]?)
        case keys(fn: Bool, bindings: [UInt8: [UInt8]])
        case macro(slot: UInt8, data: Data)
    }

    enum Scope: Sendable {
        case lighting, keys(fn: Bool, slots: Set<UInt8>), macro(UInt8)
    }

    let version: Int
    let device: String
    let firmware: UInt16
    let payload: Payload

    var scope: Scope {
        switch payload {
        case .lighting: .lighting
        case .keys(let fn, let bindings): .keys(fn: fn, slots: Set(bindings.keys))
        case .macro(let slot, _): .macro(slot)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard let preset = try? JSONDecoder().decode(Self.self, from: data) else { throw PresetError.invalid }
        try preset.validate()
        return preset
    }

    func encode() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private func validate() throws {
        guard version == 1, device == SettingsSnapshot.model else { throw PresetError.invalid }
        switch payload {
        case .lighting(let effect, let colors):
            guard effect.isSupported, colors?.allSatisfy({ $0 <= 0xFFFFFF }) ?? true,
                  colors == nil || colors?.count == 128, (effect.effect == 66) == (colors != nil) else { throw PresetError.invalid }
        case .keys(_, let bindings):
            let knownSlots = Set(KeySettingsView.slots.values)
            guard !bindings.isEmpty, bindings.allSatisfy({ knownSlots.contains($0.key) && encodedBinding($0.value) }) else {
                throw PresetError.invalid
            }
        case .macro(let slot, let data):
            guard slot < 50, let macro = try? Macro(bytes: Array(data)),
                  (try? macro.encoded()) != nil, (try? Macro.writeLength(Array(data))) != nil else { throw PresetError.invalid }
        }
    }

    private func encodedBinding(_ bytes: [UInt8]) -> Bool {
        switch KeyAssignment(bytes: bytes) {
        case .key(let code): (4...231).contains(code)
        case .disabled, .media: true
        case .custom, .macro: false
        }
    }

    func desired(from current: SettingsSnapshot) -> SettingsSnapshot {
        var output = current
        switch payload {
        case .lighting(let effect, let colors):
            output.lighting = effect
            if let colors { output.keyColors = colors }
        case .keys(let fn, let bindings):
            let active = Int(current.activeProfile)
            var profile = output.profiles[active]
            for (slot, binding) in bindings {
                if fn { profile.function[Int(slot)] = binding }
                else { profile.base[Int(slot)] = binding }
            }
            output.profiles[active] = profile
            if fn && Keyboard.sharesFnLayer(current.firmware) && active > 0 {
                output.profiles[3 - active].function = profile.function
            }
        case .macro(let slot, let data):
            output.macros?[slot] = data
        }
        return output
    }
}

enum PresetError: LocalizedError {
    case invalid, dependentKey

    var errorDescription: String? {
        switch self {
        case .invalid: "Geçerli bir TOP75 ön ayar dosyası seç."
        case .dependentKey: "Seçim makro veya özel bir atama içeriyor. Makroyu ayrı dosya olarak paylaş."
        }
    }
}

extension Keyboard {
    static func exportPreset(_ scope: SharedPreset.Scope, connection: KeyboardConnection) throws -> Data {
        try withDevice(connection: connection) { device in
            let current = try readPresetState(device, scope: scope)
            let active = current.profiles[Int(current.activeProfile)]
            let payload: SharedPreset.Payload
            switch scope {
            case .lighting:
                payload = .lighting(current.lighting, colors: current.lighting.effect == 66 ? current.keyColors : nil)
            case .keys(let fn, let slots):
                let layer = fn ? active.function : active.base
                let bindings = Dictionary(uniqueKeysWithValues: slots.map { ($0, layer[Int($0)]) })
                guard bindings.values.allSatisfy({
                    switch KeyAssignment(bytes: $0) {
                    case .custom, .macro: false
                    default: true
                    }
                }) else { throw PresetError.dependentKey }
                payload = .keys(fn: fn, bindings: bindings)
            case .macro(let slot):
                guard let data = current.macros?[slot] else { throw PresetError.invalid }
                payload = .macro(slot: slot, data: Data(try Macro(bytes: Array(data)).encoded()))
            }
            return try SharedPreset(version: 1, device: SettingsSnapshot.model, firmware: current.firmware, payload: payload).encode()
        }
    }

    static func reviewPreset(_ preset: SharedPreset, connection: KeyboardConnection) throws -> SnapshotRestorePlan {
        try withDevice(connection: connection) { device in
            let current = try readPresetState(device, scope: preset.scope)
            guard preset.firmware == current.firmware else { throw SnapshotError.differentFirmware }
            return try SnapshotRestorePlan(current: current, backup: preset.desired(from: current), presetScope: preset.scope)
        }
    }
}

struct SharedPresetsSection: View {
    @Environment(\.appLanguage) private var l
    let connection: KeyboardConnection?
    let transfer: WorkspaceTransfer
    let review: (URL) -> Void
    @State private var category = Category.lighting
    @State private var keys: Set<UInt8> = []
    @State private var fn = false
    @State private var macro: UInt8 = 0
    @State private var exporting = false
    @State private var importing = false
    @State private var document: SnapshotDocument?
    @State private var action = DeviceAction()

    private enum Category: String, CaseIterable, Identifiable {
        case lighting = "Aydınlatma"
        case keys = "Tuş atamaları"
        case macro = "Tek makro"
        var id: Self { self }
    }

    var body: some View {
        Section(l("Paylaşılabilir ön ayarlar")) {
            Picker(l("Dosya içeriği"), selection: $category) {
                ForEach(Category.allCases) { Text(l($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if category == .keys {
                Picker(l("Katman"), selection: $fn) {
                    Text(l("Temel")).tag(false)
                    Text("Fn").tag(true)
                }
                KeyboardLayout(selected: keys, select: { code in
                    if keys.contains(code) { keys.remove(code) } else { keys.insert(code) }
                })
                Text(l("Etkin profilden paylaşacağın tuşları seç. İçe aktarırken etkin profile uygulanır."))
                    .foregroundStyle(.secondary)
            } else if category == .macro {
                Picker(l("Yuva"), selection: $macro) {
                    ForEach(0..<50) { Text(l.format("Makro %@", String($0 + 1))).tag(UInt8($0)) }
                }
            }
            HStack {
                Button(l("Ön ayar dosyasını kaydet"), action: export)
                    .disabled(connection == nil || (category == .keys && keys.isEmpty))
                Button(l("Ön ayar dosyasını aç")) { importing = true }
                    .disabled(connection == nil)
            }
            if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
        }
        .disabled(transfer.isBusy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) {
            switch $0 {
            case .success(let url): review(url)
            case .failure(let error): action.status = l.message(error)
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "TOP75-preset") {
            if case .failure(let error) = $0 { action.status = l.message(error) }
        }
    }

    private func export() {
        guard let connection, let id = transfer.start(.device, title: "Ayarlar okunuyor", determinate: false) else { return }
        let scope: SharedPreset.Scope = switch category {
        case .lighting: .lighting
        case .keys: .keys(fn: fn, slots: Set(keys.compactMap { KeySettingsView.slots[$0] }))
        case .macro: .macro(macro)
        }
        action.status = ""
        action.perform({ try Keyboard.exportPreset(scope, connection: connection) }) { result in
            transfer.finish(id)
            switch result {
            case .success(let data): document = SnapshotDocument(bytes: data); exporting = true
            case .failure(let error): action.status = l.message(error)
            }
        }
    }
}
