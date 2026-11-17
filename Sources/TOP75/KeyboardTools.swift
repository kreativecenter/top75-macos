import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyboardTestView: View {
    @Environment(\.appLanguage) private var l
    let connection: KeyboardConnection?
    let isActive: Bool
    let requestAccess: () -> Void
    @State private var reader = KeyInput()
    @State private var running = false
    @State private var held: Set<KeySignal> = []
    @State private var seen: Set<KeySignal> = []
    @State private var latest: KeySignal?
    @State private var peak = 0
    @State private var firmware: UInt16?
    @State private var diagnostic = ""
    @State private var action = DeviceAction()
    private let battery = BatteryMonitor.shared

    var body: some View {
        Form {
            Section(l("Tuş testi")) {
                Text(l("Çizim, klavyenin gönderdiği tuş kodlarını gösterir. Yeniden atanmış tuşlar yeni kodlarıyla görünür."))
                    .foregroundStyle(.secondary)
                KeyboardLayout(selected: codes(held), marked: codes(seen))
                LabeledContent(l("Son sinyal"), value: latest.map(signalLabel) ?? "—")
                LabeledContent(l("Aynı anda basılan tuşlar"), value: l.format("%@ · en çok %@", String(held.count), String(peak)))
                LabeledContent(l("Görülen farklı kodlar"), value: String(seen.count))
                HStack {
                    Button(l(running ? "Durdur" : "Testi başlat"), systemImage: running ? "stop.fill" : "play.fill") {
                        if running { stop() } else { start() }
                    }
                    Button(l("Testi temizle")) { reset() }.disabled(seen.isEmpty)
                    if !KeyInput.hasAccess {
                        Button(l("Giriş İzleme ayarlarını aç"), action: requestAccess).buttonStyle(.link)
                    }
                }
                if !action.status.isEmpty { Text(l(action.status)).foregroundStyle(.secondary) }
            }
            Section(l("Bağlantı tanısı")) {
                LabeledContent(l("Mac’in gördüğü bağlantı"), value: detectedLabel)
                LabeledContent(l("Ayar bağlantısı"), value: connection.map { l($0.label) } ?? "—")
                LabeledContent(l("Giriş İzleme"), value: l(KeyInput.hasAccess ? "İzin verildi" : "İzin gerekiyor"))
                LabeledContent(l("Firmware"), value: firmware.map(String.init) ?? "—")
                LabeledContent(l("Pil kaynağı"), value: batterySource)
                HStack {
                    Button(l("Ayar bağlantısını sına"), action: probe)
                        .disabled(connection == nil || action.busy || WorkspaceTransfer.shared.isBusy)
                    Button(l("Tanıyı kopyala"), systemImage: "doc.on.doc", action: copy)
                    if action.busy { ProgressView().controlSize(.small) }
                }
                if !diagnostic.isEmpty { Text(diagnostic).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onChange(of: isActive) { if !isActive { stop() } }
        .onChange(of: connection) { stop(); firmware = nil; diagnostic = "" }
        .onDisappear(perform: stop)
    }

    private var detectedLabel: String {
        if Keyboard.hasUSBInterface() { return l(KeyboardConnection.usb.label) }
        if let bluetooth = BluetoothKeyboard.detectedConnection() { return l(bluetooth.label) }
        if battery.receiverOnline { return l(KeyboardConnection.receiver.label) }
        return l("Klavye bağlantısı yok")
    }

    private var batterySource: String {
        guard let percent = battery.percent, let source = battery.percentSource else { return l("Pil yüzdesi alınamadı") }
        return "\(l(source.label)) · \((Double(percent) / 100).formatted(.percent.locale(Locale(identifier: l.code))))"
    }

    private func signalLabel(_ signal: KeySignal) -> String {
        let code = String(format: "0x%02X", signal.usage)
        let name = signal.page == 7
            ? KeySettingsView.keys.first(where: { UInt32($0.0) == signal.usage })?.1
            : KeyAssignment.mediaOptions.first(where: { UInt32($0.0) == signal.usage })?.1
        return "\(name.map { l($0) } ?? (signal.page == 7 ? "HID" : l("Medya"))) · \(code)"
    }

    private func codes(_ signals: Set<KeySignal>) -> Set<UInt8> {
        Set(signals.compactMap { $0.page == 7 ? UInt8(exactly: $0.usage) : nil })
    }

    private func start() {
        action.status = ""
        running = reader.start { signal, down in
            guard running, NSApp.isActive else { return }
            if down {
                held.insert(signal)
                seen.insert(signal)
                latest = signal
                peak = max(held.count, peak)
            } else {
                held.remove(signal)
            }
        }
        if !running { action.status = "Tuşları okumak için TOP75’e Giriş İzleme izni ver ve uygulamayı yeniden aç." }
    }

    private func stop() {
        reader.stop()
        running = false
        held.removeAll()
    }

    private func reset() {
        seen = held
        latest = nil
        peak = held.count
    }

    private func probe() {
        guard let connection else { return }
        action.busy = true
        diagnostic = ""
        action.perform({ try Keyboard.profileInfo(connection: connection).firmware }) { result in
            action.busy = false
            guard self.connection == connection else { return }
            switch result {
            case .success(let version):
                firmware = version
                diagnostic = l("Klavye ayar sorgusuna yanıt verdi.")
            case .failure(let error):
                firmware = nil
                diagnostic = l.message(error)
            }
        }
    }

    private func copy() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let lines = [
            "TOP75 \(version) / macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "\(l("Mac’in gördüğü bağlantı")): \(detectedLabel)",
            "\(l("Ayar bağlantısı")): \(connection.map { l($0.label) } ?? "—")",
            "\(l("Giriş İzleme")): \(l(KeyInput.hasAccess ? "İzin verildi" : "İzin gerekiyor"))",
            "\(l("Firmware")): \(firmware.map(String.init) ?? "—")",
            "\(l("Pil kaynağı")): \(batterySource)",
            diagnostic
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

extension KeyboardConnection {
    var label: String {
        switch self {
        case .usb: "USB"
        case .receiver: "2,4 GHz"
        case .bluetooth: "Bluetooth 3.0"
        case .bluetoothLowEnergy: "Bluetooth 5.0"
        }
    }
}

struct ActiveKeymap: Sendable {
    let profile: UInt8
    let base: [UInt8: KeyAssignment]
    let function: [UInt8: KeyAssignment]
}

struct KeymapCard: View {
    @Environment(\.appLanguage) private var l
    @AppStorage("profileNames") private var names = Data()
    @State private var map: ActiveKeymap?
    @State private var fn = false
    @State private var pin = false
    @State private var refresh = 0
    @State private var error = ""
    @State private var exportDocument: PDFDocument?
    @State private var exporting = false
    private let transfer = WorkspaceTransfer.shared
    private let profiles = ProfileAutomation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l("Tuş haritası")).font(.title2.bold())
                Spacer()
                Toggle(l("Üstte tut"), isOn: $pin).toggleStyle(.checkbox)
            }
            if let map {
                Text(profileName(map.profile, stored: names, language: l)).foregroundStyle(.secondary)
                Picker(l("Katman"), selection: $fn) {
                    Text(l("Temel")).tag(false)
                    Text("Fn").tag(true)
                }.pickerStyle(.segmented)
                layout(map, fn: fn)
                Text(l("Bir atamanın tam adını görmek için imleci tuşun üzerinde tut.")).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
            HStack {
                Button(l("Klavyeden oku"), systemImage: "arrow.clockwise") { refresh += 1 }.disabled(transfer.isBusy)
                Spacer()
                Button(l("PDF olarak kaydet"), systemImage: "square.and.arrow.up", action: prepareExport)
                    .disabled(map == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 565, idealWidth: 630)
        .background(WindowLevel(pinned: pin))
        .task(id: LoadKey(profile: profiles.profile, revision: transfer.settingsRevision, refresh: refresh, busy: transfer.isBusy)) {
            if !transfer.isBusy { await load() }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .pdf, defaultFilename: "TOP75-keymap") {
            if case .failure(let failure) = $0 { error = l.message(failure) }
        }
    }

    private struct LoadKey: Equatable {
        let profile: UInt8?
        let revision: Int
        let refresh: Int
        let busy: Bool
    }

    private func load() async {
        guard let connection = Keyboard.availableConnection() else { map = nil; error = l("Klavye bağlantısı yok"); return }
        do {
            let current = try await Task.detached { try Keyboard.activeKeymap(connection: connection) }.value
            guard !Task.isCancelled, Keyboard.availableConnection() == connection else { return }
            map = current
            error = ""
        } catch {
            guard !Task.isCancelled else { return }
            map = nil
            self.error = l.message(error)
        }
    }

    private func layout(_ map: ActiveKeymap, fn: Bool) -> some View {
        let layer = fn ? map.function : map.base
        let labels = layer.map { code, assignment in
            let label: String
            if fn, assignment == .disabled, let inherited = map.base[code] {
                label = "↳ \(inherited.displayName(fn: false, language: l))"
            } else {
                label = assignment.displayName(fn: fn, language: l)
            }
            return (code, label)
        }
        return KeyboardLayout(legends: Dictionary(uniqueKeysWithValues: labels))
    }

    private func prepareExport() {
        guard let map else { return }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 720, height: 500)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 9) {
            Text("TOP75 · \(profileName(map.profile, stored: names, language: l))").font(.title2.bold())
            Text(l("Temel")).font(.headline)
            layout(map, fn: false)
            Text("Fn").font(.headline)
            layout(map, fn: true)
        }.environment(\.colorScheme, .light).environment(\.appLanguage, l).padding(16).frame(width: 720))
        renderer.render { size, draw in
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: 0, y: max(0, box.height - size.height))
            draw(pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        exportDocument = PDFDocument(data: data as Data)
        exporting = true
    }
}

private struct WindowLevel: NSViewRepresentable {
    let pinned: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in view.window?.level = pinned ? .floating : .normal }
    }
}

private struct PDFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
