import Foundation
import UserNotifications

/// Pomodoro'nun telefondaki yerel bildirimlerini sunucudaki tura göre tutar. Tur yalnız Beceriler
/// ekranından değil sesle (telefonda /v1/command, Siri) ve masaüstünden de başlar/durur; bu yüzden
/// bildirimler tek bir yerde kurulur ve silinir:
/// - Beceriler ekranı özeti yükleyince `apply`,
/// - telefondaki sesli komut pomodoroyu değiştirince `refresh` (önce eski bildirimler hemen silinir),
/// - uygulama öne gelince `refreshIfScheduled` (masaüstünden durdurulmuş tur için).
@MainActor
enum PomodoroAlertSync {
    /// Telefonda kurulu pomodoro bildirimi var mı; yoksa öne gelişte ağa çıkılmaz.
    private static let scheduledKey = "junior.pomodoro.alertsScheduled"
    private static let client = JuniorClient()

    /// Bildirimleri süren tura göre kurar ya da kaldırır. İzin yalnız `ask` iken (telefondan
    /// başlatınca) sorulur; sesle/masaüstünden başlayan tur için izin varsa kurulur.
    static func apply(_ overview: SkillsOverview?, ask: Bool) async {
        clear()
        guard let overview, overview.enabled(.pomodoro) else { return }
        let pomodoro = overview.pomodoro
        let alerts = PomodoroAlerts.plan(phase: pomodoro.phase, ends: pomodoro.ends,
                                         breakMin: pomodoro.breakMin ?? overview.breakMin, now: Date())
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        if ask {
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        } else {
            let settings = await center.notificationSettings()
            allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
        guard allowed else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let seconds = max(1, alert.fireAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
        UserDefaults.standard.set(true, forKey: scheduledKey)
    }

    /// Bekleyen iki pomodoro bildirimini siler (çalışma sonu ve mola sonu).
    static func clear() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: PomodoroAlerts.ids)
        UserDefaults.standard.set(false, forKey: scheduledKey)
    }

    /// Sesli komut pomodoroyu başlattı ya da durdurdu. Eski bildirimler ağı beklemeden silinir
    /// (yoksa durdurulan tur için "Pomodoro bitti" gelirdi); sonra sunucudaki yeni tur kurulur.
    /// `config` verilmezse (Siri) kayıtlı ayarlar okunur.
    static func refresh(config: Config? = nil) async {
        clear()
        let settings = config ?? Config()
        guard let overview = await fetch(settings) else { return }
        await apply(overview, ask: false)
    }

    /// Uygulama öne gelince: kurulu bildirim varsa sunucudaki turla karşılaştırır. Tur bu arada
    /// masaüstünden durdurulduysa bildirim silinir. Bilgisayara ulaşılamazsa bildirimler kalır.
    static func refreshIfScheduled(config: Config) async {
        guard UserDefaults.standard.bool(forKey: scheduledKey) else { return }
        guard let overview = await fetch(config) else { return }
        await apply(overview, ask: false)
    }

    private static func fetch(_ config: Config) async -> SkillsOverview? {
        guard let token = config.token, !token.isEmpty, let url = config.url(path: "/v1/skills/daily") else { return nil }
        guard let data = try? await client.json(method: "GET", url: url, token: token, timeout: SkillsModel.timeout) else {
            return nil
        }
        return SkillsOverview.parse(data)
    }
}
