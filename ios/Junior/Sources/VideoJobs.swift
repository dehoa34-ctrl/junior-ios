import Foundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Galeriden secilen video. Fotograflar'daki dosya gecici klasore kopyalanir;
/// yukleme bitince silinir.
struct PickedVideo: Equatable {
    let url: URL
    let name: String
    let size: Int64

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

/// PhotosPicker'dan video almak icin: Data olarak yuklemek yuzlerce MB'i
/// bellege alirdi, dosya olarak kopyalanir.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("JuniorUpload", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

/// Bilgisayardaki kurgu isinin durumu (`GET /v1/desktop/jobs/{id}`).
struct DesktopJobStatus: Equatable {
    enum State: String { case queued, running, done, failed }

    let state: State
    let progress: String
    let reply: String
    let hasResult: Bool
    let desktopOnline: Bool

    static func parse(_ data: Data) -> DesktopJobStatus? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = State(rawValue: json["status"] as? String ?? "") else { return nil }
        return DesktopJobStatus(state: state,
                                progress: json["progress"] as? String ?? "",
                                reply: json["reply"] as? String ?? "",
                                hasResult: json["has_result"] as? Bool ?? false,
                                desktopOnline: json["desktop_online"] as? Bool ?? false)
    }

    /// Telefonda gorunecek tek satir.
    var line: String {
        switch state {
        case .queued:
            return desktopOnline ? "Bilgisayardaki Junior işi almak üzere..."
                : "Bilgisayardaki Junior uygulaması kapalı; açılınca kurgulamaya başlayacak."
        case .running:
            return progress.isEmpty ? "Bilgisayarda kurgulanıyor..." : "Bilgisayarda: \(progress)"
        case .done: return "Kurgu bitti."
        case .failed: return reply.isEmpty ? "Kurgu tamamlanamadı." : reply
        }
    }
}

enum VideoJobError: LocalizedError {
    case server(String)
    case network
    case cancelled

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .network: return "Bilgisayara ulaşılamadı. Bilgisayar ve tünel açık mı?"
        case .cancelled: return "Video işi durduruldu."
        }
    }
}

