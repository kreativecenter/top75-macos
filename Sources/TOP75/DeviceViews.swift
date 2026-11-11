import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(rgb24: UInt32) {
        self.init(
            red: Double((rgb24 >> 16) & 255) / 255,
            green: Double((rgb24 >> 8) & 255) / 255,
            blue: Double(rgb24 & 255) / 255
        )
    }

    var rgb24: UInt32? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return values.reduce(0) { ($0 << 8) | UInt32((min(1, max(0, $1)) * 255).rounded()) }
    }
}

@MainActor
struct DeviceAction {
    var busy = false
    var status = ""

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T,
        completion: @escaping @MainActor (Result<T, any Error>) -> Void
    ) {
        Task {
            do {
                completion(.success(try await Task.detached(operation: operation).value))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

struct KeyColorControls: View {
    @Environment(\.appLanguage) private var l
    @State private var source: UInt8 = 4
    @State private var palette: [UInt32] = []
    @State private var color = Color.black
    @State private var action = DeviceAction()

    var body: some View {
        Section(l("Tuş başına renk")) {
            if !palette.isEmpty { KeyboardLayout(selection: $source, colors: palette) }
            Picker(l("Fiziksel tuş"), selection: $source) {
                ForEach(KeySettingsView.keys.filter { KeySettingsView.slots[$0.0] != nil }, id: \.0) { key in
                    Text(l(key.1)).tag(key.0)
                }
            }
            .onChange(of: source) { showCurrent() }
            ColorPicker(l("Tuş rengi"), selection: $color, supportsOpacity: false)
                .disabled(palette.isEmpty)
            HStack {
                Button(l("Renkleri oku")) { load() }
                Button(l("Tuş rengini yaz")) { save() }.disabled(palette.isEmpty)
                Button(l("Tuş renklerini göster")) { activate() }.disabled(palette.isEmpty)
            }
            if action.busy { ProgressView().controlSize(.small) }
            if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
        }
        .disabled(action.busy)
    }

    private func showCurrent() {
        guard let slot = KeySettingsView.slots[source], palette.indices.contains(Int(slot)) else { return }
        color = Color(rgb24: palette[Int(slot)])
    }

    private func load() {
        run("Tuş renkleri okundu.") { try Keyboard.keyColors() } update: {
            palette = $0
            showCurrent()
        }
    }

    private func save() {
        guard let slot = KeySettingsView.slots[source], palette.indices.contains(Int(slot)),
              let rgb = color.rgb24 else { return }
        let previous = palette[Int(slot)]
        run("Tuş rengi yazıldı ve doğrulandı.") {
            try Keyboard.setKeyColor(slot: slot, rgb: rgb, previous: previous)
        } update: { palette[Int(slot)] = $0 }
    }

    private func activate() {
        run("Tuş başına renk efekti etkin.") { try Keyboard.showKeyColors() } update: { _ in }
    }

    private func run<T: Sendable>(
        _ success: String, operation: @escaping @Sendable () throws -> T, update: @escaping (T) -> Void
    ) {
        action.busy = true
        action.status = ""
        action.perform(operation) { result in
            action.busy = false
            switch result {
            case .success(let value):
                update(value)
                action.status = success
            case .failure(let error):
                palette = []
                action.status = l.message(error)
            }
        }
    }
}

struct DeviceOptionsView: View {
    @Environment(\.appLanguage) private var l
    @State private var snapshot: SnapshotDocument?
    @State private var exporting = false
    @State private var initial: DeviceOptions?
    @State private var draft = DeviceOptions(debounce: 0, automaticOS: false, timers: [0, 0, 0, 0])
    @State private var action = DeviceAction()

    var body: some View {
        Form {
            Section(l("Tuş tepkisi")) {
                Stepper(l.format("Debounce · %@ ms", String(draft.debounce)), value: $draft.debounce, in: 0...10)
                Toggle(l("İşletim sistemini otomatik algıla"), isOn: $draft.automaticOS)
            }
            .disabled(initial == nil || action.busy)
            Section(l("Kablosuz uyku zamanlayıcıları")) {
                timer("Bluetooth ışık", index: 0)
                timer("2,4 GHz ışık", index: 1)
                timer("Bluetooth derin uyku", index: 2)
                timer("2,4 GHz derin uyku", index: 3)
                Text(l("Değeri 0 yaparsan ilgili zamanlayıcı kapanır.")).foregroundStyle(.secondary)
            }
            .disabled(initial == nil || action.busy)
            Section {
                HStack {
                    Button(l("Klavyeden oku")) { load() }
                    Button(l("Ayarları uygula")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(initial == nil || initial == draft)
                    if action.busy { ProgressView().controlSize(.small) }
                }
                .disabled(action.busy)
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
            Section(l("Ayar kaydı")) {
                Button(l("Ayarları JSON olarak dışa aktar")) { export() }.disabled(action.busy)
                Text(l("Üç profilin tuş atamalarını, aydınlatmayı ve cihaz ayarlarını dosyaya kaydeder."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if initial == nil && !action.busy { load() } }
        .fileExporter(isPresented: $exporting, document: snapshot, contentType: .json, defaultFilename: "TOP75-settings") { result in
            if case .failure(let error) = result { action.status = l.message(error) }
        }
    }

    private func export() {
        action.busy = true
        action.status = ""
        action.perform { try Keyboard.settingsSnapshot() } completion: { result in
            action.busy = false
            switch result {
            case .success(let bytes):
                snapshot = SnapshotDocument(bytes: bytes)
                exporting = true
            case .failure(let error):
                action.status = l.message(error)
            }
        }
    }

    private func timer(_ title: String, index: Int) -> some View {
        Stepper(l.format("%@ · %@ dk", l(title), String(Int(draft.timers[index]) / 60)), value: $draft.timers[index], in: 0...3600, step: 60)
    }

    private func load() {
        run("Ayarlar klavyeden okundu.") { try Keyboard.options() }
    }

    private func save() {
        guard let initial else { return }
        let desired = draft
        run("Ayarlar yazıldı ve klavyeden doğrulandı.") {
            try Keyboard.updateOptions(desired, previous: initial)
        }
    }

    private func run(_ success: String, operation: @escaping @Sendable () throws -> DeviceOptions) {
        action.busy = true
        action.status = ""
        action.perform(operation) { result in
            action.busy = false
            switch result {
            case .success(let options):
                initial = options
                draft = options
                action.status = success
            case .failure(let error):
                initial = nil
                action.status = l.message(error)
            }
        }
    }
}

struct MacroView: View {
    @Environment(\.appLanguage) private var l
    @State private var slot: UInt8 = 0
    @State private var previous: [UInt8]?
    @State private var strokes: [Macro.Stroke] = []
    @State private var repeats: UInt16 = 1
    @State private var key: UInt8 = 4
    @State private var delay: UInt16 = 40
    @State private var action = DeviceAction()

    var body: some View {
        Form {
            Section(l("Klavye makrosu")) {
                Picker(l("Yuva"), selection: $slot) {
                    ForEach(0..<50) { value in Text(l.format("Makro %@", String(value + 1))).tag(UInt8(value)) }
                }
                .onChange(of: slot) { previous = nil; strokes = []; action.status = "" }
                Button(l("Yuvayı oku")) { load() }
                Stepper(l.format("Tekrar · %@", String(repeats)), value: $repeats, in: 1...999)
                    .disabled(previous == nil)
            }
            .disabled(action.busy)
            Section(l("Tuş olayları")) {
                Picker(l("Tuş"), selection: $key) {
                    ForEach(KeySettingsView.keys, id: \.0) { item in Text(l(item.1)).tag(item.0) }
                }
                Stepper(l.format("Olaydan sonra bekle · %@ ms", String(delay)), value: $delay, in: 0...5000, step: 10)
                HStack {
                    Button(l("Vuruş ekle")) {
                        strokes += [Macro.Stroke(key: key, down: true, delay: 30), Macro.Stroke(key: key, down: false, delay: delay)]
                    }
                    Button(l("Basma ekle")) { strokes.append(Macro.Stroke(key: key, down: true, delay: delay)) }
                    Button(l("Bırakma ekle")) { strokes.append(Macro.Stroke(key: key, down: false, delay: delay)) }
                    Button(l("Son olayı çıkar")) { strokes.removeLast() }.disabled(strokes.isEmpty)
                }
                .disabled(strokes.count >= 110)
                if strokes.isEmpty { Text(l("Olay yok")).foregroundStyle(.secondary) }
                ForEach(strokes.indices, id: \.self) { index in
                    let stroke = strokes[index]
                    let name = KeySettingsView.keys.first { $0.0 == stroke.key }?.1 ?? "HID \(stroke.key)"
                    Text("\(index + 1). \(l(name)) · \(l(stroke.down ? "Bas" : "Bırak")) · \(stroke.delay) ms")
                }
                Button(l("Taslağı temizle")) { strokes = [] }.disabled(strokes.isEmpty)
            }
            .disabled(previous == nil || action.busy)
            Section {
                HStack {
                    Button(l("Makroyu klavyeye yaz")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(previous == nil || action.busy)
                    if action.busy { ProgressView().controlSize(.small) }
                }
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func load() {
        let index = slot
        run("Makro okundu.") { try Keyboard.macro(slot: index) }
    }

    private func save() {
        guard let previous else { return }
        let index = slot
        do {
            let bytes = try Macro(repeats: repeats, strokes: strokes).encoded()
            run("Makro yazıldı ve klavyeden doğrulandı.") {
                try Keyboard.setMacro(slot: index, bytes: bytes, previous: previous)
            }
        } catch {
            action.status = l.message(error)
        }
    }

    private func run(_ success: String, operation: @escaping @Sendable () throws -> [UInt8]) {
        action.busy = true
        action.status = ""
        action.perform(operation) { result in
            action.busy = false
            do {
                let bytes = try result.get()
                let macro = try Macro(bytes: bytes)
                previous = bytes
                repeats = min(999, max(1, macro.repeats))
                strokes = macro.strokes
                action.status = success
            } catch {
                previous = nil
                action.status = l.message(error)
            }
        }
    }
}

struct ScreenView: View {
    @Environment(\.appLanguage) private var l
    @State private var artwork: ScreenArtwork?
    @State private var fileName = ""
    @State private var choosing = false
    @State private var confirming = false
    @State private var slot: UInt8 = 0
    @State private var progress = 0.0
    @State private var action = DeviceAction()

    var body: some View {
        Form {
            Section(l("128 × 128 ekran")) {
                Button(l("Görsel veya GIF seç")) { choosing = true }.disabled(action.busy)
                if let artwork {
                    if let data = artwork.previewPNG, let preview = NSImage(data: data) {
                        Image(nsImage: preview)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 144, height: 144)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .padding(10)
                            .background(.black, in: RoundedRectangle(cornerRadius: 14))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .accessibilityLabel(l("Ekran önizlemesi"))
                    }
                    LabeledContent(l("Dosya"), value: fileName)
                    if artwork.frames.count == 1 {
                        Picker(l("Görsel yuvası"), selection: $slot) {
                            ForEach(0..<5) { value in Text(l.format("Yuva %@", String(value + 1))).tag(UInt8(value)) }
                        }
                        .disabled(action.busy)
                    } else {
                        LabeledContent(l("Animasyon"), value: l.format("%@ kare · %@ ms", String(artwork.frames.count), String(artwork.delay)))
                    }
                }
            }
            Section {
                Button(l("Ekrana aktar")) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(action.busy || artwork == nil)
                if action.busy { ProgressView(value: progress) }
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .gif]) { result in
            do {
                let url = try result.get()
                action.busy = true
                action.status = ""
                action.perform { try ScreenArtwork(url: url) } completion: { result in
                    action.busy = false
                    switch result {
                    case .success(let decoded):
                        artwork = decoded
                        fileName = url.lastPathComponent
                    case .failure(let error):
                        artwork = nil
                        action.status = l.message(error)
                    }
                }
            } catch {
                action.status = l.message(error)
            }
        }
        .confirmationDialog(l("Ekran içeriğini değiştir"), isPresented: $confirming) {
            Button(l("Aktar")) { upload() }
        } message: {
            Text(artwork?.frames.count == 1
                ? l.format("Yuva %@ içindeki görsel değişecek.", String(Int(slot) + 1))
                : l("Mevcut animasyon değişecek."))
        }
    }

    private func upload() {
        guard let artwork else { return }
        let destination = slot
        progress = 0
        action.busy = true
        action.status = ""
        action.perform {
            try Keyboard.uploadArtwork(artwork, slot: destination) { value in
                Task { @MainActor in progress = value }
            }
        } completion: { result in
            action.busy = false
            switch result {
            case .success:
                action.status = "Aktarım gönderildi. Sonucu klavye ekranından kontrol et."
            case .failure(let error):
                action.status = l.message(error)
            }
        }
    }
}

struct SnapshotDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.bytes = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}
