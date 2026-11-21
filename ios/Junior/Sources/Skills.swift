import Foundation

/// Beceri paketleri bilgisayardaki Junior sunucusunda durur (mobile_api/skills_core.py: hava ve
/// web arama; mobile_api/skills_daily.py: pomodoro, su, kalori, şınav, aralıklı tekrar, sınav).
/// Telefon aynı uçları kullanır; sayılar masaüstüyle ortaktır. Bu dosyada yalnız saf mantık var
/// (JSON çözme, süre/ilerleme hesapları); ağ işleri SkillsModel'de.
enum SkillPack: String, CaseIterable, Identifiable {
    case weather, search, pomodoro, water, calories, pushups, review, quiz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "Hava durumu"
        case .search: return "Web arama"
        case .pomodoro: return "Pomodoro"
        case .water: return "Su hatırlatıcısı"
        case .calories: return "Kalori sayacı"
        case .pushups: return "Şınav sayacı"
        case .review: return "Aralıklı tekrar"
        case .quiz: return "Sınav"
        }
    }

    var icon: String {
        switch self {
        case .weather: return "cloud.sun.fill"
        case .search: return "magnifyingglass"
        case .pomodoro: return "timer"
        case .water: return "drop.fill"
        case .calories: return "fork.knife"
        case .pushups: return "figure.strengthtraining.traditional"
        case .review: return "rectangle.on.rectangle.angled"
        case .quiz: return "checklist"
        }
    }

    /// Sunucudaki paket adı (/v1/skills/daily/<ad>); hava ve arama paket değil, sunucuda hep çalışır.
    var serverName: String? {
        switch self {
        case .weather, .search: return nil
        default: return rawValue
        }
    }

    /// Hava ve arama sunucuda açma/kapama durumu tutmaz: masaüstündeki eklenti anahtarı yalnız
    /// bilgisayardaki asistanın aracını kapatır, telefon aynı uçları her zaman kullanabilir.
    var alwaysOn: Bool { serverName == nil }

    /// Paket listesindeki sağdaki etiket. Hep kullanılabilenler "Açık" demez: masaüstünde
    /// eklentisi kapatılmış olsa da telefonda çalışırlar, "Açık" yanlış izlenim verirdi.
    func badge(enabled: Bool) -> String {
        if alwaysOn { return "Her zaman" }
        return enabled ? "Açık" : "Kapalı"
    }

    /// Kapalı paketin ekranda söylediği: nereden açılacağı.
    var closedText: String {
        "\(title) paketi kapalı. Bilgisayardaki Junior'da Ayarlar > Eklentiler'den “\(title)” paketini aç; "
            + "sonra bu ekranı aşağı çekip yenile."
    }

    /// Bilgisayar dosyasına ya da hesabına dokunan paketler telefona açılmaz (yalnız bilgi).
    static let computerOnly: [ComputerOnlySkill] = [
        ComputerOnlySkill(title: "Obsidian", icon: "book.closed.fill"),
        ComputerOnlySkill(title: "Excel", icon: "tablecells.fill"),
        ComputerOnlySkill(title: "Yazıcı", icon: "printer.fill"),
        ComputerOnlySkill(title: "WhatsApp arama", icon: "message.fill"),
        ComputerOnlySkill(title: "Uçuş arama", icon: "airplane"),
    ]
}

struct ComputerOnlySkill: Identifiable, Equatable {
    let title: String
    let icon: String

    var id: String { title }
}

