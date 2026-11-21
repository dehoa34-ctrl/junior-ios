import XCTest
@testable import Junior

/// Pano "Düzelt" ve görünüm eşzamanlaması: yalnız saf mantık, ağ ve arayüz yok.
final class ClipboardFixTests: XCTestCase {
    func testTextIsNotCode() {
        XCTAssertFalse(ClipboardFix.looksLikeCode("Yarın toplantıya geç kalmayacağım, söz veriyorum."))
        XCTAssertFalse(ClipboardFix.looksLikeCode("Merhaba nasılsın"))
    }

    func testCodeIsDetected() {
        XCTAssertTrue(ClipboardFix.looksLikeCode("```swift\nlet a = 1\n```"))
        XCTAssertTrue(ClipboardFix.looksLikeCode("func topla(a: Int, b: Int) -> Int {\n    return a + b\n}"))
        XCTAssertTrue(ClipboardFix.looksLikeCode("const x = (a) => {\n  return a == 1\n}"))
    }

    func testPromptsDiffer() {
        let text = ClipboardFix.prompt(for: "bugun hava cok guzel")
        XCTAssertTrue(text.contains("yazım ve dilbilgisi"))
        XCTAssertTrue(text.hasSuffix("bugun hava cok guzel"))
        let code = ClipboardFix.prompt(for: "func a() {\n    retrun 1\n}")
        XCTAssertTrue(code.contains("koddaki hataları"))
        XCTAssertTrue(code.hasSuffix("}"))
    }

    func testPromptFitsMessageLimit() {
        let prompt = ClipboardFix.prompt(for: String(repeating: "x", count: 10_000))
        XCTAssertLessThanOrEqual(prompt.count, JuniorLimits.maxMessageChars)
    }

    func testFixIsOfferedOnlyForText() {
        let text = ClipboardAsk.options(for: "bugun hava cok guzel")
        XCTAssertEqual(text.last?.title, "Düzelt")
        XCTAssertEqual(text.last?.fix, true)
        XCTAssertEqual(text.filter(\.fix).count, 1)
        XCTAssertTrue(ClipboardAsk.options(for: "https://example.com").allSatisfy { !$0.fix })
    }

    func testCleanStripsSingleFence() {
        XCTAssertEqual(ClipboardFix.clean("  merhaba dünya \n"), "merhaba dünya")
        XCTAssertEqual(ClipboardFix.clean("```swift\nlet a = 1\n```"), "let a = 1")
        XCTAssertEqual(ClipboardFix.clean("```\nsatır 1\nsatır 2\n```\n"), "satır 1\nsatır 2")
        // Çit yoksa dokunulmaz.
        XCTAssertEqual(ClipboardFix.clean("a ``` b"), "a ``` b")
    }

    func testParseReply() throws {
        let ok = try JSONSerialization.data(withJSONObject: ["reply": "Düzeltilmiş metin.\n", "provider": "x"])
        XCTAssertEqual(ClipboardFix.parseReply(ok), "Düzeltilmiş metin.")
        XCTAssertNil(ClipboardFix.parseReply(try JSONSerialization.data(withJSONObject: ["reply": "  "])))
        XCTAssertNil(ClipboardFix.parseReply(try JSONSerialization.data(withJSONObject: ["error": "x"])))
        XCTAssertNil(ClipboardFix.parseReply(Data("bozuk".utf8)))
    }
}

