import Foundation
import UIKit
import UserNotifications

/// Junior'ın bildirim türleri. Ayarlar'da her biri ayrı açılıp kapatılır; kapalı türden
/// bildirim üretilmez.
enum NotificationCategory: String, CaseIterable, Identifiable {
    case task, routine, checkin, watch, system, remote, screen, notify, briefing, hardware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task: return "Görev bitti"
        case .routine: return "Rutin ve hatırlatma"
        case .checkin: return "Yoklama"
        case .watch: return "Yeni başlık izleme"
        case .system: return "Sistem uyarıları"
        case .remote: return "Uzak komut sonucu"
        case .screen: return "Ekran olayı"
        case .notify: return "Haber"
        case .briefing: return "Brifing"
        case .hardware: return "Donanım uyarısı"
        }
    }

    var detail: String {
        switch self {
        case .task: return "Araştırma görevi ya da video kurgusu bitince"
        case .routine: return "Kurduğun rutinler ve saatli hatırlatmalar"
        case .checkin: return "Uzun sessizlikten sonra \"su içtin mi\" gibi sorular"
        case .watch: return "İzlenen konularda yeni başlık çıkınca"
        case .system: return "Kayıt durdu gibi telefonun kendi uyarıları"
        case .remote: return "Bilgisayara ilettiğin komutun sonucu ve onay istekleri"
        case .screen: return "Bilgisayarda \"ekranda X görünürse haber ver\" kuralı eşleşince"
        case .notify: return "Junior arkada çalışırken iş bitince ya da önemli bir şey olunca (Haber ver)"
        case .briefing: return "Açılış brifingi: bilgisayar açılınca günün özeti"
        case .hardware: return "Bilgisayarda işlemci, bellek, disk, ekran kartı ya da sıcaklık eşiği aşılınca"
        }
    }

    var symbol: String {
        switch self {
        case .task: return "checkmark.circle.fill"
        case .routine: return "alarm.fill"
        case .checkin: return "hand.wave.fill"
        case .watch: return "newspaper.fill"
        case .system: return "exclamationmark.triangle.fill"
        case .remote: return "desktopcomputer"
        case .screen: return "eye.fill"
        case .notify: return "bell.badge.fill"
        case .briefing: return "sun.max.fill"
        case .hardware: return "thermometer.high"
        }
    }

    /// Kendiliğinden gelen türler sessiz saatte susar. Kullanıcının kurduğu hatırlatma susmaz.
    var silencedInQuietHours: Bool { self == .checkin || self == .watch }

    /// Bilgisayardan gelen telefon işinin türü (`/v1/phone/tasks`: `category`, `builtin`, `kind`).
    /// Kategorisiz not/bağlantı/pano: bilgisayardan açıkça gönderilen şey, her zaman gösterilir (nil).
    /// `notifyType`: Haber ver olayının türü (`notify_type`); "hardware_alert" ayrı bir kategoridir.
    static func from(server category: String?, builtin: String?, kind: String,
                     notifyType: String? = nil) -> NotificationCategory? {
        switch builtin {
        case "checkin": return .checkin
        case "watch": return .watch
        case "briefing": return .briefing
        default: break
        }
        if category == "notify", notifyType == "hardware_alert" { return .hardware }
        switch category {
        case "task": return .task
        case "routine": return .routine
        case "system": return .system
        case "remote": return .remote
        case "screen": return .screen
        case "notify": return .notify
        default: return kind == "reminder" ? .routine : nil
        }
    }
}

/// Kategorilerin açık/kapalı tercihi (UserDefaults; varsayılan açık).
enum NotificationPreferences {
    static func key(_ category: NotificationCategory) -> String { "junior.notify." + category.rawValue }

    static func isEnabled(_ category: NotificationCategory, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key(category)) as? Bool) ?? true
    }

    static func set(_ category: NotificationCategory, enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(category))
    }

    static func enabledSet(defaults: UserDefaults = .standard) -> Set<NotificationCategory> {
        Set(NotificationCategory.allCases.filter { isEnabled($0, defaults: defaults) })
    }
}

/// Bildirim kapısı: bir bildirimin gösterilip gösterilmeyeceği. Saf karar.
enum NotificationGate {
    /// - category: nil ise kategorisiz (bilgisayardan açıkça gönderilen not/bağlantı): her zaman.
    /// - userScheduled: kullanıcının kurduğu saatli hatırlatma; sessiz saate takılmaz.
    static func shouldDeliver(_ category: NotificationCategory?, enabled: Set<NotificationCategory>,
                              quietNow: Bool, userScheduled: Bool) -> Bool {
        guard let category else { return true }
        guard enabled.contains(category) else { return false }
        if quietNow, category.silencedInQuietHours, !userScheduled { return false }
        return true
    }