/// JSONSerialization değerlerini güvenle okur: sayı ile mantıksal değer karışmasın.
enum SkillJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    static func int(_ value: Any?) -> Int? { number(value)?.intValue }

    static func double(_ value: Any?) -> Double? { number(value)?.doubleValue }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func date(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Ekrandaki sayılar: kalan süre, yüzde, ilerleme çubuğu.
enum SkillFormat {
    /// "24:59", bir saati aşınca "1:05:00". Eksi süre 00:00 olur.
    static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let hours = s / 3600, minutes = (s % 3600) / 60, rest = s % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%02d:%02d", minutes, rest)
    }

    static func secondsLeft(until end: Date, now: Date) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    /// 0…1 arası; hedef yoksa 0, hedefi aşınca 1.
    static func progress(_ value: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(goal)))
    }

    static func percent(_ value: Int, goal: Int) -> Int {
        guard goal > 0 else { return 0 }
        return Int((100 * Double(max(0, value)) / Double(goal)).rounded())
    }

    /// Süren evrenin ne kadarı geçti (0…1): çalışma work_min, mola break_min dakika sürer.
    static func phaseProgress(phase: String, ends: Date?, workMin: Int, breakMin: Int, now: Date) -> Double {
        guard let ends else { return 0 }
        let total = Double((phase == "work" ? workMin : breakMin) * 60)
        guard total > 0, phase == "work" || phase == "break" else { return 0 }
        let left = ends.timeIntervalSince(now)
        return min(1, max(0, 1 - left / total))
    }
}

struct PomodoroState: Equatable {
    var phase: String
    var ends: Date?
    var doneToday: Int
    /// Süren turun çalışma ve mola süresi (dakika); eski sunucu bildirmezse nil, ayardaki değer kullanılır.
    var workMin: Int?
    var breakMin: Int?

    var running: Bool { phase == "work" || phase == "break" }

    static let idle = PomodoroState(phase: "idle", ends: nil, doneToday: 0, workMin: nil, breakMin: nil)
}

struct QuizScore: Equatable {
    let topic: String
    let correct: Int
    let total: Int

    static func parse(_ raw: Any?) -> QuizScore? {
        guard let raw = raw as? [String: Any], let correct = SkillJSON.int(raw["correct"]),
              let total = SkillJSON.int(raw["total"]), total > 0 else { return nil }
        return QuizScore(topic: (raw["topic"] as? String) ?? "", correct: correct, total: total)
    }
}

/// GET /v1/skills/daily: hangi paket açık, ayarlar ve bugünün özeti.
struct SkillsOverview: Equatable {
    var packs: [String: Bool]
    var date: String
    var pomodoro: PomodoroState
    var workMin: Int
    var breakMin: Int
    var waterML: Int
    var waterGoal: Int
    var glassML: Int
    var kcal: Int
    var kcalGoal: Int
    var pushupsToday: Int
    var pushupsWeek: Int
    var pushupsGoal: Int
    var reviewDue: Int
    var reviewCards: Int
    var quizActive: Bool
    var quizCount: Int
    var lastScore: QuizScore?

    static func parse(_ data: Data) -> SkillsOverview? {
        guard let raw = SkillJSON.object(data), let packsRaw = raw["packs"] as? [String: Any],
              let today = raw["today"] as? [String: Any] else { return nil }
        var packs: [String: Bool] = [:]
        for (name, value) in packsRaw { packs[name] = SkillJSON.bool(value) ?? false }
        let config = raw["config"] as? [String: Any] ?? [:]
        func cfg(_ pack: String, _ key: String, _ fallback: Int) -> Int {
            SkillJSON.int((config[pack] as? [String: Any])?[key]) ?? fallback
        }
        func part(_ key: String) -> [String: Any] { today[key] as? [String: Any] ?? [:] }
        let pomodoro = part("pomodoro")
        let water = part("water"), calories = part("calories"), pushups = part("pushups")
        let review = part("review"), quiz = part("quiz")
        return SkillsOverview(
            packs: packs,
            date: (today["date"] as? String) ?? "",
            pomodoro: PomodoroState(phase: (pomodoro["phase"] as? String) ?? "idle",
                                    ends: SkillJSON.date(pomodoro["ends"]),
                                    doneToday: SkillJSON.int(pomodoro["done_today"]) ?? 0,
                                    workMin: SkillJSON.int(pomodoro["work_min"]),
                                    breakMin: SkillJSON.int(pomodoro["break_min"])),
            workMin: cfg("pomodoro", "work_min", 25),
            breakMin: cfg("pomodoro", "break_min", 5),
            waterML: SkillJSON.int(water["ml"]) ?? 0,
            waterGoal: SkillJSON.int(water["goal_ml"]) ?? cfg("water", "goal_ml", 2000),
            glassML: cfg("water", "glass_ml", 250),
            kcal: SkillJSON.int(calories["kcal"]) ?? 0,
            kcalGoal: SkillJSON.int(calories["goal_kcal"]) ?? cfg("calories", "goal_kcal", 2000),
            pushupsToday: SkillJSON.int(pushups["today"]) ?? 0,
            pushupsWeek: SkillJSON.int(pushups["week"]) ?? 0,
            pushupsGoal: cfg("pushups", "goal_daily", 0),
            reviewDue: SkillJSON.int(review["due"]) ?? 0,
            reviewCards: SkillJSON.int(review["cards"]) ?? 0,
            quizActive: SkillJSON.bool(quiz["active"]) ?? false,
            quizCount: cfg("quiz", "count", 5),
            lastScore: QuizScore.parse(quiz["last"]))
    }

