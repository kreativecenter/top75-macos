import SwiftUI

struct Entry: Identifiable, Hashable {
    let title: String
    let group: String
    let shortcut: String
    let detail: String
    let keywords: String
    var id: String { title }

    static let catalog = [
        Entry(title: "Mac modu", group: "Sistem", shortcut: "Fn + Sağ Ctrl · 3 sn", detail: "Mac multimedya tuşlarını etkinleştirir. Windows moduna dönmek için aynı tuşları tekrar 3 saniye basılı tut.", keywords: "macOS iOS windows multimedia"),
        Entry(title: "Bluetooth eşleştirme", group: "Bağlantı", shortcut: "Fn + E / R / T · basılı tut", detail: "Üç Bluetooth yuvasından birini seç. Mavi ışık hızlı yanıp sönerken Mac’in Bluetooth ayarlarında TOP75 BT3.0 veya BT5.0 adını ara.", keywords: "bt pairing kablosuz"),
        Entry(title: "USB bağlantısı", group: "Bağlantı", shortcut: "Mod anahtarı → OFF", detail: "Veri kablosunu bağla ve mod anahtarını OFF konumuna getir. Klavye ekranında USB durumunu kontrol et.", keywords: "wired cable kablo"),
        Entry(title: "Arka ışığı aç veya kapat", group: "Aydınlatma", shortcut: "Fn + Delete", detail: "Klavye aydınlatmasını açar veya kapatır.", keywords: "rgb led backlight"),
        Entry(title: "Aydınlatma efekti", group: "Aydınlatma", shortcut: "Fn + Home", detail: "18 aydınlatma efekti arasında geçiş yapar.", keywords: "rgb led lighting"),
        Entry(title: "Parlaklık", group: "Aydınlatma", shortcut: "Fn + ↑ / ↓", detail: "Arka ışığı beş parlaklık seviyesinden birine ayarlar.", keywords: "rgb brightness ışık"),
        Entry(title: "Efekt hızı", group: "Aydınlatma", shortcut: "Fn + ← / →", detail: "Aydınlatma efektinin hızını beş seviyede değiştirir.", keywords: "rgb speed animasyon"),
        Entry(title: "Tek renk ve efekt yönü", group: "Aydınlatma", shortcut: "Fn + PgUp / PgDn", detail: "PgUp tek renk moduna geçer. PgDn destekleyen efektlerde yönü değiştirir.", keywords: "rgb monochrome direction"),
        Entry(title: "Özel tuş aydınlatması", group: "Aydınlatma", shortcut: "Fn + U / I / O / P", detail: "Bir aydınlatma yuvası seç. Fn + ters eğik çizgi tuşuyla kaydı başlat, renkleri değiştirmek için ilgili tuşlara bas ve aynı kısayolla kaydet.", keywords: "rgb custom led per key profil"),
        Entry(title: "Klavye ekranını aç veya kapat", group: "Ekran", shortcut: "Fn + Caps Lock", detail: "Klavye üzerindeki renkli ekranı açar veya kapatır.", keywords: "lcd display screen"),
        Entry(title: "Ekran görseli ve GIF", group: "Ekran", shortcut: "", detail: "Ekran bölümünden PNG, JPEG veya GIF seçip klavyeye gönderebilirsin.", keywords: "lcd animasyon resim display"),
        Entry(title: "Pil ve şarj", group: "Sistem", shortcut: "", detail: "Pil simgesi kırmızıysa klavyeyi şarj et. Kablo bağlıyken ekrandaki pil animasyonu şarj durumunu gösterir.", keywords: "batarya battery charge")
    ]

    static func search(_ query: String, language: AppLanguage = AppLanguage(code: "tr")) -> [Entry] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return catalog }
        let phrase = terms.joined(separator: " ")
        return catalog.enumerated().compactMap { index, entry -> (Int, Int, Entry)? in
            let title = normalized(language(entry.title))
            let body = normalized([language(entry.group), language(entry.shortcut), language(entry.detail), entry.keywords].joined(separator: " "))
            guard terms.allSatisfy({ title.contains($0) || body.contains($0) }) else { return nil }
            let titleMatches = terms.filter { title.contains($0) }.count
            let score = titleMatches * 10 + (title.hasPrefix(phrase) ? 5 : 0)
            return (score, index, entry)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
        }.map { $0.2 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }
}

