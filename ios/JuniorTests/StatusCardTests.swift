import XCTest
@testable import Junior

/// Durum kartı (GET /v1/status/pc) ve Brifing / Donanım uyarısı bildirim kategorileri.
/// Ağ, bildirim merkezi ve arayüz kullanılmaz; saat enjekte edilir.
final class StatusCardTests: XCTestCase {
    private let json = """
    {"tasks_open": 2, "routines_open": 5, "now": 1800000100,
     "last_report": {"id": "a1", "title": "Lastik fiyatlarını araştır", "summary": "Dört lastik karşılaştırıldı.",
                     "finished": 1800000000},
     "pc": {"reachable": true, "last_seen": 1800000090, "age": 10, "stale": false, "message": "",
            "cpu": 37.5, "ram_pct": 61.2, "ram_used": 9800000000, "ram_total": 16000000000, "temp": 58,
            "gpu": {"name": "NVIDIA GeForce GTX 1650", "temp": 49, "util": 12}}}
    """

    private func parsed() throws -> PcStatus {
        try XCTUnwrap(PcStatus.parse(Data(json.utf8)))
    }

    func testParsesCountsReportAndMachineValues() throws {
        let status = try parsed()
        XCTAssertEqual(status.tasksOpen, 2)
        XCTAssertEqual(status.routinesOpen, 5)
        XCTAssertEqual(status.report?.title, "Lastik fiyatlarını araştır")
        XCTAssertEqual(status.report?.finished, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(status.cpu, 37.5)
        XCTAssertEqual(status.ramPercent, 61.2)
        XCTAssertEqual(status.temp, 58)
        XCTAssertEqual(status.gpu, PcStatus.Gpu(name: "NVIDIA GeForce GTX 1650", temp: 49, util: 12))
        XCTAssertTrue(status.reachable)
    }

    func testMissingValuesStayNilAndBrokenJSONIsRejected() throws {
        let sparse = """
        {"tasks_open": 0, "routines_open": 0, "last_report": null, "now": 5,
         "pc": {"reachable": false, "last_seen": null, "cpu": null, "gpu": null, "temp": true}}
        """
        let status = try XCTUnwrap(PcStatus.parse(Data(sparse.utf8)))
        XCTAssertNil(status.report)
        XCTAssertNil(status.lastSeen)
        XCTAssertNil(status.cpu)
        XCTAssertNil(status.gpu)
        XCTAssertNil(status.temp, "Mantıksal değer sayı sayılmaz")
        XCTAssertFalse(status.reachable)
        XCTAssertNil(PcStatus.parse(Data("[]".utf8)))
        XCTAssertNil(PcStatus.parse(Data("{\"tasks_open\": 1}".utf8)))
    }

    func testStalenessUsesServerClockPlusElapsedPhoneTime() throws {
        let status = try parsed()
        let fetched = Date(timeIntervalSince1970: 5_000)   // telefon saati sunucudan bağımsız
        XCTAssertEqual(status.age(now: fetched, fetchedAt: fetched), 10)
        XCTAssertEqual(status.age(now: fetched.addingTimeInterval(30), fetchedAt: fetched), 40)
        XCTAssertTrue(status.isReachable(now: fetched.addingTimeInterval(50), fetchedAt: fetched))
        XCTAssertFalse(status.isReachable(now: fetched.addingTimeInterval(51), fetchedAt: fetched))
        // Sunucu "ulaşılamıyor" diyorsa taze görünse bile ulaşılabilir sayılmaz.
        var down = status
        down.reachable = false
        XCTAssertFalse(down.isReachable(now: fetched, fetchedAt: fetched))
    }

    func testReachabilityTextsAreHonest() throws {
        let fetched = Date(timeIntervalSince1970: 5_000)
        let status = try parsed()
        XCTAssertEqual(StatusFormat.reachability(status, now: fetched, fetchedAt: fetched).text, "Bilgisayar yanıt veriyor")
        let late = StatusFormat.reachability(status, now: fetched.addingTimeInterval(170), fetchedAt: fetched)
        XCTAssertFalse(late.ok)
        XCTAssertEqual(late.text, "Bilgisayar yanıt vermiyor · son görülme 3 dk önce")
        var never = status
        never.lastSeen = nil
        never.reachable = false
        XCTAssertEqual(StatusFormat.reachability(never, now: fetched, fetchedAt: fetched).text,
                       "Bilgisayardan henüz bilgi gelmedi")
    }

    func testFormatting() {
        XCTAssertEqual(StatusFormat.percent(37.6), "%38")
        XCTAssertEqual(StatusFormat.percent(nil), "—")
        XCTAssertEqual(StatusFormat.temperature(58.4), "58 °C")
        XCTAssertEqual(StatusFormat.temperature(nil), "—")
        XCTAssertEqual(StatusFormat.lastSeen(age: nil), "hiç görülmedi")
        XCTAssertEqual(StatusFormat.lastSeen(age: 3), "az önce")
        XCTAssertEqual(StatusFormat.lastSeen(age: 20), "20 sn önce")
        XCTAssertEqual(StatusFormat.lastSeen(age: 180), "3 dk önce")
        XCTAssertEqual(StatusFormat.lastSeen(age: 7_300), "2 sa önce")
        XCTAssertEqual(StatusFormat.lastSeen(age: 200_000), "2 gün önce")
        XCTAssertEqual(StatusFormat.gpuLine(PcStatus.Gpu(name: "X", temp: 49, util: 12)), "%12 kullanım · 49 °C")
        XCTAssertEqual(StatusFormat.gpuLine(PcStatus.Gpu(name: "X", temp: nil, util: nil)), "Ekran kartı okunamıyor")
        XCTAssertEqual(StatusFormat.gpuLine(nil), "Ekran kartı okunamıyor")
    }

    func testLevels() {
        XCTAssertEqual(StatusFormat.load(40), .normal)
        XCTAssertEqual(StatusFormat.load(88), .warm)
        XCTAssertEqual(StatusFormat.load(97), .hot)
        XCTAssertEqual(StatusFormat.load(nil), .unknown)
        XCTAssertEqual(StatusFormat.heat(79.9), .normal)
        XCTAssertEqual(StatusFormat.heat(80), .warm)
        XCTAssertEqual(StatusFormat.heat(91), .hot)
    }
}

final class BriefingHardwareCategoryTests: XCTestCase {
    func testServerNotesMapToTheNewCategories() {
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: "briefing", kind: "note"), .briefing)
        XCTAssertEqual(NotificationCategory.from(server: "notify", builtin: nil, kind: "note", notifyType: "hardware_alert"), .hardware)
        // Öbür Haber ver türleri "Haber" kalır; yoklama ve izleme eskisi gibi.
        XCTAssertEqual(NotificationCategory.from(server: "notify", builtin: nil, kind: "note", notifyType: "task_done"), .notify)
        XCTAssertEqual(NotificationCategory.from(server: "notify", builtin: nil, kind: "note"), .notify)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: "checkin", kind: "note"), .checkin)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: nil, kind: "note"), .routine)
        // Donanım türü yalnız Haber ver kategorisinde sayılır.
        XCTAssertEqual(NotificationCategory.from(server: "task", builtin: nil, kind: "note", notifyType: "hardware_alert"), .task)
    }

    func testPhoneTaskParsesTypeAndTitles() {
        let json = """
        {"tasks": [{"id": "h1", "kind": "note", "text": "İşlemci yüzde 97.", "category": "notify", "notify_type": "hardware_alert"},
                   {"id": "b1", "kind": "note", "text": "Günaydın, bugün güneşli.", "category": "routine", "builtin": "briefing"}]}
        """
        let tasks = PhoneTask.parse(Data(json.utf8))
        XCTAssertEqual(tasks.map(\.notificationCategory), [.hardware, .briefing])
        XCTAssertEqual(tasks[0].notification.title, "Donanım uyarısı")
        XCTAssertEqual(tasks[1].notification.title, "Açılış brifingi")
    }

    func testEachCategoryIsTogglableOnItsOwn() throws {
        let suite = "junior.test.statuscard"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NotificationPreferences.isEnabled(.briefing, defaults: defaults))
        XCTAssertTrue(NotificationPreferences.isEnabled(.hardware, defaults: defaults))
        NotificationPreferences.set(.hardware, enabled: false, defaults: defaults)
        XCTAssertFalse(NotificationPreferences.isEnabled(.hardware, defaults: defaults))
        XCTAssertTrue(NotificationPreferences.isEnabled(.briefing, defaults: defaults))
        XCTAssertTrue(NotificationPreferences.isEnabled(.notify, defaults: defaults))
        let enabled = NotificationPreferences.enabledSet(defaults: defaults)
        XCTAssertFalse(NotificationGate.shouldDeliver(.hardware, enabled: enabled, quietNow: false, userScheduled: false))
        XCTAssertTrue(NotificationGate.shouldDeliver(.briefing, enabled: enabled, quietNow: true, userScheduled: false))
        XCTAssertNotEqual(NotificationCategory.briefing.title, NotificationCategory.hardware.title)
        XCTAssertFalse(NotificationCategory.hardware.symbol.isEmpty)
    }
}