    func enabled(_ pack: SkillPack) -> Bool {
        guard let name = pack.serverName else { return true }
        return packs[name] ?? false
    }

    /// Paket listesindeki kısa durum satırı.
    func status(_ pack: SkillPack) -> String {
        if pack == .weather { return "Bugün ve yarın" }
        if pack == .search { return "Hızlı, derin ya da haber" }
        guard enabled(pack) else { return "Kapalı" }
        switch pack {
        case .pomodoro:
            let phase = pomodoro.phase == "work" ? "Çalışma sürüyor" : pomodoro.phase == "break" ? "Mola sürüyor" : "Boşta"
            return "\(phase) · bugün \(pomodoro.doneToday)"
        case .water: return "\(waterML) / \(waterGoal) ml"
        case .calories: return "\(kcal) / \(kcalGoal) kalori"
        case .pushups: return "Bugün \(pushupsToday) · hafta \(pushupsWeek)"
        case .review: return reviewDue > 0 ? "Bugün \(reviewDue) kart" : "Bugün kart yok (\(reviewCards) kart)"
        case .quiz:
            if quizActive { return "Sınav sürüyor" }
            if let lastScore { return "Son: \(lastScore.correct) / \(lastScore.total)" }
            return "Henüz sınav yok"
        case .weather, .search: return ""
        }
    }
}

struct ReviewCard: Equatable {
    let id: String
    let front: String
    /// Çevrilmeden gelmez; "show" sonrası dolu.
    let back: String?

    static func parse(_ raw: Any?) -> ReviewCard? {
        guard let raw = raw as? [String: Any], let id = raw["id"] as? String, !id.isEmpty,
              let front = raw["front"] as? String else { return nil }
        return ReviewCard(id: id, front: front, back: raw["back"] as? String)
    }
}

struct QuizQuestion: Equatable {
    let number: Int
    let total: Int
    let question: String
    let options: [String]

    static func parse(_ raw: Any?) -> QuizQuestion? {
        guard let raw = raw as? [String: Any], let question = raw["question"] as? String,
              let options = raw["options"] as? [String], options.count == 4,
              let number = SkillJSON.int(raw["number"]), let total = SkillJSON.int(raw["total"]) else { return nil }
        return QuizQuestion(number: number, total: total, question: question, options: options)
    }

    static let letters = ["A", "B", "C", "D"]

