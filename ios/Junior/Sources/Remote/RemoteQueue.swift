import SwiftUI

/// "Bilgisayar açılınca …" kuyruğundaki iş (`GET /v1/remote/queue`). Saf mantık.
///
/// Sunucu böyle bir işi en çok 24 saat tutar; bilgisayardaki Junior açılınca alıp yürütür, sonucu
/// telefona not olarak düşer. Kuyruktaki iş buradan iptal edilir (`POST /v1/remote/{id}/cancel`).
struct RemoteQueueItem: Identifiable, Equatable {
    let id: String
    let text: String
    let expiresAt: Date

    /// `{"jobs": [...]}`; yalnız henüz alınmamış (`queued`) işler, bozuk kayıtlar atlanır.
    static func parseList(_ data: Data, now: Date = Date()) -> [RemoteQueueItem]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]] else { return nil }
        return jobs.compactMap { raw in
            guard let id = raw["id"] as? String, !id.isEmpty, (raw["state"] as? String) == "queued" else { return nil }
            let seconds = (raw["expires_in"] as? Double) ?? Double((raw["expires_in"] as? Int) ?? 0)
            let text = ((raw["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteQueueItem(id: id, text: text.isEmpty ? "Komut" : String(text.prefix(300)),
                                   expiresAt: now.addingTimeInterval(max(0, seconds)))
        }
    }

    /// "23 sa 10 dk içinde alınmazsa silinir"
    func remainingText(now: Date = Date()) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) sa \(minutes) dk içinde alınmazsa silinir" }
        return "\(max(1, minutes)) dk içinde alınmazsa silinir"
    }

    /// İptal yanıtının kullanıcıya söylenecek hâli; sorun yoksa nil.
    static func cancelMessage(status: Int) -> String? {
        switch status {
        case 200, 404: return nil
        case 409: return "Bilgisayar bu işi az önce aldı; artık iptal edilemez."
        case 401, 403: return JuniorError.unauthorized.localizedDescription
        default: return "İptal edilemedi (\(status))."
        }
    }
}

@MainActor
final class RemoteQueueModel: ObservableObject {
    @Published private(set) var items: [RemoteQueueItem]?
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
        do {
            let (url, token) = try endpoint("/v1/remote/queue")
            let data = try await client.json(method: "GET", url: url, token: token)
            guard let parsed = RemoteQueueItem.parseList(data) else { throw JuniorError.server("Kuyruk okunamadı.") }
            items = parsed
            error = nil
        } catch {
            self.error = RoutinesModel.describe(error)
        }
    }

    func cancel(_ item: RemoteQueueItem) async {
        do {
            let (url, token) = try endpoint("/v1/remote/\(item.id)/cancel")
            let response = try await client.jsonResponse(method: "POST", url: url, token: token, body: [:])
            error = RemoteQueueItem.cancelMessage(status: response.status)
        } catch {
            self.error = RoutinesModel.describe(error)
        }
        await load()
    }
}

/// Ayarlar → Bilgisayar kuyruğu: "bilgisayar açılınca …" dediğin, henüz yürütülmemiş komutlar.
struct RemoteQueueView: View {
    @StateObject private var model: RemoteQueueModel

    init(config: Config) {
        _model = StateObject(wrappedValue: RemoteQueueModel(config: config))
    }

    var body: some View {
        Form {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(JuniorTheme.orange)
                    Button("Yeniden dene") { Task { await model.load() } }
                }
            }
            Section {
                if let items = model.items {
                    if items.isEmpty {
                        Text("Bekleyen iş yok.").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.text).lineLimit(3)
                                Text(item.remainingText()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("İptal", role: .destructive) {
                                Task { await model.cancel(item) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Bilgisayar açılınca yapılacaklar")
            } footer: {
                Text("“Bilgisayar açılınca …” ya da “bilgisayara gelince …” dediğin komutlar en çok 24 saat bekler; "
                     + "bilgisayardaki Junior açılınca yürütülür, sonucu bildirim olarak gelir. Diğer komutlar bilgisayar "
                     + "bir dakika içinde almazsa hiç yürütülmez.")
            }
        }
        .navigationTitle("Bilgisayar kuyruğu")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .refreshable { await model.load() }
    }
}
