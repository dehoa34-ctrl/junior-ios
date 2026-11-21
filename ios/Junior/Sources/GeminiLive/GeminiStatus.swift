import Foundation

/// GET /v1/live/gemini/status yanıtı. Anahtarın kendisi hiç gelmez; yalnız "…abcd" maskesi.
struct GeminiStatus: Equatable {
    struct LastError: Equatable {
        let reason: GeminiFallbackReason
        let message: String
        let at: Date
        /// "phone" ya da "desktop": hatayı hangi cihazın oturumu aldı.
        let client: String
    }

    var available: Bool
    /// Kullanılamıyorsa neden: anahtar yok ya da bugünkü sınır dolu.
    var reason: GeminiFallbackReason?
    /// Sunucunun kullanıcıya söylediği: ne yapılacak.
    var message: String?
    var configured: Bool
    var apiKeyHint: String
    /// "free" ya da "paid"
    var tier: String
    var freeTierNotice: String?
    var usedMinutes: Double
    var capMinutes: Double
    var remainingMinutes: Double
    var activeSessions: Int
    var lastError: LastError?

    static func parse(_ data: Data) -> GeminiStatus? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let available = raw["available"] as? Bool,
              let tier = raw["tier"] as? String else { return nil }
        func number(_ key: String) -> Double { (raw[key] as? NSNumber)?.doubleValue ?? 0 }
        var last: LastError?
        if let error = raw["last_error"] as? [String: Any], let message = error["message"] as? String {
            last = LastError(reason: GeminiFallbackReason(wire: error["reason"] as? String),
                             message: message,
                             at: Date(timeIntervalSince1970: (error["at"] as? NSNumber)?.doubleValue ?? 0),
                             client: error["client"] as? String ?? "")
        }
        return GeminiStatus(
            available: available,
            reason: (raw["reason"] as? String).map { GeminiFallbackReason(wire: $0) },
            message: raw["message"] as? String,
            configured: raw["configured"] as? Bool ?? false,
            apiKeyHint: raw["api_key_hint"] as? String ?? "",
            tier: tier,
            freeTierNotice: raw["free_tier_notice"] as? String,
            usedMinutes: number("used_minutes"),
            capMinutes: number("cap_minutes"),
            remainingMinutes: number("remaining_minutes"),
            activeSessions: Int(number("active_sessions")),
            lastError: last
        )
    }
}

/// Yalnız telefonun gördüğü son Gemini hatası: köprüye ulaşılamadı, köprü zamanında hazır
/// olmadı, tünel koptu. Sunucu bunları hiç duymaz (durum ucunun last_error'ında yoktur), kart
/// yine de göstersin diye UserDefaults'ta durur; Ayarlar @AppStorage ile aynı anahtarları izler.
enum GeminiPhoneError {
    static let messageKey = "junior.gemini.phoneError.message"
    static let reasonKey = "junior.gemini.phoneError.reason"
    static let atKey = "junior.gemini.phoneError.at"

    static func save(reason: GeminiFallbackReason, message: String, at: Date, defaults: UserDefaults = .standard) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        defaults.set(clean, forKey: messageKey)
        defaults.set(reason.rawValue, forKey: reasonKey)
        defaults.set(at.timeIntervalSince1970, forKey: atKey)
    }

    static func load(defaults: UserDefaults = .standard) -> GeminiStatus.LastError? {
        decode(message: defaults.string(forKey: messageKey) ?? "",
               reason: defaults.string(forKey: reasonKey) ?? "",
               at: defaults.double(forKey: atKey))
    }

    /// Saklanan üç değerden kartın "son hata" satırı; boşsa nil.
    static func decode(message: String, reason: String, at: Double) -> GeminiStatus.LastError? {
        guard !message.isEmpty, at > 0 else { return nil }
        return GeminiStatus.LastError(reason: GeminiFallbackReason(wire: reason), message: message,
                                      at: Date(timeIntervalSince1970: at), client: "phone")
    }
}

/// Durum kartının ve motor seçiminin metinleri (saf; testte denenir).
enum GeminiStatusText {
    static let freeWarning = "Ücretsiz katman: Google bu konuşmaları ürünlerini geliştirmek için kullanabilir."
    static let paidNote = "Ücretli katman: konuşmalar Google ürünlerini geliştirmek için kullanılmaz; kullanım AI Studio faturana yansır."
    /// Her iki katmanda da geçerli söz: canlı dinleme ve gün boyu kayıt sesi Gemini'ye gitmez.
    static let privacyNote = "Telefonda sürekli dinleme ve gün boyu kayıt sesi Gemini'ye hiç gitmez; yalnız konuş düğmesiyle açtığın oturum gider."

