import SwiftUI

struct KeyboardLayout: View {
    struct Cap {
        let code: UInt8?
        let legend: String
        var units: CGFloat = 1
    }

    static let rows: [[Cap]] = [
        [Cap(code: 41, legend: "esc")] + (58...69).map { Cap(code: UInt8($0), legend: "F\($0 - 57)") }
            + [Cap(code: 76, legend: "del"), Cap(code: nil, legend: "▣", units: 1.5)],
        [Cap(code: 53, legend: "~")] + zip(30...39, "1234567890").map { Cap(code: UInt8($0), legend: String($1)) }
            + [Cap(code: 45, legend: "−"), Cap(code: 46, legend: "="), Cap(code: 42, legend: "⌫", units: 2),
               Cap(code: 74, legend: "home")],
        [Cap(code: 43, legend: "⇥", units: 1.5)] + letters("QWERTYUIOP")
            + [Cap(code: 47, legend: "["), Cap(code: 48, legend: "]"), Cap(code: 49, legend: "\\", units: 1.5),
               Cap(code: 75, legend: "pg↑")],
        [Cap(code: 57, legend: "⇪", units: 1.75)] + letters("ASDFGHJKL")
            + [Cap(code: 51, legend: ";"), Cap(code: 52, legend: "'"), Cap(code: 40, legend: "↩", units: 2.25),
               Cap(code: 78, legend: "pg↓")],
        [Cap(code: 225, legend: "⇧", units: 2.25)] + letters("ZXCVBNM")
            + [Cap(code: 54, legend: ","), Cap(code: 55, legend: "."), Cap(code: 56, legend: "/"),
               Cap(code: 229, legend: "⇧", units: 1.75), Cap(code: 82, legend: "↑")],
        [Cap(code: 224, legend: "⌃", units: 1.25), Cap(code: 227, legend: "⌘", units: 1.25),
         Cap(code: 226, legend: "⌥", units: 1.25), Cap(code: 44, legend: "", units: 6.25),
         Cap(code: 230, legend: "⌥", units: 1.25), Cap(code: nil, legend: "fn", units: 1.25),
         Cap(code: 228, legend: "⌃", units: 1.25), Cap(code: 80, legend: "←"),
         Cap(code: 81, legend: "↓"), Cap(code: 79, legend: "→")]
    ]

    static var selectableCodes: [UInt8] { rows.flatMap { $0.compactMap(\.code) } }

    @Environment(\.appLanguage) private var l
    @Binding var selection: UInt8
    var colors: [UInt32] = []

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - 24) / 16.5
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(Self.rows[row].indices, id: \.self) { index in
                            let cap = Self.rows[row][index]
                            key(cap)
                                .frame(width: unit * cap.units - 4, height: 25)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
        }
        .frame(height: 194)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Klavye yerleşimi"))
    }

    @ViewBuilder
    private func key(_ cap: Cap) -> some View {
        if let code = cap.code {
            let selected = code == selection
            let name = KeySettingsView.keys.first { $0.0 == code }?.1 ?? cap.legend
            let slot = KeySettingsView.slots[code].map(Int.init)
            let rgb = slot.flatMap { colors.indices.contains($0) ? colors[$0] : nil } ?? 0
            let tint = rgb == 0 ? Color(nsColor: .controlBackgroundColor) : Color(rgb24: rgb).opacity(0.36)
            let painted = !colors.isEmpty
            Button { selection = code } label: {
                Text(cap.legend)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected && !painted ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected && !painted ? Color.accentColor : tint, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        if selected && painted {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l(name))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(l(name))
        } else {
            Text(cap.legend)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }

    private static func letters(_ values: String) -> [Cap] {
        values.utf8.map { Cap(code: $0 - 61, legend: String(UnicodeScalar($0))) }
    }
}

struct ColorSwatches: View {
    @Environment(\.appLanguage) private var l
    @Binding var color: Color
    private static let values: [UInt32] = [0xFFFFFF, 0xFF5858, 0xFFB250, 0xF1D65A, 0x57D99A, 0x4DBCE9, 0x608AFF, 0xBC7DFF]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.values, id: \.self) { rgb in
                let selected = color.rgb24 == rgb
                let hex = String(format: "#%06X", rgb)
                Button { color = Color(rgb24: rgb) } label: {
                    Circle()
                        .fill(Color(rgb24: rgb))
                        .frame(width: 22, height: 22)
                        .overlay { Circle().strokeBorder(.black.opacity(0.14), lineWidth: 1) }
                        .padding(2)
                        .overlay { Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hex)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(hex)
            }
            Spacer(minLength: 0)
            if let rgb = color.rgb24 {
                Text(String(format: "#%06X", rgb))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Renk örnekleri"))
    }
}
