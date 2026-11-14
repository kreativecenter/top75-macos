import AppKit
import SwiftUI

struct BatteryStatusView: View {
    @Environment(\.appLanguage) private var l
    private let battery = BatteryMonitor.shared
    @Bindable private var scheduler = LightingScheduler.shared
    @State private var testing = false
    @State private var testStatus = ""

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
            Button(l("Test bildirimi gönder")) {
                testing = true
                Task {
                    let sent = await battery.sendTestNotification(language: l)
                    testStatus = sent ? "Test bildirimi gönderildi." : "Bildirim gönderilemedi. macOS bildirim ayarlarını kontrol et."
                    testing = false
                }
            }
            .disabled(testing)
            if !testStatus.isEmpty { Text(l(testStatus)).foregroundStyle(.secondary) }
            Picker(l("Düşük pilde aydınlatma"), selection: $scheduler.batteryAction) {
                Text(l("Olduğu gibi bırak")).tag(LightingScheduler.BatteryAction.off)
                Text(l("Işığı kıs")).tag(LightingScheduler.BatteryAction.dim)
                Text(l("Işığı kapat")).tag(LightingScheduler.BatteryAction.dark)
            }
            if scheduler.batteryAction != .off {
                Stepper(l.format("Pil tasarrufu eşiği: %@", (Double(scheduler.batteryThreshold) / 100).formatted(.percent)),
                        value: $scheduler.batteryThreshold, in: 10...50, step: 5)
            }
            if scheduler.batterySaving { Text(l("Pil tasarrufu etkin")).foregroundStyle(.secondary) }
            Text(l("Pil yüzdesi Bluetooth 5.0 ve 2,4 GHz bağlantılarında okunur. Şarj durumunu klavyenin kendi ekranından kontrol et."))
                .foregroundStyle(.secondary)
        }
        .task { await battery.refreshAuthorization() }
    }
}