    static func tierTitle(_ tier: String) -> String {
        tier == "paid" ? "Ücretli" : "Ücretsiz"
    }

    /// Katman uyarısı; ücretsizde uyarı tonunda.
    static func tierNote(_ tier: String) -> (warn: Bool, text: String) {
        tier == "paid" ? (false, paidNote) : (true, freeWarning)
    }

    /// 12.5 → "12,5", 30.0 → "30"
    static func minutes(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }

    /// "Bugün 12,5 / 30 dk kullanıldı (kalan 17,5 dk)."
    static func usage(_ status: GeminiStatus) -> String {
        let used = minutes(status.usedMinutes), cap = minutes(status.capMinutes)
        if status.remainingMinutes <= 0 {
            return "Bugün \(used) / \(cap) dk kullanıldı — sınır doldu, yarına kadar normal ses kullanılır."
        }
        return "Bugün \(used) / \(cap) dk kullanıldı (kalan \(minutes(status.remainingMinutes)) dk)."
    }

    /// "Son hata (bugün 14:05, telefon): …"
    static func lastError(_ error: GeminiStatus.LastError, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(error.at, inSameDayAs: now) ? "'bugün' HH:mm" : "d MMM HH:mm"
        let device = error.client == "phone" ? ", telefon" : error.client == "desktop" ? ", bilgisayar" : ""
        return "Son hata (\(formatter.string(from: error.at))\(device)): \(error.message)"
    }

    /// Kartta gösterilecek son hata: sunucunun kaydı ile telefonun kendi gördüğünden yenisi.
    static func latestError(server: GeminiStatus.LastError?, phone: GeminiStatus.LastError?) -> GeminiStatus.LastError? {
        guard let server else { return phone }
        guard let phone else { return server }
        return phone.at > server.at ? phone : server
    }

    /// Ayarlar'daki "Gemini Live" seçeneği açık mı, değilse neden.
    ///
    /// Durum henüz okunuyorsa (`loading`, ya da ilk istek daha başlamadı ve hata yok) neden
    /// yazılmaz: kart dönen göstergeyi gösterir. "Alınamadı" yalnız istek gerçekten düşünce.
    static func availability(status: GeminiStatus?, loadError: String?, loading: Bool = false) -> (enabled: Bool, reason: String?) {
        guard let status else {
            guard let loadError, !loading else { return (false, nil) }
            return (false, "Gemini Live durumu bilgisayardan alınamadı (\(loadError)). Bilgisayar ve tünel açıkken yeniden dene.")
        }
        guard status.configured else {
            return (false, "Bilgisayardaki Junior'da Gemini anahtarı yok: oradaki Ayarlar > Ses bölümüne Google AI Studio anahtarını gir.")
        }
        if status.reason == .cap || status.remainingMinutes <= 0 {
            return (true, "Bugünkü Gemini süresi doldu; seçebilirsin ama yarına kadar normal ses kullanılır.")
        }
        return (true, nil)
    }
}

/// Durum ucunu okur; Ayarlar'daki kart ve konuş düğmesinin engel kararı bunu kullanır.
@MainActor
final class GeminiStatusModel: ObservableObject {
    @Published private(set) var status: GeminiStatus?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private let config: Config
    private let client = JuniorClient()

    init(config: Config) {
        self.config = config
    }

    @discardableResult
    func load() async -> GeminiStatus? {
        loading = true
        defer { loading = false }
        do {
            guard let token = config.token, !token.isEmpty else { throw JuniorError.notConfigured }
            guard let url = config.url(path: "/v1/live/gemini/status") else { throw JuniorError.badAddress }
            let data = try await client.json(method: "GET", url: url, token: token)
            guard let parsed = GeminiStatus.parse(data) else {
                throw JuniorError.server("Sunucu Gemini Live durumunu anlaşılır biçimde vermedi; bilgisayardaki Junior'u güncelle.")
            }
            status = parsed
            error = nil
            return parsed
        } catch {
            if case JuniorError.network = error {
                self.error = "Bilgisayara ulaşılamıyor. Junior sunucusu ve tünel açık olmalı."
            } else if case JuniorError.server(let message) = error, message == "İstek desteklenmiyor." {
                // Eski sunucu bu ucu bilmiyor.
                self.error = "Bilgisayardaki Junior sunucusu Gemini Live'ı bilmiyor; güncelle."
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Gemini Live durumu alınamadı."
            }
            return nil
        }
    }
}
