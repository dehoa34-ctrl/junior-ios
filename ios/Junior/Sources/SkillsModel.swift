import Foundation

/// Beceriler ekranının durumu: bugünün özetini yükler, paket işlemlerini sunucuya yazar.
/// Her istek en çok 30 saniye bekler (sınav ve kalori tahmini modeli, derin arama sayfaları
/// okuduğu için daha uzun); ulaşılamazsa ekran donmaz, "bilgisayara ulaşılamıyor" der.
@MainActor
final class SkillsModel: ObservableObject {
    static let timeout: TimeInterval = 30
    /// Sunucu modeli en çok 90 sn bekler; telefon biraz daha uzun bekler ki yanıt kaybolmasın.
    static let modelTimeout: TimeInterval = 95
    static let deepSearchTimeout: TimeInterval = 60

    @Published private(set) var overview: SkillsOverview?
    @Published private(set) var loading = false
    @Published var error: String?
    /// Şu an işlemi süren paket (düğmeler kilitlenir, dönen çark görünür).
    @Published private(set) var working: SkillPack?
    /// Her paketin son yanıtı (sesli komutla aynı cümle).
    @Published private(set) var notes: [SkillPack: String] = [:]

    @Published var city = ""
    @Published private(set) var weather: WeatherReport?
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var searchNote: String?
    @Published private(set) var card: ReviewCard?
    @Published private(set) var reviewDue: Int?
    @Published private(set) var question: QuizQuestion?
    @Published private(set) var quizVerdict: String?
    @Published private(set) var quizScore: QuizScore?
    @Published private(set) var calorieEntries: [CalorieEntry] = []

    private let config: Config
    private let client = JuniorClient()
    private var cityLoaded = false

    init(config: Config) {
        self.config = config
    }

    private func endpoint(_ path: String, query: [(String, String)] = []) throws -> (URL, String) {
        guard let token = config.token, !token.isEmpty else { throw JuniorError.notConfigured }
        guard let base = config.url(path: path) else { throw JuniorError.badAddress }
        guard let url = query.isEmpty ? base : SkillQuery.url(base: base, items: query) else { throw JuniorError.badAddress }
        return (url, token)
    }

    static func describe(_ error: Error) -> String {
        if case JuniorError.network = error {
            return "Bilgisayara ulaşılamıyor. Junior sunucusu ve tünel açık olmalı; açıksa biraz sonra yeniden dene."
        }
        return (error as? LocalizedError)?.errorDescription ?? "İstek tamamlanamadı; yeniden dene."
    }

    // MARK: - Özet

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (url, token) = try endpoint("/v1/skills/daily")
            let data = try await client.json(method: "GET", url: url, token: token, timeout: Self.timeout)
            guard let parsed = SkillsOverview.parse(data) else {
                throw JuniorError.server("Beceri özeti okunamadı; bilgisayardaki Junior'ı güncelle.")
            }
            overview = parsed
            error = nil
            reviewDue = parsed.reviewDue
            if !parsed.quizActive { question = nil }
            await syncPomodoroAlerts(ask: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Paket işlemi: POST /v1/skills/daily/<paket>. Yanıt cümlesi paketin notuna yazılır.
    private func call(_ pack: SkillPack, _ body: [String: Any], timeout: TimeInterval = SkillsModel.timeout) async -> SkillReply? {
        guard let name = pack.serverName else { return nil }
        working = pack
        defer { working = nil }
        do {
            let (url, token) = try endpoint("/v1/skills/daily/\(name)")
            let data = try await client.json(method: "POST", url: url, token: token, body: body, timeout: timeout)
            guard let reply = SkillReply.parse(data) else {
                throw JuniorError.server("Junior'ın yanıtı okunamadı; bilgisayardaki Junior'ı güncelle.")
            }
            notes[pack] = reply.reply
            return reply
        } catch {
            notes[pack] = Self.describe(error)
            return nil
        }
    }

    // MARK: - Hava

    func loadCity() async {
        guard !cityLoaded else { return }
        do {
            let (url, token) = try endpoint("/v1/tools/weather/city")
            let data = try await client.json(method: "GET", url: url, token: token, timeout: Self.timeout)
            cityLoaded = true
            if city.isEmpty, let saved = SkillJSON.object(data)?["city"] as? String { city = saved }
        } catch {
            notes[.weather] = Self.describe(error)
        }
    }

    func loadWeather() async {
        let place = city.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = [("days", "2")]
        if !place.isEmpty { query.append(("place", place)) }
        working = .weather
        defer { working = nil }
        do {
            let (url, token) = try endpoint("/v1/tools/weather", query: query)
            let data = try await client.json(method: "GET", url: url, token: token, timeout: Self.timeout)
            guard let report = WeatherReport.parse(data) else { throw JuniorError.server("Hava durumu yanıtı okunamadı.") }
            weather = report.outcome == "done" ? report : nil
            notes[.weather] = report.outcome == "done" ? nil : report.reply
        } catch {
            weather = nil
            notes[.weather] = Self.describe(error)
        }
    }

    // MARK: - Arama

    func search(_ text: String, mode: SearchMode) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        working = .search
        defer { working = nil }
        do {
            let (url, token) = try endpoint("/v1/tools/search", query: [("q", String(q.prefix(200))), ("mode", mode.rawValue)])
            let data = try await client.json(method: "GET", url: url, token: token,
                                             timeout: mode == .deep ? Self.deepSearchTimeout : Self.timeout)
            guard let parsed = SearchHit.parse(data) else { throw JuniorError.server("Arama yanıtı okunamadı.") }
            hits = parsed.hits
            searchNote = parsed.note.isEmpty ? nil : parsed.note
        } catch {
            hits = []
            searchNote = Self.describe(error)
        }
    }

