import CoreText
import SwiftUI

enum UsageMetric: String, CaseIterable, Sendable {
    case used, remaining

    var title: String { self == .used ? "Kullanılan" : "Kalan" }

    func percent(_ window: UsageLimits.Window) -> Double {
        self == .used ? window.usedPercentage : 100 - window.usedPercentage
    }

    func displayNumber(_ window: UsageLimits.Window?) -> Int? {
        // A partially consumed window should not look full unless the source reports 100%.
        window.map { Int(percent($0).rounded(.down)) }
    }

    func approachesLimit(_ number: Int) -> Bool {
        self == .used ? number >= 90 : number <= 10
    }

    func header(weekly: Bool, turkish: Bool) -> String {
        let period = turkish ? (weekly ? "7G" : "5S") : (weekly ? "7D" : "5H")
        let metric = turkish ? (self == .used ? "DOLU" : "KALAN") : (self == .used ? "USED" : "LEFT")
        return "\(period) \(metric)"
    }
}

struct UsageLCD: Equatable, Sendable {
    let codex: UsageLimits
    let claude: UsageLimits
    var metric = UsageMetric.used

    var hasLimits: Bool { !codex.isEmpty || !claude.isEmpty }

    var numbers: [Int?] {
        [codex.fiveHour, codex.weekly, claude.fiveHour, claude.weekly].map(metric.displayNumber)
    }

    func artwork(turkish: Bool = false) throws -> ScreenArtwork {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScreenError.invalidFile
        }
        func fill(_ color: UInt32, x: Int, y: Int, w: Int, h: Int) {
            context.setFillColor(rgb(color))
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: UInt32) {
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
            let string = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(color)
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        func percentage(_ value: Int?, x: Int, baseline: Int, accent: UInt32) {
            text(value.map { "\($0)%" } ?? "--", x: CGFloat(x), y: CGFloat(baseline),
                 size: 16, color: value == nil ? 0x758094 : 0xF4F7FB)
            fill(0x27344A, x: x, y: baseline - 9, w: 47, h: 3)
            if let value, value > 0 {
                fill(metric.approachesLimit(value) ? 0xFF756C : accent, x: x, y: baseline - 9, w: max(1, value * 47 / 100), h: 3)
            }
        }

        fill(0x101827, x: 0, y: 0, w: 128, h: 128)
        fill(0x1F2C40, x: 0, y: 108, w: 128, h: 20)
        text(metric.header(weekly: false, turkish: turkish), x: 9, y: 114, size: 9, color: 0xD5DEEB)
        text(metric.header(weekly: true, turkish: turkish), x: 70, y: 114, size: 9, color: 0xD5DEEB)
        text("CODEX", x: 10, y: 90, size: 11, color: 0x77E4BA)
        percentage(metric.displayNumber(codex.fiveHour), x: 10, baseline: 70, accent: 0x77E4BA)
        percentage(metric.displayNumber(codex.weekly), x: 70, baseline: 70, accent: 0x77E4BA)
        fill(0x263549, x: 9, y: 55, w: 110, h: 1)
        text("CLAUDE", x: 10, y: 39, size: 11, color: 0xFFB586)
        percentage(metric.displayNumber(claude.fiveHour), x: 10, baseline: 19, accent: 0xFFB586)
        percentage(metric.displayNumber(claude.weekly), x: 70, baseline: 19, accent: 0xFFB586)
        guard let image = context.makeImage() else { throw ScreenError.invalidFile }
        return try ScreenArtwork(still: image)
    }

    private func rgb(_ value: UInt32) -> CGColor {
        CGColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255, alpha: 1)
    }
}

struct UsageLimitSection: View {
    @Environment(\.appLanguage) private var l
    let connected: Bool
    let transfer: WorkspaceTransfer

    private enum Confirmation: String, Identifiable {
        case link, unlink, upload, automatic
        var id: Self { self }
    }

    @Bindable private var display = UsageDisplay.shared
    @State private var confirmation: Confirmation?

    var body: some View {
        controls
            .onAppear { display.updateLanguage(l); display.readClaude() }
            .onChange(of: l) { display.updateLanguage(l) }
            .alert(item: $confirmation, content: alert)
    }

