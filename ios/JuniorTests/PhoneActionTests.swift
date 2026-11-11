import XCTest
@testable import Junior

/// Telefon eylemlerinin saf parçaları: sunucu sözleşmesini çözme, rehber eşleme,
/// numara düzeni, uygulama adları. EventKit/UIKit kullanmaz.
final class PhoneActionParseTests: XCTestCase {
    private func parse(_ name: String, _ arguments: [String: Any]) -> PhoneAction? {
        PhoneAction.parse(["name": name, "arguments": arguments])
    }

    func testReminderWithAndWithoutDue() throws {
        let timed = try XCTUnwrap(parse("reminder", ["title": "annemi aramak", "due": "2026-11-12T09:00:00", "due_epoch": 1]))
        guard case .reminder(let title, let due) = timed else { return XCTFail("hatırlatıcı bekleniyordu") }
        XCTAssertEqual(title, "annemi aramak")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(due))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 12, 9, 0])

        let undated = try XCTUnwrap(parse("reminder", ["title": "süt al", "due": NSNull()]))
        XCTAssertEqual(undated, .reminder(title: "süt al", due: nil))
        XCTAssertNil(parse("reminder", ["title": "   "]))
    }

    func testRelativeReminderUsesInSeconds() throws {
        let action = try XCTUnwrap(parse("reminder", ["title": "su iç", "due": "2020-01-01T00:00:00", "in_seconds": 600]))
        guard case .reminder(_, let due) = action else { return XCTFail("hatırlatıcı bekleniyordu") }
        XCTAssertEqual(try XCTUnwrap(due).timeIntervalSinceNow, 600, accuracy: 5)
    }

    func testEpochIsUsedWhenLocalStringMissing() throws {
        let action = try XCTUnwrap(parse("reminder", ["title": "x", "due_epoch": 1_800_000_000]))
        XCTAssertEqual(action, .reminder(title: "x", due: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testEventDefaultsToOneHourAndRejectsBackwardsRange() throws {
        let action = try XCTUnwrap(parse("event", ["title": "toplantı", "start": "2026-11-12T14:00:00"]))
        guard case .event(_, let start, let end) = action else { return XCTFail("etkinlik bekleniyordu") }
        XCTAssertEqual(end.timeIntervalSince(start), 3600, accuracy: 1)
        let explicit = try XCTUnwrap(parse("event", ["title": "x", "start": "2026-11-12T14:00:00", "duration_minutes": 30]))
        guard case .event(_, let s2, let e2) = explicit else { return XCTFail() }
        XCTAssertEqual(e2.timeIntervalSince(s2), 1800, accuracy: 1)
        XCTAssertNil(parse("event", ["title": "x", "start": "2026-11-12T14:00:00", "end": "2026-11-12T13:00:00"]))
        XCTAssertNil(parse("event", ["title": "x"]))
    }

    func testTimerBounds() throws {
        XCTAssertEqual(parse("timer", ["seconds": 600, "label": "çay"]), .timer(seconds: 600, label: "çay"))
        XCTAssertEqual(parse("timer", ["seconds": 45]), .timer(seconds: 45, label: nil))
        XCTAssertNil(parse("timer", ["seconds": 0]))
        XCTAssertNil(parse("timer", ["seconds": 86_401]))
        XCTAssertNil(parse("timer", [:]))
    }

    func testCallAndMessage() throws {
        XCTAssertEqual(parse("call", ["contact": "Ali"]), .call(contact: "Ali", number: nil))
        XCTAssertEqual(parse("call", ["number": "05321234567"]), .call(contact: nil, number: "05321234567"))
        XCTAssertNil(parse("call", [:]))
        XCTAssertEqual(parse("message", ["contact": "Ali", "text": "akşam gelirim", "channel": "whatsapp"]),
                       .message(contact: "Ali", number: nil, text: "akşam gelirim", channel: .whatsapp))
        XCTAssertEqual(parse("message", ["contact": "Ali", "text": "selam"]),
                       .message(contact: "Ali", number: nil, text: "selam", channel: .sms))
        XCTAssertNil(parse("message", ["contact": "Ali"]), "metinsiz mesaj olmaz")
    }

    func testAppTorchAndMusic() throws {
        XCTAssertEqual(parse("open_app", ["app": "spotify"]), .openApp("spotify"))
        XCTAssertEqual(parse("torch", ["on": true]), .torch(on: true))
        XCTAssertNil(parse("torch", [:]))
        XCTAssertEqual(parse("apple_music", ["action": "play", "query": "Tarkan"]), .appleMusic(.play, query: "Tarkan"))
        XCTAssertEqual(parse("apple_music", ["action": "pause", "query": "Tarkan"]), .appleMusic(.pause, query: nil))
        XCTAssertEqual(parse("spotify", ["action": "volume_up"]), .spotify(.volumeUp, query: nil, level: nil))
        XCTAssertEqual(parse("spotify", ["action": "play", "query": "Şımarık"]), .spotify(.play, query: "Şımarık", level: nil))
        XCTAssertNil(parse("spotify", ["action": "patla"]))
    }

    func testUnknownNameAndMissingNameAreRejected() {
        XCTAssertNil(parse("roket_firlat", [:]))
        XCTAssertNil(PhoneAction.parse(["arguments": [:]]))
    }

    func testForegroundRequirement() {
        XCTAssertTrue(PhoneAction.call(contact: "a", number: nil).needsForeground)
        XCTAssertTrue(PhoneAction.torch(on: true).needsForeground)
        XCTAssertTrue(PhoneAction.spotify(.play, query: nil, level: nil).needsForeground)
        XCTAssertFalse(PhoneAction.timer(seconds: 5, label: nil).needsForeground)
        XCTAssertFalse(PhoneAction.reminder(title: "x", due: nil).needsForeground)
        XCTAssertFalse(PhoneAction.appleMusic(.pause, query: nil).needsForeground)
    }

    func testPayloadRoundTripThroughNotification() throws {
        let payload: [String: Any] = ["name": "call", "arguments": ["contact": "Ali"]]
        let raw = try XCTUnwrap(PhoneActionPayload.encode(payload))
        let decoded = try XCTUnwrap(PhoneActionPayload.decode(raw))
        XCTAssertEqual(PhoneAction.parse(decoded), .call(contact: "Ali", number: nil))
    }

    func testDateParsingAcceptsOffsets() throws {
        let zulu = try XCTUnwrap(PhoneActionDates.parse("2026-11-12T06:00:00Z"))
        let offset = try XCTUnwrap(PhoneActionDates.parse("2026-11-12T09:00:00+03:00"))
        XCTAssertEqual(zulu, offset)
        XCTAssertNil(PhoneActionDates.parse("yarın sabah"))
    }
}

final class ContactMatchingTests: XCTestCase {
    private func entry(_ name: String, _ numbers: [(String, String)], nickname: String = "") -> ContactMatching.Entry {
        ContactMatching.Entry(name: name, nickname: nickname, numbers: numbers.map { (label: $0.0, number: $0.1) })
    }

    private lazy var book = [
        entry("Anne", [("mobile", "0532 111 22 33")], nickname: "Annem"),
        entry("Ali Yılmaz", [("home", "0212 000 00 00"), ("iPhone", "0533 444 55 66")]),
        entry("Ayşe Kaya", [("mobile", "0535 777 88 99")]),
        entry("Ali Demir", [("mobile", "0536 999 00 11")]),
        entry("Şükrü Aksoy", [("mobile", "0537 123 45 67")]),
    ]

    func testExactAndInflectedNames() {
        XCTAssertEqual(ContactMatching.best(for: "Ayşe", in: book)?.name, "Ayşe Kaya")
        XCTAssertEqual(ContactMatching.best(for: "Ayşe'yi", in: book)?.name, "Ayşe Kaya")
        XCTAssertEqual(ContactMatching.best(for: "sukru", in: book)?.name, "Şükrü Aksoy")
        // "annemi" → rehberde takma ad "Annem".
        XCTAssertEqual(ContactMatching.best(for: "annemi", in: book)?.name, "Anne")
    }

    func testAmbiguousNamesAreNotGuessed() {
        XCTAssertNil(ContactMatching.best(for: "Ali", in: book))
        if case .ambiguous(let hits) = ContactMatching.match(for: "Ali", in: book) {
            XCTAssertEqual(Set(hits.map(\.name)), ["Ali Yılmaz", "Ali Demir"])
        } else {
            XCTFail("belirsiz bekleniyordu")
        }
        XCTAssertEqual(ContactMatching.best(for: "Ali Demir", in: book)?.name, "Ali Demir")
    }

    func testUnknownNameFindsNothing() {
        XCTAssertEqual(ContactMatching.match(for: "Zeynep", in: book), .none)
        XCTAssertEqual(ContactMatching.match(for: "   ", in: book), .none)
    }

    func testPrefersMobileNumber() throws {
        let ali = try XCTUnwrap(ContactMatching.best(for: "Ali Yılmaz", in: book))
        XCTAssertEqual(ContactMatching.preferredNumber(ali), "0533 444 55 66")
    }

    func testNumberFormatting() {
        XCTAssertEqual(ContactMatching.dialable("0532 123-45 (67)"), "05321234567")
        XCTAssertEqual(ContactMatching.dialable("+90 532 123 45 67"), "+905321234567")
        XCTAssertEqual(ContactMatching.international("0532 123 45 67"), "905321234567")
        XCTAssertEqual(ContactMatching.international("+90 532 123 45 67"), "905321234567")
        XCTAssertEqual(ContactMatching.international("5321234567"), "905321234567")
        XCTAssertEqual(ContactMatching.international("0090 532 123 45 67"), "905321234567")
    }
}

final class PhoneAppCatalogTests: XCTestCase {
    func testKnownAppsAndInflections() {
        XCTAssertEqual(PhoneAppCatalog.lookup("spotify")?.url, "spotify://")
        XCTAssertEqual(PhoneAppCatalog.lookup("WhatsApp")?.display, "WhatsApp")
        XCTAssertEqual(PhoneAppCatalog.lookup("harita")?.url, "maps://")
        XCTAssertEqual(PhoneAppCatalog.lookup("Spotify'ı")?.display, "Spotify")
        XCTAssertEqual(PhoneAppCatalog.lookup("fotoğraflar")?.display, "Fotoğraflar")
        XCTAssertNil(PhoneAppCatalog.lookup("bilinmeyenuygulama"))
    }
}

final class PhoneActionTextTests: XCTestCase {
    @MainActor
    func testSpokenDurations() {
        XCTAssertEqual(PhoneActionService.spoken(seconds: 45), "45 saniye")
        XCTAssertEqual(PhoneActionService.spoken(seconds: 600), "10 dakika")
        XCTAssertEqual(PhoneActionService.spoken(seconds: 90), "1 dakika 30 saniye")
        XCTAssertEqual(PhoneActionService.spoken(seconds: 3600), "1 saat")
    }

    @MainActor
    func testSpotifyDeepLinkAndAppleFallbackMapping() {
        XCTAssertEqual(PhoneActionService.spotifySearchURL("Tarkan Şımarık"), "spotify:search:Tarkan%20%C5%9E%C4%B1mar%C4%B1k")
        XCTAssertNil(PhoneActionService.spotifySearchURL("   "))
        XCTAssertEqual(PhoneActionService.appleEquivalent(of: .resume), .play)
        XCTAssertEqual(PhoneActionService.appleEquivalent(of: .next), .next)
        XCTAssertNil(PhoneActionService.appleEquivalent(of: .volumeUp))
    }
}
