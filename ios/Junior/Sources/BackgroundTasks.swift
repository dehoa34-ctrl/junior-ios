import Foundation

/// Arka plan görevi (Junior sunucusundaki görev motoru, mobile_api/tasks.py). Görev telefonda
/// değil bilgisayarda çalışır; uygulama kapalıyken de sürer, bitince bildirim gelir.
struct BackgroundTask: Identifiable, Equatable {
    enum Status: String {
        case queued, running, paused, done, failed, cancelled
    }

    let id: String
    let goal: String
    let status: Status
    let minutes: Int
    let steps: Int
    let maxSteps: Int
    let findings: Int
    let sources: Int
    let progress: [String]
    let result: String
    let error: String
    let hasReport: Bool
    let startAt: Date
    let created: Date

    static func parse(_ raw: [String: Any]) -> BackgroundTask? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let goal = raw["goal"] as? String,
              let statusRaw = raw["status"] as? String, let status = Status(rawValue: statusRaw) else { return nil }
        func int(_ key: String) -> Int { (raw[key] as? Int) ?? Int((raw[key] as? Double) ?? 0) }
        func date(_ key: String) -> Date { Date(timeIntervalSince1970: (raw[key] as? Double) ?? Double(int(key))) }
        return BackgroundTask(
            id: id, goal: goal, status: status,
            minutes: int("minutes"), steps: int("steps"), maxSteps: int("max_steps"),
            findings: int("findings"), sources: int("sources"),
            progress: (raw["progress"] as? [String]) ?? [],
            result: (raw["result"] as? String) ?? "", error: (raw["error"] as? String) ?? "",
            hasReport: (raw["report"] as? Bool) ?? false,
            startAt: date("start_at"), created: date("created"))
    }

    static func parseList(_ data: Data) -> [BackgroundTask]? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = raw["tasks"] as? [[String: Any]] else { return nil }
        return items.compactMap(BackgroundTask.parse)
    }

    static func parseOne(_ data: Data) -> BackgroundTask? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let item = raw["task"] as? [String: Any] else { return nil }
        return parse(item)
    }

    var isActive: Bool { status == .queued || status == .running || status == .paused }

    var statusText: String {
        switch status {
        case .queued: return startAt.timeIntervalSinceNow > 30 ? "Sırada" : "Başlıyor"
        case .running: return "Çalışıyor"
        case .paused: return "Bekliyor"
        case .done: return "Bitti"
        case .failed: return "Başarısız"
        case .cancelled: return "Durduruldu"
        }
    }

    var detailText: String {
        switch status {
        case .queued where startAt.timeIntervalSinceNow > 30:
            return "Başlama: " + startAt.formatted(date: .abbreviated, time: .shortened)
        case .running, .paused:
            var text = "\(steps)/\(maxSteps) adım · \(sources) kaynak · \(findings) doğrulanmış bulgu"
            if status == .paused { text += " · model yanıt vermedi, kendiliğinden sürecek" }
            return text
        case .done: return result
        case .failed: return error
        default: return progress.last ?? ""
        }
    }
}

@MainActor
final class TasksModel: ObservableObject {
    @Published private(set) var tasks: [BackgroundTask]?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var report: (task: BackgroundTask, text: String)?

    private let config: Config
    private let client = JuniorClient()

    init(config: Config) {
        self.config = config
    }

    private func endpoint(_ path: String) throws -> (URL, String) {
        guard let token = config.token, !token.isEmpty else { throw JuniorError.notConfigured }
        guard let url = config.url(path: path) else { throw JuniorError.badAddress }
        return (url, token)
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (url, token) = try endpoint("/v1/tasks")
            let data = try await client.json(method: "GET", url: url, token: token)
            guard let parsed = BackgroundTask.parseList(data) else { throw JuniorError.server("Görevler okunamadı.") }
            tasks = parsed
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
    }

    /// Yeni görev; `minutes` 2–120. `startAt` verilirse o saatte başlar.
    func start(goal: String, minutes: Int, startAt: Date?) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Ne araştırılacağını yaz."
            return
        }
        var body: [String: Any] = ["goal": trimmed, "minutes": min(120, max(2, minutes))]
        if let startAt, startAt.timeIntervalSinceNow > 30 { body["start_at"] = startAt.timeIntervalSince1970 }
        await send("/v1/tasks", body: body)
    }

    func cancel(_ task: BackgroundTask) async { await send("/v1/tasks/\(task.id)/cancel", body: [:]) }
    func finish(_ task: BackgroundTask) async { await send("/v1/tasks/\(task.id)/finish", body: [:]) }

    func steer(_ task: BackgroundTask, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await send("/v1/tasks/\(task.id)/steer", body: ["text": trimmed])
    }

    func openReport(_ task: BackgroundTask) async {
        do {
            let (url, token) = try endpoint("/v1/tasks/\(task.id)/report")
            let data = try await client.json(method: "GET", url: url, token: token)
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let text = raw?["report"] as? String else { throw JuniorError.server("Rapor okunamadı.") }
            report = (task, text)
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
    }

    func closeReport() { report = nil }

    /// Raporu Dosyalar'da görünen Belgeler klasörüne Markdown olarak yazar; dosya adresini döndürür.
    func saveReport() -> URL? {
        guard let report else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("JuniorReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(for: report.task))
        do {
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            self.error = "Rapor kaydedilemedi."
            return nil
        }
    }

    static func fileName(for task: BackgroundTask) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = task.goal.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(6).joined(separator: "-")
        return (slug.isEmpty ? "rapor" : String(slug.prefix(40))) + "-" + task.id + ".md"
    }

    private func send(_ path: String, body: [String: Any]) async {
        do {
            let (url, token) = try endpoint(path)
            _ = try await client.json(method: "POST", url: url, token: token, body: body)
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
        await load()
    }
}
