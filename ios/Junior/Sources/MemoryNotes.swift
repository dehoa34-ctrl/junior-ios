import Foundation

/// Junior'ın kalıcı hafızasındaki bir not. Notlar bilgisayardaki sunucuda durur ve
/// masaüstüyle ortaktır; bu ekran onları telefondan gösterir ve sildirir.
struct MemoryNote: Identifiable, Equatable {
    let id: String
    let text: String
    /// Öğrenildiği an; bilinmiyorsa nil.
    let learned: Date?

    static func parse(_ raw: [String: Any]) -> MemoryNote? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let text = raw["text"] as? String, !text.isEmpty else { return nil }
        let at = (raw["at"] as? Double) ?? 0
        return MemoryNote(id: id, text: text, learned: at > 0 ? Date(timeIntervalSince1970: at) : nil)
    }

    static func parseList(_ data: Data) -> (notes: [MemoryNote], total: Int)? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = raw["notes"] as? [[String: Any]] else { return nil }
        let notes = items.compactMap(MemoryNote.parse)
        return (notes, (raw["total"] as? Int) ?? notes.count)
    }

    var learnedText: String {
        guard let learned else { return "Ne zaman öğrenildiği bilinmiyor" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: learned)
    }

    /// Arama kutusu: Türkçe büyük/küçük harfe duyarsız içerme.
    static func filter(_ notes: [MemoryNote], query: String) -> [MemoryNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.text.lowercased(with: Locale(identifier: "tr_TR")).contains(q) }
    }
}

@MainActor
final class MemoryModel: ObservableObject {
    @Published private(set) var notes: [MemoryNote]?
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published var error: String?

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
            let (url, token) = try endpoint("/v1/memory")
            let data = try await client.json(method: "GET", url: url, token: token)
            guard let parsed = MemoryNote.parseList(data) else { throw JuniorError.server("Hafıza okunamadı.") }
            notes = parsed.notes
            total = parsed.total
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
    }

    func remove(_ note: MemoryNote) async {
        do {
            let (url, token) = try endpoint("/v1/memory/\(note.id)")
            _ = try await client.json(method: "DELETE", url: url, token: token)
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
        await load()
    }

    func add(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let (url, token) = try endpoint("/v1/memory")
            _ = try await client.json(method: "POST", url: url, token: token, body: ["text": trimmed])
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
        await load()
    }
}
