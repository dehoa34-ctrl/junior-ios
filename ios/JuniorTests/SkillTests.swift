import XCTest
@testable import Junior

/// Beceriler ekranının saf parçaları: sunucu yanıtlarını çözme, süre biçimi, ilerleme
/// hesapları, sorgu kodlama ve pomodoro bildirimlerinin planı. Ağ yok.
final class SkillTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private let overviewJSON: [String: Any] = [
        "packs": ["pomodoro": true, "water": true, "quiz": false, "review": true, "calories": true, "pushups": false],
        "config": [
            "pomodoro": ["work_min": 50, "break_min": 10],
            "water": ["goal_ml": 2500, "glass_ml": 300],
            "calories": ["goal_kcal": 1800],
            "pushups": ["goal_daily": 40],
            "quiz": ["count": 5],
        ],
        "today": [
            "date": "2026-11-21",
            "pomodoro": ["phase": "work", "ends": 1_795_000_000.5, "done_today": 2, "work_min": 50, "break_min": 10],
            "water": ["ml": 1250, "goal_ml": 2500],
            "calories": ["kcal": 900, "goal_kcal": 1800],
            "pushups": ["today": 20, "week": 75],
            "review": ["due": 3, "cards": 40],
            "quiz": ["active": false, "last": ["at": 1, "topic": "Osmanlı", "correct": 4, "total": 5]],
        ],
    ]

    func testOverviewParsesPacksTotalsAndConfig() throws {
        let overview = try XCTUnwrap(SkillsOverview.parse(data(overviewJSON)))
        XCTAssertTrue(overview.enabled(.water))
        XCTAssertFalse(overview.enabled(.quiz))
        XCTAssertFalse(overview.enabled(.pushups))
        XCTAssertTrue(overview.enabled(.weather), "hava hep açık")
        XCTAssertTrue(overview.enabled(.search), "arama hep açık")
        XCTAssertEqual(overview.pomodoro.phase, "work")
        XCTAssertEqual(overview.pomodoro.ends, Date(timeIntervalSince1970: 1_795_000_000.5))
        XCTAssertEqual(overview.pomodoro.doneToday, 2)
        XCTAssertEqual(overview.pomodoro.breakMin, 10)
        XCTAssertEqual(overview.workMin, 50)
        XCTAssertEqual(overview.glassML, 300)
        XCTAssertEqual(overview.waterML, 1250)
        XCTAssertEqual(overview.waterGoal, 2500)
        XCTAssertEqual(overview.kcalGoal, 1800)
        XCTAssertEqual(overview.pushupsGoal, 40)
        XCTAssertEqual(overview.pushupsWeek, 75)
        XCTAssertEqual(overview.reviewDue, 3)
        XCTAssertEqual(overview.lastScore, QuizScore(topic: "Osmanlı", correct: 4, total: 5))
    }

    func testOverviewStatusLines() throws {
        let overview = try XCTUnwrap(SkillsOverview.parse(data(overviewJSON)))
        XCTAssertEqual(overview.status(.water), "1250 / 2500 ml")
        XCTAssertEqual(overview.status(.calories), "900 / 1800 kalori")
        XCTAssertEqual(overview.status(.pushups), "Kapalı")
        XCTAssertEqual(overview.status(.pomodoro), "Çalışma sürüyor · bugün 2")
        XCTAssertEqual(overview.status(.review), "Bugün 3 kart")
        XCTAssertEqual(overview.status(.quiz), "Kapalı")
    }

    func testOverviewToleratesOldServerAndRejectsGarbage() throws {
        // Eski sunucu: pomodoro süresi yok, ends null, config eksik.
        let old = try XCTUnwrap(SkillsOverview.parse(data([
            "packs": ["water": true],
            "today": ["pomodoro": ["phase": "idle", "ends": NSNull(), "done_today": 0]],
        ])))
        XCTAssertNil(old.pomodoro.ends)
        XCTAssertNil(old.pomodoro.breakMin)
        XCTAssertFalse(old.pomodoro.running)
        XCTAssertEqual(old.waterGoal, 2000)
        XCTAssertEqual(old.breakMin, 5)
        XCTAssertNil(SkillsOverview.parse(Data("bozuk".utf8)))
        XCTAssertNil(SkillsOverview.parse(data(["packs": [String: Any]()])))
    }

    func testBooleansAreNotNumbers() {
        XCTAssertNil(SkillJSON.int(true))
        XCTAssertEqual(SkillJSON.int(NSNumber(value: 3)), 3)
        XCTAssertNil(SkillJSON.bool(NSNumber(value: 1)))
        XCTAssertEqual(SkillJSON.bool(true), true)
    }

    func testCountdownFormatting() {
        XCTAssertEqual(SkillFormat.countdown(25 * 60), "25:00")
        XCTAssertEqual(SkillFormat.countdown(59), "00:59")
        XCTAssertEqual(SkillFormat.countdown(0), "00:00")
        XCTAssertEqual(SkillFormat.countdown(-5), "00:00")
        XCTAssertEqual(SkillFormat.countdown(3900), "1:05:00")
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SkillFormat.secondsLeft(until: now.addingTimeInterval(90.2), now: now), 91)
        XCTAssertEqual(SkillFormat.secondsLeft(until: now.addingTimeInterval(-3), now: now), 0)
    }

    func testProgressAndPercent() {
        XCTAssertEqual(SkillFormat.progress(1000, goal: 2000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SkillFormat.progress(3000, goal: 2000), 1)
        XCTAssertEqual(SkillFormat.progress(10, goal: 0), 0)
        XCTAssertEqual(SkillFormat.percent(1250, goal: 2500), 50)
        XCTAssertEqual(SkillFormat.percent(2600, goal: 2000), 130)
        XCTAssertEqual(SkillFormat.percent(5, goal: 0), 0)
        let now = Date(timeIntervalSince1970: 10_000)
        let half = SkillFormat.phaseProgress(phase: "work", ends: now.addingTimeInterval(750), workMin: 25, breakMin: 5, now: now)
        XCTAssertEqual(half, 0.5, accuracy: 0.0001)
        let breakDone = SkillFormat.phaseProgress(phase: "break", ends: now.addingTimeInterval(-1), workMin: 25, breakMin: 5, now: now)
        XCTAssertEqual(breakDone, 1)
        XCTAssertEqual(SkillFormat.phaseProgress(phase: "idle", ends: now, workMin: 25, breakMin: 5, now: now), 0)
        XCTAssertEqual(SkillFormat.phaseProgress(phase: "work", ends: nil, workMin: 25, breakMin: 5, now: now), 0)
    }

    func testPomodoroAlertsPlan() {
        let now = Date(timeIntervalSince1970: 50_000)
        let ends = now.addingTimeInterval(600)
        let work = PomodoroAlerts.plan(phase: "work", ends: ends, breakMin: 5, now: now)
        XCTAssertEqual(work.map(\.id), [PomodoroAlerts.workID, PomodoroAlerts.breakID])
        XCTAssertEqual(work[0].fireAt, ends)
        XCTAssertEqual(work[1].fireAt, ends.addingTimeInterval(300))
        XCTAssertTrue(work[0].body.contains("5 dakika mola"))
        let rest = PomodoroAlerts.plan(phase: "break", ends: ends, breakMin: 5, now: now)
        XCTAssertEqual(rest.map(\.id), [PomodoroAlerts.breakID])
        XCTAssertEqual(rest[0].fireAt, ends)
        XCTAssertTrue(PomodoroAlerts.plan(phase: "work", ends: now.addingTimeInterval(-1), breakMin: 5, now: now).isEmpty)
        XCTAssertTrue(PomodoroAlerts.plan(phase: "idle", ends: ends, breakMin: 5, now: now).isEmpty)
        XCTAssertTrue(PomodoroAlerts.plan(phase: "work", ends: nil, breakMin: 5, now: now).isEmpty)
    }

    func testSkillReplyForReviewAndQuiz() throws {
        let review = try XCTUnwrap(SkillReply.parse(data([
            "outcome": "done", "reply": "2 kart kaldı.", "text": "[done] 2 kart kaldı.",
            "due": 2, "card": ["id": "ab12", "front": "kedi"],
        ])))
        XCTAssertTrue(review.worked)
        XCTAssertEqual(review.due, 2)
        XCTAssertEqual(review.card, ReviewCard(id: "ab12", front: "kedi", back: nil))

        let answer = try XCTUnwrap(SkillReply.parse(data([
            "outcome": "done", "reply": "Doğru! Ankara 1923'ten beri başkent. Soru 2/2: 2 + 2 kaç eder? A) 3 B) 4 C) 5 D) 6",
            "correct": true,
            "question": ["number": 2, "total": 2, "question": "2 + 2 kaç eder?", "options": ["3", "4", "5", "6"]],
        ])))
        XCTAssertEqual(answer.correct, true)
        XCTAssertEqual(answer.question?.number, 2)
        XCTAssertEqual(answer.question?.options.count, 4)
        XCTAssertEqual(QuizQuestion.verdict(from: answer.reply), "Doğru! Ankara 1923'ten beri başkent.")

        let end = try XCTUnwrap(SkillReply.parse(data([
            "outcome": "done", "reply": "Yanlış; doğru cevap B) 4. Sınav bitti: 1 / 2 doğru.",
            "correct": false, "score": ["correct": 1, "total": 2],
        ])))
        XCTAssertEqual(end.correct, false)
        XCTAssertNil(end.question)
        XCTAssertEqual(end.score?.correct, 1)
        XCTAssertEqual(QuizQuestion.verdict(from: end.reply), end.reply)
        // Seçeneği 4 olmayan soru alınmaz.
        XCTAssertNil(QuizQuestion.parse(["number": 1, "total": 1, "question": "x", "options": ["a", "b"]]))
    }

    func testSkillReplyCalorieEntriesAndTagFallback() throws {
        let status = try XCTUnwrap(SkillReply.parse(data([
            "outcome": "done", "reply": "Bugün 550 / 2000 kalori.",
            "entries": [
                ["at": 1_795_000_000, "food": "mercimek çorbası", "kcal": 350, "estimated": true, "portion": "1 kase"],
                ["at": 1_795_000_100, "food": "yulaf", "kcal": 200, "estimated": false, "portion": ""],
                ["food": "bozuk"],
            ],
        ])))
        XCTAssertEqual(status.entries.map(\.food), ["mercimek çorbası", "yulaf"])
        XCTAssertEqual(status.entries.map(\.estimated), [true, false])
        XCTAssertEqual(status.entries.first?.portion, "1 kase")
        let failed = try XCTUnwrap(SkillReply.parse(data(["outcome": "failed", "text": "[failed] Su paketi kapalı."])))
        XCTAssertFalse(failed.worked)
        XCTAssertEqual(failed.reply, "Su paketi kapalı.")
        XCTAssertTrue(try XCTUnwrap(SkillReply.parse(data(["outcome": "started", "reply": "Başladı"]))).worked)
        XCTAssertNil(SkillReply.parse(data(["reply": "durumsuz"])))
        XCTAssertEqual(SkillReply.stripTag("etiketsiz"), "etiketsiz")
    }

    func testWeatherReportParsing() throws {
        let report = try XCTUnwrap(WeatherReport.parse(data([
            "outcome": "done",
            "place": ["name": "İzmir", "country": "Türkiye"],
            "current": ["temperature": 17, "feels_like": 16, "description": "parçalı bulutlu"],
            "days": [
                ["date": "2026-11-21", "label": "Bugün", "description": "parçalı bulutlu", "min": 11, "max": 19,
                 "precipitation_probability": 5],
                ["date": "2026-11-22", "label": "Yarın", "description": "yağmurlu", "min": 10, "max": 16,
                 "precipitation_probability": 80],
            ],
            "summary": "İzmir: şu an 17°C.", "reply": "İzmir: şu an 17°C.",
        ])))
        XCTAssertEqual(report.place, "İzmir")
        XCTAssertEqual(report.temperature, 17)
        XCTAssertEqual(report.days.map(\.label), ["Bugün", "Yarın"])
        XCTAssertEqual(report.days[1].rangeText, "10–16°C")
        XCTAssertEqual(report.days[1].precipitation, 80)
        let abroad = try XCTUnwrap(WeatherReport.parse(data(["outcome": "done", "place": ["name": "Paris", "country": "Fransa"]])))
        XCTAssertEqual(abroad.place, "Paris (Fransa)")
        let ask = try XCTUnwrap(WeatherReport.parse(data(["outcome": "ask", "reply": "Hangi şehir için bakayım?"])))
        XCTAssertEqual(ask.outcome, "ask")
        XCTAssertTrue(ask.days.isEmpty)
        XCTAssertEqual(ask.reply, "Hangi şehir için bakayım?")
    }

    func testSearchParsingKeepsOnlyWebLinks() throws {
        let parsed = try XCTUnwrap(SearchHit.parse(data([
            "outcome": "done",
            "results": [
                ["title": "Haber", "url": "https://ornek.com/a", "snippet": "özet", "excerpt": "sayfadan"],
                ["title": "Kötü", "url": "javascript:alert(1)"],
                ["title": "", "url": "http://ornek.org/b"],
            ],
        ])))
        XCTAssertEqual(parsed.hits.map(\.url.absoluteString), ["https://ornek.com/a", "http://ornek.org/b"])
        XCTAssertEqual(parsed.hits.map(\.id), [0, 1])
        XCTAssertEqual(parsed.hits[1].title, "ornek.org")
        XCTAssertEqual(parsed.hits[0].excerpt, "sayfadan")
        XCTAssertEqual(parsed.note, "")
        let empty = try XCTUnwrap(SearchHit.parse(data(["outcome": "failed", "results": [],
                                                       "text": "[failed] \"x\" için sonuç bulunamadı."])))
        XCTAssertTrue(empty.hits.isEmpty)
        XCTAssertEqual(empty.note, "\"x\" için sonuç bulunamadı.")
    }

    func testQueryEncodingKeepsPlusAndTurkish() throws {
        let base = try XCTUnwrap(URL(string: "https://junior.example/v1/tools/search"))
        let url = try XCTUnwrap(SkillQuery.url(base: base, items: [("q", "c++ & İzmir"), ("mode", "news")]))
        XCTAssertEqual(url.absoluteString, "https://junior.example/v1/tools/search?q=c%2B%2B%20%26%20%C4%B0zmir&mode=news")
        XCTAssertEqual(SkillQuery.url(base: base, items: [])?.absoluteString, base.absoluteString)
    }

    func testPackMetadata() {
        XCTAssertNil(SkillPack.weather.serverName)
        XCTAssertEqual(SkillPack.pushups.serverName, "pushups")
        XCTAssertTrue(SkillPack.search.alwaysOn)
        XCTAssertTrue(SkillPack.water.closedText.contains("Ayarlar > Eklentiler"))
        XCTAssertEqual(SkillPack.allCases.count, 8)
        XCTAssertFalse(SkillPack.computerOnly.map(\.title).contains("Su hatırlatıcısı"))
    }

    func testPackBadgeDoesNotClaimAlwaysOnPacksAreSwitchedOn() {
        // Hava ve arama masaüstünde kapatılabilir ama telefonda çalışır: "Açık" yazmaz.
        XCTAssertEqual(SkillPack.weather.badge(enabled: true), "Her zaman")
        XCTAssertEqual(SkillPack.search.badge(enabled: false), "Her zaman")
        XCTAssertEqual(SkillPack.water.badge(enabled: true), "Açık")
        XCTAssertEqual(SkillPack.quiz.badge(enabled: false), "Kapalı")
    }

    func testPomodoroVoiceActionsInvalidateAlerts() {
        XCTAssertTrue(PomodoroAlerts.touches(["pomodoro_stop"]))
        XCTAssertTrue(PomodoroAlerts.touches(["pomodoro_start"]))
        XCTAssertFalse(PomodoroAlerts.touches(["pomodoro_status"]), "durum sorusu bildirimi değiştirmez")
        XCTAssertFalse(PomodoroAlerts.touches(["water_log", "spotify_play"]))
        XCTAssertFalse(PomodoroAlerts.touches([]))
        XCTAssertEqual(Set(PomodoroAlerts.ids), [PomodoroAlerts.workID, PomodoroAlerts.breakID])
    }
}
