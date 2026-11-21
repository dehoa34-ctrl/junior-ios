import Foundation

/// Sohbetteki video bağlantıları (YouTube vb.). Saf mantık.
enum VideoLink {
    /// Oynatıcı sayfası açılacak siteler; alt alan adları da sayılır (m.youtube.com …).
    /// Sunucudaki `mobile_api/media.py` SITES ve DIRECT_EXTENSIONS ile aynı kalmalı: sunucu
    /// yt-dlp'ye yalnız bu siteleri verir (gömülü adres izleyen genel çıkarıcı kapalı).
    static let hosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "twitch.tv",
                        "tiktok.com", "instagram.com", "x.com", "twitter.com"]
    /// Doğrudan oynatılabilen dosya uzantıları.
    static let fileExtensions = ["mp4", "m4v", "mov", "m3u8"]

    static func isVideo(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Metindeki ilk video bağlantısı.
    static func first(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, isVideo(url) { return url }
        }
        return nil
    }
}

/// `GET /v1/media/resolve?url=…` yanıtı: telefonda oynatılacak doğrudan akış adresi.
struct ResolvedMedia: Equatable {
    let streamURL: URL
    let title: String
    let duration: Double?

    static func parse(_ data: Data) -> ResolvedMedia? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["url"] as? String, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let duration = (root["duration"] as? Double) ?? (root["duration"] as? Int).map(Double.init)
        return ResolvedMedia(streamURL: url, title: title, duration: duration)
    }

    /// Hata yanıtının kullanıcıya gösterilecek metni (`{"error": {"message": …}}`).
    static func errorMessage(status: Int, data: Data) -> String {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let message = (root?["error"] as? [String: Any])?["message"] as? String, !message.isEmpty {
            return message
        }
        switch status {
        case 401, 403: return JuniorError.unauthorized.localizedDescription
        case 404: return "Bilgisayardaki Junior video çözümlemeyi bilmiyor; sunucuyu güncelle."
        default: return "Video açılamadı (\(status))."
        }
    }
}

/// Video sesi ile "Hey Junior" dinlemesinin durum makinesi. Saf mantık.
///
/// Oynatıcı **sessiz** başlar. Ses açılınca uyandırma dinlemesi duraklar (videodaki konuşma
/// Junior'ı uyandırmasın, Junior videoyu dinlemesin); ses kapanınca ya da oynatıcı kapanınca
/// sürer. Duraklatma bir kez istenir, bir kez bırakılır.
struct VideoAudioGate: Equatable {
    enum Effect: Equatable {
        case none
        case pauseWakeWord
        case resumeWakeWord
    }

    private(set) var muted = true
    /// Bu oynatıcı "Hey Junior" dinlemesini duraklattı mı.
    private(set) var holdsWakeWord = false

    mutating func setMuted(_ value: Bool) -> Effect {
        muted = value
        if !value, !holdsWakeWord {
            holdsWakeWord = true
            return .pauseWakeWord
        }
        if value, holdsWakeWord {
            holdsWakeWord = false
            return .resumeWakeWord
        }
        return .none
    }

    /// Oynatıcı kapandı.
    mutating func close() -> Effect {
        muted = true
        guard holdsWakeWord else { return .none }
        holdsWakeWord = false
        return .resumeWakeWord
    }
}

/// Sunucudan video akış adresi ister. İstek 30 sn'de zaman aşımına uğrar.
@MainActor
enum MediaResolver {
    enum Failure: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static func resolve(_ source: URL, config: Config, client: JuniorClient = JuniorClient()) async throws -> ResolvedMedia {
        guard let token = config.token, !token.isEmpty else { throw JuniorError.notConfigured }
        guard let base = config.url(path: "/v1/media/resolve"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw JuniorError.badAddress }
        components.queryItems = [URLQueryItem(name: "url", value: source.absoluteString)]
        guard let url = components.url else { throw JuniorError.badAddress }
        let response: (status: Int, data: Data)
        do {
            response = try await client.jsonResponse(method: "GET", url: url, token: token, timeout: 30)
        } catch {
            throw Failure.message("Bilgisayara ulaşılamıyor; video açılamadı. Bilgisayar ve tünel açık mı?")
        }
        guard response.status == 200 else {
            throw Failure.message(ResolvedMedia.errorMessage(status: response.status, data: response.data))
        }
        guard let media = ResolvedMedia.parse(response.data) else {
            throw Failure.message("Bilgisayar videonun adresini döndürmedi.")
        }
        return media
    }
}
