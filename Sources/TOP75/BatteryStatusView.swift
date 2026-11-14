import AppKit
import SwiftUI

struct BatteryStatusView: View {
    @Environment(\.appLanguage) private var l
    private let battery = BatteryMonitor.shared

    var body: some View {
        Section(l("Pil ve şarj")) {
            LabeledContent(l("Pil seviyesi")) {
                if let percent = battery.percent {
                    Text(Double(percent) / 100, format: .percent.locale(Locale(identifier: l.code)))
                        .monospacedDigit()
                        .foregroundStyle(battery.isLow ? Color.orange : Color.primary)
                } else {
                    Text(l("Pil bilgisi alınamadı")).foregroundStyle(.secondary)
                }
            }
            if battery.isLow {
                Label(l("TOP75 pili azaldı"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: Binding(get: { battery.alertsEnabled }, set: { enabled in
                Task { await battery.setAlertsEnabled(enabled) }
            })) {
                Text(l("Düşük pil bildirimi"))
                Text(l("TOP75 açıkken pil %20’ye düştüğünde macOS bildirimi al."))
            }
            .disabled(battery.requestingPermission)
            if battery.alertsEnabled, battery.authorization == .denied {
                Button(l("Bildirim ayarlarını aç")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(l("Pil yüzdesi Bluetooth 5.0 ve 2,4 GHz bağlantılarında okunur. Şarj durumunu klavyenin kendi ekranından kontrol et."))
                .foregroundStyle(.secondary)
        }
        .task { await battery.refreshAuthorization() }
    }
}
