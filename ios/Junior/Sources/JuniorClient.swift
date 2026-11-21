import Foundation
import UIKit

/// mobile_api sozlesmesi. Sunucu sinirlari burada da uygulanir ki
/// gereksiz istek gonderilmesin ve hata mesaji anlasilir olsun.
enum JuniorLimits {
    static let maxMessageChars = 4000
    static let maxHistoryMessages = 12
    static let maxImageBytes = 2 * 1024 * 1024
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    let date: Date

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

/// Sunucunun donebilecegi durumlar. Bilinmeyen bir deger gelirse ham metni korur.
enum CommandStatus: Equatable {
    case ok
    case needsTarget
    case needsImage
    case setupRequired
    case notCompleted
    case outcomeUnknown
    /// Sunucu işi telefona bıraktı (hatırlatıcı, arama, zamanlayıcı …): `phone_action`.
    case phoneAction
    /// Komut bilgisayardaki Junior'a iletildi; sonuç `GET /v1/remote/{id}` ile beklenir.
    case remoteStarted
    case other(String)

    init(raw: String?) {
        switch raw {
        case nil: self = .ok
        case "dispatched": self = .ok
        case "needs_target": self = .needsTarget
        case "needs_image": self = .needsImage
        case "setup_required": self = .setupRequired
        case "not_completed": self = .notCompleted
        case "outcome_unknown": self = .outcomeUnknown
        case "phone_action": self = .phoneAction
        case "remote_started": self = .remoteStarted
        case let value?: self = .other(value)
        }
    }
}

struct CommandResponse {
    let reply: String
    let status: CommandStatus
    let errorCode: String?
    /// Sunucunun bölüp önden seslendirmeye başladığı parçalar; boşsa uygulama kendisi böler.
    var speech: [String] = []
    /// `status == .phoneAction` iken telefonun yapacağı iş (ve bildirime konacak ham hali).
    var phoneAction: PhoneAction?
    var phoneActionPayload: [String: Any]?
    /// `status == .remoteStarted` iken bilgisayara iletilen işin kimliği.
    var remoteJobID: String?
    /// Sunucunun yaptığı işler ("pomodoro_stop" …): telefon kendi durumunu buna göre tazeler.
    var actionsExecuted: [String] = []
}

enum JuniorError: LocalizedError {
    case notConfigured
    case badAddress
    case unauthorized
    case busy
    case providerLoginRequired
    case rateLimited
    case server(String)
    case network
    /// Komut gönderildi ama yanıt gelmedi (zaman aşımı, bağlantı yarıda koptu): sunucuya
    /// ulaşmış olabilir. Çevrimdışı kuyruğa girmez, kendiliğinden yeniden gönderilmez.
    case noReply

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Once Ayarlar'dan sunucu adresini ve tokeni gir."
        case .badAddress: return "Sunucu adresi gecersiz. https://... biciminde olmali."
        case .unauthorized: return "Token gecersiz. Ayarlar'dan kontrol et."
        case .busy: return "Junior su an mesgul. Birkac saniye sonra tekrar dene."
        case .providerLoginRequired: return "Bilgisayardaki Claude oturumu kapali. `claude auth status` ile kontrol et."
        case .rateLimited: return "Dakikalik istek sinirina ulasildi."
        case .server(let message): return message
        case .network: return "Sunucuya ulasilamadi. Bilgisayar ve tunel acik mi?"
        case .noReply: return "Yanıt gecikti; komut bilgisayara gitmiş olabilir. Yeniden denemeden önce bilgisayardan kontrol et."
        }
    }

    /// Komut isteğinin ağ hatası: yalnız bağlantı **hiç kurulamadıysa** `.network` (istek
    /// sunucuya gitmedi, kuyruğa alınabilir). Zaman aşımı ya da yarıda kopma `.noReply`:
    /// istek ulaşmış olabilir, otomatik yeniden gönderme aynı sohbet turunu iki kez çalıştırırdı.
    static func commandFailure(_ error: Error) -> JuniorError {
        if let junior = error as? JuniorError { return junior }
        guard let urlError = error as? URLError else { return .noReply }
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .network
        default:
            return .noReply
        }
    }
}

/// Komut isteğinin yanıtı; görev grubundan taşınabilsin diye tek değer.
private struct CommandReply: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}

