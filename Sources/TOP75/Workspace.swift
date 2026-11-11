import IOKit.hid
import SwiftUI

enum LanguagePreference: String, CaseIterable, Identifiable {
    case system, english, turkish
    var id: Self { self }

    var language: AppLanguage {
        switch self {
        case .system: AppLanguage(code: Locale.preferredLanguages.first?.hasPrefix("tr") == true ? "tr" : "en")
        case .english: AppLanguage(code: "en")
        case .turkish: AppLanguage(code: "tr")
        }
    }
}

struct AppLanguage: Equatable, Sendable {
    let code: String

    private var translations: Bundle? {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        guard let path = resources.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    func callAsFunction(_ key: String) -> String {
        translations?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self(key), locale: Locale(identifier: code), arguments: arguments)
    }

    func message(_ error: any Error) -> String {
        switch error {
        case KeyboardError.wrongDevice(let id):
            format("Cihaz kimliği eşleşmedi (%@).", String(id))
        case KeyboardError.transport(let operation, let code):
            format("%@ başarısız (%@).", self(operation), String(format: "0x%08X", UInt32(bitPattern: code)))
        default:
            self(error.localizedDescription)
        }
    }
}

private struct LanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage(code: "en")
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[LanguageKey.self] }
        set { self[LanguageKey.self] = newValue }
    }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case lighting, keys, macros, display, device, guide

    var id: Self { self }

    var title: String {
        switch self {
        case .lighting: "Aydınlatma"
        case .keys: "Tuşlar ve profiller"
        case .macros: "Makrolar"
        case .display: "Ekran"
        case .device: "Cihaz ayarları"
        case .guide: "Kılavuz"
        }
    }

    var symbol: String {
        switch self {
        case .lighting: "lightbulb"
        case .keys: "keyboard"
        case .macros: "command"
        case .display: "display"
        case .device: "gearshape"
        case .guide: "book"
        }
    }

    var subtitle: String {
        switch self {
        case .lighting: "RGB efektlerini düzenle veya her tuşa kendi rengini ver."
        case .keys: "Klavye üzerindeki profilleri ve tuş atamalarını düzenle."
        case .macros: "Tuş vuruşlarını birleştir ve klavyedeki bir yuvaya kaydet."
        case .display: "Klavye ekranına bir fotoğraf veya animasyon yükle."
        case .device: "Tuş tepkisini, kablosuz uyku sürelerini ve ayar kayıtlarını yönet."
        case .guide: "TOP75 kısayollarını ve bağlantı adımlarını ara."
        }
    }
}

struct WorkspaceView: View {
    @Environment(\.appLanguage) private var l
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("workspace.page") private var storedPage = WorkspacePage.lighting
    @State private var mountedPages: Set<WorkspacePage> = []
    @State private var guideFocus = 0
    @State private var connected = false

    private var selection: Binding<WorkspacePage?> {
        Binding(get: { storedPage }, set: { if let page = $0 { storedPage = page } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section(l("Düzenle")) {
                    sidebarRow(.lighting)
                    sidebarRow(.keys)
                    sidebarRow(.macros)
                    sidebarRow(.display)
                }
                Section(l("Cihaz")) {
                    sidebarRow(.device)
                    sidebarRow(.guide)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 195, ideal: 217, max: 250)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Darmoshark TOP75").font(.subheadline.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle().fill(connected ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(l(connected ? "USB bağlı" : "USB bağlantısı yok"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(.bar)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l(storedPage.title)).font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(l(storedPage.subtitle)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                Divider()
                ZStack {
                    ForEach(WorkspacePage.allCases.filter { mountedPages.contains($0) || storedPage == $0 }) { page in
                        content(page)
                            .frame(maxWidth: 790)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(page == storedPage ? 1 : 0)
                            .allowsHitTesting(page == storedPage)
                            .accessibilityHidden(page != storedPage)
                    }
                }
            }
            .background(.background)
            .navigationTitle("TOP75")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(l("Kılavuzda ara"), systemImage: "magnifyingglass") {
                        storedPage = .guide
                        guideFocus += 1
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help(l("Kılavuzda ara"))
                    Button(l("Uygulama ayarları"), systemImage: "gearshape") {
                        openSettings()
                    }
                    .help(l("Uygulama ayarları"))
                }
            }
        }
        .frame(minWidth: 790, minHeight: 550)
        .onChange(of: storedPage, initial: true) { mountedPages.insert(storedPage) }
        .task {
            while !Task.isCancelled {
                connected = Keyboard.hasUSBInterface()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sidebarRow(_ page: WorkspacePage) -> some View {
        Label(l(page.title), systemImage: page.symbol).tag(page)
    }

    @ViewBuilder
    private func content(_ page: WorkspacePage) -> some View {
        switch page {
        case .lighting: LightingView()
        case .keys: KeySettingsView()
        case .macros: MacroView()
        case .display: ScreenView()
        case .device: DeviceOptionsView()
        case .guide: GuideView(focusRequest: guideFocus)
        }
    }
}

struct PreferencesView: View {
    @Environment(\.appLanguage) private var l
    @Binding var preference: LanguagePreference

    var body: some View {
        Form {
            Picker(l("Uygulama dili"), selection: $preference) {
                Text(l("Sistem dili")).tag(LanguagePreference.system)
                Text("English").tag(LanguagePreference.english)
                Text("Türkçe").tag(LanguagePreference.turkish)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 136)
    }
}

extension Keyboard {
    static let usbMatching: [String: Int] = [
        kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x4015,
        kIOHIDPrimaryUsagePageKey: 0xFFFF, kIOHIDPrimaryUsageKey: 2
    ]

    static func hasUSBInterface() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, usbMatching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains {
            IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String == "USB"
        }
    }
}

struct LevelSlider: View {
    @Environment(\.appLanguage) private var l
    let title: String
    @Binding var value: Int
    let icon: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 9) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...4, step: 1)
                    .frame(width: 146)
                    .accessibilityLabel(l(title))
                Text("\(value + 1) / 5")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Label(l(title), systemImage: icon)
        }
    }
}
