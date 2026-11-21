import XCTest
@testable import Junior

/// Haber ver (sunucu notify.py): telefon kuyruğundaki "notify" olayları "Haber" kategorisinde gösterilir.
/// Ağ, bildirim merkezi ve UIKit kullanılmaz.
final class NotifyCategoryTests: XCTestCase {
    func testServerNotifyCategoryMapsToNews() {
        XCTAssertEqual(NotificationCategory.from(server: "notify", builtin: nil, kind: "note"), .notify)
        XCTAssertEqual(NotificationCategory.notify.title, "Haber")
        XCTAssertFalse(NotificationCategory.notify.symbol.isEmpty)
        XCTAssertTrue(NotificationCategory.allCases.contains(.notify))
    }

    func testNotifyNoteParsesAndHasItsOwnTitle() {
        let json = """
        {"tasks": [{"id": "n1", "kind": "note", "text": "Görev bitti: lastik araştırması.", "category": "notify",
                    "notify_type": "task_done"},
                   {"id": "n2", "kind": "note", "text": "Sunum 15:00'te"}]}
        """
        let tasks = PhoneTask.parse(Data(json.utf8))
        XCTAssertEqual(tasks.map(\.notificationCategory), [.notify, nil])
        XCTAssertEqual(tasks[0].notification.title, "Junior haber veriyor")
        XCTAssertEqual(tasks[0].notification.body, "Görev bitti: lastik araştırması.")
        XCTAssertEqual(tasks[1].notification.title, "Bilgisayardan not")
    }

    func testNotifyIsNotSilencedTwiceInQuietHours() {
        // Sessiz saati sunucu uygular (acil türler deler); telefon ikinci kez susturmaz.
        let all = Set(NotificationCategory.allCases)
        XCTAssertFalse(NotificationCategory.notify.silencedInQuietHours)
        XCTAssertTrue(NotificationGate.shouldDeliver(.notify, enabled: all, quietNow: true, userScheduled: false))
        XCTAssertFalse(NotificationGate.shouldDeliver(.notify, enabled: all.subtracting([.notify]),
                                                      quietNow: false, userScheduled: false))
    }
}
