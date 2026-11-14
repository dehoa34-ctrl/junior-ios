import Foundation

/// Rutinler Junior sunucusunda durur (mobile_api/routines.py); bu ekran aynı listeyi
/// telefondan yönetir. "Söyle" türü rutinler telefona bildirim olarak da gelir.
struct RoutineItem: Identifiable, Equatable {
    enum WhatKind: String { case say, `do`, task }

    let id: String
    var name: String
    var enabled: Bool
    var speak: Bool
    let whenType: String
    let at: String?
    let date: String?
    let days: [Int]
    let day: Int?
    let everyMin: Int?
    let from: String?
    let to: String?
    let idleMin: Int?
    let what: WhatKind
    let text: String
    let unprompted: Bool
    let builtin: String?
    let next: Date?

    /// Sunucunun gönderdiği sözlükten okur; zorunlu alan yoksa nil.
    static func parse(_ raw: [String: Any]) -> RoutineItem? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let when = raw["when"] as? [String: Any], let whenType = when["type"] as? String,
              let what = raw["what"] as? [String: Any], let whatRaw = what["type"] as? String,
              let kind = WhatKind(rawValue: whatRaw), let text = what["text"] as? String else { return nil }
        let next = (raw["next"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return RoutineItem(
            id: id,
            name: (raw["name"] as? String) ?? String(text.prefix(40)),
            enabled: (raw["enabled"] as? Bool) ?? true,
            speak: (raw["speak"] as? Bool) ?? true,
            whenType: whenType,
            at: when["at"] as? String,
            date: when["date"] as? String,
            days: (when["days"] as? [Int]) ?? [],
            day: when["day"] as? Int,
            everyMin: when["every_min"] as? Int,
            from: when["from"] as? String,
            to: when["to"] as? String,
            idleMin: when["idle_min"] as? Int,
            what: kind,
            text: text,
            unprompted: (raw["unprompted"] as? Bool) ?? false,
            builtin: raw["builtin"] as? String,
            next: next)
    }

    /// 0 = Pazar … 6 = Cumartesi (masaüstüyle aynı).
    static let dayNames = ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"]

    static func describeDays(_ days: [Int]) -> String {
        let sorted = Array(Set(days)).sorted()
        if sorted.isEmpty || sorted.count == 7 { return "her gün" }
        if sorted == [1, 2, 3, 4, 5] { return "hafta içi" }
        if sorted == [0, 6] { return "hafta sonu" }
        return sorted.compactMap { (0...6).contains($0) ? dayNames[$0] : nil }.joined(separator: ", ")
    }

    var whenText: String {
        switch whenType {
        case "once": return "\(date ?? "") \(at ?? "") (bir kez)".trimmingCharacters(in: .whitespaces)
        case "weekly": return "\(at ?? ""), \(Self.describeDays(days))"
        case "monthly": return "her ayın \(day ?? 1). günü \(at ?? "")"
        case "interval": return "\(from ?? "")–\(to ?? "") arası \(everyMin ?? 0) dakikada bir"
        case "startup": return "Bilgisayardaki Junior açılırken"
        case "idle": return "\(idleMin ?? 0) dakika sessizlikten sonra"
        default: return whenType
        }
    }

    var whatLabel: String {
        switch what {
        case .say: return "Söyle"
        case .`do`: return "Yap"
        case .task: return "Görev"
        }
    }
}

struct QuietHours: Equatable {
    var enabled: Bool
    var from: String
    var to: String

    static func parse(_ raw: [String: Any]?) -> QuietHours {
        QuietHours(enabled: (raw?["enabled"] as? Bool) ?? false,
                   from: (raw?["from"] as? String) ?? "23:00",
                   to: (raw?["to"] as? String) ?? "07:00")
    }

    /// "23:00" → bugünün o saati (DatePicker için); geçersizse nil.
    static func date(from text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    static func text(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

struct RoutineListing: Equatable {
    var routines: [RoutineItem]
    var quiet: QuietHours
    var quietNow: Bool
    var broken: Bool

    static func parse(_ data: Data) -> RoutineListing? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let items = (raw["routines"] as? [[String: Any]] ?? []).compactMap(RoutineItem.parse)
        return RoutineListing(routines: items,
                              quiet: QuietHours.parse(raw["quiet"] as? [String: Any]),
                              quietNow: (raw["quiet_now"] as? Bool) ?? false,
                              broken: (raw["broken"] as? Bool) ?? false)
    }
}

/// Rutinler ekranının durumu: listeyi yükler, değişiklikleri sunucuya yazar.
@MainActor
final class RoutinesModel: ObservableObject {
    @Published private(set) var listing: RoutineListing?
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
            let (url, token) = try endpoint("/v1/routines")
            let data = try await client.json(method: "GET", url: url, token: token)
            guard let parsed = RoutineListing.parse(data) else { throw JuniorError.server("Rutin listesi okunamadı.") }
            listing = parsed
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func change(_ path: String, method: String, body: [String: Any]?) async {
        do {
            let (url, token) = try endpoint(path)
            _ = try await client.json(method: method, url: url, token: token, body: body)
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        await load()
    }

    func setEnabled(_ item: RoutineItem, _ on: Bool) async {
        await change("/v1/routines/\(item.id)", method: "POST", body: ["enabled": on])
    }

    func remove(_ item: RoutineItem) async {
        await change("/v1/routines/\(item.id)", method: "DELETE", body: nil)
    }

    func run(_ item: RoutineItem) async {
        await change("/v1/routines/\(item.id)/run", method: "POST", body: [:])
    }

    func setQuiet(enabled: Bool? = nil, from: String? = nil, to: String? = nil) async {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let from { body["from"] = from }
        if let to { body["to"] = to }
        await change("/v1/routines/quiet", method: "PUT", body: body)
    }

    /// Telefondan hızlı hatırlatma: her gün ya da seçilen günlerde, belirli saatte söylenir.
    func addReminder(text: String, at: String, days: [Int]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Ne hatırlatılacağını yaz."
            return
        }
        await change("/v1/routines", method: "POST", body: [
            "when": ["type": "weekly", "at": at, "days": days],
            "what": ["type": "say", "text": trimmed],
            "speak": true,
        ])
    }

    static func describe(_ error: Error) -> String {
        if case JuniorError.network = error { return "Bilgisayara ulaşılamıyor. Junior sunucusu ve tünel açık olmalı." }
        return (error as? LocalizedError)?.errorDescription ?? "Rutinler alınamadı."
    }
}
