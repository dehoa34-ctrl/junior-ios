import Foundation

/// Bir işin sonucu. Bilgisayara iletilen uzak komut da telefonun kendi eylemi de bu beş
/// durumdan biriyle biter; kullanıcıya söylenen cümle durumdan çıkar, "oldu" yalnız `done`'da denir.
enum JuniorOutcome: String, CaseIterable, Equatable {
    /// Yapıldı (doğrulandı).
    case done
    /// Gönderildi / denendi ama yapıldığı doğrulanamadı.
    case unverified
    /// Olmadı; mesaj nedenini söyler.
    case failed
    /// Junior yapmadan önce bir şey soruyor (ya da kullanıcının dokunması gerekiyor).
    case ask
    /// Bilgisayar zamanında yanıt vermedi.
    case expired
}

/// Bilgisayardaki onay isteği (`/v1/remote/confirm/pending`, işin `confirm` alanı).
struct RemoteConfirm: Equatable, Identifiable {
    let id: String
    let jobID: String
    let title: String
    let detail: String
    /// Telefonun saatine göre sona erme anı (sunucunun `expires_in` saniyesinden).
    let expiresAt: Date

    static func parse(_ raw: [String: Any], now: Date = Date()) -> RemoteConfirm? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        // Karar verilmiş istek bekleyen sayılmaz.
        if let decision = raw["decision"] as? String, !decision.isEmpty { return nil }
        let seconds = (raw["expires_in"] as? Double) ?? Double((raw["expires_in"] as? Int) ?? 0)
        return RemoteConfirm(id: id, jobID: raw["job_id"] as? String ?? "", title: title,
                             detail: (raw["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             expiresAt: now.addingTimeInterval(max(0, seconds)))
    }

    /// `{"confirms": [...]}`; bozuk kayıtlar atlanır.
    static func parsePending(_ data: Data, now: Date = Date()) -> [RemoteConfirm]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["confirms"] as? [[String: Any]] else { return nil }
        return items.compactMap { parse($0, now: now) }
    }

    /// Bildirimde ve adada görünen tek satır.
    var summary: String { detail.isEmpty ? title : "\(title) · \(detail)" }

    func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// Bekleyen onay listesinin yeni yoklamayla güncellenmesi. Saf mantık: bildirim ve ada
/// bundan beslenir (yeni gelene bildirim, düşene bildirim kaldırma).
enum RemoteConfirmDiff {
    struct Result: Equatable {
        var pending: [RemoteConfirm]
        var added: [RemoteConfirm]
        var removedIDs: [String]
    }

    /// `fetched` nil: sunucuya ulaşılamadı; eldeki liste korunur ama süresi geçenler düşer.
    static func reconcile(current: [RemoteConfirm], fetched: [RemoteConfirm]?, now: Date) -> Result {
        let source = fetched ?? current
        var seen = Set<String>()
        let pending = source.filter { !$0.isExpired(at: now) && seen.insert($0.id).inserted }
        let known = Set(current.map(\.id))
        let keep = Set(pending.map(\.id))
        return Result(pending: pending,
                      added: pending.filter { !known.contains($0.id) },
                      removedIDs: current.map(\.id).filter { !keep.contains($0) })
    }
}

/// Uzak işin telefona görünen hâli (`GET /v1/remote/{id}` → `{"job": {...}}`).
struct RemoteJob: Equatable {
    enum State: Equatable {
        case queued
        case claimed
        case finished(JuniorOutcome)
        case unknown(String)
    }

    let id: String
    let state: State
    /// Bilgisayar işi aldı mı (`claimed_at` dolu).
    let claimed: Bool
    let progress: String?
    let message: String
    let reply: String
    /// `false`: bilgisayardaki Junior etkili bir araç çalıştırmadı (yalnız yanıt yazdı).
    let acted: Bool
    let confirm: RemoteConfirm?

    var outcome: JuniorOutcome? {
        if case .finished(let outcome) = state { return outcome }
        return nil
    }

    var isFinal: Bool { outcome != nil }

    static func parse(_ data: Data, now: Date = Date()) -> RemoteJob? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let job = root["job"] as? [String: Any] else { return nil }
        return parse(job: job, now: now)
    }

    static func parse(job raw: [String: Any], now: Date = Date()) -> RemoteJob? {
        guard let id = raw["id"] as? String, !id.isEmpty, let stateRaw = raw["state"] as? String else { return nil }
        let state: State
        switch stateRaw {
        case "queued": state = .queued
        case "claimed": state = .claimed
        default: state = JuniorOutcome(rawValue: stateRaw).map { State.finished($0) } ?? .unknown(stateRaw)
        }
        let result = raw["result"] as? [String: Any]
        let progress = (raw["progress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteJob(id: id, state: state,
                         claimed: raw["claimed_at"] is Double || raw["claimed_at"] is Int,
                         progress: (progress?.isEmpty ?? true) ? nil : progress,
                         message: result?["message"] as? String ?? "",
                         reply: result?["reply"] as? String ?? "",
                         acted: (result?["acted"] as? Bool) ?? true,
                         confirm: (raw["confirm"] as? [String: Any]).flatMap { RemoteConfirm.parse($0, now: now) })
    }
}

/// Uzak komutun telefondaki cümleleri. Saf mantık; durum → doğru ifade.
enum RemoteOutcomeText {
    /// Sunucunun "ilettim" cümlesinin sonundaki söz; sonuç gelince balondan düşer.
    static let promise = "Sonucu birazdan söylerim."
    static let notFound = "Bu komutun sonucu bilinmiyor: sunucu yeniden başlamış ya da kaydın süresi geçmiş olabilir. Bilgisayardan kontrol et."
    static let timedOut = "Bilgisayar 2 dakikadır sonuç bildirmedi; olup olmadığını bilmiyorum. Bilgisayardan kontrol et."
    static let unreachable = "Bilgisayara ulaşılamıyor; komutun sonucunu öğrenemedim. Bağlantı gelince yeniden bakacağım."
    static let unauthorized = "Token geçersiz olduğu için komutun sonucunu alamadım. Ayarlar'dan kontrol et."

    /// Sunucu metnindeki durum etiketini ("[done] …") ve kalın yazı işaretlerini atar.
    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "^\\[(done|unverified|failed|ask|started)\\]\\s*", options: .regularExpression) {
            value.removeSubrange(range)
        }
        return String(value.replacingOccurrences(of: "**", with: "").prefix(600))
    }