actor JuniorClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Claude yaniti 90 saniyeye kadar surebilir.
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func capabilities(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Komut bu kadar saniyede bitmezse sunucunun ayakta olup olmadığına bakılır.
    static let reachabilityDelay: TimeInterval = 5
    static let reachabilityTimeout: TimeInterval = 10

    /// - requestID: çevrimdışı kuyruktan gönderilen komut ilk denemenin kimliğini taşır.
    /// - followsRemote: uzak komutun sonucunu `GET /v1/remote/{id}` ile bekleyecek miyiz
    ///   (sunucu "sonucu birazdan söylerim" sözünü yalnız o zaman verir).
    /// - healthURL: verilirse bağlantı ölüyken 100 sn beklenmez; en geç ~15 sn'de `.network`.
    func send(url: URL, token: String, message: String, history: [ChatMessage],
              image: Data?, target: String?, requestID: String = UUID().uuidString,
              followsRemote: Bool = false, healthURL: URL? = nil) async throws -> CommandResponse {
        var body: [String: Any] = [
            "message": String(message.prefix(JuniorLimits.maxMessageChars)),
            // Ag tekrari sarkiyi iki kez atlamasin diye her istek benzersiz kimlik tasir.
            "request_id": requestID,
        ]
        let pairs = Self.completedPairs(from: history)
        if !pairs.isEmpty { body["history"] = pairs }
        if let target { body["target"] = target }
        if let image {
            body["image_base64"] = image.base64EncodedString()
            body["image_mime_type"] = "image/jpeg"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sunucu yanitla birlikte seslendirme parcalarini da gondersin ve ilk
        // parcalarin sesini hemen uretmeye baslasin: ses birkac saniye erken gelir.
        request.setValue("chunks", forHTTPHeaderField: "X-Junior-Speech")
        if followsRemote { request.setValue("1", forHTTPHeaderField: "X-Junior-Remote") }

        // Eşleştirme anahtarı varsa gövde AES-256-GCM ile şifreli gider (PairingCrypto.swift).
        let (data, response) = try await sealedExchange(request, url: url, token: token, body: body) { request in
            try await self.performCommand(request, health: healthURL)
        }
        try check(response: response, data: data)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let reply = parsed["reply"] as? String ?? ""
        let error = parsed["error"] as? [String: Any]
        let speech = (parsed["speech"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        let status = CommandStatus(raw: parsed["status"] as? String)
        var result = CommandResponse(reply: reply.isEmpty ? "Junior bos yanit dondurdu." : reply,
                                       status: status,
                                       errorCode: error?["code"] as? String,
                                       speech: reply.isEmpty ? [] : speech)
        result.actionsExecuted = (parsed["actions_executed"] as? [Any])?.compactMap { $0 as? String } ?? []
        if status == .phoneAction, let payload = parsed["phone_action"] as? [String: Any] {
            result.phoneActionPayload = payload
            result.phoneAction = PhoneAction.parse(payload)
        }
        if status == .remoteStarted { result.remoteJobID = parsed["job_id"] as? String }
        return result
    }

    /// Sunucu ayakta mi. Token istemez ve hizli doner; konusmadan **once**
    /// bilgisayarin acik olup olmadigini gostermek icin.
    func isReachable(url: URL, timeout: TimeInterval = 6) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Yanit metnini sunucuda dogal sese cevirtir; MP3 baytlari doner.
    /// Hata durumunda cagiran taraf iOS'un yerlesik sesine duser.
    func tts(url: URL, token: String, text: String) async throws -> Data {
        var request = URLRequest(url: url)
        // Ses gelmezse yerleşik sese düşmek için uzun bekleme yok: oturumun
        // 100 saniyelik sınırı kullanıcıyı sessizlikte bırakıyordu.
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": String(text.prefix(1600))])
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        guard !data.isEmpty else { throw JuniorError.server("Ses sentezi bos dondu.") }
        return data
    }

    /// Konusmayi sunucudaki whisper'a yazdirir. Govde 16 kHz tek kanal WAV.
    func stt(url: URL, token: String, wav: Data) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wav
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return parsed?["text"] as? String ?? ""
    }

    /// QR eslestirmesinden hemen sonra: belirtec ve tunel calisiyor mu, bilgisayara
    /// "eslestim" de (masaustundeki QR penceresi bunu gorunce "baglandi" der).
    /// Bu ucu bilmeyen eski sunucuda yetenek ucuyla yalniz baglanti denenir.
    func confirmPairing(url: URL, token: String, fallback: URL?) async throws -> [String] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        if (response as? HTTPURLResponse)?.statusCode == 404, let fallback {
            _ = try await capabilities(url: fallback, token: token)
            return []
        }
        try check(response: response, data: data)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (parsed?["providers"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Küçük JSON uçları (rutinler vb.): isteği gönderir, yanıt verisini döndürür.
    /// `timeout`: model ya da web okuyan beceri uçları (sınav, derin arama) daha uzun bekler.
    func json(method: String, url: URL, token: String, body: [String: Any]? = nil,
              timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        return data
    }

    /// Durum kodu anlam taşıyan küçük JSON uçları (uzak komut ve onay: 404/409/410).
    /// Yalnız ağ hatasında atar; HTTP yanıtı olduğu gibi döner. Zaman aşımı en çok 30 sn.
    /// `sealed`: eşleştirme anahtarı varsa gövde şifreli gider (uzak komut onayı).
    func jsonResponse(method: String, url: URL, token: String, body: [String: Any]? = nil,
                      timeout: TimeInterval = 30, sealed: Bool = false) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(30, timeout)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let exchanged: (Data, URLResponse)
        if sealed, method == "POST", let body {
            exchanged = try await sealedExchange(request, url: url, token: token, body: body) { request in
                try await self.perform(request)
            }
        } else {
            exchanged = try await perform(request)
        }
        let (data, response) = exchanged
        guard let http = response as? HTTPURLResponse else { throw JuniorError.network }
        // Tünel ayakta ama bilgisayardaki sunucu kapalı: ulaşılamıyor sayılır.
        if Self.originUnreachable(http.statusCode) { throw JuniorError.network }
        return (http.statusCode, data)
    }

    /// Cloudflare tünelinin "arkadaki sunucuya ulaşamadım" kodları.
    static func originUnreachable(_ status: Int) -> Bool { status == 502 || status == 530 }

    /// Bilgisayardaki Junior'in telefona biraktigi isler; alinanlar sunucudan duser.
    func phoneTasks(url: URL, token: String) async throws -> [PhoneTask] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        return PhoneTask.parse(data)
    }

    /// Sürekli dinlemeden bir konuşma parçası yükler (gövde dosyadan akar, belleğe alınmaz).
    /// Dönüş: HTTP durum kodu; ağ hatasında nil.
    func uploadFile(_ request: URLRequest, file: URL) async -> Int? {
        guard let (_, response) = try? await session.upload(for: request, fromFile: file),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }

    /// Sunucu yalniz tamamlanmis user/assistant ciftlerini kabul eder.
    /// Testten erisilebilir olmali: es sirasi hatasi sunucuda 400 olarak doner.
    static func completedPairs(from history: [ChatMessage]) -> [[String: String]] {
        var pairs: [[String: String]] = []
        var index = 0
        while index + 1 < history.count {
            let first = history[index], second = history[index + 1]
            if first.role == .user, second.role == .assistant, !first.text.isEmpty, !second.text.isEmpty {
                pairs.append(["role": "user", "content": String(first.text.prefix(2000))])
                pairs.append(["role": "assistant", "content": String(second.text.prefix(2000))])
                index += 2
            } else {
                // Tek kalan mesaj (kullanıcı sorusu olmadan duyuru, yanıtsız söz) yalnız kendisi atlanır:
                // ikişer atlamak sonraki bütün çiftleri kaydırıp geçmişten düşürürdü.
                index += 1
            }
        }
        return Array(pairs.suffix(JuniorLimits.maxHistoryMessages))
    }

    // MARK: - Eşleştirme şifrelemesi (PairingCrypto.swift, sunucuda mobile_api/pairing_crypto.py)

    /// Eşleştirme anahtarı: Keychain'de varsa o; yoksa QR'dan gelen bekleyen sırdan türetilip saklanır
    /// (ağa çıkmaz, PBKDF2 bu aktörde çalışır). QR'da sır yoksa (eski bilgisayar uygulaması) nil:
    /// istekler eskisi gibi düz gider.
    @discardableResult
    func preparePairingKey(token: String) -> PairingKey? {
        if let stored = PairingKeyStore.load(token: token) { return stored }
        guard let seed = PairingKeyStore.loadPending(token: token),
              let key = PairingCrypto.deriveKey(secret: seed.secret, salt: seed.salt, iterations: seed.iterations)
        else { return nil }
        let made = PairingKey(kid: seed.kid, key: key, tokenTag: PairingKeyStore.tag(token))
        PairingKeyStore.save(made)
        // Sır yalnız türetme için tutulur; anahtar Keychain'e yazıldıysa silinir (yazılamadıysa sonra yeniden denenir).
        if PairingKeyStore.load(token: token) != nil { PairingKeyStore.clearPending() }
        return made
    }

    /// Gövdeyi anahtar varsa şifreli, yoksa düz gönderir; şifreli yanıtı açar. Anahtar varken istek
    /// hiçbir durumda düz gönderilmez ve şifre katmanının reddinden (crypto_key_unknown, crypto_failed)
    /// sonra yeniden gönderilmez, anahtar da silinmez: araya giren biri sahte bir ret yanıtıyla telefonu
    /// şifresiz göndermeye düşüremez. Kullanıcı sunucunun "QR kodla yeniden eşleştir" iletisini görür.
    private func sealedExchange(_ base: URLRequest, url: URL, token: String, body: [String: Any],
                                run: (URLRequest) async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        let key = preparePairingKey(token: token)
        var request = base
        request.httpBody = try PairingCrypto.requestBody(body, key: key, method: base.httpMethod ?? "POST",
                                                         path: PairingCrypto.aadPath(url))
        let (data, response) = try await run(request)
        return (try unsealed(data, response: response, url: url, method: base.httpMethod ?? "POST", key: key), response)
    }

    /// Şifreli gönderdiysek başarılı yanıt da şifreli olmalı; şifre katmanının kendi hatası düz gelir.
    private func unsealed(_ data: Data, response: URLResponse, url: URL, method: String, key: PairingKey?) throws -> Data {
        guard let key else { return data }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if PairingCrypto.isEnvelope(data) {
            do {
                return try PairingCrypto.openResponse(data, key: key.key, kid: key.kid, method: method,
                                                      path: PairingCrypto.aadPath(url))
            } catch {
                throw JuniorError.server("Bilgisayardan gelen şifreli yanıt açılamadı; telefonu QR kodla yeniden eşleştir.")
            }
        }
        if (200..<300).contains(status) {
            throw JuniorError.server("Bilgisayardan şifresiz yanıt geldi; güvenlik için kullanılmadı.")
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw JuniorError.network
        }
    }

    /// Komut isteği. Claude yanıtı 90 sn sürebildiği için istek uzun bekleyebilir (oturumun
    /// 100 sn sınırı yalnız sunucu ayaktayken işler). Bağlantı ölüyse kullanıcı o kadar
    /// beklemesin: istek birkaç saniyede bitmezse `/health`'e bakılır; sunucuya ulaşılamıyorsa
    /// istek bırakılır ve `.network` atılır (komut çevrimdışı kuyruğa girer).
    private func performCommand(_ request: URLRequest, health: URL?) async throws -> (Data, URLResponse) {
        let session = self.session
        let reply = try await withThrowingTaskGroup(of: CommandReply?.self, returning: CommandReply.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: request)
                    return CommandReply(data: data, response: response)
                } catch {
                    throw JuniorError.commandFailure(error)
                }
            }
            if let health {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(JuniorClient.reachabilityDelay * 1_000_000_000))
                    if await self.isReachable(url: health, timeout: JuniorClient.reachabilityTimeout) {
                        // Sunucu ayakta: yanıt uzun sürse de beklenir.
                        return nil
                    }
                    throw JuniorError.network
                }
            }
            while let next = try await group.next() {
                if let reply = next {
                    group.cancelAll()
                    return reply
                }
            }
            throw JuniorError.noReply
        }
        return (reply.data, reply.response)
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw JuniorError.network }
        if (200..<300).contains(http.statusCode) { return }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = parsed?["error"] as? [String: Any]
        let code = error?["code"] as? String
        if Self.originUnreachable(http.statusCode) { throw JuniorError.network }
        switch (http.statusCode, code) {
        case (401, _), (403, _): throw JuniorError.unauthorized
        case (429, _): throw JuniorError.rateLimited
        case (503, "provider_login_required"): throw JuniorError.providerLoginRequired
        case (503, _): throw JuniorError.busy
        default:
            throw JuniorError.server(error?["message"] as? String ?? "Sunucu hatasi (\(http.statusCode)).")
        }
    }
}

extension UIImage {
    /// 2 MiB sinirinin altinda kalacak sekilde kucultur.
    func juniorJPEGData() -> Data? {
        let maxSide: CGFloat = 1280
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in [0.8, 0.6, 0.45, 0.3] as [CGFloat] {
            if let data = resized.jpegData(compressionQuality: quality),
               data.count <= JuniorLimits.maxImageBytes { return data }
        }
        return nil
    }
}