struct GuideView: View {
    @Environment(\.appLanguage) private var l
    let focusRequest: Int
    @State private var query = ""
    @State private var selection: Entry.ID?
    @FocusState private var searchFocused: Bool

    private var results: [Entry] { Entry.search(query, language: l) }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(l("İşlev veya kısayol ara"), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !query.isEmpty {
                        Button(l("Aramayı temizle"), systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
                List(selection: $selection) {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = results.first {
                        Section(l("En iyi eşleşme")) { row(first) }
                        if results.count > 1 {
                            Section(l("Diğer sonuçlar")) { ForEach(results.dropFirst()) { row($0) } }
                        }
                    } else {
                        ForEach(results) { row($0) }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView(l("Sonuç bulunamadı"), systemImage: "magnifyingglass")
                    }
                }
            }
            .frame(minHeight: 170, idealHeight: 260)
            ScrollView {
                if let entry = results.first(where: { $0.id == selection }) ?? results.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l(entry.title)).font(.title2.bold())
                        if !entry.shortcut.isEmpty {
                            Text(l(entry.shortcut))
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        Text(l(entry.detail)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
            .frame(minHeight: 150)
        }
        .onChange(of: query, initial: true) { selection = results.first?.id }
        .onChange(of: l) { selection = results.first?.id }
        .onChange(of: focusRequest, initial: true) { if focusRequest > 0 { searchFocused = true } }
    }

    private func row(_ entry: Entry) -> some View {
        HStack {
            Text(l(entry.title))
            Spacer()
            Text(l(entry.shortcut.isEmpty ? entry.group : entry.shortcut))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .tag(entry.id)
    }
}

@main
enum Launch {
    static func main() {
        if CommandLine.arguments.contains("--verify") {
            precondition(Entry.search("MAC").first?.title == "Mac modu")
            precondition(Entry.search("parlaklik").first?.title == "Parlaklık")
            precondition(Entry.search("rgb parlaklik").first?.title == "Parlaklık")
            precondition(Entry.search("    ").count == Entry.catalog.count)
            precondition(Entry.search("bilinmeyen-terim").isEmpty)
            precondition(AppIcon.image() != nil, "The application icon is missing or unreadable.")
            let english = AppLanguage(code: "en")
            let turkish = AppLanguage(code: "tr")
            precondition(english("Aydınlatma") == "Lighting")
            precondition(turkish("Aydınlatma") == "Aydınlatma")
            precondition(english.format("Profil %@", "2") == "Profile 2")
            precondition(Entry.search("brightness", language: english).first?.title == "Parlaklık")
            precondition(Set(KeyboardLayout.selectableCodes).isSubset(of: Set(KeySettingsView.slots.keys)))
            let lighting = Lighting(effect: 1, speed: 2, brightness: 3, flags: 7, rgb: 0x10A0FF)
            let report = lighting.report
            precondition(report.count == 64 && report.prefix(9).reduce(UInt8(0), &+) == 0xFF)
            precondition(report.prefix(8) == [0x07, 1, 2, 3, 7, 0x10, 0xA0, 0xFF])
            let identify = Keyboard.report([0x8F], checksumIndex: 7)
            precondition(identify[7] == 0x70)
            let macro = Macro(repeats: 1, strokes: [
                Macro.Stroke(key: 115, down: true, delay: 20),
                Macro.Stroke(key: 115, down: false, delay: 250)
            ])
            let bytes = try! macro.encoded()
            let decoded = try! Macro(bytes: bytes)
            precondition(decoded.strokes.count == 2 && decoded.strokes[1].delay == 250)
            let pixels = ScreenArtwork.rgb565 { x, y in x == 0 && y == 1 ? (255, 0, 0) : (0, 0, 255) }
            precondition(pixels.count == 32_768 && pixels.prefix(6) == [0, 31, 248, 0, 0, 31])
            print("Localization, search, keyboard layout, HID packet, macro and RGB565 checks passed.")
            return
        }
        TOP75App.main()
    }

}

struct TOP75App: App {
    #if SWIFT_PACKAGE
    @NSApplicationDelegateAdaptor(DevelopmentAppDelegate.self) private var appDelegate
    #endif
    @AppStorage("interfaceLanguage") private var preference = LanguagePreference.system

    var body: some Scene {
        WindowGroup("TOP75") {
            WorkspaceView()
                .environment(\.appLanguage, preference.language)
                .environment(\.locale, Locale(identifier: preference.language.code))
        }
        .defaultSize(width: 1060, height: 735)
        Settings {
            PreferencesView(preference: $preference)
                .environment(\.appLanguage, preference.language)
                .environment(\.locale, Locale(identifier: preference.language.code))
        }
    }
}

struct LightingView: View {
    @Environment(\.appLanguage) private var l
    private static let effects: [(UInt8, String)] = [
        (0, "Kapalı"), (1, "Sabit"), (2, "Nefes"), (3, "Spektrum"), (4, "Dalga"), (5, "Halka"),
        (6, "Yağmur damlası"), (7, "Yılan"), (8, "Tuşa basınca"), (9, "Birleşme"),
        (10, "Sinüs dalgası"), (11, "Kaleydoskop"), (12, "Çizgi dalgası"),
        (14, "Lazer"), (15, "Dairesel dalga"), (16, "Parıltı"),
        (17, "Yağmur"), (18, "Meteor"), (19, "Tuşa basınca sön"), (66, "Tuş başına renk")
    ]

    @State private var draft: Lighting?
    @State private var effect: UInt8 = 1
    @State private var direction = 0
    @State private var speed = 2
    @State private var brightness = 4
    @State private var rainbow = false
    @State private var presetSlot = 1
    @AppStorage("lightingPresets") private var storedPresets = Data()
    @State private var color = Color.white
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        Form {
            Section(l("Klavye aydınlatması")) {
                Picker(l("Efekt"), selection: Binding(get: { effect }, set: { effect = $0; direction = 0 })) {
                    if !Self.effects.contains(where: { $0.0 == effect }) {
                        Text(l.format("Mevcut efekt (%@)", String(effect))).tag(effect)
                    }
                    ForEach(Self.effects, id: \.0) { item in
                        Text(l(item.1)).tag(item.0)
                    }
                }
                if effect != 0 && effect != 66 {
                    if effect != 3 {
                        Toggle(l("Gökkuşağı"), isOn: $rainbow)
                        if !rainbow {
                            ColorPicker(l("Renk"), selection: $color, supportsOpacity: false)
                            ColorSwatches(color: $color)
                        }
                    }
                    if [4, 7, 11, 12, 15].contains(effect) {
                        Picker(l("Yön"), selection: $direction) {
                            ForEach(0..<(effect == 4 ? 4 : 2), id: \.self) { value in
                                Text(l(directionName(value))).tag(value)
                            }
                        }
                    }
                    LevelSlider(title: "Parlaklık", value: $brightness, icon: "sun.max")
                    if effect != 1 {
                        LevelSlider(title: "Hız", value: $speed, icon: "speedometer")
                    }
                }
            }
            .disabled(draft == nil || busy)
            Section {
                HStack {
                    Button(l("Klavyeden oku")) { read() }.disabled(busy)
                    Button(l("Klavyeye uygula")) { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == nil || busy || !Self.effects.contains(where: { $0.0 == effect }))
                    if busy { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(l(status)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section(l("Yerel aydınlatma ön ayarları")) {
                Picker(l("Ön ayar"), selection: $presetSlot) {
                    ForEach(1...5, id: \.self) { value in Text(l.format("Ön ayar %@", String(value))).tag(value) }
                }
                HStack {
                    Button(l("Taslağı kaydet")) { savePreset() }.disabled(draft == nil)
                    Button(l("Ön ayarı aç")) {
                        if let preset = presets[presetSlot] {
                            load(preset)
                            status = "Ön ayar açıldı. Klavyeye göndermek için Uygula’ya bas."
                        }
                    }
                    .disabled(presets[presetSlot] == nil || draft == nil)
                }
            }
            .disabled(busy)
            KeyColorControls()
        }
        .formStyle(.grouped)
        .onAppear { if draft == nil && !busy { read() } }

    }

    private func directionName(_ index: Int) -> String {
        switch effect {
        case 4: ["Sağa", "Sola", "Aşağı", "Yukarı"][index]
        case 7: ["Z", "Dönüş"][index]
        case 11: ["Dışa", "İçe"][index]
        case 15: ["Saat yönünün tersi", "Saat yönü"][index]
        default: ["Sağa", "Sola"][index]
        }
    }

    private func read() {
        run("TOP75 bağlı. Aydınlatma ayarı okundu.") { try Keyboard.lighting() }
    }

    private var presets: [Int: Lighting] {
        (try? JSONDecoder().decode([Int: Lighting].self, from: storedPresets)) ?? [:]
    }

    private func savePreset() {
        guard let requested = requestedLighting else { return }
        var updated = presets
        updated[presetSlot] = requested
        if let data = try? JSONEncoder().encode(updated) {
            storedPresets = data
            status = "Ön ayar bu Mac’e kaydedildi."
        }
    }

    private var requestedLighting: Lighting? {
        guard let rgb = color.rgb24 else { return nil }
        if effect == 66 { return Lighting(effect: 66, speed: 0, brightness: 0, flags: 7, rgb: 0) }
        let supportsDirection = [4, 7, 11, 12, 15].contains(effect)
        let option = supportsDirection ? UInt8(direction) << 4 : 0
        let flags: UInt8 = [0, 3].contains(effect) ? 7 : (rainbow ? 8 : 7)
        return Lighting(
            effect: effect, speed: UInt8(speed), brightness: UInt8(brightness),
            flags: option | flags, rgb: effect == 3 ? 0 : rgb
        )
    }

    private func apply() {
        guard let requested = requestedLighting else { return }
        run("Aydınlatma uygulandı ve klavyeden doğrulandı.") { try Keyboard.apply(requested) }
    }

    private func load(_ lighting: Lighting) {
        effect = lighting.effect
        direction = min(Int(lighting.flags >> 4), lighting.effect == 4 ? 3 : 1)
        speed = Int(lighting.speed)
        brightness = Int(min(lighting.brightness, 4))
        rainbow = (lighting.flags & 0x0F) == 8
        let palette: [UInt32] = [0xFF0000, 0xFF8000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF]
        let index = Int(lighting.flags & 0x0F)
        color = Color(rgb24: palette.indices.contains(index) ? palette[index] : lighting.rgb)
    }

    private func run(_ success: String, operation: @escaping @Sendable () throws -> Lighting) {
        busy = true
        status = ""
        Task {
            defer { busy = false }
            do {
                let current = try await Task.detached(operation: operation).value
                draft = current
                load(current)
                status = success
            } catch {
                status = l.message(error)
            }
        }
    }
}

struct KeySettingsView: View {
    @Environment(\.appLanguage) private var l
    static let keys: [(UInt8, String)] = {
        let letters = zip(UInt8(4)...29, "ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { ($0, String($1)) }
        let digits = zip(UInt8(30)...39, "1234567890").map { ($0, String($1)) }
        let functionKeys = zip(Array(UInt8(58)...69) + Array(UInt8(104)...115), 1...24).map { ($0, "F\($1)") }
        let controls: [(UInt8, String)] = [
            (40, "Enter"), (41, "Esc"), (42, "Backspace"), (43, "Tab"), (44, "Boşluk"),
            (45, "-"), (46, "="), (47, "["), (48, "]"), (49, "Ters eğik çizgi"),
            (50, "ISO #"), (51, ";"), (52, "'"), (53, "Tilde"), (54, ","), (55, "."),
            (56, "/"), (57, "Caps Lock"), (70, "Print Screen"), (71, "Scroll Lock"),
            (72, "Pause"), (73, "Insert"), (74, "Home"), (75, "Page Up"),
            (76, "Delete"), (77, "End"), (78, "Page Down"), (79, "Sağ ok"),
            (80, "Sol ok"), (81, "Aşağı ok"), (82, "Yukarı ok"), (100, "ISO <"),
            (224, "Sol Ctrl"), (225, "Sol Shift"), (226, "Sol Alt"), (227, "Sol Command"),
            (228, "Sağ Ctrl"), (229, "Sağ Shift"), (230, "Sağ Alt"), (231, "Sağ Command")
        ]
        return letters + digits + functionKeys + controls
    }()
    static let slots: [UInt8: UInt8] = [4: 9, 5: 40, 6: 28, 7: 21, 8: 20, 9: 27, 10: 33, 11: 39, 12: 50, 13: 45, 14: 51, 15: 57, 16: 52, 17: 46, 18: 56, 19: 62, 20: 8, 21: 26, 22: 15, 23: 32, 24: 44, 25: 34, 26: 14, 27: 22, 28: 38, 29: 16, 30: 7, 31: 13, 32: 19, 33: 25, 34: 31, 35: 37, 36: 43, 37: 49, 38: 55, 39: 61, 40: 81, 41: 0, 42: 79, 43: 2, 44: 41, 45: 67, 46: 73, 47: 68, 48: 74, 49: 80, 50: 75, 51: 63, 52: 69, 53: 1, 54: 58, 55: 64, 56: 70, 57: 3, 58: 12, 59: 18, 60: 24, 61: 30, 62: 36, 63: 42, 64: 48, 65: 54, 66: 60, 67: 66, 68: 72, 69: 78, 74: 86, 75: 87, 76: 85, 78: 88, 79: 89, 80: 77, 81: 83, 82: 82, 100: 10, 224: 5, 225: 4, 226: 17, 227: 11, 228: 71, 229: 76, 230: 59]

    @State private var profile: UInt8?
    @State private var selectedProfile: UInt8 = 0
    @State private var source: UInt8 = 69
    @State private var fn = false
    @State private var bindingKind = 0
    @State private var macroSlot: UInt8 = 0
    @State private var playback: UInt8 = 0
    @State private var media: UInt16 = 233
    @State private var destination: UInt8 = 69
    @State private var binding: [UInt8]?
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        Form {
            Section(l("Etkin profil")) {
                Picker(l("Profil"), selection: $selectedProfile) {
                    ForEach(0..<3) { profile in Text(l.format("Profil %@", String(profile + 1))).tag(UInt8(profile)) }
                }
                .disabled(profile == nil || busy)
                HStack {
                    Button(l("Klavyeden oku")) { loadProfile() }.disabled(busy)
                    Button(l("Profili değiştir")) { switchProfile() }
                        .disabled(profile == nil || profile == selectedProfile || busy)
                }
            }
            Section(l("Tuş ataması")) {
                KeyboardLayout(selection: $source)
                Picker(l("Katman"), selection: $fn) {
                    Text(l("Temel")).tag(false)
                    Text("Fn").tag(true)
                }
                .onChange(of: fn) { binding = nil }
                Picker(l("Fiziksel tuş"), selection: $source) {
                    ForEach(Self.keys.filter { Self.slots[$0.0] != nil }, id: \.0) { key in
                        Text(l(key.1)).tag(key.0)
                    }
                }
                .onChange(of: source) { binding = nil }
                if let binding {
                    let key = Self.keys.first { binding == [0, 0, $0.0, 0] }
                    let display = binding.allSatisfy { $0 == 0 } ? (fn ? l("Temel katman") : l("Devre dışı")) :
                        binding[0] == 9 ? l.format("Makro %@", String(Int(binding[2]) + 1)) : l(key?.1 ?? "Özel atama")
                    Text(l.format("Mevcut atama · %@", display))
                }
                Picker(l("Atama türü"), selection: $bindingKind) {
                    Text(l("Tuş")).tag(0)
                    Text(l("Makro")).tag(1)
                    Text(l("Multimedya")).tag(2)
                    Text(l(fn ? "Temel katmanı kullan" : "Devre dışı")).tag(3)
                }
                switch bindingKind {
                case 0:
                    Picker(l("Yeni tuş"), selection: $destination) {
                        ForEach(Self.keys, id: \.0) { key in Text(l(key.1)).tag(key.0) }
                    }
                case 1:
                    Picker(l("Makro"), selection: $macroSlot) {
                        ForEach(0..<50) { slot in Text(l.format("Makro %@", String(slot + 1))).tag(UInt8(slot)) }
                    }
                    Picker(l("Çalma"), selection: $playback) {
                        Text(l("Belirlenen tekrar sayısı")).tag(UInt8(0))
                        Text(l("Aç / kapat")).tag(UInt8(1))
                        Text(l("Basılı tutarken")).tag(UInt8(2))
                    }
                case 2:
                    Picker(l("Multimedya"), selection: $media) {
                        Text(l("Sesi artır")).tag(UInt16(233))
                        Text(l("Sesi azalt")).tag(UInt16(234))
                        Text(l("Sesi kapat")).tag(UInt16(226))
                        Text(l("Oynat / duraklat")).tag(UInt16(205))
                        Text(l("Sonraki parça")).tag(UInt16(181))
                        Text(l("Önceki parça")).tag(UInt16(182))
                    }
                default: EmptyView()
                }
            }
            .disabled(profile == nil || busy || selectedProfile != profile)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    if busy { ProgressView().controlSize(.small) }
                    if !status.isEmpty {
                        Text(l(status)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(l("Atamayı oku")) { loadBinding() }
                        .disabled(profile == nil || busy || selectedProfile != profile)
                    Button(l("Atamayı uygula")) { assignBinding() }
                        .buttonStyle(.borderedProminent)
                        .disabled(binding == nil || busy || selectedProfile != profile)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(.bar)
        }
        .onAppear { if profile == nil && !busy { loadProfile() } }
    }

    private func loadProfile() {
        run("Etkin profil okundu.", operation: { try Keyboard.profile() }) { current in
            profile = current
            selectedProfile = current
            binding = nil
        }
    }

    private func switchProfile() {
        let target = selectedProfile
        run("Profil değiştirildi ve doğrulandı.", operation: { try Keyboard.selectProfile(target) }) { current in
            profile = current
            selectedProfile = current
            binding = nil
        }
    }

    private func loadBinding() {
        guard let slot = Self.slots[source], let profile else { return }
        let layer = fn
        run("Atama klavyeden okundu.", operation: { try Keyboard.keyBinding(slot: slot, expectedProfile: profile, fn: layer) }) {
            binding = $0
            destination = Self.keys.first { key in binding == [0, 0, key.0, 0] }?.0 ?? source
        }
    }

    private func assignBinding() {
        guard let slot = Self.slots[source], let profile, let previousBinding = binding else { return }
        let layer = fn
        let target: [UInt8] = switch bindingKind {
        case 1: [9, playback, macroSlot, 0]
        case 2: [3, 0, UInt8(truncatingIfNeeded: media), UInt8(media >> 8)]
        case 3: [0, 0, 0, 0]
        default: [0, 0, destination, 0]
        }
        run("Tuş atandı ve klavyeden doğrulandı.", operation: {
            try Keyboard.assignKey(slot: slot, binding: target, expectedProfile: profile, previousBinding: previousBinding, fn: layer)
        }) { binding = $0 }
    }

    private func run<T: Sendable>(
        _ success: String, operation: @escaping @Sendable () throws -> T, update: @escaping (T) -> Void
    ) {
        busy = true
        status = ""
        Task {
            defer { busy = false }
            do {
                update(try await Task.detached(operation: operation).value)
                status = success
            } catch {
                binding = nil
                status = l.message(error)
            }
        }
    }
}
