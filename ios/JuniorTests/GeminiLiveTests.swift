import XCTest
@testable import Junior

/// Gemini Live'ın saf parçaları: ileti kodlama/çözme, PCM parçalama, yankı kapısı, tur
/// toplama, geri düşüş kararları ve durum kartı metinleri. Ağ, mikrofon ve ses yok.
final class GeminiLiveTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Telefondan köprüye

    func testStartMessageIsPhoneClientWithoutTools() {
        let start = json(GeminiWire.start())
        XCTAssertEqual(start["type"] as? String, "start")
        XCTAssertEqual(start["client"] as? String, "phone")
        XCTAssertEqual((start["tools"] as? [Any])?.count, 0)
        XCTAssertTrue((start["system"] as? String ?? "").contains("aracın yok"))
    }

    func testAudioMessageIsBase64AndRejectsEmptyOrHuge() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let message = json(GeminiWire.audio(pcm) ?? "")
        XCTAssertEqual(message["type"] as? String, "audio")
        XCTAssertEqual(message["data"] as? String, pcm.base64EncodedString())
        XCTAssertNil(GeminiWire.audio(Data()))
        XCTAssertNil(GeminiWire.audio(Data(count: GeminiWire.maxAudioBytes + 1)))
    }

    func testTextToolResultAndEnd() {
        XCTAssertNil(GeminiWire.text("   "))
        XCTAssertEqual(json(GeminiWire.text("  merhaba ") ?? "")["text"] as? String, "merhaba")
        XCTAssertEqual((json(GeminiWire.text(String(repeating: "a", count: 5000)) ?? "")["text"] as? String)?.count, 4000)
        let result = json(GeminiWire.toolResult(id: "c1", name: "saat", output: GeminiWire.unavailableToolOutput("saat")))
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["id"] as? String, "c1")
        XCTAssertTrue((result["output"] as? String ?? "").hasPrefix("[failed]"))
        XCTAssertEqual(json(GeminiWire.end)["type"] as? String, "end")
    }

    func testBridgeURLSwitchesSchemeAndKeepsPath() {
        XCTAssertEqual(GeminiWire.bridgeURL(from: URL(string: "https://junior.example.com/v1/live/gemini/ws"))?.absoluteString,
                       "wss://junior.example.com/v1/live/gemini/ws")
        XCTAssertEqual(GeminiWire.bridgeURL(from: URL(string: "http://192.168.1.5:8765/v1/live/gemini/ws"))?.absoluteString,
                       "ws://192.168.1.5:8765/v1/live/gemini/ws")
        XCTAssertNil(GeminiWire.bridgeURL(from: URL(string: "ftp://x/y")))
        XCTAssertNil(GeminiWire.bridgeURL(from: nil))
    }

    // MARK: - Köprüden telefona

    func testDecodesServerMessages() {
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"ready","model":"gemini-3.8-live"}"#), .ready)
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"audio","data":"AAECAw==","rate":24000}"#),
                       .audio(Data([0, 1, 2, 3]), rate: 24000))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"audio","data":"AAECAw==","rate":3}"#),
                       .audio(Data([0, 1, 2, 3]), rate: 24000))
        XCTAssertNil(GeminiServerMessage.decode(#"{"type":"audio","data":""}"#))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"transcript","role":"user","text":"merhaba"}"#),
                       .transcript(role: .user, text: "merhaba"))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"transcript","role":"model","text":"selam"}"#),
                       .transcript(role: .model, text: "selam"))
        XCTAssertNil(GeminiServerMessage.decode(#"{"type":"transcript","role":"kedi","text":"x"}"#))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"turn_complete"}"#), .turnComplete)
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"interrupted"}"#), .interrupted)
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"tool_call","id":"c1","name":"saat","args":{}}"#),
                       .toolCall(id: "c1", name: "saat"))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"tool_cancel","ids":["c1"]}"#), .toolCancel(["c1"]))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"fallback","reason":"cap","message":"doldu"}"#),
                       .fallback(.cap, message: "doldu"))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"fallback","reason":"yeni_neden"}"#),
                       .fallback(.error, message: ""))
        XCTAssertEqual(GeminiServerMessage.decode(#"{"type":"error","message":"start olmalı"}"#), .error("start olmalı"))
        XCTAssertNil(GeminiServerMessage.decode("bozuk"))
        XCTAssertNil(GeminiServerMessage.decode(#"{"type":"bilinmeyen"}"#))
        // Köprü ikili çerçeve de gönderebilir.
        XCTAssertEqual(GeminiServerMessage.decode(Data(#"{"type":"ready"}"#.utf8)), .ready)
    }

    func testFallbackNoticesNeverSayJunior() {
        for reason in [GeminiFallbackReason.noKey, .auth, .quota, .cap, .error] {
            XCTAssertFalse(reason.notice.lowercased().contains("junior"), "\(reason)")
            XCTAssertTrue(reason.notice.contains("normal sese geçtim"), "\(reason)")
        }
        XCTAssertEqual(GeminiFallbackReason(wire: "no_key"), .noKey)
        XCTAssertEqual(GeminiFallbackReason(wire: nil), .error)
    }

    // MARK: - PCM

    func testPCMSamplesFloatsAndRms() {
        let pcm = PCM16.data([0, 16384, -16384, Int16.max, Int16.min])
        XCTAssertEqual(pcm.count, 10)
        XCTAssertEqual(PCM16.samples(pcm), [0, 16384, -16384, Int16.max, Int16.min])
        XCTAssertEqual(PCM16.floats(pcm)[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(PCM16.floats(pcm)[4], -1, accuracy: 0.0001)
        XCTAssertEqual(PCM16.rms(PCM16.data([0, 0, 0])), 0)
        XCTAssertEqual(PCM16.rms(PCM16.data([16384, -16384])), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PCM16.rms(Data()), 0)
        // Tek bayt artığı yok sayılır.
        XCTAssertEqual(PCM16.samples(Data([0x01, 0x00, 0x07])), [1])
    }

    func testChunkerEmitsFixedSizeAndKeepsRemainder() {
        var chunker = PCMChunker(size: 4)
        XCTAssertEqual(chunker.push(Data([1, 2, 3])), [])
        XCTAssertEqual(chunker.pendingBytes, 3)
        XCTAssertEqual(chunker.push(Data([4, 5, 6, 7, 8, 9])), [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])])
        XCTAssertEqual(chunker.pendingBytes, 1)
        chunker.reset()
        XCTAssertEqual(chunker.pendingBytes, 0)
        XCTAssertEqual(PCMChunker().size, 3_200)   // 100 ms @ 16 kHz mono PCM16
    }

    func testBargeInGateHoldsEchoAndReleasesOnSustainedSpeech() {
        var gate = BargeInGate()
        let quiet = Data([0, 0]), loud = Data([9, 9])
        XCTAssertEqual(gate.decide(quiet, rms: 0.01, playing: false), .send([quiet]))
        // Junior konuşurken: hoparlör yankısı (tek tük yüksek parça) bekletilir.
        XCTAssertEqual(gate.decide(quiet, rms: 0.01, playing: true), .hold)
        XCTAssertEqual(gate.decide(loud, rms: 0.2, playing: true), .hold)
        XCTAssertEqual(gate.decide(quiet, rms: 0.01, playing: true), .hold)
        XCTAssertEqual(gate.decide(loud, rms: 0.2, playing: true), .hold)
        XCTAssertEqual(gate.decide(loud, rms: 0.2, playing: true), .hold)
        // Üçüncü ardışık yüksek parça: söze giriş; bekletilen son 5 parça gönderilir.
        guard case .bargeIn(let parts) = gate.decide(loud, rms: 0.2, playing: true) else {
            return XCTFail("söze giriş bekleniyordu")
        }
        XCTAssertEqual(parts.count, BargeInGate.keep)
        XCTAssertTrue(gate.held.isEmpty)
        // Çalma bitince bekletilenler (yankı) atılır, ses doğrudan gider.
        _ = gate.decide(loud, rms: 0.2, playing: true)
        XCTAssertEqual(gate.decide(quiet, rms: 0.01, playing: false), .send([quiet]))
        XCTAssertTrue(gate.held.isEmpty)
    }

    // MARK: - Turlar

    func testTurnBufferGroupsQuestionAndAnswer() {
        var turns = GeminiTurnBuffer()
        turns.user("Yarın ")
        turns.user("hava nasıl?")
        turns.modelAudio()
        turns.model("Güneşli ")
        turns.user(" İstanbul'da")   // modelden sonra gelen geç döküm, aynı soru
        turns.model("olacak.")
        XCTAssertEqual(turns.flush(all: true), [
            GeminiTurn(role: .user, text: "Yarın hava nasıl? İstanbul'da"),
            GeminiTurn(role: .assistant, text: "Güneşli olacak."),
        ])
        XCTAssertEqual(turns.pendingUserText, "")
    }

    func testInterruptionKeepsNewQuestionPending() {
        var turns = GeminiTurnBuffer()
        turns.user("Bir fıkra anlat")
        turns.model("Temel bir gün")
        turns.user("dur, saat kaç")   // söze giriş: yeni soru
        XCTAssertEqual(turns.flush(all: false), [
            GeminiTurn(role: .user, text: "Bir fıkra anlat"),
            GeminiTurn(role: .assistant, text: "Temel bir gün"),
        ])
        XCTAssertEqual(turns.pendingUserText, "dur, saat kaç")
        // Yanıt gelmeden Bitir: yanıtsız soru geçmişe tek başına yazılmaz.
        XCTAssertEqual(turns.flush(all: true), [])
        XCTAssertEqual(turns.pendingUserText, "")
    }

    /// Geçmişe giden her tur ya boş ya da tam kullanıcı + Junior çiftidir.
    private func assertPaired(_ out: [GeminiTurn], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(out.isEmpty || out.map(\.role) == [.user, .assistant], "\(out)", file: file, line: line)
    }

    func testStopBeforeAnswerWritesNothing() {
        var turns = GeminiTurnBuffer()
        turns.user("Bugün ne var")
        let out = turns.flush(all: true)
        XCTAssertEqual(out, [])
        assertPaired(out)
    }

    func testInterruptionBeforeAnswerTranscriptKeepsQuestionForNextTurn() {
        var turns = GeminiTurnBuffer()
        turns.user("Bir şiir oku")
        turns.modelAudio()               // ses geldi, dökümü henüz yok
        let interrupted = turns.flush(all: false)
        XCTAssertEqual(interrupted, [])
        turns.user("kısa olsun")         // kesintiden sonra söylenen
        XCTAssertEqual(turns.pendingUserText, "Bir şiir oku kısa olsun")
        turns.model("Tamam, kısa bir şiir.")
        XCTAssertEqual(turns.flush(all: true), [
            GeminiTurn(role: .user, text: "Bir şiir oku kısa olsun"),
            GeminiTurn(role: .assistant, text: "Tamam, kısa bir şiir."),
        ])
    }

    func testMissingTranscriptsGetPlaceholdersSoPairsStayIntact() {
        var answerOnly = GeminiTurnBuffer()
        answerOnly.model("Merhaba!")     // kullanıcı dökümü hiç gelmedi
        let a = answerOnly.flush(all: true)
        XCTAssertEqual(a, [GeminiTurn(role: .user, text: GeminiTurnBuffer.unheardQuestion),
                           GeminiTurn(role: .assistant, text: "Merhaba!")])
        assertPaired(a)

        var voiceOnly = GeminiTurnBuffer()
        voiceOnly.user("Saat kaç")
        voiceOnly.modelAudio()           // yanıt yalnız sesle geldi
        let b = voiceOnly.flush(all: true)
        XCTAssertEqual(b, [GeminiTurn(role: .user, text: "Saat kaç"),
                           GeminiTurn(role: .assistant, text: GeminiTurnBuffer.unheardAnswer)])
        assertPaired(b)
    }

    func testLiveTurnsKeepClassicHistoryPairs() {
        // Gemini turları ve klasik turlar karışık: sunucuya giden geçmiş hiçbirini düşürmez.
        var turns = GeminiTurnBuffer()
        turns.user("yanıtsız")
        var history = [ChatMessage(role: .user, text: "u1"), ChatMessage(role: .assistant, text: "a1")]
        for turn in turns.flush(all: true) { history.append(ChatMessage(role: turn.role, text: turn.text)) }
        history += [ChatMessage(role: .user, text: "u2"), ChatMessage(role: .assistant, text: "a2")]
        XCTAssertEqual(JuniorClient.completedPairs(from: history).map { $0["content"] }, ["u1", "a1", "u2", "a2"])
    }

    // MARK: - Yerel söze giriş

    func testModelAudioGateDropsRestOfTurnAfterLocalBargeIn() {
        var gate = GeminiModelAudioGate()
        XCTAssertTrue(gate.audio())
        gate.localBargeIn()
        XCTAssertTrue(gate.suppressed)
        // Sunucu kesintiyi anlayana kadar gelen ses çalınmaz (yankı kapısı yeniden kapanmasın).
        XCTAssertFalse(gate.audio())
        XCTAssertFalse(gate.audio())
        gate.turnEnded()                 // "interrupted" ya da "turn_complete"
        XCTAssertTrue(gate.audio())      // yeni sorunun yanıtı çalar
    }

    func testModelAudioGateIgnoresBargeInAfterTurnEnded() {
        var gate = GeminiModelAudioGate()
        XCTAssertTrue(gate.audio())
        gate.turnEnded()                 // tur bitti, yalnız sıradaki ses çalıyordu
        gate.localBargeIn()
        XCTAssertFalse(gate.suppressed)
        XCTAssertTrue(gate.audio())      // sonraki turun sesi atılmaz
        // Hiç ses gelmeden söze giriş de bir şey atmaz.
        var fresh = GeminiModelAudioGate()
        fresh.localBargeIn()
        XCTAssertTrue(fresh.audio())
    }

    // MARK: - Oturum sürerken yazılan

    func testComposerRouteDuringLiveSession() {
        // Oturum yokken her şey klasik.
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: false, text: "saat kaç", hasVideo: false), .classic)
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: false, text: "", hasVideo: true), .classic)
        // Oturum açıkken düz metin köprüye gider; klasik yanıt Gemini sesiyle çakışmaz.
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: true, text: "  saat kaç \n", hasVideo: false), .gemini("saat kaç"))
        // Boş gönderim oturumu kapatmaz.
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: true, text: "   ", hasVideo: false), .ignore)
        // Canlı oturumda yapılamayanlar: oturum kapanır, istek klasik yoldan gider.
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: true, text: "bunu editle", hasVideo: true), .endSessionThenClassic)
        XCTAssertEqual(GeminiComposerRoute.decide(sessionActive: true, text: "Şuna bak bakalım", hasVideo: false), .endSessionThenClassic)
    }

    func testTypedTextBeforeAnswerIsTheQuestion() {
        var turns = GeminiTurnBuffer()
        turns.typed("Yarın hava nasıl")
        XCTAssertEqual(turns.pendingUserText, "Yarın hava nasıl")
        turns.model("Yarın güneşli.")
        XCTAssertEqual(turns.flush(all: true), [
            GeminiTurn(role: .user, text: "Yarın hava nasıl"),
            GeminiTurn(role: .assistant, text: "Yarın güneşli."),
        ])
        XCTAssertEqual(turns.pendingUserText, "")
    }

    func testTypedTextDuringAnswerWaitsForNextTurn() {
        var turns = GeminiTurnBuffer()
        turns.user("Bir fıkra anlat")
        turns.model("Temel bir gün")
        turns.typed("saat kaç")          // model konuşurken yazıldı: yeni soru
        XCTAssertEqual(turns.pendingUserText, "Bir fıkra anlat saat kaç")
        XCTAssertEqual(turns.flush(all: true), [
            GeminiTurn(role: .user, text: "Bir fıkra anlat"),
            GeminiTurn(role: .assistant, text: "Temel bir gün"),
        ])
        // Yazılan bir sonraki turun sorusu; geri düşüşte de klasik yolda sorulur.
        XCTAssertEqual(turns.pendingUserText, "saat kaç")
        turns.model("Saat beş.")
        XCTAssertEqual(turns.flush(all: true), [
            GeminiTurn(role: .user, text: "saat kaç"),
            GeminiTurn(role: .assistant, text: "Saat beş."),
        ])

        // Söz kesilince de kaybolmaz.
        var cut = GeminiTurnBuffer()
        cut.user("Şiir oku")
        cut.modelAudio()
        cut.typed("kısa olsun")
        XCTAssertEqual(cut.flush(all: false), [])
        XCTAssertEqual(cut.pendingUserText, "Şiir oku kısa olsun")
    }

    func testPendingUserTextIncludesUnansweredQuestion() {
        var turns = GeminiTurnBuffer()
        turns.user("Annemi ara")
        turns.modelAudio()
        XCTAssertEqual(turns.pendingUserText, "Annemi ara")
        XCTAssertEqual(GeminiFallbackPolicy.next(afterFallbackWith: turns.pendingUserText), .send("Annemi ara"))
        XCTAssertEqual(GeminiFallbackPolicy.next(afterFallbackWith: "  "), .listen)
    }

    // MARK: - Geri düşüş kararları

    func testBlockDurations() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for reason in [GeminiFallbackReason.quota, .error] {
            let block = GeminiFallbackPolicy.block(for: reason, at: now)
            XCTAssertTrue(GeminiFallbackPolicy.isBlocked(block, now: now.addingTimeInterval(299)))
            XCTAssertFalse(GeminiFallbackPolicy.isBlocked(block, now: now.addingTimeInterval(301)))
        }
        for reason in [GeminiFallbackReason.noKey, .auth, .cap] {
            let block = GeminiFallbackPolicy.block(for: reason, at: now)
            XCTAssertTrue(GeminiFallbackPolicy.isBlocked(block, now: now.addingTimeInterval(86_400 * 30)))
        }
        XCTAssertFalse(GeminiFallbackPolicy.isBlocked(nil, now: now))
    }

    func testRouteFollowsEngineAndBlock() {
        let now = Date()
        XCTAssertEqual(GeminiFallbackPolicy.route(engine: .classic, block: nil, now: now), .classic)
        XCTAssertEqual(GeminiFallbackPolicy.route(engine: .geminiLive, block: nil, now: now), .gemini)
        let cap = GeminiFallbackPolicy.block(for: .cap, at: now)
        XCTAssertEqual(GeminiFallbackPolicy.route(engine: .geminiLive, block: cap, now: now), .classic)
        let quota = GeminiFallbackPolicy.block(for: .quota, at: now)
        XCTAssertEqual(GeminiFallbackPolicy.route(engine: .geminiLive, block: quota, now: now.addingTimeInterval(400)), .gemini)
        XCTAssertEqual(VoiceEngine(rawValue: "gemini_live"), .geminiLive)
        XCTAssertEqual(VoiceEngine.classic.title, "Klasik")
    }

    func testStatusClearsBlockOnlyWhenProblemIsFixed() {
        var status = sampleStatus()
        let now = Date()
        let noKey = GeminiFallbackPolicy.block(for: .noKey, at: now)
        status.configured = false
        XCTAssertFalse(GeminiFallbackPolicy.clears(noKey, with: status))
        status.configured = true
        XCTAssertTrue(GeminiFallbackPolicy.clears(noKey, with: status))

        let cap = GeminiFallbackPolicy.block(for: .cap, at: now)
        status.remainingMinutes = 0
        XCTAssertFalse(GeminiFallbackPolicy.clears(cap, with: status))
        status.remainingMinutes = 12
        XCTAssertTrue(GeminiFallbackPolicy.clears(cap, with: status))

        let auth = GeminiFallbackPolicy.block(for: .auth, at: now, keyHint: "…abcd")
        status.apiKeyHint = "…abcd"
        XCTAssertFalse(GeminiFallbackPolicy.clears(auth, with: status))
        status.apiKeyHint = "…wxyz"
        XCTAssertTrue(GeminiFallbackPolicy.clears(auth, with: status))

        XCTAssertFalse(GeminiFallbackPolicy.clears(GeminiFallbackPolicy.block(for: .quota, at: now), with: status))
    }

    // MARK: - Durum kartı

    private func sampleStatus() -> GeminiStatus {
        GeminiStatus(available: true, reason: nil, message: nil, configured: true, apiKeyHint: "…abcd",
                     tier: "free", freeTierNotice: "x", usedMinutes: 12.5, capMinutes: 30,
                     remainingMinutes: 17.5, activeSessions: 0, lastError: nil)
    }

    func testParsesStatusResponse() {
        let parsed = GeminiStatus.parse(data([
            "available": false, "reason": "cap", "message": "Bugünkü süre doldu",
            "configured": true, "api_key_hint": "…abcd", "tier": "free",
            "free_tier_notice": "Google kullanabilir", "model": "gemini-3.8-live",
            "date": "2026-11-21", "used_minutes": 30.4, "cap_minutes": 30, "remaining_minutes": 0,
            "active_sessions": 1,
            "last_error": ["reason": "cap", "message": "doldu", "at": 1_800_000_000, "client": "phone"],
        ]))
        XCTAssertEqual(parsed?.available, false)
        XCTAssertEqual(parsed?.reason, .cap)
        XCTAssertEqual(parsed?.capMinutes, 30)
        XCTAssertEqual(parsed?.usedMinutes ?? 0, 30.4, accuracy: 0.001)
        XCTAssertEqual(parsed?.activeSessions, 1)
        XCTAssertEqual(parsed?.lastError?.client, "phone")
        XCTAssertEqual(parsed?.lastError?.at, Date(timeIntervalSince1970: 1_800_000_000))

        let fresh = GeminiStatus.parse(data(["available": true, "reason": NSNull(), "tier": "paid",
                                             "last_error": NSNull(), "configured": true]))
        XCTAssertNil(fresh?.reason)
        XCTAssertNil(fresh?.lastError)
        XCTAssertNil(GeminiStatus.parse(data(["tier": "free"])))
        XCTAssertNil(GeminiStatus.parse(Data("bozuk".utf8)))
    }

    func testStatusTexts() {
        XCTAssertEqual(GeminiStatusText.minutes(12.5), "12,5")
        XCTAssertEqual(GeminiStatusText.minutes(30), "30")
        XCTAssertEqual(GeminiStatusText.minutes(0.04), "0")
        var status = sampleStatus()
        XCTAssertEqual(GeminiStatusText.usage(status), "Bugün 12,5 / 30 dk kullanıldı (kalan 17,5 dk).")
        status.usedMinutes = 30
        status.remainingMinutes = 0
        XCTAssertTrue(GeminiStatusText.usage(status).contains("sınır doldu"))

        XCTAssertEqual(GeminiStatusText.tierTitle("free"), "Ücretsiz")
        XCTAssertEqual(GeminiStatusText.tierTitle("paid"), "Ücretli")
        let free = GeminiStatusText.tierNote("free")
        XCTAssertTrue(free.warn)
        XCTAssertTrue(free.text.contains("Google bu konuşmaları ürünlerini geliştirmek için kullanabilir"))
        XCTAssertFalse(GeminiStatusText.tierNote("paid").warn)
        XCTAssertTrue(GeminiStatusText.privacyNote.contains("gün boyu kayıt"))

        let now = Date()
        let error = GeminiStatus.LastError(reason: .quota, message: "Kota doldu.", at: now, client: "phone")
        let line = GeminiStatusText.lastError(error, now: now)
        XCTAssertTrue(line.hasPrefix("Son hata (bugün "), line)
        XCTAssertTrue(line.contains("telefon"), line)
        XCTAssertTrue(line.hasSuffix("Kota doldu."), line)
    }

    func testPhoneSideErrorIsStoredAndShownWhenNewer() {
        let suite = "junior.tests.geminiPhoneError.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("geçici ayar deposu açılamadı") }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(GeminiPhoneError.load(defaults: defaults))
        GeminiPhoneError.save(reason: .error, message: "   ", at: Date(), defaults: defaults)
        XCTAssertNil(GeminiPhoneError.load(defaults: defaults))

        let at = Date(timeIntervalSince1970: 1_800_000_500)
        GeminiPhoneError.save(reason: .error, message: "Bilgisayara ulaşılamadığı için Gemini açılamadı.", at: at, defaults: defaults)
        let phone = GeminiPhoneError.load(defaults: defaults)
        XCTAssertEqual(phone?.client, "phone")
        XCTAssertEqual(phone?.reason, .error)
        XCTAssertEqual(phone?.at, at)
        XCTAssertTrue(GeminiStatusText.lastError(phone!).contains("telefon"))

        // Kart, sunucunun kaydı ile telefonun gördüğünden yenisini gösterir; durum okunamasa da.
        let older = GeminiStatus.LastError(reason: .cap, message: "doldu", at: at.addingTimeInterval(-60), client: "desktop")
        let newer = GeminiStatus.LastError(reason: .quota, message: "kota", at: at.addingTimeInterval(60), client: "desktop")
        XCTAssertEqual(GeminiStatusText.latestError(server: older, phone: phone), phone)
        XCTAssertEqual(GeminiStatusText.latestError(server: newer, phone: phone), newer)
        XCTAssertEqual(GeminiStatusText.latestError(server: nil, phone: phone), phone)
        XCTAssertEqual(GeminiStatusText.latestError(server: older, phone: nil), older)
        XCTAssertNil(GeminiStatusText.latestError(server: nil, phone: nil))
        XCTAssertNil(GeminiPhoneError.decode(message: "", reason: "error", at: 1))
        XCTAssertNil(GeminiPhoneError.decode(message: "x", reason: "error", at: 0))
    }

    func testEngineAvailability() {
        let unreachable = GeminiStatusText.availability(status: nil, loadError: "Bilgisayara ulaşılamıyor.")
        XCTAssertFalse(unreachable.enabled)
        XCTAssertTrue(unreachable.reason?.contains("alınamadı") == true)

        var status = sampleStatus()
        status.configured = false
        let noKey = GeminiStatusText.availability(status: status, loadError: nil)
        XCTAssertFalse(noKey.enabled)
        XCTAssertTrue(noKey.reason?.contains("anahtar") == true)

        status.configured = true
        XCTAssertEqual(GeminiStatusText.availability(status: status, loadError: nil).enabled, true)
        XCTAssertNil(GeminiStatusText.availability(status: status, loadError: nil).reason)

        status.reason = .cap
        status.remainingMinutes = 0
        let capped = GeminiStatusText.availability(status: status, loadError: nil)
        XCTAssertTrue(capped.enabled)
        XCTAssertTrue(capped.reason?.contains("doldu") == true)
    }

    func testEngineAvailabilityWhileLoadingShowsNoError() {
        // Ayarlar her açılışta durumu yeniden okur: ilk çizimde ve istek sürerken "alınamadı" yazmaz.
        let firstRender = GeminiStatusText.availability(status: nil, loadError: nil)
        XCTAssertFalse(firstRender.enabled)
        XCTAssertNil(firstRender.reason)
        let loading = GeminiStatusText.availability(status: nil, loadError: nil, loading: true)
        XCTAssertNil(loading.reason)
        // Önceki istek düşmüştü, yenisi sürüyor: eski hata da bu arada gösterilmez.
        let retrying = GeminiStatusText.availability(status: nil, loadError: "Bilgisayara ulaşılamıyor.", loading: true)
        XCTAssertNil(retrying.reason)
        let failed = GeminiStatusText.availability(status: nil, loadError: "Bilgisayara ulaşılamıyor.", loading: false)
        XCTAssertTrue(failed.reason?.contains("Bilgisayara ulaşılamıyor.") == true)
    }
}
