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

final class PairingLinkTests: XCTestCase {
    private let token = "abcdefghijklmnopqrstuvwxyz_0123456789-ABCDEF"

    private func link(_ base: String, _ token: String) -> URL {
        var components = URLComponents(string: "junior://pair")!
        components.queryItems = [URLQueryItem(name: "u", value: base), URLQueryItem(name: "t", value: token)]
        return components.url!
    }

    @MainActor
    func testValidLinkIsParsed() {
        let request = Config.parsePairing(link("https://junior.example.com/", token))
        XCTAssertEqual(request?.baseURL, "https://junior.example.com")
        XCTAssertEqual(request?.token, token)
        XCTAssertEqual(request?.host, "junior.example.com")
    }

    @MainActor
    func testRejectsPlainHttpPathsAndBadTokens() {
        XCTAssertNil(Config.parsePairing(link("http://junior.example.com", token)))
        XCTAssertNil(Config.parsePairing(link("https://junior.example.com/baska", token)))
        XCTAssertNil(Config.parsePairing(link("https://junior.example.com", "kisa")))
        XCTAssertNil(Config.parsePairing(link("https://junior.example.com", token + " ")))
        XCTAssertNil(Config.parsePairing(URL(string: "junior://pair")!))
        XCTAssertNil(Config.parsePairing(URL(string: "junior://register?u=x")!))
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

    func testCommonMishearingsStillTrigger() {
        // Sunucu tanimasi "junior"i cesitli sekillerde yaziyor; hepsi
        // uyandirmali, yoksa kullanici konusuyor ama hicbir sey olmuyor.
        for text in ["junyor", "juniyor", "hey junyor", "hey jünior", "Jünior"] {
            XCTAssertTrue(detects(text), "tetiklemeliydi: \(text)")
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

final class LiveActivityTests: XCTestCase {
    func testEveryPhaseHasTitleBadgeAndSymbol() {
        for phase in JuniorActivityPhase.allCases {
            XCTAssertFalse(phase.title.isEmpty)
            XCTAssertFalse(phase.badge.isEmpty)
            XCTAssertFalse(phase.symbol.isEmpty)
        }
        // Bilinmeyen ham değer (ör. eski sürümden kalan durum) çökmeden "bekliyor"a düşer.
        XCTAssertEqual(JuniorActivityPhase(raw: "bilinmiyor"), .waiting)
    }

    @MainActor
    func testHandsFreePhasesMapToActivityPhases() {
        XCTAssertNil(HandsFreeSession.activityPhase(.off))
        XCTAssertEqual(HandsFreeSession.activityPhase(.waiting), "waiting")
        XCTAssertEqual(HandsFreeSession.activityPhase(.listening), "listening")
        XCTAssertEqual(HandsFreeSession.activityPhase(.capturing), "looking")
        XCTAssertEqual(HandsFreeSession.activityPhase(.thinking), "thinking")
        XCTAssertEqual(HandsFreeSession.activityPhase(.speaking), "speaking")
    }

    func testContentStateRoundTrips() throws {
        let state = JuniorActivityAttributes.ContentState(phase: "speaking", detail: "Yarın hava güneşli.", glasses: true, updatedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(JuniorActivityAttributes.ContentState.self, from: data), state)
    }

    func testDotCatHasEyesEarsAndClosedEyes() {
        // Göz bebeği parlak, göz çevresi boş, kulak ucu dolu, dışarısı boş.
        XCTAssertGreaterThan(JuniorDots.weight(x: -0.3, y: 0.04, eyesClosed: false), 1)
        XCTAssertEqual(JuniorDots.weight(x: -0.42, y: 0.04, eyesClosed: false), 0)
        XCTAssertGreaterThan(JuniorDots.weight(x: -0.6, y: -0.8, eyesClosed: false), 0)
        XCTAssertEqual(JuniorDots.weight(x: 0.95, y: 0.95, eyesClosed: false), 0)
        // Kapalı gözde göz bebeği yerine çizgi.
        XCTAssertGreaterThan(JuniorDots.weight(x: -0.42, y: 0.04, eyesClosed: true), 0)
        XCTAssertEqual(JuniorDots.weight(x: -0.3, y: 0.12, eyesClosed: true), 0)
    }
}

/// Yanıt parça parça seslendirilir; parçalama sunucuyla aynı kurala uymalı.
final class SpeechChunkTests: XCTestCase {
    func testFirstChunkIsShortAndNothingIsLost() {
        let text = "Tamam, hemen bakıyorum. Bugün hava parçalı bulutlu, en yüksek sıcaklık yirmi iki derece. "
            + "Akşam saatlerinde hafif yağmur bekleniyor, şemsiyeni yanına almanı öneririm. "
            + "Ayrıca takviminde saat üçte bir toplantı var."
        let chunks = SpeechService.speechChunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 80)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 170) }
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testShortReplyStaysWhole() {
        XCTAssertEqual(SpeechService.speechChunks("Tamam."), ["Tamam."])
        XCTAssertEqual(SpeechService.speechChunks(""), [])
    }

    func testMarkdownAndLinksAreNotReadAloud() {
        XCTAssertEqual(SpeechService.speechChunks("**Tamam** https://a.b/c"), ["Tamam bağlantı"])
    }

    func testLongSentenceWithoutPeriodIsSplit() {
        let words = (0..<60).map { "kelime\($0)" }.joined(separator: " ")
        let chunks = SpeechService.speechChunks(words)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 80)
        XCTAssertEqual(chunks.joined(separator: " "), words)
    }
}

/// Sunucunun yerine geçer: her yoklamayı kaydeder, yanıtı test belirler.
@MainActor
private final class FakeHealth {
    private(set) var urls: [URL] = []
    /// Sırayla verilecek yanıtlar; bitince `fallback` döner.
    var script: [Bool] = []
    var fallback = false
    /// Açıkken yanıt, test `release` diyene kadar bekletilir (yavaş ağ).
    var hold = false
    private var held: [CheckedContinuation<Bool, Never>] = []

