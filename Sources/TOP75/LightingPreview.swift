import SwiftUI

struct LightingSimulation {
    let lighting: Lighting

    var reactsToKeys: Bool {
        switch lighting.effect {
        case 5, 8, 19: true
        default: false
        }
    }

    var loops: Bool {
        switch lighting.effect {
        case 2, 3, 4, 6, 7, 9, 10, 11, 12, 14, 15, 16, 17, 18: true
        default: false
        }
    }

    func color(at point: CGPoint, time: TimeInterval, pressed: CGPoint?, age: TimeInterval?, keyColor: UInt32?) -> Color? {
        let effect = lighting.effect
        if effect == 66 { return keyColor.flatMap { $0 == 0 ? nil : Color(rgb24: $0) } }
        guard effect != 0, effect == 1 || loops || reactsToKeys else { return nil }

        let x = Double(point.x)
        let y = Double(point.y)
        let radius = hypot(x - 0.5, y - 0.5)
        let angle = atan2(y - 0.5, x - 0.5) / (2 * .pi)
        let direction = lighting.flags >> 4
        let phase = time * (0.20 + Double(min(lighting.speed, 4)) * 0.12)
        let axis: Double = switch direction {
        case 1: 1 - x
        case 2: y
        case 3: 1 - y
        default: x
        }

        func wave(_ offset: Double, width: Double = 2) -> Double {
            pow(0.5 + 0.5 * cos(offset * 2 * .pi), width)
        }

        let level: Double
        switch effect {
        case 1, 3: level = 1
        case 2: level = 0.12 + 0.88 * wave(phase, width: 1)
        case 4: level = 0.14 + 0.86 * wave(axis * 1.6 - phase)
        case 5, 8, 19:
            let intensity: Double
            if let pressed, let age, age >= 0, age < 1.4 {
                let distance = hypot(x - pressed.x, y - pressed.y)
                let travel = age * (0.24 + Double(lighting.speed) * 0.15)
                let spatial = effect == 5 ? max(0, 1 - abs(distance - travel) / 0.18) : max(0, 1 - distance / 0.10)
                intensity = spatial * max(0, 1 - age / 1.4)
            } else {
                intensity = 0
            }
            level = effect == 19 ? 1 - intensity : 0.06 + 0.94 * intensity
        case 6: level = 0.12 + 0.88 * wave(x * 11.7 + y * 7.3 - phase * 1.7, width: 12)
        case 7: level = 0.08 + 0.92 * wave((Int(y * 6).isMultiple(of: 2) ? x : 1 - x) * 0.4 + y - phase)
        case 9: level = 0.1 + 0.9 * wave(abs(x - 0.5) * 2 + abs(y - 0.5) * 0.35 + phase)
        case 10: level = 0.1 + 0.9 * max(0, 1 - abs(y - (0.5 + 0.32 * sin((x - phase) * 2 * .pi))) * 4)
        case 11: level = 0.18 + 0.82 * wave(radius * 2.8 + abs(cos(angle * 8 * .pi)) * 0.35 + (direction == 0 ? -phase : phase))
        case 12: level = 0.12 + 0.88 * wave(axis * 1.8 + y * 0.25 - phase)
        case 14: level = 0.08 + 0.92 * wave(x * 1.2 - phase * 1.3, width: 10)
        case 15: level = 0.1 + 0.9 * wave(angle + (direction == 0 ? phase : -phase), width: 4)
        case 16: level = 0.20 + 0.80 * wave(x * 7 + y * 4 - phase, width: 5)
        case 17: level = 0.08 + 0.92 * wave(y * 1.7 + x * 8.7 - phase * 1.7, width: 6)
        default: level = 0.08 + 0.92 * wave(x * 1.8 + y * 0.9 - phase * 1.4, width: 8)
        }

        let brightness = level * Double(min(lighting.brightness, 4) + 1) / 5
        if effect == 3 || lighting.flags & 0x0F == 8 {
            let hue = (phase * 0.65 + axis * 0.75 + y * 0.16).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.82, brightness: 0.14 + brightness * 0.83)
        }

        let rgb = lighting.rgb
        return Color(
            red: Double((rgb >> 16) & 255) / 255 * brightness,
            green: Double((rgb >> 8) & 255) / 255 * brightness,
            blue: Double(rgb & 255) / 255 * brightness
        )
    }
}

struct LightingPreview: View {
    @Environment(\.appLanguage) private var l
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lighting: Lighting
    let palette: [UInt32]
    let isActive: Bool

    @State private var playing = true
    @State private var origin = Date()
    @State private var pausedAt = Date()
    @State private var pressed: CGPoint?
    @State private var pressedAt: Date?