    // MARK: - Pomodoro

    func pomodoroStart() async {
        guard await call(.pomodoro, ["action": "start"]) != nil else { return }
        await load()
        await syncPomodoroAlerts(ask: true)
    }

    func pomodoroStop() async {
        guard await call(.pomodoro, ["action": "stop"]) != nil else { return }
        await load()
    }

    /// Süren evre bitince özeti yeniden alır (sayaç ve bugünkü sayı güncellensin).
    func waitForPomodoroPhase() async {
        guard let pomodoro = overview?.pomodoro, pomodoro.running, let ends = pomodoro.ends else { return }
        let seconds = ends.timeIntervalSinceNow
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64((seconds + 2) * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        await load()
    }

    /// Yerel bildirimleri süren tura göre kurar ya da kaldırır (PomodoroAlertSync; sesli komut
    /// ve öne geliş de aynı yeri kullanır). İzin yalnız telefondan başlatınca sorulur.
    private func syncPomodoroAlerts(ask: Bool) async {
        await PomodoroAlertSync.apply(overview, ask: ask)
    }

    // MARK: - Su, kalori, şınav

    func logWater(ml: Int? = nil) async {
        var body: [String: Any] = ["action": "log"]
        if let ml { body["ml"] = ml }
        guard await call(.water, body) != nil else { return }
        await load()
    }

    func loadCalories() async {
        guard overview?.enabled(.calories) == true else { return }
        if let reply = await call(.calories, ["action": "status"]) {
            calorieEntries = reply.entries
            // Durum cümlesi listeyle aynı; son kayıt notu kalsın.
            notes[.calories] = nil
        }
    }

    /// `kcal` boşsa Junior modelle tahmin eder ve kayıt "tahmini" işaretlenir.
    func logCalories(food: String, kcal: Int?) async {
        let name = food.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notes[.calories] = "Ne yediğini yaz (ör. mercimek çorbası)."
            return
        }
        var body: [String: Any] = ["action": "log", "food": name]
        if let kcal { body["kcal"] = kcal }
        guard let reply = await call(.calories, body, timeout: kcal == nil ? Self.modelTimeout : Self.timeout) else { return }
        let saved = reply.reply
        await load()
        await loadCalories()
        notes[.calories] = saved
    }

    func logPushups(_ count: Int) async {
        guard await call(.pushups, ["action": "log", "count": count]) != nil else { return }
        await load()
    }

    // MARK: - Aralıklı tekrar

    private func applyReview(_ reply: SkillReply) {
        card = reply.card
        if let due = reply.due { reviewDue = due }
        if reply.card == nil { notes[.review] = reply.reply }
    }

    func reviewStart() async {
        guard let reply = await call(.review, ["action": "start"]) else { return }
        applyReview(reply)
    }

    func reviewFlip() async {
        guard let current = card, let reply = await call(.review, ["action": "show", "id": current.id]) else { return }
        if reply.worked, let flipped = reply.card { card = flipped } else { card = nil }
    }

    func reviewGrade(knew: Bool) async {
        guard let current = card,
              let reply = await call(.review, ["action": "grade", "id": current.id, "knew": knew]) else { return }
        if reply.due == nil {
            // Kart başka bir oturumdan (ses) değerlendirildi; sıradakini yeniden iste.
            await reviewStart()
        } else {
            applyReview(reply)
        }
        await load()
    }

    func addCard(front: String, back: String) async {
        let f = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !b.isEmpty else {
            notes[.review] = "Kartın ön ve arka yüzünü yaz."
            return
        }
        guard await call(.review, ["action": "add", "front": f, "back": b]) != nil else { return }
        await load()
    }

    // MARK: - Sınav

    private func applyQuiz(_ reply: SkillReply) {
        if let next = reply.question {
            question = next
        } else if reply.outcome != "ask" {
            // Sınav bitti, bırakıldı ya da sunucuda süren sınav yok.
            question = nil
        }
        if let score = reply.score { quizScore = score }
    }

    func quizStart(topic: String) async {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["action": "start"]
        if t.isEmpty { body["from_memory"] = true } else { body["topic"] = String(t.prefix(120)) }
        quizVerdict = nil
        quizScore = nil
        guard let reply = await call(.quiz, body, timeout: Self.modelTimeout) else {
            // Yanıt gelmeden zaman aşımı olduysa sınav yine de hazırlanmış olabilir: özete bak.
            await load()
            if overview?.quizActive == true { await quizResume() }
            return
        }
        applyQuiz(reply)
        await load()
    }

    /// Süren sınavın sıradaki sorusu (sesle başlamış ya da ekran yeniden açılmış olabilir).
    func quizResume() async {
        guard question == nil, overview?.quizActive == true,
              let reply = await call(.quiz, ["action": "status"]) else { return }
        question = reply.question
    }

    func quizAnswer(_ index: Int) async {
        guard question != nil, let reply = await call(.quiz, ["action": "answer", "choice": index]) else { return }
        if reply.correct != nil { quizVerdict = QuizQuestion.verdict(from: reply.reply) }
        applyQuiz(reply)
        if reply.score != nil { await load() }
    }

    func quizStop() async {
        guard await call(.quiz, ["action": "stop"]) != nil else { return }
        question = nil
        quizVerdict = nil
        await load()
    }
}
