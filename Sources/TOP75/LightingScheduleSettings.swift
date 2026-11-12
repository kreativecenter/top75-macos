import ServiceManagement
import SwiftUI

struct LightingScheduleSettings: View {
    @Environment(\.appLanguage) private var l
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var scheduler = LightingScheduler.shared
    @State private var loginEnabled = false
    @State private var loginApproval = false
    @State private var loginError = false

    var body: some View {
        Section(l("Işık kapatma aralığı")) {
            Toggle(l("Işığı her gün belirli saatlerde kapat"), isOn: $scheduler.schedule.enabled)
            HStack(spacing: 24) {
                DatePicker(l("Başlangıç"), selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker(l("Bitiş"), selection: time(\.end), displayedComponents: .hourAndMinute)
            }
            Text(l("TOP75 çalışırken ve klavye bağlıyken önceki aydınlatma aralık sonunda geri yüklenir."))
                .foregroundStyle(.secondary)
            LabeledContent(l("Durum"), value: l(scheduler.status))
            if scheduler.canSkip {
                Button(l("Bu aralığı atla"), action: scheduler.skipCurrentInterval)
            }
        }
        Section(l("Oturum açma")) {
            Toggle(l("Oturum açınca TOP75’i başlat"), isOn: Binding(get: { loginEnabled }, set: setLogin))
            if loginApproval {
                Button(l("Oturum açma öğelerini aç")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if loginError {
                Text(l("Oturum açılışında başlatma ayarlanamadı.")).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: readLoginStatus)
        .onChange(of: scenePhase) { if scenePhase == .active { readLoginStatus() } }
    }

    private func time(_ key: WritableKeyPath<LightingSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = scheduler.schedule[keyPath: key]
            let calendar = Calendar.current
            return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            scheduler.schedule[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private func readLoginStatus() {
        let status = SMAppService.mainApp.status
        loginApproval = status == .requiresApproval
        loginEnabled = status == .enabled || loginApproval
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = false
        } catch {
            loginError = true
        }
        readLoginStatus()
    }
}
