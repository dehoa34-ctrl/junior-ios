import Foundation
import UIKit
import UserNotifications

/// Onay kararının sunucu yanıtına göre kullanıcıya söylenecek cümle. Saf mantık.
enum RemoteConfirmText {
    struct Outcome: Equatable {
        let text: String
        /// İstek kapandı mı (karar verildi, süresi doldu, yok): listeden ve bildirimden düşer.
        let resolved: Bool
    }

    /// - status: HTTP durum kodu; nil ise sunucuya ulaşılamadı.
    static func decision(status: Int?, approve: Bool, serverMessage: String?) -> Outcome {
        guard let status else {
            return Outcome(text: "Bilgisayara ulaşılamıyor; kararın gönderilemedi. Bilgisayardaki pencereden de yanıtlayabilirsin.",
                           resolved: false)
        }
        switch status {
        case 200:
            return Outcome(text: approve ? "Onayladım; bilgisayar işleme devam ediyor."
                                         : "Reddettim; bilgisayar bu işlemi yapmayacak.", resolved: true)
        case 409:
            return Outcome(text: serverMessage ?? "Bu istek zaten yanıtlandı.", resolved: true)
        case 410:
            return Outcome(text: "Onay isteğinin süresi doldu; işlem yapılmadı.", resolved: true)
        case 404:
            return Outcome(text: "Bu onay isteği artık yok.", resolved: true)
        case 401, 403:
            return Outcome(text: JuniorError.unauthorized.localizedDescription, resolved: false)
        default:
            return Outcome(text: serverMessage ?? "Karar gönderilemedi (\(status)).", resolved: false)
        }
    }

    /// Sunucunun hata gövdesindeki `error.message`.
    static func serverMessage(_ data: Data) -> String? {
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (parsed?["error"] as? [String: Any])?["message"] as? String
    }
}

/// Bilgisayardaki Junior'ın telefondan istediği onaylar.
///
/// Uygulama açıkken `/v1/remote/confirm/pending` 5 sn'de bir yoklanır. Yeni istek için
/// Onayla/Reddet düğmeli bildirim (`JUNIOR_CONFIRM`) ve Dynamic Island'da düğme gösterilir;
/// listeden düşen ya da süresi geçen istek bildirimden ve adadan kaldırılır. Karar
/// `POST /v1/remote/confirm/{id}` ile tek kullanımlıktır; ilk gelen karar geçerlidir.
@MainActor
final class RemoteConfirmCenter: ObservableObject {
    static let shared = RemoteConfirmCenter()
    static let pollInterval: TimeInterval = 5

    @Published private(set) var pending: [RemoteConfirm] = []
    @Published private(set) var deciding: Set<String> = []
    /// Son kararın sonucu; kartta kısa süre görünür.
    @Published var notice: String?

    private weak var config: Config?
    /// Uygulama yalnız bildirim/ada düğmesi için arka planda açıldıysa kendi yapılandırması.
    private var ownConfig: Config?
    private let client = JuniorClient()
    private var loop: Task<Void, Never>?

    func attach(_ config: Config) {
        self.config = config
    }

    private var activeConfig: Config {
        if let config { return config }
        if let ownConfig { return ownConfig }
        let made = Config()
        ownConfig = made
        return made
    }

    nonisolated static func notificationID(_ confirmID: String) -> String { "junior-confirm-" + confirmID }

    // MARK: - Yoklama

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Arka plana geçerken: cepteyken 5 sn'de bir ağa çıkılmaz.
    func pause() {
        loop?.cancel()
        loop = nil
    }

    func pollOnce() async {
        let config = activeConfig
        guard let token = config.token, !token.isEmpty,
              let url = config.url(path: "/v1/remote/confirm/pending") else { return }
        var fetched: [RemoteConfirm]?
        if let response = try? await client.jsonResponse(method: "GET", url: url, token: token, timeout: 10),
           response.status == 200 {
            fetched = RemoteConfirm.parsePending(response.data)
        }
        apply(RemoteConfirmDiff.reconcile(current: pending, fetched: fetched, now: Date()))
    }

