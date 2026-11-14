import Foundation
import Observation
import UserNotifications

struct LowBatteryWarning {
    static let threshold = 20
    private(set) var notified: Bool

    mutating func shouldNotify(percent: Int) -> Bool {
        if percent >= Self.threshold + 5 { notified = false }
        return percent <= Self.threshold && !notified
    }

    mutating func didNotify() {
        notified = true
    }
}

@MainActor
@Observable
final class BatteryMonitor {
    static let shared = BatteryMonitor()

    private(set) var receiverOnline = false
    private(set) var percent: Int?
    private(set) var alertsEnabled = false
    private(set) var authorization = UNAuthorizationStatus.notDetermined
    private(set) var requestingPermission = false

    @ObservationIgnored private var verifiedReceiver: UInt64?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var warning = LowBatteryWarning(notified: UserDefaults.standard.bool(forKey: "lowBatteryNotified"))
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private let notificationDelegate = BatteryNotificationDelegate()

    private init() {
        alertsEnabled = UserDefaults.standard.bool(forKey: "batteryAlertsEnabled")
    }

    var isLow: Bool {
        percent.map { $0 <= LowBatteryWarning.threshold } ?? false
    }

    func start() {
        guard monitoring == nil else { return }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
        monitoring = Task {
            while !Task.isCancelled {
                let receiver = verifiedReceiver
                let reading = await Task.detached { ReceiverBattery.read(verifiedReceiver: receiver) }.value
                receiverOnline = reading?.status.online == true
                percent = reading?.status.percent
                verifiedReceiver = receiverOnline ? reading?.receiverID : nil
                await notifyIfNeeded()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func setAlertsEnabled(_ enabled: Bool) async {
        guard !requestingPermission else { return }
        if enabled, Bundle.main.bundleIdentifier != nil {
            requestingPermission = true
            defer { requestingPermission = false }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        alertsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "batteryAlertsEnabled")
        await notifyIfNeeded()
    }

    private func notifyIfNeeded() async {
        guard let percent else { return }
        let previouslyNotified = warning.notified
        let shouldNotify = warning.shouldNotify(percent: percent)
        if warning.notified != previouslyNotified {
            UserDefaults.standard.set(warning.notified, forKey: "lowBatteryNotified")
        }
        guard shouldNotify, alertsEnabled, !notifying, Bundle.main.bundleIdentifier != nil else { return }
        notifying = true
        defer { notifying = false }
        await refreshAuthorization()
        guard alertsEnabled, authorization == .authorized, let current = self.percent,
              warning.shouldNotify(percent: current) else { return }

        let preference = UserDefaults.standard.string(forKey: "interfaceLanguage")
            .flatMap(LanguagePreference.init(rawValue:)) ?? .system
        let language = preference.language
        let content = UNMutableNotificationContent()
        content.title = language("TOP75 pili azaldı")
        content.body = language.format("Klavye pili %@. Şarj kablosunu bağla.", (Double(current) / 100).formatted(.percent.locale(Locale(identifier: language.code))))
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "top75-low-battery", content: content, trigger: nil)
            )
            warning.didNotify()
            UserDefaults.standard.set(warning.notified, forKey: "lowBatteryNotified")
        } catch {
            // Leave the warning armed so the next valid sample can retry.
        }
    }
}

private final class BatteryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