    private var simulation: LightingSimulation { LightingSimulation(lighting: lighting) }
    private var usesMotion: Bool { simulation.loops || simulation.reactsToKeys }
    private var running: Bool {
        isActive && playing && !reduceMotion && (simulation.loops || pressedAt != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(l("Efekt önizlemesi"), systemImage: "lightbulb")
                    .font(.headline)
                Spacer()
                if usesMotion && !reduceMotion {
                    Button(l(playing ? "Duraklat" : "Oynat"), systemImage: playing ? "pause.fill" : "play.fill") {
                        playing.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .help(l(playing ? "Duraklat" : "Oynat"))
                }
            }
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !running)) { timeline in
                let frame = running ? timeline.date : pausedAt
                Canvas { context, size in draw(in: context, size: size, frame: frame) }
                    .frame(height: 180)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size, initial: true) { canvasSize = geometry.size }
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
                    .onTapGesture(coordinateSpace: .local) { location in
                        if simulation.reactsToKeys { pulse(location) }
                    }
                    .onChange(of: timeline.date) { _, date in
                        if let pressedAt, date.timeIntervalSince(pressedAt) > 1.4 {
                            self.pressedAt = nil
                            pressed = nil
                        }
                    }
                    .focusable(simulation.reactsToKeys)
                    .onKeyPress(keys: [.return, .space]) { _ in
                        guard simulation.reactsToKeys else { return .ignored }
                        startPulse(at: CGPoint(x: 0.5, y: 0.5))
                        return .handled
                    }
                    .accessibilityElement()
                    .accessibilityLabel(l("Klavye aydınlatması"))
                    .accessibilityAddTraits(simulation.reactsToKeys ? .isButton : .isImage)
                    .accessibilityAction {
                        if simulation.reactsToKeys { startPulse(at: CGPoint(x: 0.5, y: 0.5)) }
                    }
            }
            Text(l(previewHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: lighting.effect) {
            origin = .now
            pausedAt = origin
            pressedAt = nil
            pressed = nil
        }
        .onChange(of: running) { _, newValue in
            let now = Date()
            if newValue {
                let pausedDuration = now.timeIntervalSince(pausedAt)
                origin = origin.addingTimeInterval(pausedDuration)
                if let pressedAt, pressedAt <= pausedAt {
                    self.pressedAt = pressedAt.addingTimeInterval(pausedDuration)
                }
            } else {
                pausedAt = now
            }
        }
    }

    private var previewHint: String {
        if lighting.effect == 66 && palette.isEmpty { return "Tuş renklerini görmek için klavyeden oku." }
        if simulation.reactsToKeys { return "Efekti denemek için çizimde bir tuşa tıkla." }
        return "Yaklaşık önizleme. Ayarlar Uygula ile klavyeye gönderilir."
    }

    private func pulse(_ location: CGPoint) {
        guard let size = canvasSize, size.width > 0, size.height > 0 else { return }
        startPulse(at: CGPoint(x: location.x / size.width, y: location.y / size.height))
    }

    @State private var canvasSize: CGSize?

    private func startPulse(at point: CGPoint) {
        pressed = point
        pressedAt = .now
        if !running { pausedAt = pressedAt ?? .now }
    }

    private func draw(in context: GraphicsContext, size: CGSize, frame: Date) {
        let simulation = simulation
        let unit = (size.width - 24) / 16.5
        let rowHeight = (size.height - 24) / 6
        let elapsed = max(0, frame.timeIntervalSince(origin))
        let age = pressedAt.map { max(0, frame.timeIntervalSince($0)) }
        for (rowIndex, row) in KeyboardLayout.rows.enumerated() {
            var x: CGFloat = 12
            let y = 12 + CGFloat(rowIndex) * rowHeight
            for cap in row {
                let width = cap.units * unit
                let rect = CGRect(x: x, y: y, width: max(1, width - 4), height: max(1, rowHeight - 4))
                let path = Path(roundedRect: rect, cornerRadius: 4)
                let point = CGPoint(x: rect.midX / size.width, y: rect.midY / size.height)
                let keyColor = cap.code.flatMap { KeySettingsView.slots[$0] }.flatMap { slot in
                    palette.indices.contains(Int(slot)) ? palette[Int(slot)] : nil
                }
                let led = cap.code == nil ? nil : simulation.color(
                    at: point, time: elapsed, pressed: pressed, age: age, keyColor: keyColor
                )
                context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))
                if let led {
                    context.fill(path, with: .color(led.opacity(0.58)))
                    context.stroke(path, with: .color(led.opacity(0.65)), lineWidth: 1)
                } else {
                    context.stroke(path, with: .color(Color.primary.opacity(0.14)), lineWidth: 1)
                }
                context.draw(
                    Text(cap.legend).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary),
                    at: CGPoint(x: rect.midX, y: rect.midY)
                )
                x += width
            }
        }
    }
}
