import Foundation
import UIKit

/// iOS'tan biraz arka plan süresi ister; süre dolunca kendiliğinden bırakır.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Süre doldu: iOS uygulamayı askıya alacak. Kalan iş öne dönünce sürer.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Bilgisayara iletilen komutun sonucunu bekler (`GET /v1/remote/{id}?wait=25`, en çok 2 dk).
///
/// Sonuç gelince sohbet balonu güncellenir; uygulama o an arka plandaysa sonuç bildirimle
/// gelir. iOS uygulamayı askıya alırsa bekleyen iş kaydedilir ve öne dönünce son durum sorulur
/// (sunucu işleri 24 saat tutar).
@MainActor
final class RemoteCommandFollower {
    static let maxFollow: TimeInterval = 120
    static let pollWait: TimeInterval = 25
    private static let storeKey = "junior.remote.pending"

    struct Pending: Codable, Equatable {
        let jobID: String
        let messageID: UUID
        let relayed: String
        let startedAt: Date
    }

    /// (balon kimliği, balonun yeni metni, söylenecek sonuç, sonuç kesin mi)
    var onResult: ((UUID, String, String, Bool) -> Void)?

    private let config: Config
    private let client = JuniorClient()
    private var running: [String: Task<Void, Never>] = [:]

    init(config: Config) {
        self.config = config
    }

    func follow(jobID: String, messageID: UUID, relayed: String) {
        let pending = Pending(jobID: jobID, messageID: messageID, relayed: relayed, startedAt: Date())
        var all = load().filter { $0.jobID != jobID }
        all.append(pending)
        save(all)
        start(pending)
    }

    /// Öne dönünce ya da açılışta: yarıda kalan işlerin son durumuna bakar.
    func resumePending() {
        let now = Date()
        var all = load()
        // 24 saatten eskiyi sunucu da tutmuyor.
        all.removeAll { now.timeIntervalSince($0.startedAt) > 24 * 3600 }
        save(all)
        for pending in all where running[pending.jobID] == nil { start(pending) }
    }

    private func start(_ pending: Pending) {
        guard running[pending.jobID] == nil else { return }
        running[pending.jobID] = Task { [weak self] in
            await self?.run(pending)
            self?.running[pending.jobID] = nil
        }
    }

    private enum Fetch {
        case job(RemoteJob)
        case notFound
        case unauthorized
        case unreachable
    }

    private func fetch(_ jobID: String, wait: TimeInterval) async -> Fetch {
        guard let token = config.token, !token.isEmpty,
              let base = config.url(path: "/v1/remote/\(jobID)"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return .unauthorized }
        components.queryItems = [URLQueryItem(name: "wait", value: String(Int(wait)))]
        guard let url = components.url else { return .unreachable }
        do {
            // Uzun yoklama en çok 25 sn bekler; istek 30 sn'de zaman aşımına uğrar.
            let (status, data) = try await client.jsonResponse(method: "GET", url: url, token: token,
                                                               timeout: min(30, max(10, wait + 5)))
            switch status {
            case 200: return RemoteJob.parse(data).map { Fetch.job($0) } ?? .unreachable
            case 404: return .notFound
            case 401, 403: return .unauthorized
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    private func run(_ pending: Pending) async {
        let background = BackgroundActivity(name: "junior-remote-\(pending.jobID)")
        defer { background.end() }
        let deadline = pending.startedAt.addingTimeInterval(Self.maxFollow)
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            let wait = max(0, min(Self.pollWait, remaining))
            switch await fetch(pending.jobID, wait: wait) {
            case .job(let job):
                if let result = RemoteOutcomeText.phrase(job) {
                    // Kedi yüzü: yapıldıysa mutlu, olmadıysa üzgün.
                    if let outcome = job.outcome { JuniorMood.shared.record(outcome: outcome.rawValue) }
                    finish(pending, result: result)
                    return
                }
                // Bilgisayar onay istiyor: yoklama döngüsü kapalıyken (arka planda) de görünsün.
                if let confirm = job.confirm { RemoteConfirmCenter.shared.offer(confirm) }
                if remaining <= 0 {
                    finish(pending, result: RemoteOutcomeText.timedOut)
                    return
                }
            case .notFound:
                finish(pending, result: RemoteOutcomeText.notFound)
                return
            case .unauthorized:
                finish(pending, result: RemoteOutcomeText.unauthorized)
                return
            case .unreachable:
                if remaining <= 0 {
                    // Kayıt kalır: bağlantı gelince (öne dönüşte) yeniden bakılır.
                    onResult?(pending.messageID,
                               RemoteOutcomeText.bubble(relayed: pending.relayed, result: RemoteOutcomeText.unreachable),
                               RemoteOutcomeText.unreachable, false)
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func finish(_ pending: Pending, result: String) {
        save(load().filter { $0.jobID != pending.jobID })
        onResult?(pending.messageID, RemoteOutcomeText.bubble(relayed: pending.relayed, result: result), result, true)
        if UIApplication.shared.applicationState != .active {
            let id = "junior-remote-\(pending.jobID)"
            Task { await JuniorNotifications.post(.remote, title: "Bilgisayardan sonuç", body: result, id: id) }
        }
    }

    private func load() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private func save(_ items: [Pending]) {
        if let data = try? JSONEncoder().encode(Array(items.suffix(20))) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
