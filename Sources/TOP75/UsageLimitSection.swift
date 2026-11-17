import CoreText
import SwiftUI

struct UsageLCD: Equatable, Sendable {
    let codex: UsageLimits
    let claude: UsageLimits

    var hasLimits: Bool { !codex.isEmpty || !claude.isEmpty }

    var numbers: [Int?] {
        [codex.fiveHour?.remaining, codex.weekly?.remaining, claude.fiveHour?.remaining, claude.weekly?.remaining]
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
                fill(value <= 10 ? 0xFF756C : accent, x: x, y: baseline - 9, w: max(1, value * 47 / 100), h: 3)
            }
        }

        fill(0x101827, x: 0, y: 0, w: 128, h: 128)
        fill(0x1F2C40, x: 0, y: 108, w: 128, h: 20)
        text(turkish ? "5S KALAN" : "5H LEFT", x: 9, y: 114, size: 9, color: 0xD5DEEB)
        text(turkish ? "7G KALAN" : "7D LEFT", x: 70, y: 114, size: 9, color: 0xD5DEEB)
        text("CODEX", x: 10, y: 90, size: 11, color: 0x77E4BA)
        percentage(codex.fiveHour?.remaining, x: 10, baseline: 70, accent: 0x77E4BA)
        percentage(codex.weekly?.remaining, x: 70, baseline: 70, accent: 0x77E4BA)
        fill(0x263549, x: 9, y: 55, w: 110, h: 1)
        text("CLAUDE", x: 10, y: 39, size: 11, color: 0xFFB586)
        percentage(claude.fiveHour?.remaining, x: 10, baseline: 19, accent: 0xFFB586)
        percentage(claude.weekly?.remaining, x: 70, baseline: 19, accent: 0xFFB586)
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

    @State private var codex = UsageLimits()
    @State private var claude: ClaudeUsage.Reading?
    @State private var bridgeEnabled = false
    @State private var artwork: ScreenArtwork?
    @State private var confirmation: Confirmation?
    @State private var refreshing = false
    @State private var autoUpdate = false
    @State private var slot: UInt8?
    @State private var sentNumbers: [Int?]?
    @State private var codexMessage = ""
    @State private var status = ""

    private var card: UsageLCD { UsageLCD(codex: codex, claude: claude?.limits ?? UsageLimits()) }

    var body: some View {
        controls
            .onAppear {
                bridgeEnabled = ClaudeUsage.isConfigured
                claude = bridgeEnabled ? ClaudeUsage.read() : nil
                preparePreview()
            }
            .onChange(of: connected) { sentNumbers = nil }
            .onChange(of: slot) { sentNumbers = nil }
            .onChange(of: l.code) { preparePreview() }
            .task(id: autoUpdate && connected ? slot : nil, autoRefresh)
            .alert(item: $confirmation, content: alert)
    }

    private var controls: some View {
        Section(l("Codex ve Claude limitleri")) {
            HStack(alignment: .top, spacing: 18) {
                if let image = artwork?.previews.first {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none).frame(width: 128, height: 128)
                        .clipShape(.rect(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 10) {
                    usageRow("Codex", windows: codex)
                    usageRow("Claude", windows: claude?.limits ?? UsageLimits())
                    if !codexMessage.isEmpty { Text(l(codexMessage)).font(.caption).foregroundStyle(.secondary) }
                    Text(claudeStatus).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(l("Limitleri yenile"), systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(refreshing)
                if refreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button(l(bridgeEnabled ? "Claude bağlantısını kaldır" : "Claude Code’u bağla")) {
                    confirmation = bridgeEnabled ? .unlink : .link
                }
                .disabled(refreshing)
            }
            Picker(l("Limit kartı yuvası"), selection: $slot) {
                Text(l("Yuva seç")).tag(nil as UInt8?)
                ForEach(0..<5) { Text(l.format("Yuva %@", String($0 + 1))).tag(UInt8($0) as UInt8?) }
            }
            .disabled(autoUpdate || transfer.isBusy)
            HStack {
                Button(l("Limit kartını ekrana aktar"), systemImage: "display") { confirmation = .upload }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || slot == nil || !card.hasLimits || transfer.isBusy || refreshing)
                if autoUpdate {
                    Button(l("Otomatik aktarımı durdur")) { autoUpdate = false }
                } else {
                    Button(l("Otomatik aktarımı aç")) { confirmation = .automatic }
                        .disabled(!connected || slot == nil || transfer.isBusy || refreshing)
                }
            }
            Text(l("USB ile seçilen yuvaya aktarılır. Otomatik mod, pencere açıkken 15 dakikada bir kontrol eder."))
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(l(status)).foregroundStyle(.secondary) }
        }
    }

    private func autoRefresh() async {
        guard autoUpdate, connected, slot != nil else { return }
        while !Task.isCancelled {
            await refresh()
            if !Task.isCancelled, autoUpdate, sentNumbers != card.numbers { await upload() }
            do { try await Task.sleep(for: .seconds(15 * 60)) }
            catch { return }
        }
    }

    private func alert(_ option: Confirmation) -> Alert {
        switch option {
        case .link:
            return Alert(title: Text(l("Claude Code’u bağla")),
                         message: Text(l("TOP75, Claude Code’un status line ayarına bir okuyucu ekler. Mevcut komut çalışmaya devam eder. Yeni bir CLI yanıtı geldiğinde limitler okunur.")),
                         primaryButton: .default(Text(l("Bağla"))) { configureClaude(true) },
                         secondaryButton: .cancel())
        case .unlink:
            return Alert(title: Text(l("Claude bağlantısını kaldır")),
                         message: Text(l("Claude Code’un önceki status line komutu geri yüklenir.")),
                         primaryButton: .default(Text(l("Kaldır"))) { configureClaude(false) },
                         secondaryButton: .cancel())
        case .upload, .automatic:
            return Alert(title: Text(l(option == .upload ? "Limit kartını ekrana aktar" : "Otomatik aktarımı aç")),
                         message: Text(l.format("Yuva %@ içindeki görsel değişecek.", String(Int(slot ?? 0) + 1))),
                         primaryButton: .default(Text(l(option == .upload ? "Aktar" : "Aç"))) {
                             if option == .upload { Task { await upload() } }
                             else { sentNumbers = nil; autoUpdate = true }
                         },
                         secondaryButton: .cancel())
        }
    }

    private var claudeStatus: String {
        if let claude {
            let time = claude.observedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: l.code)))
            return l.format("Claude verisi %@ alındı.", time)
        }
        return l(bridgeEnabled ? "Claude Code’da bir yanıt alıp limitleri yenile." : "Claude limitleri için Claude Code’u bağla.")
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
            Text(value.map { (Double($0.remaining) / 100).formatted(.percent.locale(Locale(identifier: l.code))) } ?? "—")
                .font(.title3.monospacedDigit())
            if let date = value?.resetsAt {
                Text(l.format("Sıfırlanma %@", date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: l.code)))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configureClaude(_ enabled: Bool) {
        do {
            try ClaudeUsage.configure(enabled: enabled)
            bridgeEnabled = ClaudeUsage.isConfigured
            claude = enabled ? ClaudeUsage.read() : nil
            preparePreview()
            status = enabled ? "Claude Code’da yeni bir yanıt al ve limitleri yenile." : "Claude Code bağlantısı kaldırıldı."
        } catch {
            status = l.message(error)
        }
    }

    private func preparePreview() {
        let show = card.hasLimits || (autoUpdate && sentNumbers != nil)
        artwork = show ? try? card.artwork(turkish: l.code == "tr") : nil
    }

    private func refresh() async {
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

    private func upload() async {
        guard connected, let slot, let artwork,
              let id = transfer.start(.display, title: "Limit kartı aktarılıyor") else { return }
        let numbers = card.numbers
        defer { transfer.finish(id) }
        do {
            try await Task.detached {
                try Keyboard.uploadArtwork(artwork, slot: slot) { fraction in
                    Task { @MainActor in transfer.update(id, progress: fraction) }
                }
            }.value
            sentNumbers = numbers
            status = l.format("Limit kartı %@. yuvaya gönderildi.", String(Int(slot) + 1))
        } catch {
            status = l.message(error)
        }
    }
}
