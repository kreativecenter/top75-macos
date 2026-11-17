import CoreGraphics
import CoreText
import SwiftUI

struct ScreenTemplate: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable {
        case name, monogram, pixel
        var id: Self { self }
        var title: String {
            switch self {
            case .name: "İsim"
            case .monogram: "Monogram"
            case .pixel: "Piksel çizimi"
            }
        }
    }

    static let gridSize = 16
    var kind = Kind.name
    var name = "TOP75"
    var monogram = "T"
    var foreground: UInt32 = 0xFFFFFF
    var background: UInt32 = 0x18264A
    var pixels: [Int: UInt32] = [:]

    func artwork() throws -> ScreenArtwork {
        if kind == .pixel {
            let unit = ScreenArtwork.side / Self.gridSize
            return try ScreenArtwork(frame: ScreenArtwork.rgb565 { x, y in
                let rgb = pixels[(y / unit) * Self.gridSize + x / unit] ?? background
                return (UInt8(truncatingIfNeeded: rgb >> 16), UInt8(truncatingIfNeeded: rgb >> 8), UInt8(truncatingIfNeeded: rgb))
            })
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: ScreenArtwork.side, height: ScreenArtwork.side,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ScreenError.invalidFile }
        func color(_ rgb: UInt32) -> CGColor {
            CGColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                    blue: Double(rgb & 255) / 255, alpha: 1)
        }
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: ScreenArtwork.side, height: ScreenArtwork.side))
        let value = String(kind == .name ? name.prefix(32) : monogram.prefix(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, kind == .name ? 28 : 62, nil)
            let text = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(foreground)
            ])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if bounds.width > 0 && bounds.height > 0 {
                let scale = min(1, 106 / bounds.width, 104 / bounds.height)
                context.translateBy(x: 64 - bounds.midX * scale, y: 64 - bounds.midY * scale)
                context.scaleBy(x: scale, y: scale)
                context.textPosition = .zero
                CTLineDraw(line, context)
            }
        }
        guard let image = context.makeImage() else { throw ScreenError.invalidFile }
        return try ScreenArtwork(still: image)
    }
}

struct ScreenTemplateEditor: View {
    @Environment(\.appLanguage) private var l
    @State private var template = ScreenTemplate()
    @State private var pen = Color.white
    @State private var paper = Color(rgb24: 0x18264A)
    @State private var erasing = false
    let use: (ScreenArtwork, String) -> Void
    let cancel: () -> Void

    var body: some View {
        let artwork = try? template.artwork()
        VStack(alignment: .leading, spacing: 15) {
            Text(l("Ekran şablonları")).font(.title2.bold())
            Picker(l("Şablon"), selection: $template.kind) {
                ForEach(ScreenTemplate.Kind.allCases) { Text(l($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    if template.kind == .pixel {
                        pixelGrid
                        Toggle(l("Silgi"), isOn: $erasing).toggleStyle(.checkbox)
                        Button(l("Çizimi temizle")) { template.pixels.removeAll() }.disabled(template.pixels.isEmpty)
                    } else if template.kind == .name {
                        TextField(l("Ekranda görünecek isim"), text: $template.name)
                            .onChange(of: template.name) { template.name = String(template.name.prefix(32)) }
                    } else {
                        TextField(l("En fazla üç karakter"), text: $template.monogram)
                            .onChange(of: template.monogram) { template.monogram = String(template.monogram.prefix(3)) }
                    }
                    ColorPicker(l("Ön plan"), selection: $pen, supportsOpacity: false)
                    ColorPicker(l("Arka plan"), selection: $paper, supportsOpacity: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let image = artwork?.previews.first {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none)
                        .frame(width: 128, height: 128)
                        .padding(8)
                        .background(.black, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(l("Ekran önizlemesi"))
                }
            }
            HStack {
                Button(l("Vazgeç"), role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(l("Şablonu kullan")) {
                    if let artwork { use(artwork, l(template.kind.title)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(artwork == nil)
            }
        }
        .onChange(of: pen) { if let rgb = pen.rgb24 { template.foreground = rgb } }
        .onChange(of: paper) { if let rgb = paper.rgb24 { template.background = rgb } }
        .padding(22)
        .frame(width: 475)
    }

    private var pixelGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 1), count: ScreenTemplate.gridSize), spacing: 1) {
            ForEach(0..<(ScreenTemplate.gridSize * ScreenTemplate.gridSize), id: \.self) { index in
                Button {
                    template.pixels[index] = erasing ? nil : template.foreground
                } label: {
                    Rectangle()
                        .fill(Color(rgb24: template.pixels[index] ?? template.background))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l.format("Piksel %@, %@", String(index / ScreenTemplate.gridSize + 1), String(index % ScreenTemplate.gridSize + 1)))
            }
        }
        .frame(width: 207)
        .padding(3)
        .background(.secondary.opacity(0.3))
    }
}