    private var controls: some View {
        Section(l("Codex ve Claude limitleri")) {
            Picker(l("Limit gösterimi"), selection: $display.metric) {
                ForEach(UsageMetric.allCases, id: \.self) { Text(l($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 18) {
                if let image = display.artwork?.previews.first {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none).frame(width: 128, height: 128)
                        .clipShape(.rect(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 10) {
                    usageRow("Codex", windows: display.codex)
                    usageRow("Claude", windows: display.claude?.limits ?? UsageLimits())
                    if !display.codexMessage.isEmpty { Text(l(display.codexMessage)).font(.caption).foregroundStyle(.secondary) }
                    Text(claudeStatus).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(l("Limitleri yenile"), systemImage: "arrow.clockwise") {
                    Task { await display.refresh() }
                }
                .disabled(display.refreshing)
                if display.refreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button(l(display.bridgeEnabled ? "Claude bağlantısını kaldır" : "Claude Code’u bağla")) {
                    confirmation = display.bridgeEnabled ? .unlink : .link
                }
                .disabled(display.refreshing)
            }
            Picker(l("Limit kartı yuvası"), selection: $display.slot) {
                Text(l("Yuva seç")).tag(nil as UInt8?)
                ForEach(0..<5) { Text(l.format("Yuva %@", String($0 + 1))).tag(UInt8($0) as UInt8?) }
            }
            .disabled(display.autoUpdate || transfer.isBusy)
            HStack {
                Button(l("Limit kartını ekrana aktar"), systemImage: "display") { confirmation = .upload }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || display.slot == nil || !display.card.hasLimits || transfer.isBusy || display.refreshing)
                if display.autoUpdate {
                    Button(l("Otomatik aktarımı durdur")) { display.stopAutomatic() }
                } else {
                    Button(l("Otomatik aktarımı aç")) { confirmation = .automatic }
                        .disabled(!connected || display.slot == nil || transfer.isBusy || display.refreshing)
                }
            }
            Text(l("USB ile seçilen yuvaya aktarılır. Otomatik mod, TOP75 menü çubuğunda açıkken de her 15 dakikada bir kontrol eder."))
                .font(.caption).foregroundStyle(.secondary)
            if !display.status.isEmpty { Text(display.status).foregroundStyle(.secondary) }
        }
    }

    private func alert(_ option: Confirmation) -> Alert {
        switch option {
        case .link:
            return Alert(title: Text(l("Claude Code’u bağla")),
                         message: Text(l("TOP75, Claude Code’un status line ayarına bir okuyucu ekler. Mevcut komut çalışmaya devam eder. Yeni bir CLI yanıtı geldiğinde limitler okunur.")),
                         primaryButton: .default(Text(l("Bağla"))) { display.configureClaude(true) },
                         secondaryButton: .cancel())
        case .unlink:
            return Alert(title: Text(l("Claude bağlantısını kaldır")),
                         message: Text(l("Claude Code’un önceki status line komutu geri yüklenir.")),
                         primaryButton: .default(Text(l("Kaldır"))) { display.configureClaude(false) },
                         secondaryButton: .cancel())
        case .upload, .automatic:
            return Alert(title: Text(l(option == .upload ? "Limit kartını ekrana aktar" : "Otomatik aktarımı aç")),
                         message: Text(l.format("Yuva %@ içindeki görsel değişecek.", String(Int(display.slot ?? 0) + 1))),
                         primaryButton: .default(Text(l(option == .upload ? "Aktar" : "Aç"))) {
                             if option == .upload { Task { await display.upload() } }
                             else { display.startAutomatic() }
                         },
                         secondaryButton: .cancel())
        }
    }

    private var claudeStatus: String {
        if let claude = display.claude {
            let time = claude.observedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: l.code)))
            return l.format("Claude verisi %@ alındı.", time)
        }
        return l(display.bridgeEnabled ? "Claude Code’da bir yanıt alıp limitleri yenile." : "Claude limitleri için Claude Code’u bağla.")
    }

    private func usageRow(_ title: String, windows: UsageLimits) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack(spacing: 14) {
                window(l("5 saat"), value: windows.fiveHour)
                window(l("7 gün"), value: windows.weekly)
            }
        }
    }

    private func window(_ title: String, value: UsageLimits.Window?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { formatted(display.metric, window: $0) } ?? "—")
                .font(.title3.monospacedDigit())
            if let value {
                let other: UsageMetric = display.metric == .used ? .remaining : .used
                Text(l.format(other == .used ? "%@ kullanıldı" : "%@ kaldı", formatted(other, window: value)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let date = value?.resetsAt {
                Text(l.format("Sıfırlanma %@", date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: l.code)))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ metric: UsageMetric, window: UsageLimits.Window) -> String {
        (metric.percent(window) / 100).formatted(.percent.precision(.fractionLength(0...2)).locale(Locale(identifier: l.code)))
    }

}

@MainActor
@Observable
final class UsageDisplay {
    static let shared = UsageDisplay()

    private struct SentCard: Equatable {
        let numbers: [Int?]
        let metric: UsageMetric
        let language: String
    }

    var metric = UserDefaults.standard.string(forKey: "usageDisplayMetric")
        .flatMap(UsageMetric.init(rawValue:)) ?? .used {
        didSet {
            UserDefaults.standard.set(metric.rawValue, forKey: "usageDisplayMetric")
            preparePreview()
        }
    }
    var slot: UInt8? { didSet { if oldValue != slot { sentCard = nil } } }
    private(set) var codex = UsageLimits()
    private(set) var claude: ClaudeUsage.Reading?
    private(set) var bridgeEnabled = false
    private(set) var artwork: ScreenArtwork?
    private(set) var refreshing = false
    private(set) var codexMessage = ""
    private(set) var status = ""
    private(set) var autoUpdate = false
    @ObservationIgnored private var automatic: Task<Void, Never>?
    private var sentCard: SentCard?
    private var language = LanguagePreference.system.language
    private let transfer = WorkspaceTransfer.shared

    var card: UsageLCD {
        UsageLCD(codex: codex, claude: claude?.limits ?? UsageLimits(), metric: metric)
    }

    private var cardStamp: SentCard {
        SentCard(numbers: card.numbers, metric: metric, language: language.code)
    }

    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        preparePreview()
    }

    func readClaude() {
        bridgeEnabled = ClaudeUsage.isConfigured
        claude = bridgeEnabled ? ClaudeUsage.read() : nil
        preparePreview()
    }

    func configureClaude(_ enabled: Bool) {
        do {
            try ClaudeUsage.configure(enabled: enabled)
            readClaude()
            status = language(enabled ? "Claude Code’da yeni bir yanıt al ve limitleri yenile." : "Claude Code bağlantısı kaldırıldı.")
        } catch {
            status = language.message(error)
        }
    }

    func startAutomatic() {
        guard slot != nil, automatic == nil else { return }
        autoUpdate = true
        sentCard = nil
        automatic = Task {
            let clock = ContinuousClock()
            var nextCheck = clock.now
            var wasConnected = false
            while !Task.isCancelled {
                let connected = Keyboard.hasUSBInterface()
                if connected != wasConnected {
                    sentCard = nil
                    if connected { nextCheck = clock.now }
                    wasConnected = connected
                }
                if connected, clock.now >= nextCheck, !refreshing, !transfer.isBusy {
                    await refresh()
                    guard !Task.isCancelled else { return }
                    if sentCard != cardStamp { await upload() }
                    nextCheck = clock.now + .seconds(15 * 60)
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    func stopAutomatic() {
        automatic?.cancel()
        automatic = nil
        autoUpdate = false
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await Task.detached { Result { try CodexUsage.read() } }.value
        guard !Task.isCancelled else { return }
        bridgeEnabled = ClaudeUsage.isConfigured
        claude = bridgeEnabled ? ClaudeUsage.read() : nil
        switch result {
        case .success(let limits):
            codex = limits
            codexMessage = limits.isEmpty ? UsageSourceError.unavailable.localizedDescription : ""
        case .failure(let error):
            codex = UsageLimits()
            codexMessage = error.localizedDescription
        }
        preparePreview()
    }

    func upload() async {
        guard Keyboard.hasUSBInterface(), let slot, let artwork,
              let id = transfer.start(.display, title: "Limit kartı aktarılıyor") else { return }
        let stamp = cardStamp
        defer { transfer.finish(id) }
        do {
            try await Task.detached { [transfer] in
                try Keyboard.uploadArtwork(artwork, slot: slot) { fraction in
                    Task { @MainActor in transfer.update(id, progress: fraction) }
                }
            }.value
            sentCard = stamp
            status = language.format("Limit kartı %@. yuvaya gönderildi.", String(Int(slot) + 1))
        } catch {
            status = language.message(error)
        }
    }

    private func preparePreview() {
        let show = card.hasLimits || (autoUpdate && sentCard != nil)
        artwork = show ? try? card.artwork(turkish: language.code == "tr") : nil
    }
}