    /// Cevap yanıtındaki değerlendirme: "Doğru! …" ya da "Yanlış; doğru cevap B) … ".
    /// Sunucu sonraki sorunun satırını da ekler ("Soru 2/5: …"); ekranda soru ayrıca görünür.
    static func verdict(from reply: String) -> String {
        guard let range = reply.range(of: #"\s*Soru \d+/\d+:"#, options: .regularExpression) else { return reply }
        return String(reply[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}

struct CalorieEntry: Equatable, Identifiable {
    let id: Int
    let at: Date?
    let food: String
    let kcal: Int
    let estimated: Bool
    let portion: String

    static func parseList(_ raw: Any?) -> [CalorieEntry] {
        guard let items = raw as? [[String: Any]] else { return [] }
        var out: [CalorieEntry] = []
        for (index, item) in items.enumerated() {
            guard let kcal = SkillJSON.int(item["kcal"]) else { continue }
            out.append(CalorieEntry(id: index, at: SkillJSON.date(item["at"]), food: (item["food"] as? String) ?? "",
                                    kcal: kcal, estimated: SkillJSON.bool(item["estimated"]) ?? false,
                                    portion: (item["portion"] as? String) ?? ""))
        }
        return out
    }
}

/// POST /v1/skills/daily/<paket> yanıtı: outcome, sesli okunacak reply ve pakete göre alanlar.
struct SkillReply: Equatable {
    let outcome: String
    let reply: String
    var phase: String?
    var ends: Date?
    var due: Int?
    var card: ReviewCard?
    var question: QuizQuestion?
    var correct: Bool?
    var score: QuizScore?
    var entries: [CalorieEntry] = []
    var estimated: Bool?

    var worked: Bool { outcome == "done" || outcome == "started" }

    static func parse(_ data: Data) -> SkillReply? {
        guard let raw = SkillJSON.object(data), let outcome = raw["outcome"] as? String else { return nil }
        var reply = (raw["reply"] as? String) ?? ""
        if reply.isEmpty, let text = raw["text"] as? String { reply = stripTag(text) }
        return SkillReply(outcome: outcome, reply: reply,
                          phase: raw["phase"] as? String,
                          ends: SkillJSON.date(raw["ends"]),
                          due: SkillJSON.int(raw["due"]),
                          card: ReviewCard.parse(raw["card"]),
                          question: QuizQuestion.parse(raw["question"]),
                          correct: SkillJSON.bool(raw["correct"]),
                          score: QuizScore.parse(raw["score"]),
                          entries: CalorieEntry.parseList(raw["entries"]),
                          estimated: SkillJSON.bool(raw["estimated"]))
    }

    /// "[done] Kaydettim" → "Kaydettim": etiket ajana içindir, ekranda gösterilmez.
    static func stripTag(_ text: String) -> String {
        guard let range = text.range(of: #"^\[(done|started|ask|failed|unverified)\]\s*"#, options: .regularExpression) else {
            return text
        }
        return String(text[range.upperBound...])
    }
}

struct WeatherDay: Equatable, Identifiable {
    let date: String
    let label: String
    let description: String
    let min: Int?
    let max: Int?
    let precipitation: Int?

    var id: String { date }

    var rangeText: String {
        guard let min, let max else { return "" }
        return "\(min)–\(max)°C"
    }
}

/// GET /v1/tools/weather: yer, şu anki durum ve gün gün özet. outcome "ask" ise yalnız soru var.
struct WeatherReport: Equatable {
    let outcome: String
    let reply: String
    let place: String
    let temperature: Int?
    let feelsLike: Int?
    let current: String?
    let days: [WeatherDay]

    static func parse(_ data: Data) -> WeatherReport? {
        guard let raw = SkillJSON.object(data), let outcome = raw["outcome"] as? String else { return nil }
        let place = raw["place"] as? [String: Any]
        var name = (place?["name"] as? String) ?? ""
        if let country = place?["country"] as? String, !country.isEmpty, country != "Türkiye", country != "Turkey", !name.isEmpty {
            name += " (\(country))"
        }
        let current = raw["current"] as? [String: Any]
        let days = (raw["days"] as? [[String: Any]] ?? []).compactMap { day -> WeatherDay? in
            guard let date = day["date"] as? String else { return nil }
            return WeatherDay(date: date, label: (day["label"] as? String) ?? date,
                              description: (day["description"] as? String) ?? "",
                              min: SkillJSON.int(day["min"]), max: SkillJSON.int(day["max"]),
                              precipitation: SkillJSON.int(day["precipitation_probability"]))
        }
        return WeatherReport(outcome: outcome,
                             reply: (raw["reply"] as? String) ?? (raw["summary"] as? String) ?? "",
                             place: name,
                             temperature: SkillJSON.int(current?["temperature"]),
                             feelsLike: SkillJSON.int(current?["feels_like"]),
                             current: current?["description"] as? String,
                             days: days)
    }
}

enum SearchMode: String, CaseIterable, Identifiable {
    case quick, deep, news

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: return "Hızlı"
        case .deep: return "Derin"
        case .news: return "Haber"
        }
    }
}

struct SearchHit: Equatable, Identifiable {
    let id: Int
    let title: String
    let url: URL
    let snippet: String
    let excerpt: String?

    var host: String { url.host ?? url.absoluteString }

    /// GET /v1/tools/search: (sonuçlar, not). Yalnız http/https bağlantılar alınır.
    static func parse(_ data: Data) -> (hits: [SearchHit], note: String)? {
        guard let raw = SkillJSON.object(data), raw["outcome"] is String else { return nil }
        var hits: [SearchHit] = []
        for item in raw["results"] as? [[String: Any]] ?? [] {
            guard let link = item["url"] as? String, let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { continue }
            let title = (item["title"] as? String) ?? ""
            hits.append(SearchHit(id: hits.count, title: title.isEmpty ? (url.host ?? link) : title, url: url,
                                  snippet: (item["snippet"] as? String) ?? "",
                                  excerpt: item["excerpt"] as? String))
        }
        let note: String
        if hits.isEmpty {
            note = SkillReply.stripTag((raw["text"] as? String) ?? "Sonuç bulunamadı; sorguyu değiştirip yeniden dene.")
        } else {
            note = ""
        }
        return (hits, note)
    }
}

/// Sorgu dizesi: harf, rakam ve -._~ dışındaki her şey yüzde kodlanır ("+" boşluk sanılmasın).
enum SkillQuery {
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func url(base: URL, items: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedQuery = items.isEmpty ? nil
            : items.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        return components.url
    }
}

/// Pomodoro bitince telefonda yerel bildirim: uygulama arka planda olsa da gelir.
enum PomodoroAlerts {
    static let workID = "junior-pomodoro-work"
    static let breakID = "junior-pomodoro-break"
    static var ids: [String] { [workID, breakID] }

    /// Sesli komut yanıtındaki actions_executed pomodoroyu başlattı ya da durdurdu mu
    /// ("pomodoro_start", "pomodoro_stop"). O zaman telefondaki bekleyen bildirimler
    /// eskimiştir: silinip sunucudaki yeni duruma göre yeniden kurulmalı. Durum sorusu dokunmaz.
    static func touches(_ actions: [String]) -> Bool {
        actions.contains { $0.hasPrefix("pomodoro_") && $0 != "pomodoro_status" }
    }

    struct Alert: Equatable {
        let id: String
        let fireAt: Date
        let title: String
        let body: String
    }

    /// Süren evreye göre kurulacak bildirimler; geçmişte kalan kurulmaz.
    static func plan(phase: String, ends: Date?, breakMin: Int, now: Date) -> [Alert] {
        guard let ends, ends > now else { return [] }
        let breakEnd = Alert(id: breakID, fireAt: phase == "work" ? ends.addingTimeInterval(Double(breakMin * 60)) : ends,
                             title: "Mola bitti",
                             body: "Yeni tur için Junior'da Beceriler > Pomodoro'dan başlat ya da “pomodoro başlat” de.")
        switch phase {
        case "work":
            let workEnd = Alert(id: workID, fireAt: ends, title: "Pomodoro bitti",
                                body: breakMin > 0 ? "Şimdi \(breakMin) dakika mola." : "Tur tamamlandı.")
            return breakMin > 0 ? [workEnd, breakEnd] : [workEnd]
        case "break":
            return [breakEnd]
        default:
            return []
        }
    }
}