    func probe(_ url: URL) async -> Bool {
        urls.append(url)
        if hold { return await withCheckedContinuation { held.append($0) } }
        return script.isEmpty ? fallback : script.removeFirst()
    }

    func release(_ index: Int, up: Bool) {
        held[index].resume(returning: up)
    }
}

final class ServerMonitorTests: XCTestCase {
    private let address = URL(string: "https://junior.example.com/health")!

    @MainActor
    private func monitor(_ fake: FakeHealth, url: URL?, retry: TimeInterval = 10,
                         debounce: TimeInterval = 10) -> ServerMonitor {
        ServerMonitor(healthURL: { url }, probe: { await fake.probe($0) },
                      retryInterval: retry, debounceInterval: debounce)
    }

    /// Koşul sağlanana ya da süre dolana dek bekler; kontrol main actor'da yapılır.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func idle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    func testLateFailureDoesNotOverwriteNewerSuccess() async {
        // Gerçek cihazdaki durum: Wi-Fi'dan hücresele geçerken başlayan kontrol
        // zaman aşımıyla geç döner, sonra başlayan ve başarılı olanı ezmemeli.
        let fake = FakeHealth()
        fake.hold = true
        let server = monitor(fake, url: address)
        server.check()
        await waitUntil { fake.urls.count == 1 }
        server.check()
        await waitUntil { fake.urls.count == 2 }

        fake.release(1, up: true)
        await waitUntil { server.serverUp == true }
        XCTAssertEqual(server.serverUp, true)

        fake.release(0, up: false)
        await idle(0.2)
        XCTAssertEqual(server.serverUp, true, "eski kontrolün sonucu uygulanmamalı")
    }

    @MainActor
    func testRetriesUntilReachableThenStops() async {
        // Uyarı "Yeniden dene"ye basılmadan kendiliğinden kalkmalı.
        let fake = FakeHealth()
        fake.script = [false, false]
        fake.fallback = true
        let server = monitor(fake, url: address, retry: 0.05)
        server.check()
        await waitUntil { server.serverUp == false }
        XCTAssertEqual(server.serverUp, false)

        await waitUntil { server.serverUp == true }
        XCTAssertEqual(server.serverUp, true)
        XCTAssertEqual(fake.urls.count, 3)

        // Sunucu gelince döngü durur.
        await idle(0.3)
        XCTAssertEqual(fake.urls.count, 3)
    }

    @MainActor
    func testMissingAddressNeverProbes() async {
        let fake = FakeHealth()
        let server = monitor(fake, url: nil, retry: 0.05)
        server.check()
        await idle(0.2)
        XCTAssertNil(server.serverUp)
        XCTAssertTrue(fake.urls.isEmpty)
    }

    @MainActor
    func testPauseStopsTheRetryLoop() async {
        let fake = FakeHealth()
        let server = monitor(fake, url: address, retry: 0.05)
        server.check()
        await waitUntil { server.serverUp == false }
        server.pause()
        let probes = fake.urls.count
        await idle(0.3)
        XCTAssertEqual(fake.urls.count, probes, "arka planda ağa çıkılmamalı")
        // Öne dönünce yeniden başlar.
        fake.fallback = true
        server.check()
        await waitUntil { server.serverUp == true }
        XCTAssertEqual(server.serverUp, true)
    }

    @MainActor
    func testTypingProbesOnceWithTheFinalAddress() async {
        let fake = FakeHealth()
        fake.fallback = true
        var current: URL?
        let server = ServerMonitor(healthURL: { current }, probe: { await fake.probe($0) },
                                   retryInterval: 10, debounceInterval: 0.1)
        for typed in ["https://j", "https://junior", "https://junior.example.com"] {
            current = URL(string: typed + "/health")
            server.addressChanged()
        }
        XCTAssertTrue(fake.urls.isEmpty, "her tuşta ağa çıkılmamalı")
        await waitUntil { server.serverUp == true }
        await idle(0.2)
        XCTAssertEqual(fake.urls, [address])
    }

