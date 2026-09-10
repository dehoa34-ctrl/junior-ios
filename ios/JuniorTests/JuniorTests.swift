import XCTest
import UIKit
@testable import Junior

/// Simulatorde calisir. Ag, mikrofon, kamera veya Claude hesabi kullanmaz.
final class ConfigURLTests: XCTestCase {
    @MainActor
    private func config(_ base: String) -> Config {
        let config = Config()
        config.baseURL = base
        return config
    }

    @MainActor
    func testBuildsPathForBareHost() {
        XCTAssertEqual(config("https://junior.example.com").url(path: "/v1/command")?.absoluteString,
                       "https://junior.example.com/v1/command")
    }

    @MainActor
    func testTrailingSlashDoesNotDoubleUp() {
        XCTAssertEqual(config("https://junior.example.com/").url(path: "/v1/command")?.absoluteString,
                       "https://junior.example.com/v1/command")
    }

    @MainActor
    func testStripsQueryAndFragmentFromBase() {
        // Kullanici adresi tarayicidan kopyalarsa artik parametre gelebilir.
        let url = config("https://junior.example.com/?utm=1#x").url(path: "/health")
        XCTAssertEqual(url?.absoluteString, "https://junior.example.com/health")
    }

    @MainActor
    func testRejectsUnsupportedSchemesAndGarbage() {
        for base in ["ftp://junior.example.com", "junior.example.com", "", "   ", "https://"] {
            XCTAssertNil(config(base).url(path: "/health"), "kabul edilmemeliydi: \(base)")
        }
    }

    @MainActor
    func testWhitespaceAroundAddressIsTolerated() {
        XCTAssertEqual(config("  https://junior.example.com  ").url(path: "/health")?.absoluteString,
                       "https://junior.example.com/health")
    }
}

final class HistoryPairingTests: XCTestCase {
    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    func testBuildsAlternatingPairs() {
        let history = [message(.user, "a"), message(.assistant, "b"),
                       message(.user, "c"), message(.assistant, "d")]
        let pairs = JuniorClient.completedPairs(from: history)
        XCTAssertEqual(pairs.count, 4)
        XCTAssertEqual(pairs.map { $0["role"] }, ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(pairs.first?["content"], "a")
    }

    func testDropsTrailingUnansweredMessage() {
        // Sunucu tek sayida history'yi 400 ile reddediyor.
        let history = [message(.user, "a"), message(.assistant, "b"), message(.user, "yanitsiz")]
        let pairs = JuniorClient.completedPairs(from: history)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.last?["content"], "b")
    }

    func testResultIsAlwaysEvenAndWithinServerLimit() {
        let history = (0..<40).map { message($0 % 2 == 0 ? .user : .assistant, "m\($0)") }
        let pairs = JuniorClient.completedPairs(from: history)
        XCTAssertEqual(pairs.count % 2, 0)
        XCTAssertLessThanOrEqual(pairs.count, JuniorLimits.maxHistoryMessages)
    }

    func testKeepsMostRecentTurns() {
        let history = (0..<40).map { message($0 % 2 == 0 ? .user : .assistant, "m\($0)") }
        XCTAssertEqual(JuniorClient.completedPairs(from: history).last?["content"], "m39")
    }

    func testEmptyHistoryProducesNothing() {
        XCTAssertTrue(JuniorClient.completedPairs(from: []).isEmpty)
        XCTAssertTrue(JuniorClient.completedPairs(from: [message(.user, "tek")]).isEmpty)
    }
}

final class CommandStatusTests: XCTestCase {
    func testMapsServerStatuses() {
        XCTAssertEqual(CommandStatus(raw: nil), .ok)
        XCTAssertEqual(CommandStatus(raw: "dispatched"), .ok)
        XCTAssertEqual(CommandStatus(raw: "needs_target"), .needsTarget)
        XCTAssertEqual(CommandStatus(raw: "needs_image"), .needsImage)
        XCTAssertEqual(CommandStatus(raw: "setup_required"), .setupRequired)
        XCTAssertEqual(CommandStatus(raw: "outcome_unknown"), .outcomeUnknown)
    }

