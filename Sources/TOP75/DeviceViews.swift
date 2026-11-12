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

struct KeyColorDraft {
    var selection: Set<UInt8> = []
    var changes: [UInt8: UInt32] = [:]
    var undo: [UInt8: UInt32] = [:]
    var color = Color(rgb24: 0x739BFF)
    var action = DeviceAction()
}

struct KeyColorControls: View {
    @Environment(\.appLanguage) private var l
    @Binding var palette: [UInt32]
    let connected: Bool
    let modeActive: Bool
    var onActivate: () -> Void
    @Binding var draft: KeyColorDraft
    private let transfer = WorkspaceTransfer.shared

    var body: some View {
        Section(l("Tuş başına renk")) {
            KeyboardLayout(selected: draft.selection, marked: marked, colors: preview, select: toggle)
            HStack {
                Button(l("Tüm tuşları seç")) { draft.selection = Set(KeyboardLayout.selectableCodes) }
                Button(l("Seçimi temizle")) { draft.selection = [] }.disabled(draft.selection.isEmpty)
                Spacer()
                Text(l.format("%@ tuş seçili", String(draft.selection.count))).foregroundStyle(.secondary)
            }
            ColorPicker(l("Tuş rengi"), selection: $draft.color, supportsOpacity: false)
            ColorSwatches(color: $draft.color)
            Button(l("Seçili tuşları boya"), action: paint)
                .disabled(draft.selection.isEmpty || palette.isEmpty)
        }
        .disabled(draft.action.busy)
        Section {
            HStack {
                Button(l("Renkleri oku"), action: load).disabled(!connected)
                if !draft.changes.isEmpty {
                    Button(l("Taslağı sıfırla")) { draft.changes = [:] }
                } else if !draft.undo.isEmpty {
                    Button(l("Geri al")) { save(draft.undo, isUndo: true) }
                        .disabled(!connected || palette.isEmpty)
                }
                Spacer()
                Button(l("Tuş renklerini göster"), action: onActivate)
                    .disabled(!connected || modeActive || palette.isEmpty)
                Button(l("Renkleri uygula")) { save(draft.changes, isUndo: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || palette.isEmpty || draft.changes.isEmpty)
            }
            if draft.action.busy && transfer.job?.page != .lighting { ProgressView().controlSize(.small) }
            if !draft.action.status.isEmpty { Text(l(draft.action.status)).foregroundStyle(.secondary) }
        }
        .disabled(draft.action.busy)
        .onChange(of: connected, initial: true) { _, available in
            if available && palette.isEmpty && !draft.action.busy { load() }
        }
        .onChange(of: palette) {
            if palette.isEmpty { draft.undo = [:] }
        }
    }

    private var marked: Set<UInt8> {
        Set(KeySettingsView.slots.compactMap { draft.changes[$0.value] == nil ? nil : $0.key })
    }

    private var preview: [UInt32] {
        guard palette.count == 128 else { return [] }
        var result = palette
        for (slot, rgb) in draft.changes { result[Int(slot)] = rgb }
        return result
    }

    private func toggle(_ key: UInt8) {
        if draft.selection.remove(key) == nil {
            draft.selection.insert(key)
            if draft.selection.count == 1, let slot = KeySettingsView.slots[key], preview.indices.contains(Int(slot)) {
                draft.color = Color(rgb24: preview[Int(slot)])
            }
        }
    }

    private func paint() {
        guard let rgb = draft.color.rgb24, palette.count == 128 else { return }
        for slot in draft.selection.compactMap({ KeySettingsView.slots[$0] }) {
            draft.changes[slot] = palette[Int(slot)] == rgb ? nil : rgb
        }
        draft.action.status = draft.changes.isEmpty ? "" : "Uygulanmamış değişiklikler"
    }

    private func load() {
        run("Tuş renkleri okundu.", operation: { try Keyboard.keyColors() }) { current in
            if current != palette { draft.undo = [:] }
            draft.changes = draft.changes.filter { current[Int($0.key)] != $0.value }
        }
    }

    private func save(_ requested: [UInt8: UInt32], isUndo: Bool) {
        let previous = palette
        guard previous.count == 128, !requested.isEmpty,
              let id = transfer.start(.lighting, title: "Tuş renkleri yazılıyor") else { return }
        run(isUndo ? "Tuş renkleri geri alındı." : "Tuş renkleri yazıldı ve doğrulandı.", transferID: id, operation: {
            try Keyboard.setKeyColors(requested, previous: previous) { value in
                Task { @MainActor in transfer.update(id, progress: value) }
            }
        }) { _ in
            draft.changes = [:]
            draft.undo = isUndo ? [:] : requested.reduce(into: [:]) { $0[$1.key] = previous[Int($1.key)] }
        }
    }

    private func run(
        _ success: String, transferID: UUID? = nil,
        operation: @escaping @Sendable () throws -> [UInt32], update: @escaping ([UInt32]) -> Void
    ) {
        draft.action.busy = true
        draft.action.status = ""
        draft.action.perform(operation) { result in
            if let transferID { transfer.finish(transferID) }
            draft.action.busy = false
            switch result {
            case .success(let current):
                guard connected else { return }
                update(current)
                palette = current
                draft.action.status = success
            case .failure(let error):
                palette = []
                draft.action.status = l.message(error)
            }
        }
    }
}

struct DeviceOptionsView: View {
    @Environment(\.appLanguage) private var l
    let connected: Bool
    let transfer: WorkspaceTransfer
    @State private var restorePlan: SnapshotRestorePlan?
    @State private var importing = false
    @State private var reviewing = false
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
                        .disabled(!connected || initial == nil || initial == draft)
                    if action.busy { ProgressView().controlSize(.small) }
                }
                .disabled(action.busy)
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
            Section(l("Ayar kaydı")) {
                HStack {
                    Button(l("Ayarları JSON olarak dışa aktar")) { export() }
                    Button(l("JSON kaydını aç")) { importing = true }
                }
                .disabled(action.busy || !connected)
                Text(l("Üç profilin tuş atamalarını, aydınlatmayı ve cihaz ayarlarını dosyaya kaydeder."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(transfer.isBusy)
        .onChange(of: connected, initial: true) {
            if connected && !transfer.isBusy && !action.busy { load() }
            if !connected { initial = nil }
        }
        .onChange(of: transfer.settingsRevision) {
            guard connected, !action.busy else { return }
            initial = nil
            action.busy = true
            action.perform({ try Keyboard.options() }) { result in
                action.busy = false
                if connected, case .success(let options) = result {
                    initial = options
                    draft = options
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { review(try result.get()) }
            catch { action.status = l.message(error) }
        }
        .sheet(isPresented: $reviewing, onDismiss: { restorePlan = nil }) {
            if let restorePlan {
                RestoreReview(plan: restorePlan, apply: { restore(restorePlan, selection: $0) },
                              cancel: { reviewing = false })
            }
        }
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

    private func review(_ url: URL) {
        guard connected, let id = transfer.start(.device, title: "Ayarlar karşılaştırılıyor", determinate: false) else { return }
        action.status = ""
        action.perform {
            let backup = try SettingsSnapshot.load(from: url)
            return try SnapshotRestorePlan(current: Keyboard.snapshot(), backup: backup)
        } completion: { result in
            transfer.finish(id)
            switch result {
            case .success(let plan):
                restorePlan = plan
                reviewing = true
            case .failure(let error):
                action.status = l.message(error)
            }
        }
    }

    private func restore(_ plan: SnapshotRestorePlan, selection: Set<SnapshotRestorePlan.Item>) {
        guard connected, let id = transfer.start(.device, title: "Ayarlar geri yükleniyor") else { return }
        reviewing = false
        initial = nil
        action.status = ""
        action.perform {
            try Keyboard.restore(plan, selection: selection) { progress in
                Task { @MainActor in transfer.update(id, progress: progress) }
            }
        } completion: { result in
            transfer.finish(id, settingsChanged: true)
            switch result {
            case .success:
                action.status = l.format("%@ değişiklik yazıldı ve klavyeden doğrulandı.", String(selection.count))
            case .failure(let error as SnapshotRestoreFailure):
                action.status = l.format("%@ değişiklik doğrulandı. İşlem durdu. %@ Yeni bir önizleme aç.",
                                         String(error.verifiedCount), l.message(error.cause))
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
    let isActive: Bool
    let connected: Bool
    @State private var playback: Task<Void, Never>?
    @State private var held: Set<UInt8> = []
    @State private var playingIndex: Int?
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
                Button(l("Yuvayı oku")) { load() }.disabled(!connected)
                Stepper(l.format("Tekrar · %@", String(repeats)), value: $repeats, in: 1...999)
                    .disabled(previous == nil)
            }
            .disabled(action.busy)
            Section(l("Zaman çizelgesi")) {
                KeyboardLayout(selected: held)
                HStack {
                    Button(l("Bir tur önizle"), systemImage: "play.fill", action: play)
                        .disabled(strokes.isEmpty || playback != nil)
                    if playback != nil {
                        Button(l("Durdur"), systemImage: "stop.fill", action: stop)
                    }
                    Spacer()
                    Text(l.format("%@ olay · %@ ms", String(strokes.count), String(duration)))
                        .foregroundStyle(.secondary)
                }
                if let playingIndex, strokes.indices.contains(playingIndex) {
                    let stroke = strokes[playingIndex]
                    Text(l.format("%@ / %@ · %@ · %@", String(playingIndex + 1), String(strokes.count),
                                  keyName(stroke.key), l(stroke.down ? "Bas" : "Bırak")))
                        .monospacedDigit()
                }
            }
            Section(l("Olay ekle")) {
                Picker(l("Tuş"), selection: $key) {
                    ForEach(KeySettingsView.keys, id: \.0) { item in Text(l(item.1)).tag(item.0) }
                }
                Stepper(l.format("Olaydan sonra bekle · %@ ms", String(delay)), value: $delay, in: 0...5000, step: 10)
                HStack {
                    Button(l("Vuruş ekle")) {
                        strokes += [Macro.Stroke(key: key, down: true, delay: 30), Macro.Stroke(key: key, down: false, delay: delay)]
                    }
                    .disabled(strokes.count > 107)
                    Button(l("Basma ekle")) { strokes.append(Macro.Stroke(key: key, down: true, delay: delay)) }
                    Button(l("Bırakma ekle")) { strokes.append(Macro.Stroke(key: key, down: false, delay: delay)) }
                }
                .disabled(strokes.count >= 109)
            }
            .disabled(previous == nil || action.busy)
            Section(l("Tuş olayları")) {
                if strokes.isEmpty { Text(l("Olay yok")).foregroundStyle(.secondary) }
                ForEach(strokes.indices, id: \.self) { index in
                    event(index)
                }
                Button(l("Taslağı temizle")) { strokes = [] }.disabled(strokes.isEmpty)
            }
            .disabled(previous == nil || action.busy)
            Section {
                HStack {
                    Button(l("Makroyu klavyeye yaz")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(previous == nil || action.busy || !connected)
                    if action.busy { ProgressView().controlSize(.small) }
                }
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: strokes) { stop() }
        .onChange(of: isActive) { if !isActive { stop() } }
        .onDisappear { stop() }
    }

    private var duration: Int { strokes.reduce(0) { $0 + Int($1.delay) } }

    private func keyName(_ usage: UInt8) -> String {
        KeySettingsView.keys.first { $0.0 == usage }.map { l($0.1) }
            ?? String(format: "HID 0x%02X", usage)
    }

    private func event(_ index: Int) -> some View {
        let usage = strokes[index].key
        return HStack(spacing: 8) {
            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 27, alignment: .trailing)
            Picker(l("Tuş"), selection: $strokes[index].key) {
                if !KeySettingsView.keys.contains(where: { $0.0 == usage }) {
                    Text(keyName(usage)).tag(usage)
                }
                ForEach(KeySettingsView.keys, id: \.0) { item in Text(l(item.1)).tag(item.0) }
            }
            .labelsHidden()
            .frame(minWidth: 100, maxWidth: .infinity)
            Picker(l("Olay"), selection: $strokes[index].down) {
                Text(l("Bas")).tag(true)
                Text(l("Bırak")).tag(false)
            }
            .labelsHidden()
            TextField(l("Gecikme (ms)"), value: $strokes[index].delay, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 58)
            Text("ms").foregroundStyle(.secondary)
            Button(l("Yukarı taşı"), systemImage: "chevron.up") { strokes.swapAt(index, index - 1) }
                .disabled(index == 0)
                .help(l("Yukarı taşı"))
            Button(l("Aşağı taşı"), systemImage: "chevron.down") { strokes.swapAt(index, index + 1) }
                .disabled(index == strokes.count - 1)
                .help(l("Aşağı taşı"))
            Button(l("Olayı sil"), systemImage: "trash") { strokes.remove(at: index) }
                .help(l("Olayı sil"))
        }
        .labelStyle(.iconOnly)
        .padding(.vertical, 2)
        .listRowBackground(playingIndex == index ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private func play() {
        guard playback == nil else { return }
        let events = strokes
        playback = Task {
            for (index, stroke) in events.enumerated() {
                guard !Task.isCancelled else { return }
                playingIndex = index
                if stroke.down { held.insert(stroke.key) } else { held.remove(stroke.key) }
                // Very short HID events still get a visible highlight in the editor.
                do { try await Task.sleep(for: .milliseconds(max(90, Int(stroke.delay)))) }
                catch { return }
            }
            stop()
        }
    }

    private func stop() {
        playback?.cancel()
        playback = nil
        playingIndex = nil
        held = []
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
        stop()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let connected: Bool
    let isActive: Bool
    let transfer: WorkspaceTransfer
    @State private var artwork: ScreenArtwork?
    @State private var sourceData: Data?
    @State private var fileName = ""
    @State private var sizing = ScreenArtwork.Sizing.fit
    @State private var playing = false
    @State private var frame = 0
    @State private var choosing = false
    @State private var confirming = false
    @State private var dropping = false
    @State private var slot: UInt8 = 0
    @State private var action = DeviceAction()

    var body: some View {
        Form {
            Section(l("128 × 128 ekran")) {
                VStack(spacing: 8) {
                    if let artwork {
                        preview(artwork.previews[frame % artwork.previews.count])
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
                    Text(l("PNG, JPEG veya GIF dosyasını buraya bırak")).foregroundStyle(.secondary)
                    Button(l("Görsel veya GIF seç")) { choosing = true }.disabled(action.busy)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(dropping ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(
                        dropping ? Color.accentColor : Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )
                    .allowsHitTesting(false)
                }
                .dropDestination(for: URL.self) { files, _ in
                    guard !action.busy, files.count == 1, let url = files.first, url.isFileURL else { return false }
                    open(url)
                    return true
                } isTargeted: { dropping = $0 && !action.busy }
                if let artwork {
                    LabeledContent(l("Dosya"), value: fileName)
                    Picker(l("Yerleşim"), selection: $sizing) {
                        ForEach(ScreenArtwork.Sizing.allCases, id: \.self) { mode in
                            Text(l(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(action.busy)
                    if artwork.frames.count == 1 {
                        Picker(l("Görsel yuvası"), selection: $slot) {
                            ForEach(0..<5) { value in Text(l.format("Yuva %@", String(value + 1))).tag(UInt8(value)) }
                        }
                        .disabled(action.busy)
                    } else {
                        LabeledContent(l("Animasyon"), value: l.format("%@ kare · %@ ms", String(artwork.frames.count), String(artwork.delay)))
                        HStack {
                            Button(l(playing ? "Duraklat" : "Oynat"), systemImage: playing ? "pause.fill" : "play.fill") {
                                playing.toggle()
                            }
                            Stepper(l.format("Kare %@ / %@", String(frame + 1), String(artwork.frames.count)),
                                    value: $frame, in: 0...(artwork.frames.count - 1))
                                .disabled(playing)
                        }
                    }
                }
            }
            Section {
                Button(l("Ekrana aktar")) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || action.busy || artwork == nil || transfer.isBusy)
                if action.busy && transfer.job?.page != .display {
                    ProgressView().controlSize(.small)
                }
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task(id: playing && isActive ? artwork?.delay : nil) {
            guard playing, isActive, let artwork, artwork.frames.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(Int(artwork.delay))) }
                catch { return }
                frame = (frame + 1) % artwork.frames.count
            }
        }
        .onChange(of: sizing) {
            if let sourceData { prepare(fileName) { sourceData } }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .gif]) { result in
            do { open(try result.get()) }
            catch { action.status = l.message(error) }
        }
        .confirmationDialog(l("Ekran içeriğini değiştir"), isPresented: $confirming) {
            Button(l("Aktar")) { upload() }
        } message: {
            Text(artwork?.frames.count == 1
                ? l.format("Yuva %@ içindeki görsel değişecek.", String(Int(slot) + 1))
                : l("Mevcut animasyon değişecek."))
        }
    }

    private func preview(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: 128, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .background(.black, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityLabel(l("Ekran önizlemesi"))
    }

    private func open(_ url: URL) {
        prepare(url.lastPathComponent) { try ScreenArtwork.read(url) }
    }

    private func prepare(_ name: String, read: @escaping @Sendable () throws -> Data) {
        let mode = sizing
        action.busy = true
        action.status = ""
        playing = false
        frame = 0
        action.perform {
            let data = try read()
            return (data, try ScreenArtwork(data: data, sizing: mode))
        } completion: { result in
            action.busy = false
            switch result {
            case .success(let (data, decoded)):
                sourceData = data
                artwork = decoded
                fileName = name
                playing = !reduceMotion && decoded.frames.count > 1
            case .failure(let error):
                artwork = nil
                sourceData = nil
                action.status = l.message(error)
            }
        }
    }

    private func upload() {
        guard let artwork, let id = transfer.start(.display, title: "Görsel aktarılıyor") else { return }
        let destination = slot
        action.busy = true
        action.status = ""
        action.perform {
            try Keyboard.uploadArtwork(artwork, slot: destination) { value in
                Task { @MainActor in transfer.update(id, progress: value) }
            }
        } completion: { result in
            transfer.finish(id)
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