    @MainActor
    func testClosingSettingsChecksWithoutWaiting() async {
        // Ayarlar kapanınca check() çağrılır: bekleyen gecikmeli kontrol iptal
        // olur, yoklama hemen ve bir kez yapılır.
        let fake = FakeHealth()
        fake.fallback = true
        let server = monitor(fake, url: address, debounce: 0.1)
        server.addressChanged()
        server.check()
        await waitUntil { server.serverUp == true }
        XCTAssertEqual(server.serverUp, true)
        await idle(0.3)
        XCTAssertEqual(fake.urls.count, 1)
    }

    @MainActor
    func testAddressChangeDiscardsOldVerdict() async {
        let fake = FakeHealth()
        let server = monitor(fake, url: address)
        server.check()
        await waitUntil { server.serverUp == false }
        XCTAssertEqual(server.serverUp, false)

        // Eski adres için yarıda kalan yoklama yeni adresin durumunu belirlememeli.
        fake.hold = true
        server.check()
        await waitUntil { fake.urls.count == 2 }
        server.addressChanged()
        XCTAssertNil(server.serverUp)
        fake.release(0, up: false)
        await idle(0.2)
        XCTAssertNil(server.serverUp)
    }
}

/// Bilgisayardan telefona gönderilen işler (/v1/phone/tasks).
final class PhoneTaskTests: XCTestCase {
    private func parse(_ json: String) -> [PhoneTask] {
        PhoneTask.parse(json.data(using: .utf8)!)
    }

    func testParsesEveryKind() {
        let tasks = parse("""
        {"tasks": [
          {"id": "a", "kind": "note", "text": " Toplantı 15:00 ", "url": "", "at": null},
          {"id": "b", "kind": "link", "text": "", "url": "https://example.com/x", "at": null},
          {"id": "c", "kind": "clipboard", "text": "IBAN TR00", "url": "", "at": null},
          {"id": "d", "kind": "reminder", "text": "İlacını iç", "url": "", "at": 1790000000000}
        ]}
        """)
        XCTAssertEqual(tasks.map(\.kind), [.note, .link, .clipboard, .reminder])
        XCTAssertEqual(tasks[0].text, "Toplantı 15:00")
        XCTAssertEqual(tasks[1].url?.host, "example.com")
        XCTAssertEqual(tasks[3].at, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(tasks[2].notification.title, "Panoya kopyalandı")
    }

    func testSkipsBrokenOrUnsafeEntries() {
        let tasks = parse("""
        {"tasks": [
          {"id": "1", "kind": "link", "url": "javascript:alert(1)"},
          {"id": "2", "kind": "reminder", "text": "zamansız"},
          {"id": "3", "kind": "note", "text": "   "},
          {"id": "4", "kind": "unknown", "text": "x"},
          {"kind": "note", "text": "kimliksiz"},
          {"id": "5", "kind": "note", "text": "geçerli"}
        ]}
        """)
        XCTAssertEqual(tasks.map(\.id), ["5"])
        XCTAssertEqual(parse("çöp"), [])
        XCTAssertEqual(parse("{\"tasks\": []}"), [])
    }
}

/// Bilgisayarda kurgulanan video işinin durumu (/v1/desktop/jobs/{id}).
final class DesktopJobStatusTests: XCTestCase {
    private func parse(_ json: String) -> DesktopJobStatus? {
        DesktopJobStatus.parse(json.data(using: .utf8)!)
    }

    func testParsesStatusAndShowsProgress() {
        let running = parse("""
        {"id": "j1", "status": "running", "progress": "Videodaki konuşmayı yazıya çeviriyor", "reply": "", "has_result": false, "desktop_online": true}
        """)
        XCTAssertEqual(running?.state, .running)
        XCTAssertEqual(running?.line, "Bilgisayarda: Videodaki konuşmayı yazıya çeviriyor")
        let done = parse("""
        {"id": "j1", "status": "done", "progress": "", "reply": "32 saniyeye indirdim.", "has_result": true, "desktop_online": true}
        """)
        XCTAssertEqual(done?.hasResult, true)
        XCTAssertEqual(done?.reply, "32 saniyeye indirdim.")
    }

    func testQueuedJobSaysWhenDesktopAppIsClosed() {
        let offline = parse("{\"status\": \"queued\", \"desktop_online\": false}")
        XCTAssertTrue(offline?.line.contains("kapalı") ?? false)
        let online = parse("{\"status\": \"queued\", \"desktop_online\": true}")
        XCTAssertFalse(online?.line.contains("kapalı") ?? true)
        XCTAssertNil(parse("{\"status\": \"weird\"}"))
        XCTAssertNil(parse("çöp"))
    }
}