    func testUnknownStatusIsPreservedNotSwallowed() {
        // Sunucuya yeni bir durum eklenirse uygulama onu sessizce "ok" saymamali.
        XCTAssertEqual(CommandStatus(raw: "yeni_durum"), .other("yeni_durum"))
    }
}

final class ImagePreparationTests: XCTestCase {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
    }

    func testLargeImageIsBroughtUnderServerLimit() {
        let data = image(width: 4000, height: 3000).juniorJPEGData()
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data!.count, JuniorLimits.maxImageBytes)
    }

    func testOutputIsJPEG() {
        let data = image(width: 800, height: 600).juniorJPEGData()
        // JPEG dosya imzasi: FF D8 FF
        XCTAssertEqual(Array(data!.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testSmallImageSurvives() {
        XCTAssertNotNil(image(width: 40, height: 40).juniorJPEGData())
    }
}

final class ConversationArchiveTests: XCTestCase {
    private var archive: ConversationArchive!

    override func setUp() {
        super.setUp()
        archive = ConversationArchive(fileName: "test-\(UUID().uuidString).json")
        archive.clear()
    }

    override func tearDown() {
        archive.clear()
        super.tearDown()
    }

    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    func testEmptyArchiveLoadsNothing() {
        XCTAssertTrue(archive.load().isEmpty)
    }

    func testRoundTripPreservesRolesAndOrder() {
        let messages = [message(.user, "merhaba"), message(.assistant, "selam"),
                        message(.user, "Şımarık çal"), message(.assistant, "gönderdim")]
        archive.save(messages)
        let loaded = archive.load()
        XCTAssertEqual(loaded.map(\.text), messages.map(\.text))
        XCTAssertEqual(loaded.map(\.role), messages.map(\.role))
    }

    func testKeepsOnlyTheMostRecentMessages() {
        let messages = (0..<200).map { message($0 % 2 == 0 ? .user : .assistant, "m\($0)") }
        archive.save(messages)
        let loaded = archive.load()
        XCTAssertEqual(loaded.count, ConversationArchive.maxStored)
        XCTAssertEqual(loaded.last?.text, "m199")
    }

    func testClearRemovesEverything() {
        archive.save([message(.user, "silinecek")])
        archive.clear()
        XCTAssertTrue(archive.load().isEmpty)
    }

    func testCorruptFileIsIgnoredInsteadOfCrashing() {
        archive.save([message(.user, "a"), message(.assistant, "b")])
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Dosya bozulursa uygulama acilmamazlik etmemeli, sadece bos baslamali.
        let target = base.appendingPathComponent("bozuk-\(UUID().uuidString).json")
        try? Data("{bu json degil".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let broken = ConversationArchive(fileName: target.lastPathComponent)
        XCTAssertTrue(broken.load().isEmpty)
    }
}

final class WakeWordMatchingTests: XCTestCase {
    private func detects(_ transcript: String) -> Bool {
        WakeWord.matches(transcript)
    }

    func testFoldingHandlesTurkishCharacters() {
        XCTAssertEqual(WakeWord.fold("HEY JÜNİOR"), "hey junior")
        XCTAssertEqual(WakeWord.fold("Şımarık Çğıöşü"), "simarik cgiosu")
    }

    func testCommonSpokenFormsTrigger() {
        // Konusma tanima ayni ifadeyi farkli yazabiliyor; hepsi tetiklemeli.
        for text in ["Hey Junior", "hey junior", "HEY JÜNİOR", "Hey Jünior",
                     "şey hey junior bak", "Junior"] {
            XCTAssertTrue(detects(text), "tetiklemeliydi: \(text)")
        }
    }

    func testUnrelatedSpeechDoesNotTrigger() {
        // "junyor" bilerek tetikler: Turkce tanima "junior"i coju zaman boyle
        // yazar. Gercekten ilgisiz olanlar burada.
        for text in ["bugün hava nasıl", "müziği duraklat", "junio", "juno kim"] {
            XCTAssertFalse(detects(text), "tetiklememeliydi: \(text)")
        }
    }

    @MainActor
    func testServiceStartsIdle() {
        let service = WakeWordService()
        XCTAssertFalse(service.running)
        XCTAssertNil(service.message)
    }
}

final class ConversationControlTests: XCTestCase {
    func testStopPhrasesEndTheConversation() {
        for text in ["kapat", "Kapat", "dur", "yeter", "bitir", "tamamdır",
                     "sağol", "teşekkürler", "görüşürüz", "boşver",
                     "tamam kapat", "yeter artık", "hadi kapat", "teşekkür ederim"] {
            XCTAssertTrue(ConversationControl.wantsToStop(text), "bitirmeliydi: \(text)")
        }
    }

    func testCommandsContainingStopWordsDoNotEnd() {
        // "Bilgisayarda videoyu kapat" bir komut; sohbeti bitirmemeli.
        // "isik" ekli halde "isigi" oluyor; kara liste bunu iskalayip
        // "isigi kapat" ile sohbeti bitiriyordu.
        for text in ["bilgisayarda videoyu kapat", "müziği durdur", "şarkıyı kapat",
                     "ışığı kapat", "telefonda spotify'ı kapat", "sesi kapat"] {
            XCTAssertFalse(ConversationControl.wantsToStop(text), "bitirmemeliydi: \(text)")
        }
    }

    func testOrdinaryQuestionsDoNotEnd() {
        for text in ["bugün hava nasıl", "bu gördüğüm ne",
                     "bana bir şey anlat çünkü canım sıkıldı yeter artık bu sessizlik"] {
            XCTAssertFalse(ConversationControl.wantsToStop(text), "bitirmemeliydi: \(text)")
        }
    }
}

final class VisionIntentTests: XCTestCase {
    func testLooksAtWhatTheUserSees() {
        // Gozluk takiliyken en sik kurulan cumleler; hepsi kare istemeli.
        for text in ["bu gördüğüm ne", "bu ne", "şu ne", "önümde ne var",
                     "bunu oku", "burada ne yazıyor", "şuna bak",
                     "bu hangi marka", "bu yemek nedir", "ne görüyorsun"] {
            XCTAssertTrue(VisionIntent.needsPhoto(text), "kare istemeliydi: \(text)")
        }
    }

    func testWordQuestionsAreNotVisual() {
        // "bu ne demek" icinde "bu ne" geciyor ama kelime sorusu; kare istememeli.
        for text in ["bu ne demek", "bu ne anlama geliyor", "ne zaman gelecek",
                     "ne haber", "bugün hava nasıl", "müziği duraklat",
                     "bilgisayarda videoyu durdur"] {
            XCTAssertFalse(VisionIntent.needsPhoto(text), "kare istememeliydi: \(text)")
        }
    }

    func testTurkishCharactersDoNotBreakDetection() {
        XCTAssertTrue(VisionIntent.needsPhoto("BU GÖRDÜĞÜM NE"))
        XCTAssertTrue(VisionIntent.needsPhoto("Şuna bak bakalım"))
    }
}

final class AudioRouteLabelTests: XCTestCase {
    func testBuiltInMicShowsFriendlyName() {
        let description = AudioRoute.Description(inputName: "iPhone Microphone", outputName: "Speaker",
                                                 isBluetoothInput: false, isBuiltInInput: true)
        XCTAssertEqual(description.label, "iPhone mikrofonu")
    }

    func testBluetoothInputShowsDeviceName() {
        // Gozluk baglandiginda kullanici burada gozlugun adini gormeli.
        let description = AudioRoute.Description(inputName: "Ray-Ban Meta", outputName: "Ray-Ban Meta",
                                                 isBluetoothInput: true, isBuiltInInput: false)
        XCTAssertEqual(description.label, "Ray-Ban Meta")
    }
}