    /// Uzak işin yanıtında görülen onay (yoklama döngüsü kapalıyken de bildirim düşsün).
    func offer(_ confirm: RemoteConfirm) {
        guard !pending.contains(where: { $0.id == confirm.id }) else { return }
        apply(RemoteConfirmDiff.reconcile(current: pending, fetched: pending + [confirm], now: Date()))
    }

    private func apply(_ result: RemoteConfirmDiff.Result) {
        pending = result.pending
        JuniorNotifications.remove(ids: result.removedIDs.map(Self.notificationID))
        for confirm in result.added {
            Task {
                await JuniorNotifications.post(
                    .remote, title: confirm.title,
                    body: confirm.detail.isEmpty ? "Bilgisayardaki Junior onay istiyor." : confirm.detail,
                    id: Self.notificationID(confirm.id),
                    userInfo: [JuniorNotifications.confirmIDKey: confirm.id],
                    categoryIdentifier: JuniorNotifications.confirmCategory)
            }
            // Süresi dolunca bildirim ve ada kendiliğinden temizlensin (sunucuya sormadan).
            let delay = max(1, confirm.expiresAt.timeIntervalSinceNow + 1)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.sweepExpired()
            }
        }
        if let first = pending.first {
            JuniorLiveActivity.shared.showConfirm(id: first.id, text: first.summary, expiresAt: first.expiresAt)
        } else {
            JuniorLiveActivity.shared.clearConfirm()
        }
    }

    private func sweepExpired() {
        apply(RemoteConfirmDiff.reconcile(current: pending, fetched: nil, now: Date()))
    }

    // MARK: - Karar

    /// Onayla / Reddet. Dönüş: kullanıcıya söylenecek sonuç.
    @discardableResult
    func decide(id: String, approve: Bool) async -> String {
        guard !deciding.contains(id) else { return "Kararın gönderiliyor…" }
        deciding.insert(id)
        defer { deciding.remove(id) }
        let config = activeConfig
        guard let token = config.token, !token.isEmpty,
              let url = config.url(path: "/v1/remote/confirm/\(id)") else {
            let text = JuniorError.notConfigured.localizedDescription
            notice = text
            return text
        }
        var status: Int?
        var message: String?
        if let response = try? await client.jsonResponse(method: "POST", url: url, token: token,
                                                         body: ["decision": approve ? "approve" : "deny"], timeout: 15,
                                                         sealed: true) {
            status = response.status
            message = RemoteConfirmText.serverMessage(response.data)
        }
        let outcome = RemoteConfirmText.decision(status: status, approve: approve, serverMessage: message)
        if outcome.resolved {
            JuniorNotifications.remove(ids: [Self.notificationID(id)])
            apply(RemoteConfirmDiff.reconcile(current: pending, fetched: pending.filter { $0.id != id }, now: Date()))
        }
        notice = outcome.text
        return outcome.text
    }

    /// Bildirim düğmesi ya da Dynamic Island düğmesi; uygulama kapalıyken de çağrılabilir.
    static func decideFromSystem(id: String, approve: Bool) async {
        let text = await shared.decide(id: id, approve: approve)
        // Sonuç kullanıcıya ulaşsın: uygulama öndeyse kartta görünür, değilse bildirim.
        if UIApplication.shared.applicationState != .active {
            await JuniorNotifications.post(.remote, title: "Junior", body: text, id: "junior-confirm-result-" + id)
        }
    }

    /// Onay bildirimine verilen yanıt: (istek, karar). Karar nil: bildirime dokunuldu, uygulama açılır.
    nonisolated static func action(from response: UNNotificationResponse) -> (id: String, approve: Bool?)? {
        let content = response.notification.request.content
        guard content.categoryIdentifier == JuniorNotifications.confirmCategory,
              let id = content.userInfo[JuniorNotifications.confirmIDKey] as? String else { return nil }
        switch response.actionIdentifier {
        case JuniorNotifications.approveAction: return (id, true)
        case JuniorNotifications.denyAction: return (id, false)
        default: return (id, nil)
        }
    }
}
