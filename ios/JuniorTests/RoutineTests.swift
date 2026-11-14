import XCTest
@testable import Junior

/// Rutinler ekranının saf parçaları: sunucu yanıtını okuma ve Türkçe anlatım. Ağ yok.
final class RoutineTests: XCTestCase {
    private func listing(_ json: String) -> RoutineListing? {
        RoutineListing.parse(Data(json.utf8))
    }

    func testParsesServerListingWithQuietHours() {
        let parsed = listing("""
        {"routines": [
          {"id": "a1b2c3", "name": "Sabah özeti", "enabled": true, "speak": true, "unprompted": false, "builtin": null,
           "when": {"type": "weekly", "at": "08:00", "days": [1,2,3,4,5]},
           "what": {"type": "do", "text": "Hava durumunu söyle"}, "last_fired": 0, "next": 1794812400},
          {"id": "q9", "name": "Yoklama", "enabled": false, "speak": false, "unprompted": true, "builtin": "checkin",
           "when": {"type": "idle", "idle_min": 90}, "what": {"type": "say", "text": "Buradayım"}, "next": null}
        ], "quiet": {"enabled": true, "from": "23:00", "to": "07:00"}, "quiet_now": true, "broken": false}
        """)
        XCTAssertEqual(parsed?.routines.count, 2)
        let first = parsed?.routines.first
        XCTAssertEqual(first?.id, "a1b2c3")
        XCTAssertEqual(first?.what, .do)
        XCTAssertEqual(first?.whatLabel, "Yap")
        XCTAssertEqual(first?.whenText, "08:00, hafta içi")
        XCTAssertEqual(first?.next, Date(timeIntervalSince1970: 1_794_812_400))
        let second = parsed?.routines.last
        XCTAssertEqual(second?.enabled, false)
        XCTAssertEqual(second?.unprompted, true)
        XCTAssertEqual(second?.builtin, "checkin")
        XCTAssertEqual(second?.whenText, "90 dakika sessizlikten sonra")
        XCTAssertNil(second?.next)
        XCTAssertEqual(parsed?.quiet, QuietHours(enabled: true, from: "23:00", to: "07:00"))
        XCTAssertEqual(parsed?.quietNow, true)
        XCTAssertEqual(parsed?.broken, false)
    }

    func testSkipsMalformedRoutinesAndDefaultsQuiet() {
        let parsed = listing("""
        {"routines": [{"id": "", "when": {"type": "weekly"}, "what": {"type": "say", "text": "x"}},
                      {"id": "ok1", "when": {"type": "startup"}, "what": {"type": "dance", "text": "x"}},
                      {"id": "ok2", "when": {"type": "startup"}, "what": {"type": "say", "text": "Günaydın"}}]}
        """)
        XCTAssertEqual(parsed?.routines.map(\.id), ["ok2"])
        XCTAssertEqual(parsed?.routines.first?.name, "Günaydın")
        XCTAssertEqual(parsed?.quiet, QuietHours(enabled: false, from: "23:00", to: "07:00"))
        XCTAssertNil(listing("bozuk"))
    }

    func testDescribesEveryScheduleKind() {
        func when(_ json: String) -> String? {
            listing("{\"routines\": [{\"id\": \"r1\", \"when\": \(json), \"what\": {\"type\": \"say\", \"text\": \"x\"}}]}")?.routines.first?.whenText
        }
        XCTAssertEqual(when("{\"type\": \"once\", \"at\": \"09:30\", \"date\": \"2026-11-20\"}"), "2026-11-20 09:30 (bir kez)")
        XCTAssertEqual(when("{\"type\": \"weekly\", \"at\": \"22:00\", \"days\": []}"), "22:00, her gün")
        XCTAssertEqual(when("{\"type\": \"weekly\", \"at\": \"10:00\", \"days\": [0, 6]}"), "10:00, hafta sonu")
        XCTAssertEqual(when("{\"type\": \"weekly\", \"at\": \"10:00\", \"days\": [1, 5]}"), "10:00, Pazartesi, Cuma")
        XCTAssertEqual(when("{\"type\": \"monthly\", \"at\": \"17:00\", \"day\": 1}"), "her ayın 1. günü 17:00")
        XCTAssertEqual(when("{\"type\": \"interval\", \"every_min\": 90, \"from\": \"09:00\", \"to\": \"18:00\"}"), "09:00–18:00 arası 90 dakikada bir")
        XCTAssertEqual(when("{\"type\": \"startup\"}"), "Bilgisayardaki Junior açılırken")
    }

    func testQuietHourTimeRoundTrip() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let date = QuietHours.date(from: "23:05", calendar: calendar)
        XCTAssertNotNil(date)
        XCTAssertEqual(QuietHours.text(from: date!, calendar: calendar), "23:05")
        XCTAssertNil(QuietHours.date(from: "25:00", calendar: calendar))
        XCTAssertNil(QuietHours.date(from: "yedi", calendar: calendar))
    }
}
