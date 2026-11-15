import XCTest
@testable import Junior

/// Hafıza ekranının saf parçaları: sunucu yanıtını okuma, tarih metni, arama. Ağ yok.
final class MemoryTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func testParsesNotesWithIdsAndLearnTime() {
        let parsed = MemoryNote.parseList(data([
            "notes": [
                ["id": "a1", "text": "Kahveyi sütsüz içerim", "at": 1_794_000_000],
                ["id": "b2", "text": "Kedimin adı Pamuk", "at": 0],
                ["id": "", "text": "kimliksiz"],
                ["id": "c3", "text": ""],
            ],
            "total": 7,
        ]))
        XCTAssertEqual(parsed?.notes.map(\.id), ["a1", "b2"])
        XCTAssertEqual(parsed?.total, 7)
        XCTAssertEqual(parsed?.notes.first?.learned, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertNil(parsed?.notes.last?.learned)
        XCTAssertEqual(parsed?.notes.last?.learnedText, "Ne zaman öğrenildiği bilinmiyor")
        XCTAssertNotEqual(parsed?.notes.first?.learnedText, "Ne zaman öğrenildiği bilinmiyor")
    }

    func testTotalFallsBackToCountAndBadPayloadIsNil() {
        let parsed = MemoryNote.parseList(data(["notes": [["id": "a1", "text": "x"]]]))
        XCTAssertEqual(parsed?.total, 1)
        XCTAssertNil(MemoryNote.parseList(Data("bozuk".utf8)))
        XCTAssertNil(MemoryNote.parseList(data(["total": 3])))
    }

    func testFilterIsTurkishCaseInsensitive() {
        let notes = [
            MemoryNote(id: "1", text: "IŞIK açık kalmasın", learned: nil),
            MemoryNote(id: "2", text: "İstanbul'da doğdum", learned: nil),
            MemoryNote(id: "3", text: "Kedimin adı Pamuk", learned: nil),
        ]
        XCTAssertEqual(MemoryNote.filter(notes, query: "ışık").map(\.id), ["1"])
        XCTAssertEqual(MemoryNote.filter(notes, query: "istanbul").map(\.id), ["2"])
        XCTAssertEqual(MemoryNote.filter(notes, query: "  PAMUK ").map(\.id), ["3"])
        XCTAssertEqual(MemoryNote.filter(notes, query: "").count, 3)
        XCTAssertTrue(MemoryNote.filter(notes, query: "yok").isEmpty)
    }
}