/// Video yukleme ve is uclari. Sohbet istemcisinden ayri bir oturum: parcalar
/// buyuk, her biri icin daha uzun bekleme gerekiyor.
actor VideoClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    private func request(_ url: URL, token: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func json(_ request: URLRequest, accept: Set<Int> = [200]) async throws -> (Int, [String: Any]) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw VideoJobError.cancelled
        } catch {
            throw VideoJobError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if accept.contains(status) { return (status, body) }
        if status == 401 || status == 403 { throw VideoJobError.server(JuniorError.unauthorized.localizedDescription) }
        let message = (body["error"] as? [String: Any])?["message"] as? String
        throw VideoJobError.server(message ?? "Sunucu hatası (\(status)).")
    }

    func createUpload(url: URL, token: String, name: String, size: Int64) async throws -> (id: String, chunk: Int) {
        var req = request(url, token: token, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "size": size])
        let (_, body) = try await json(req)
        guard let id = body["id"] as? String else { throw VideoJobError.server("Yükleme başlatılamadı.") }
        return (id, max(256 * 1024, body["chunk_size"] as? Int ?? 8 * 1024 * 1024))
    }

    /// Bir parcayi gonderir; sunucunun o ana kadar aldigi bayt sayisini dondurur.
    /// Sira uyusmazsa (409) sunucunun bildirdigi yerden devam edilir.
    func sendChunk(url: URL, token: String, offset: Int64, data: Data) async throws -> Int64 {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw VideoJobError.network }
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        guard let target = components.url else { throw VideoJobError.network }
        var req = request(target, token: token, method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, body) = try await json(req, accept: [200, 409])
        guard let received = (body["received"] as? NSNumber)?.int64Value else { throw VideoJobError.server("Yükleme yanıtı anlaşılamadı.") }
        return received
    }

    func createJob(url: URL, token: String, videoID: String, prompt: String) async throws -> String {
        var req = request(url, token: token, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["video_id": videoID, "prompt": prompt])
        let (_, body) = try await json(req)
        guard let id = body["id"] as? String else { throw VideoJobError.server("İş oluşturulamadı.") }
        return id
    }

    func status(url: URL, token: String) async throws -> DesktopJobStatus {
        let (_, body) = try await json(request(url, token: token))
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let status = DesktopJobStatus.parse(data) else { throw VideoJobError.server("İş durumu anlaşılamadı.") }
        return status
    }

    /// Kurgulanmis videoyu indirir; uygulamanin Belgeler/Junior Videolari klasorune tasir.
    func download(url: URL, token: String, name: String) async throws -> URL {
        let temp: URL, response: URLResponse
        do {
            (temp, response) = try await session.download(for: request(url, token: token))
        } catch {
            throw VideoJobError.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VideoJobError.server("Kurgulanan video indirilemedi.") }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Junior Videoları", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}

/// Telefondan secilen videoyu bilgisayara yukler, kurgu isini verir, bitene kadar
/// izler ve sonucu Fotograflar'a kaydeder. Uygulama kapatilsa da is kimligi
/// saklanir; acilinca kaldigi yerden izlenir.
@MainActor
final class VideoJobService: ObservableObject {
    /// Ekranda gorunen durum satiri; nil ise suren is yok.
    @Published private(set) var statusLine: String?
    /// 0...1, yalniz yuklerken
    @Published private(set) var uploadProgress: Double?

    private let client = VideoClient()
    private static let pendingKey = "junior.pendingVideoJob"

    var pendingJobID: String? {
        get { UserDefaults.standard.string(forKey: Self.pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }

    /// Videoyu yukler ve isi verir; is kimligini dondurur.
    func submit(_ video: PickedVideo, prompt: String, config: Config) async throws -> String {
        guard let token = config.token, let createURL = config.url(path: "/v1/videos"),
              let jobsURL = config.url(path: "/v1/desktop/jobs") else {
            throw VideoJobError.server(JuniorError.notConfigured.localizedDescription)
        }
        // Kullanici uygulamadan cikarsa iOS yuklemeye biraz daha sure tanisin.
        let background = UIApplication.shared.beginBackgroundTask(withName: "junior-video-upload")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            uploadProgress = nil
        }
        statusLine = "Video bilgisayara yükleniyor..."
        uploadProgress = 0
        let (uploadID, chunk) = try await client.createUpload(url: createURL, token: token, name: video.name, size: video.size)
        guard let chunkURL = config.url(path: "/v1/videos/\(uploadID)") else { throw VideoJobError.network }
        let handle = try FileHandle(forReadingFrom: video.url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var failures = 0
        while offset < video.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: chunk) ?? Data()
            if data.isEmpty { throw VideoJobError.server("Video dosyası okunamadı.") }
            do {
                offset = try await client.sendChunk(url: chunkURL, token: token, offset: offset, data: data)
                failures = 0
            } catch VideoJobError.network where failures < 4 {
                // Hucresel agda kopma olagan: bekleyip ayni yerden devam et.
                failures += 1
                try await Task.sleep(nanoseconds: UInt64(failures) * 2_000_000_000)
            }
            uploadProgress = Double(offset) / Double(video.size)
            statusLine = "Video bilgisayara yükleniyor %\(Int((uploadProgress ?? 0) * 100))"
        }
        try? FileManager.default.removeItem(at: video.url)
        let jobID = try await client.createJob(url: jobsURL, token: token, videoID: uploadID, prompt: prompt)
        pendingJobID = jobID
        statusLine = "Video bilgisayarda; Junior'a verildi."
        return jobID
    }

    /// Is bitene kadar izler; bitince videoyu indirip Fotograflar'a kaydeder.
    /// Donus: telefonda gosterilecek yanit.
    func follow(jobID: String, config: Config) async throws -> String {
        guard let token = config.token, let statusURL = config.url(path: "/v1/desktop/jobs/\(jobID)"),
              let resultURL = config.url(path: "/v1/desktop/jobs/\(jobID)/result") else {
            throw VideoJobError.server(JuniorError.notConfigured.localizedDescription)
        }
        defer { statusLine = nil }
        var misses = 0
        while true {
            try Task.checkCancellation()
            let status: DesktopJobStatus
            do {
                status = try await client.status(url: statusURL, token: token)
                misses = 0
            } catch VideoJobError.network where misses < 20 {
                misses += 1
                statusLine = "Bilgisayara ulaşılamıyor, tekrar deneniyor..."
                try await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            statusLine = status.line
            switch status.state {
            case .queued, .running:
                try await Task.sleep(nanoseconds: 3_000_000_000)
            case .failed:
                pendingJobID = nil
                throw VideoJobError.server(status.line)
            case .done:
                pendingJobID = nil
                guard status.hasResult else { return status.reply.isEmpty ? "İş bitti." : status.reply }
                statusLine = "Kurgulanan video indiriliyor..."
                let file = try await client.download(url: resultURL, token: token, name: "Junior-\(jobID.prefix(6)).mp4")
                let saved = await Self.saveToPhotos(file)
                let reply = status.reply.isEmpty ? "Videon hazır." : status.reply
                return reply + (saved ? "\n\nKurgulanan video Fotoğraflar'a kaydedildi."
                                : "\n\nFotoğraflar izni olmadığı için video Dosyalar → Junior → Junior Videoları klasörüne kaydedildi.")
            }
        }
    }

    static func saveToPhotos(_ file: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
            return true
        } catch {
            return false
        }
    }

    /// Uygulama arka plandayken biterse haber ver (on plandayken de banner gorunur).
    static func notifyDone(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Videon hazır"
        content.body = String(text.prefix(300))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "junior-video-\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }
}