    /// Kategori tercihlerini ve (gerekiyorsa) sunucudaki sessiz saatleri okuyup karar verir.
    @MainActor
    static func allows(_ category: NotificationCategory?, userScheduled: Bool = false) async -> Bool {
        guard let category else { return true }
        let enabled = NotificationPreferences.enabledSet()
        guard enabled.contains(category) else { return false }
        var quiet = false
        if category.silencedInQuietHours, !userScheduled {
            quiet = await QuietHoursSource.shared.isQuietNow()
        }
        return shouldDeliver(category, enabled: enabled, quietNow: quiet, userScheduled: userScheduled)
    }
}

extension QuietHours {
    /// "23:00" → 1380; geçersizse nil.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// Bu an sessiz saatte mi. Aralık gece yarısını aşabilir (23:00–07:00); sunucudaki
    /// `routines.in_quiet` ile aynı kural (başlangıç dahil, bitiş hariç; eşitse sessiz saat yok).
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, let start = Self.minutes(from), let end = Self.minutes(to), start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (start <= minute && minute < end) : (minute >= start || minute < end)
    }
}

/// Sunucudaki sessiz saatler (`GET /v1/routines` → `quiet`, `quiet_now`). Her bildirimde
/// sunucuya gidilmez: 5 dk önbellek; ulaşılamazsa son bilinen aralık telefon saatiyle uygulanır.
@MainActor
final class QuietHoursSource {
    static let shared = QuietHoursSource()
    static let refreshAfter: TimeInterval = 5 * 60
    private static let storeKey = "junior.quietHours"

    struct Snapshot: Codable, Equatable {
        var enabled: Bool
        var from: String
        var to: String
        var quietNow: Bool
        var fetchedAt: Date
    }

    weak var config: Config?
    private let client = JuniorClient()

    /// Önbellekteki bilgiden karar. Saf: taze (1 dk) ise sunucunun `quiet_now`'ı, değilse aralık.
    nonisolated static func quiet(_ snapshot: Snapshot?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let snapshot else { return false }
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        if age >= 0, age < 60 { return snapshot.quietNow }
        return QuietHours(enabled: snapshot.enabled, from: snapshot.from, to: snapshot.to).contains(now, calendar: calendar)
    }

    func isQuietNow(now: Date = Date()) async -> Bool {
        var snapshot = load()
        if snapshot.map({ now.timeIntervalSince($0.fetchedAt) >= Self.refreshAfter }) ?? true,
           let fresh = await fetch(now: now) {
            snapshot = fresh
        }
        return Self.quiet(snapshot, now: now)
    }

    /// Rutinler ekranı listeyi yükleyince de çağrılabilir: önbelleği tazeler.
    func remember(_ listing: RoutineListing, now: Date = Date()) {
        save(Snapshot(enabled: listing.quiet.enabled, from: listing.quiet.from, to: listing.quiet.to,
                      quietNow: listing.quietNow, fetchedAt: now))
    }

    private func fetch(now: Date) async -> Snapshot? {
        guard let config, let token = config.token, !token.isEmpty,
              let url = config.url(path: "/v1/routines"),
              let data = try? await client.json(method: "GET", url: url, token: token),
              let listing = RoutineListing.parse(data) else { return nil }
        remember(listing, now: now)
        return load()
    }

    private func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func save(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }
}

/// Bildirim kategorileri (Onayla/Reddet) ve kategoriye bağlı bildirim gönderme.
enum JuniorNotifications {
    static let confirmCategory = "JUNIOR_CONFIRM"
    static let approveAction = "JUNIOR_CONFIRM_APPROVE"
    static let denyAction = "JUNIOR_CONFIRM_DENY"
    static let confirmIDKey = "confirmID"

    /// Uygulama açılırken bir kez: onay bildiriminin düğmeleri.
    static func registerCategories() {
        // Onay kilit açılmadan verilmez; Reddet kilitliyken de verilebilir.
        let approve = UNNotificationAction(identifier: approveAction, title: "Onayla", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: "Reddet", options: [.destructive])
        let confirm = UNNotificationCategory(identifier: confirmCategory, actions: [approve, deny],
                                             intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([confirm])
    }

    /// Sessiz saat önbelleği ve onay merkezi bu yapılandırmayla sunucuya gider.
    @MainActor
    static func attach(_ config: Config) {
        QuietHoursSource.shared.config = config
        RemoteConfirmCenter.shared.attach(config)
    }

    /// Bildirim izni var mı. Arka plandayken izin penceresi açılamaz; sorulmamışsa bekletmeden geçilir.
    @MainActor
    static func authorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else { return false }
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    /// Kategorisi açıksa bildirim gönderir. Dönüş: gönderildi mi.
    @MainActor
    @discardableResult
    static func post(_ category: NotificationCategory, title: String, body: String, id: String,
                     userInfo: [String: Any] = [:], categoryIdentifier: String? = nil) async -> Bool {
        guard NotificationPreferences.isEnabled(category), await authorized() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(500))
        content.sound = .default
        content.userInfo = userInfo
        content.threadIdentifier = "junior-" + category.rawValue
        if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    static func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