final class AppearanceSyncTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func testNormalizeHex() {
        XCTAssertEqual(AppearanceRecord.normalizeHex("#ABC"), "#aabbcc")
        XCTAssertEqual(AppearanceRecord.normalizeHex(" 7FDCFF "), "#7fdcff")
        XCTAssertNil(AppearanceRecord.normalizeHex(""))
        XCTAssertNil(AppearanceRecord.normalizeHex("#12345"))
        XCTAssertNil(AppearanceRecord.normalizeHex("kırmızı"))
        XCTAssertNil(AppearanceRecord.normalizeHex("#gggggg"))
    }

    func testHexRoundTrip() throws {
        let c = try XCTUnwrap(AppearanceRecord.components(hex: "#ff8000"))
        XCTAssertEqual(c.r, 1, accuracy: 0.001)
        XCTAssertEqual(c.g, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, 0, accuracy: 0.001)
        XCTAssertEqual(AppearanceRecord.hex(r: c.r, g: c.g, b: c.b), "#ff8000")
        XCTAssertEqual(AppearanceRecord.hex(r: 2, g: -1, b: 0.5), "#ff0080")
    }

    func testParseRecord() throws {
        let record = try XCTUnwrap(AppearanceRecord.parse(data([
            "appearance": ["accent": "#FF8800", "cat_face": true, "theme": "light", "updated_at": 1_794_000_000_123, "source": "phone"],
        ])))
        XCTAssertEqual(record, AppearanceRecord(accent: "#ff8800", catFace: true, theme: "light",
                                                updatedAt: 1_794_000_000_123, source: "phone"))
    }

    func testParseBadValuesFallBackToDefaults() throws {
        let record = try XCTUnwrap(AppearanceRecord.parse(data([
            "appearance": ["accent": "x", "cat_face": "evet", "theme": "mor", "updated_at": -5, "source": "tv"],
        ])))
        XCTAssertEqual(record, AppearanceRecord())
        XCTAssertNil(AppearanceRecord.parse(Data("[]".utf8)))
        XCTAssertNil(AppearanceRecord.parse(data(["x": 1])))
    }

    func testApplyOnlyNewerRecords() {
        let never = AppearanceRecord()
        XCTAssertFalse(AppearanceSyncLogic.shouldApply(server: never, known: 0))
        var server = AppearanceRecord(accent: "#112233")
        server.updatedAt = 500
        XCTAssertTrue(AppearanceSyncLogic.shouldApply(server: server, known: 0))
        XCTAssertTrue(AppearanceSyncLogic.shouldApply(server: server, known: 499))
        XCTAssertFalse(AppearanceSyncLogic.shouldApply(server: server, known: 500))
        XCTAssertFalse(AppearanceSyncLogic.shouldApply(server: server, known: 900))
    }

    func testPushBodySendsOnlyChangedFields() {
        let now = Date(timeIntervalSince1970: 1_794_000_000.5)
        let accentOnly = AppearanceSyncLogic.pushBody(accent: "#ABC", catFace: nil, now: now)
        XCTAssertEqual(accentOnly["accent"] as? String, "#aabbcc")
        XCTAssertNil(accentOnly["cat_face"])
        XCTAssertNil(accentOnly["theme"])  // masaüstünün teması ezilmez
        XCTAssertEqual(accentOnly["source"] as? String, "phone")
        XCTAssertEqual(accentOnly["updated_at"] as? Int64, 1_794_000_000_500)
        let face = AppearanceSyncLogic.pushBody(accent: nil, catFace: true, now: now)
        XCTAssertEqual(face["cat_face"] as? Bool, true)
        XCTAssertNil(face["accent"])
        // Varsayılan renge dönüş boş dizeyle yazılır.
        XCTAssertEqual(AppearanceSyncLogic.pushBody(accent: "", catFace: nil, now: now)["accent"] as? String, "")
    }

    func testAccentOnlyWriteKeepsExpressiveCatBeforeFirstSync() {
        XCTAssertTrue(AppearanceSyncLogic.baseCatFace(synced: false, catFace: false))
        XCTAssertFalse(AppearanceSyncLogic.baseCatFace(synced: true, catFace: false))
        XCTAssertTrue(AppearanceSyncLogic.baseCatFace(synced: true, catFace: true))
    }

    func testPendingIsRestoredAfterFailedPush() {
        var pending = AppearancePending(accent: "#112233", catFace: nil)
        let sent = pending
        pending = AppearancePending()
        pending.restore(sent)
        XCTAssertEqual(pending, sent)
        // Bu arada girilen daha yeni değer geri konanı ezmez.
        var newer = AppearancePending(accent: "#445566", catFace: nil)
        newer.restore(AppearancePending(accent: "#112233", catFace: true))
        XCTAssertEqual(newer, AppearancePending(accent: "#445566", catFace: true))
        XCTAssertTrue(AppearancePending().isEmpty)
        XCTAssertFalse(sent.isEmpty)
    }

    func testUnsetServerFieldsKeepLocalValues() throws {
        let record = try XCTUnwrap(AppearanceRecord.parse(data([
            "appearance": ["accent": "#ff0000", "cat_face": false, "theme": "dark", "updated_at": 500,
                           "source": "phone", "unset": ["cat_face", "theme", "bilinmez"]],
        ])))
        XCTAssertEqual(record.unset, ["cat_face", "theme"])
        let resolved = AppearanceSyncLogic.resolved(server: record, accent: "#00ff00", catFace: true)
        XCTAssertEqual(resolved.accent, "#ff0000")
        XCTAssertTrue(resolved.catFace)
        let unsetAccent = AppearanceSyncLogic.resolved(server: AppearanceRecord(unset: ["accent"]), accent: "#00ff00", catFace: true)
        XCTAssertEqual(unsetAccent.accent, "#00ff00")
    }

    func testDarkAccentIsLightenedToStayReadable() {
        let dark = AppearanceSyncLogic.readable(r: 0, g: 0, b: 0.1)
        XCTAssertGreaterThanOrEqual(AppearanceSyncLogic.luminance(r: dark.r, g: dark.g, b: dark.b), AppearanceSyncLogic.minLuminance)
        // Zaten parlak renk değişmez.
        let bright = AppearanceSyncLogic.readable(r: 0.36, g: 0.84, b: 1.0)
        XCTAssertEqual(bright.r, 0.36, accuracy: 0.0001)
        XCTAssertEqual(bright.g, 0.84, accuracy: 0.0001)
    }

    @MainActor
    func testModelStartsExpressiveAndFollowsSettingsAfterSync() {
        let suite = "appearance-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppearanceModel(defaults: defaults)
        XCTAssertTrue(fresh.expressiveCat)  // eşzamanlama olmadıysa eski davranış
        XCTAssertEqual(fresh.accent, "")
        defaults.set(true, forKey: "appearance.synced")
        defaults.set("#ff8800", forKey: "appearance.accent")
        let synced = AppearanceModel(defaults: defaults)
        XCTAssertFalse(synced.expressiveCat)  // masaüstünde kedi yüzü kapalı
        XCTAssertEqual(synced.accent, "#ff8800")
    }
}
