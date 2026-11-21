import Foundation

/// Bilgisayarın durumu (`GET /v1/status/pc`): açık görev ve rutin sayısı, son rapor, CPU/RAM/GPU/sıcaklık
/// ve bilgisayara ulaşılıp ulaşılamadığı. Saf veri ve biçimleme; ağ ve arayüz yok.
struct PcStatus: Equatable {
    struct Report: Equatable {
        let title: String
        let summary: String
        let finished: Date?
    }

    struct Gpu: Equatable {
        let name: String
        let temp: Double?
        let util: Double?
    }

    /// Sunucu bu süreden eski değeri "yanıt vermiyor" sayar (sunucudaki STALE_SECONDS ile aynı).
    static let staleSeconds: TimeInterval = 60

    var tasksOpen: Int
    var routinesOpen: Int
    var report: Report?
    /// Sunucunun kendi kararı (60 sn'den eski değer = false).
    var reachable: Bool
    var lastSeen: Date?
    var cpu: Double?
    var ramPercent: Double?
    var temp: Double?
    var gpu: Gpu?
    /// Sunucu saati (yanıt anı): son görülmenin yaşı telefon saatinden bağımsız hesaplanır.
    var serverNow: Date?

    /// Sunucu yanıtı. Bozuksa nil; eksik alanlar nil/0 kalır, uydurma değer yok.
    static func parse(_ data: Data) -> PcStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pc = root["pc"] as? [String: Any] else { return nil }
        var report: Report?
        if let raw = root["last_report"] as? [String: Any],
           let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            report = Report(title: title,
                            summary: (raw["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            finished: seconds(raw["finished"]))
        }
        var gpu: Gpu?
        if let raw = pc["gpu"] as? [String: Any] {
            gpu = Gpu(name: (raw["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                      temp: number(raw["temp"]), util: number(raw["util"]))
        }
        return PcStatus(tasksOpen: max(0, (root["tasks_open"] as? Int) ?? 0),
                        routinesOpen: max(0, (root["routines_open"] as? Int) ?? 0),
                        report: report,
                        reachable: (pc["reachable"] as? Bool) ?? false,
                        lastSeen: seconds(pc["last_seen"]),
                        cpu: number(pc["cpu"]), ramPercent: number(pc["ram_pct"]), temp: number(pc["temp"]),
                        gpu: gpu, serverNow: seconds(root["now"]))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func seconds(_ value: Any?) -> Date? {
        guard let value = number(value), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// Son görülmeden bu yana geçen süre. Yanıt alındığındaki sunucu saati ile son görülme arasındaki
    /// yaş, yanıttan beri geçen telefon süresine eklenir (iki saatin sapması sonucu bozmaz).
    func age(now: Date, fetchedAt: Date) -> TimeInterval? {
        guard let lastSeen else { return nil }
        let atFetch = max(0, (serverNow ?? fetchedAt).timeIntervalSince(lastSeen))
        return atFetch + max(0, now.timeIntervalSince(fetchedAt))
    }

    /// Bilgisayar şu an yanıt veriyor mu: sunucu öyle diyor ve değer yeterince taze.
    func isReachable(now: Date, fetchedAt: Date) -> Bool {
        guard reachable, let age = age(now: now, fetchedAt: fetchedAt) else { return false }
        return age <= Self.staleSeconds
    }
}

/// Durum kartındaki metinler (Türkçe) ve eşik renkleri.
enum StatusFormat {
    enum Level: Equatable { case normal, warm, hot, unknown }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "%" + String(Int(value.rounded()))
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded())) + " °C"
    }

    /// "az önce", "20 sn önce", "3 dk önce", "2 sa önce", "1 gün önce"; bilinmiyorsa "hiç görülmedi".
    static func lastSeen(age: TimeInterval?) -> String {
        guard let age else { return "hiç görülmedi" }
        let seconds = Int(max(0, age))
        switch seconds {
        case ..<10: return "az önce"
        case ..<60: return "\(seconds) sn önce"
        case ..<3600: return "\(seconds / 60) dk önce"
        case ..<86_400: return "\(seconds / 3600) sa önce"
        default: return "\(seconds / 86_400) gün önce"
        }
    }

    /// Başlık satırı: bağlıysa "Bilgisayar yanıt veriyor", değilse "Bilgisayar yanıt vermiyor · 3 dk önce".
    static func reachability(_ status: PcStatus, now: Date, fetchedAt: Date) -> (text: String, ok: Bool) {
        if status.isReachable(now: now, fetchedAt: fetchedAt) { return ("Bilgisayar yanıt veriyor", true) }
        let age = status.age(now: now, fetchedAt: fetchedAt)
        if age == nil { return ("Bilgisayardan henüz bilgi gelmedi", false) }
        return ("Bilgisayar yanıt vermiyor · son görülme " + lastSeen(age: age), false)
    }

    /// İşlemci/bellek/ekran kartı: %85 üstü sıcak, %95 üstü çok sıcak.
    static func load(_ value: Double?) -> Level {
        guard let value else { return .unknown }
        if value >= 95 { return .hot }
        if value >= 85 { return .warm }
        return .normal
    }

    /// Sıcaklık (°C): 80 üstü sıcak, 90 üstü çok sıcak.
    static func heat(_ value: Double?) -> Level {
        guard let value else { return .unknown }
        if value >= 90 { return .hot }
        if value >= 80 { return .warm }
        return .normal
    }

    /// Ekran kartı satırı: "%12 kullanım · 49 °C"; kart okunamıyorsa dürüstçe söylenir.
    static func gpuLine(_ gpu: PcStatus.Gpu?) -> String {
        guard let gpu else { return "Ekran kartı okunamıyor" }
        var parts: [String] = []
        if gpu.util != nil { parts.append(percent(gpu.util) + " kullanım") }
        if gpu.temp != nil { parts.append(temperature(gpu.temp)) }
        return parts.isEmpty ? "Ekran kartı okunamıyor" : parts.joined(separator: " · ")
    }

    /// Son raporun tarihi: bugünse saat, değilse gün.ay.
    static func reportTime(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM"
        return formatter.string(from: date)
    }
}