    /// Duruma göre söylenecek cümle.
    static func phrase(outcome: JuniorOutcome, message rawMessage: String, acted: Bool = true, claimed: Bool = false) -> String {
        let message = clean(rawMessage)
        func join(_ lead: String) -> String { message.isEmpty ? lead : "\(lead) \(message)" }
        switch outcome {
        case .done:
            return message.isEmpty ? "Bilgisayarda yapıldı." : "Bilgisayarda yapıldı: \(message)"
        case .unverified:
            return acted ? join("Bilgisayara gönderildi ama yapıldığı doğrulanamadı.")
                         : join("Bilgisayarda bir işlem yapılmadı.")
        case .failed:
            return message.isEmpty ? "Bilgisayarda olmadı." : "Bilgisayarda olmadı: \(message)"
        case .ask:
            return message.isEmpty ? "Bilgisayardaki Junior'ın bir sorusu var; bilgisayardan bak."
                                   : "Bilgisayardaki Junior'ın sorusu: \(message)"
        case .expired:
            return claimed
                ? "Bilgisayar işi aldı ama yanıt vermedi; olup olmadığını bilmiyorum. Bilgisayardan kontrol et."
                : "Bilgisayar yanıt vermedi; komutu yürütmedim. Bilgisayar açık ve Junior çalışıyorsa tekrar dene."
        }
    }

    /// Bitmiş işin cümlesi; bitmemişse nil.
    static func phrase(_ job: RemoteJob) -> String? {
        guard let outcome = job.outcome else { return nil }
        return phrase(outcome: outcome, message: job.message, acted: job.acted, claimed: job.claimed)
    }

    /// "Bilgisayara ilettim: X. Sonucu birazdan söylerim." → "Bilgisayara ilettim: X."
    /// (önceki ara sonuç satırı da atılır).
    static func relayHead(_ relayed: String) -> String {
        var head = relayed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = head.range(of: "\n→ ") { head = String(head[..<cut.lowerBound]) }
        if head.hasSuffix(promise) {
            head = String(head.dropLast(promise.count))
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sohbet balonunun son hâli: "ilettim" satırı (sözü atılmış) + sonuç.
    static func bubble(relayed: String, result: String) -> String {
        let head = relayHead(relayed)
        return head.isEmpty ? result : "\(head)\n→ \(result)"
    }
}

extension PhoneActionResult {
    /// Telefonun kendi eyleminin durumu: aynı beş durum.
    var outcome: JuniorOutcome {
        switch kind {
        case .done: return .done
        case .failed: return .failed
        // Bildirim bırakıldı: yapılması kullanıcının dokunmasına bağlı.
        case .deferred: return .ask
        // Uygulama açıldı; isteğin yerine gelip gelmediği henüz bilinmiyor.
        case .needsRetry: return .unverified
        }
    }

    /// Söylenecek cümle. `serverReply` sunucunun "kuruyorum" cümlesidir; yalnız iş yapıldıysa kullanılır.
    func spoken(serverReply: String) -> String {
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .done: return text.isEmpty ? serverReply : text
        case .failed: return text.isEmpty ? "Telefonda olmadı." : "Telefonda olmadı: \(text)"
        case .ask: return text.isEmpty ? "Bunu bildirim olarak bıraktım; dokununca yapacağım." : text
        case .unverified: return text.isEmpty ? "Telefonda denedim ama yapıldığını doğrulayamadım." : text
        case .expired: return text.isEmpty ? "Telefon zamanında yanıt vermedi." : text
        }
    }

    /// Sohbette sunucunun cümlesinin yerine geçecek metin. `nil`: iş yapıldı ve söylenecek
    /// kendi cümlesi yok; sunucunun cümlesi **ve önden üretilen ses parçaları** kalır.
    func replacement(serverReply: String) -> String? {
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome == .done, text.isEmpty { return nil }
        return spoken(serverReply: serverReply)
    }
}
