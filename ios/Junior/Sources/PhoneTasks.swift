import Foundation
import UIKit
import UserNotifications

/// Bilgisayardaki Junior'in telefona biraktigi is: not, baglanti, pano ya da
/// hatirlatici. Sunucu kuyrukta tutar (`/v1/phone/tasks`); telefon alinca duser.
struct PhoneTask: Equatable {
    enum Kind: String { case note, link, clipboard, reminder }

    let id: String
    let kind: Kind
    let text: String
    let url: URL?
    /// Yalniz hatirlatici icin
    let at: Date?

    /// Sunucu yaniti: {"tasks": [{"id", "kind", "text", "url", "at" (ms)}]}.
    /// Bozuk ya da bilinmeyen kayitlar atlanir; biri digerlerini engellemez.
    static func parse(_ data: Data) -> [PhoneTask] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["tasks"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let kind = Kind(rawValue: item["kind"] as? String ?? "") else { return nil }
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var url: URL?
            if let raw = item["url"] as? String, let parsed = URL(string: raw),
               let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                url = parsed
            }
            var at: Date?
            if let ms = item["at"] as? Double, ms > 0 { at = Date(timeIntervalSince1970: ms / 1000) }
            switch kind {
            case .link: if url == nil { return nil }
            case .reminder: if at == nil || text.isEmpty { return nil }
            case .note, .clipboard: if text.isEmpty { return nil }
            }
            return PhoneTask(id: id, kind: kind, text: text, url: url, at: at)
        }
    }

    /// Bildirimde gorunecek baslik ve metin.
    var notification: (title: String, body: String) {
        switch kind {
        case .note: return ("Bilgisayardan not", text)
        case .link: return ("Bilgisayardan bağlantı", text.isEmpty ? (url?.absoluteString ?? "") : text)
        case .clipboard: return ("Panoya kopyalandı", text)
        case .reminder: return ("Hatırlatma", text)
        }
    }
}

/// Uygulama acikken bilgisayardan gelen isleri alir ve yapar. iOS arka planda
/// duzenli ag istegine izin vermedigi icin yalniz on plandayken bakilir;
/// telefonda bekleyenler uygulama acilinca gelir.
@MainActor
final class PhoneTaskService: ObservableObject {
    private let config: Config
    private let client = JuniorClient()
    private let interval: TimeInterval
    private var loop: Task<Void, Never>?
    /// Ag tekrari ayni isi iki kez yaptirmasin.
    private var seen: [String] = []

    init(config: Config, interval: TimeInterval = 15) {
        self.config = config
        self.interval = interval
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard let seconds = self?.interval else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
    }

    func pollOnce() async {
        guard let url = config.url(path: "/v1/phone/tasks"),
              let token = config.token, !token.isEmpty,
              let tasks = try? await client.phoneTasks(url: url, token: token) else { return }
        for task in tasks where !seen.contains(task.id) {
            seen.append(task.id)
            if seen.count > 200 { seen.removeFirst(seen.count - 200) }
            await perform(task)
        }
    }

    private func perform(_ task: PhoneTask) async {
        switch task.kind {
        case .note:
            await Self.notify(task)
        case .link:
            if let url = task.url, UIApplication.shared.applicationState == .active {
                await UIApplication.shared.open(url)
            } else {
                await Self.notify(task)
            }
        case .clipboard:
            UIPasteboard.general.string = task.text
            await Self.notify(task)
        case .reminder:
            await Self.notify(task, at: task.at)
        }
    }

    private static func notify(_ task: PhoneTask, at date: Date? = nil) async {
        let center = UNUserNotificationCenter.current()
        // Izin ilk iste sorulur; reddedildiyse sessizce gecilir (not yine de
        // uygulamadaki eylemle yapilmis olur: pano, baglanti).
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        let text = task.notification
        content.title = text.title
        content.body = String(text.body.prefix(500))
        content.sound = .default
        if let url = task.url { content.userInfo = ["url": url.absoluteString] }
        var trigger: UNNotificationTrigger?
        if let date {
            let seconds = date.timeIntervalSinceNow
            // Saati gecmis hatirlatici hemen gosterilir.
            if seconds > 1 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false) }
        }
        try? await center.add(UNNotificationRequest(identifier: "junior-task-" + task.id, content: content, trigger: trigger))
    }
}

/// Uygulama acikken de bildirim gorunsun; bildirimdeki baglantiya dokununca acilsin.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}
