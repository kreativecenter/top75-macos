import SwiftUI

struct RestoreReview: View {
    @Environment(\.appLanguage) private var l
    let plan: SnapshotRestorePlan
    var apply: (Set<SnapshotRestorePlan.Item>) -> Void
    var cancel: () -> Void
    @State private var selected: Set<SnapshotRestorePlan.Item> = []

    private static let physicalKeys = Dictionary(uniqueKeysWithValues: KeySettingsView.slots.map { ($0.value, $0.key) })

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l("Geri yükleme önizlemesi")).font(.title2.bold())
            Text(plan.changes.isEmpty ? l("Ayar kaydı klavyeyle eşleşiyor.") : l("Klavyeye yazmak istediğin değişiklikleri seç."))
                .foregroundStyle(.secondary)
            if !plan.changes.isEmpty {
                HStack {
                    Button(l("Tümünü seç")) { selected = Set(plan.changes) }
                    Button(l("Seçimi temizle")) { selected = [] }.disabled(selected.isEmpty)
                    Spacer()
                    Text(l.format("%@ değişiklik seçili", String(selected.count))).foregroundStyle(.secondary)
                }
                Form {
                    ForEach(SnapshotRestorePlan.groups, id: \.self) { group in
                        let items = plan.changes.filter { $0.group == group }
                        if !items.isEmpty {
                            DisclosureGroup {
                                Button(l(items.allSatisfy(selected.contains) ? "Grup seçimini temizle" : "Grubu seç")) {
                                    if items.allSatisfy(selected.contains) { selected.subtract(items) }
                                    else { selected.formUnion(items) }
                                }
                                ForEach(items, id: \.self) { item in
                                    Toggle(isOn: binding(item)) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(title(item))
                                            Text("\(value(item, in: plan.current)) → \(value(item, in: plan.backup))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } label: {
                                LabeledContent(groupTitle(group), value: String(items.count))
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 300)
            }
            HStack {
                Spacer()
                Button(l("Kapat"), role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                if !plan.changes.isEmpty {
                    Button(l("Seçilenleri geri yükle")) { apply(selected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func binding(_ item: SnapshotRestorePlan.Item) -> Binding<Bool> {
        Binding(get: { selected.contains(item) }, set: { enabled in
            if enabled { selected.insert(item) }
            else { selected.remove(item) }
        })
    }

    private func groupTitle(_ group: SnapshotRestorePlan.Group) -> String {
        switch group {
        case .settings: l("Cihaz ayarları")
        case .colors: l("Tuş başına renk")
        case .profile(let profile): l.format("Profil %@", String(Int(profile) + 1))
        }
    }

    private func physicalKey(_ slot: UInt8) -> String {
        guard let usage = Self.physicalKeys[slot], let name = KeySettingsView.keys.first(where: { $0.0 == usage })?.1
        else { return l.format("Tuş yuvası %@", String(slot)) }
        return l(name)
    }

    private func title(_ item: SnapshotRestorePlan.Item) -> String {
        switch item {
        case .lighting: l("Klavye aydınlatması")
        case .debounce: l("Tuş tepkisi")
        case .automaticOS: l("İşletim sistemini otomatik algıla")
        case .timer(let index): l(SnapshotRestorePlan.timers[index])
        case .activeProfile: l("Etkin profil")
        case .color(let slot): physicalKey(slot)
        case .key(_, let fn, let slot): "\(physicalKey(slot)) · \(fn ? "Fn" : l("Temel"))"
        }
    }

    private func value(_ item: SnapshotRestorePlan.Item, in snapshot: SettingsSnapshot) -> String {
        switch item {
        case .lighting:
            let lighting = snapshot.lighting
            let effect = LightingView.effectName(lighting.effect, language: l)
            if lighting.effect == 0 || lighting.effect == 66 { return effect }
            let details = l.format("Hız %@ · parlaklık %@", String(lighting.speed + 1), String(lighting.brightness + 1))
            return "\(effect) · \(details) · \(hex(lighting.rgb)) · 0x\(String(lighting.flags, radix: 16, uppercase: true))"
        case .debounce: return "\(snapshot.options.debounce) ms"
        case .automaticOS: return l(snapshot.options.automaticOS ? "Açık" : "Kapalı")
        case .timer(let index): return l.format("%@ sn", String(snapshot.options.timers[index]))
        case .activeProfile: return groupTitle(.profile(snapshot.activeProfile))
        case .color(let slot): return hex(snapshot.keyColors[Int(slot)])
        case .key(let profile, let fn, let slot):
            let bytes = snapshot.binding(profile: profile, fn: fn, slot: slot)
            let assignment = KeyAssignment(bytes: bytes)
            if case .custom = assignment { return bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
            return assignment.displayName(fn: fn, language: l)
        }
    }

    private func hex(_ color: UInt32) -> String { String(format: "#%06X", color) }
}
