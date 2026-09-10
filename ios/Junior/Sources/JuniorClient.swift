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
        case let value?: self = .other(value)
        }
    }
}

struct CommandResponse {
    let reply: String
    let status: CommandStatus
    let errorCode: String?
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
        }
    }
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

    func send(url: URL, token: String, message: String, history: [ChatMessage],
              image: Data?, target: String?) async throws -> CommandResponse {
        var body: [String: Any] = [
            "message": String(message.prefix(JuniorLimits.maxMessageChars)),
            // Ag tekrari sarkiyi iki kez atlamasin diye her istek benzersiz kimlik tasir.
            "request_id": UUID().uuidString,
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let reply = parsed["reply"] as? String ?? ""
        let error = parsed["error"] as? [String: Any]
        return CommandResponse(reply: reply.isEmpty ? "Junior bos yanit dondurdu." : reply,
                               status: CommandStatus(raw: parsed["status"] as? String),
                               errorCode: error?["code"] as? String)
    }

    /// Sunucu ayakta mi. Token istemez ve hizli doner; konusmadan **once**
    /// bilgisayarin acik olup olmadigini gostermek icin.
    func isReachable(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Yanit metnini sunucuda dogal sese cevirtir; MP3 baytlari doner.
    /// Hata durumunda cagiran taraf iOS'un yerlesik sesine duser.
    func tts(url: URL, token: String, text: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": String(text.prefix(1600))])
        let (data, response) = try await perform(request)
        try check(response: response, data: data)
        guard !data.isEmpty else { throw JuniorError.server("Ses sentezi bos dondu.") }
        return data
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
            }
            index += 2
        }
        return Array(pairs.suffix(JuniorLimits.maxHistoryMessages))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw JuniorError.network
        }
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw JuniorError.network }
        if (200..<300).contains(http.statusCode) { return }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = parsed?["error"] as? [String: Any]
        let code = error?["code"] as? String
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
