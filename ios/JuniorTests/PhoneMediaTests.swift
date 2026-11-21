import AVFoundation
import XCTest
@testable import Junior

/// Faz 10 (bas-konuş, giriş TEST'i, Paylaş eklentisi, kedi ifadeleri, video, pano): saf parçalar.
/// Ses oturumu, ağ, pano ve ActivityKit kullanılmaz.
final class CatExpressionTests: XCTestCase {
    func testActivePhasesMapToTheirFaces() {
        XCTAssertEqual(CatExpression.derive(phase: .listening, outcome: nil), .listening)
        XCTAssertEqual(CatExpression.derive(phase: .looking, outcome: nil), .listening)
        XCTAssertEqual(CatExpression.derive(phase: .thinking, outcome: .done), .thinking)
        XCTAssertEqual(CatExpression.derive(phase: .confirm, outcome: nil), .thinking)
        XCTAssertEqual(CatExpression.derive(phase: .speaking, outcome: .failed), .speaking)
        XCTAssertEqual(CatExpression.derive(phase: .error, outcome: .done), .sad)
    }

    func testRecentOutcomeShowsOnIdleFace() {
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: .done, outcomeAge: 2), .happy)
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: .failed, outcomeAge: 2), .sad)
        // Ada "bitti" adımında da son sonuç yüzü belirler.
        XCTAssertEqual(CatExpression.derive(phase: .done, outcome: .failed, outcomeAge: 1), .sad)
        XCTAssertEqual(CatExpression.derive(phase: .done, outcome: nil), .happy)
    }

    func testOldOutcomeFadesAndLongIdleSleeps() {
        let old = CatExpression.outcomeShownFor + 1
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: .done, outcomeAge: old), .idle)
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: nil, idleFor: 10), .idle)
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: nil, idleFor: CatExpression.sleepyAfter), .sleepy)
        // Saat geri giderse (negatif yaş) sonuç gösterilmez.
        XCTAssertEqual(CatExpression.derive(phase: .waiting, outcome: .done, outcomeAge: -5), .idle)
    }

    func testOnlyDoneAndFailedChangeTheFace() {
        XCTAssertEqual(JuniorOutcomeMood(outcome: "done"), .done)
        XCTAssertEqual(JuniorOutcomeMood(outcome: "failed"), .failed)
        XCTAssertNil(JuniorOutcomeMood(outcome: "unverified"))
        XCTAssertNil(JuniorOutcomeMood(outcome: "ask"))
        XCTAssertNil(JuniorOutcomeMood(outcome: "expired"))
    }

    func testIslandUsesWrittenExpressionUnlessStale() {
        XCTAssertEqual(JuniorConfirmDisplay.expression(raw: "happy", phase: .done, isStale: false), .happy)
        // Eski sürüm ifade yazmadıysa adımdan: beklerken uykulu (eski kapalı göz).
        XCTAssertEqual(JuniorConfirmDisplay.expression(raw: nil, phase: .waiting, isStale: false), .sleepy)
        XCTAssertEqual(JuniorConfirmDisplay.expression(raw: "bozuk", phase: .speaking, isStale: false), .speaking)
        XCTAssertEqual(JuniorConfirmDisplay.expression(raw: "happy", phase: .error, isStale: true), .sad)
    }

    func testOldContentStateWithoutExpressionDecodes() throws {
        let json = #"{"phase":"thinking","detail":"x","glasses":false,"updatedAt":0}"#
        let state = try JSONDecoder().decode(JuniorActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.expression)
        XCTAssertEqual(state.phase, "thinking")
    }

    func testFacesDifferWhereTheyShould() {
        // 15 sütunlu ızgarada ağız sırası (y ≈ 0,51) ve göz sırası (y ≈ 0,08).
        let mouthY = 0.08 + 3 * (2.0 / 14)
        XCTAssertEqual(JuniorDots.weight(x: 0, y: mouthY, expression: .happy), 1.15)
        XCTAssertEqual(JuniorDots.weight(x: 0, y: mouthY, expression: .idle), 0.85)
        XCTAssertEqual(JuniorDots.weight(x: 0, y: mouthY, expression: .speaking), 1.15)
        // Uykulu ve göz kırpışı: gözler tek sıra.
        XCTAssertEqual(JuniorDots.weight(x: -0.286, y: 0.08, expression: .sleepy), 1.1)
        XCTAssertEqual(JuniorDots.weight(x: -0.286, y: 0.08, expression: .happy, eyesClosed: true), 1.1)
        // İfadesiz eski yüz değişmedi.
        XCTAssertEqual(JuniorDots.weight(x: -0.286, y: 0.08, expression: .idle),
                       JuniorDots.weight(x: -0.286, y: 0.08, eyesClosed: false))
        // Dinlerken kulaklar parlak.
        XCTAssertEqual(JuniorDots.weight(x: -0.6, y: -0.6, expression: .listening), 1.1)
        XCTAssertEqual(JuniorDots.weight(x: -0.6, y: -0.6, expression: .idle), 0.95)
    }
}

final class PushToTalkTests: XCTestCase {
    func testShortTapKeepsOldTapToTalk() {
        var ptt = PushToTalk()
        XCTAssertEqual(ptt.press(speaking: false), .none)
        XCTAssertEqual(ptt.release(), .tap)
        XCTAssertEqual(ptt.phase, .idle)
    }

    func testHoldStartsAndReleaseSends() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        XCTAssertEqual(ptt.holdElapsed(), .startRecording)
        XCTAssertTrue(ptt.isHolding)
        XCTAssertEqual(ptt.move(dy: -20), .none)
        XCTAssertEqual(ptt.release(), .send)
        XCTAssertFalse(ptt.isHolding)
    }

    func testSlideUpThenReleaseCancels() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        _ = ptt.holdElapsed()
        _ = ptt.move(dy: -PushToTalk.cancelDistance - 1)
        XCTAssertEqual(ptt.phase, .cancelArmed)
        XCTAssertEqual(ptt.release(), .cancel)
    }

    func testSlidingBackDownDisarmsCancel() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        _ = ptt.holdElapsed()
        _ = ptt.move(dy: -120)
        _ = ptt.move(dy: -10)
        XCTAssertEqual(ptt.phase, .holding)
        XCTAssertEqual(ptt.release(), .send)
    }

    func testSlideBeforeHoldDoesNotArmCancel() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        _ = ptt.move(dy: -200)
        XCTAssertEqual(ptt.phase, .pressed)
        XCTAssertEqual(ptt.release(), .tap)
    }

    func testPressWhileSpeakingSilencesAndShortReleaseDoesNothingElse() {
        var ptt = PushToTalk()
        XCTAssertEqual(ptt.press(speaking: true), .silence)
        XCTAssertEqual(ptt.release(), .none)
        // Susturduktan sonra basılı tutmak söz kesmedir: dinleme açılır.
        XCTAssertEqual(ptt.press(speaking: true), .silence)
        XCTAssertEqual(ptt.holdElapsed(), .startRecording)
        XCTAssertEqual(ptt.release(), .send)
    }

    func testHoldElapsedAfterReleaseAndDoublePressAreIgnored() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        _ = ptt.release()
        XCTAssertEqual(ptt.holdElapsed(), .none)
        _ = ptt.press(speaking: false)
        XCTAssertEqual(ptt.press(speaking: true), .none)
        XCTAssertEqual(ptt.release(), .tap)
    }

    func testInterruptCancelsAHold() {
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        XCTAssertEqual(ptt.interrupt(), .none)
        _ = ptt.press(speaking: false)
        _ = ptt.holdElapsed()
        XCTAssertEqual(ptt.interrupt(), .cancel)
        XCTAssertEqual(ptt.release(), .none)
    }

    func testLongSilenceWhileHoldingDoesNotSend() {
        // Serbest dinlemede sessizlik bitirir (konuştuktan sonra 2,8 sn).
        XCTAssertEqual(PushToTalk.silenceWait(normal: 2.8, holding: false, elapsed: 10), 2.8)
        // Basılıyken cümle ortasında 10 sn duraksamak dinlemeyi bitirmez, gönderen bırakmaktır.
        XCTAssertGreaterThan(PushToTalk.silenceWait(normal: 2.8, holding: true, elapsed: 3), 10)
        XCTAssertEqual(PushToTalk.silenceWait(normal: 6, holding: true, elapsed: 0), PushToTalk.holdLimit)
        // Yalnız üst sınır kalır; dinlemenin başından sayılır ve eller serbest bekçisinden (60 sn) önce dolar.
        XCTAssertEqual(PushToTalk.silenceWait(normal: 2.8, holding: true, elapsed: 45), PushToTalk.holdLimit - 45,
                       accuracy: 1e-9)
        XCTAssertEqual(PushToTalk.silenceWait(normal: 2.8, holding: true, elapsed: 70), 0)
        XCTAssertLessThan(PushToTalk.holdLimit, 60)
        // Duraksadıktan sonra yukarı kaydırıp bırakmak hâlâ iptaldir (dinleme açık kaldığı için).
        var ptt = PushToTalk()
        _ = ptt.press(speaking: false)
        XCTAssertEqual(ptt.holdElapsed(), .startRecording)
        _ = ptt.move(dy: -PushToTalk.cancelDistance - 5)
        XCTAssertEqual(ptt.release(), .cancel)
    }
}

final class InputTestLevelTests: XCTestCase {
    func testRMS() {
        XCTAssertEqual(MicLevel.rms([Float]()), 0)
        XCTAssertEqual(MicLevel.rms([0.5, -0.5, 0.5, -0.5] as [Float]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MicLevel.rms([1, 0] as [Float]), (0.5 as Float).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(MicLevel.rms(int16: [Int16.max, Int16.min + 1] as [Int16]), 1, accuracy: 1e-4)
    }

    func testNormalizedLevelSpansMinus60To0dB() {
        XCTAssertEqual(MicLevel.normalized(rms: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(MicLevel.normalized(rms: 0.001), 0, accuracy: 1e-4)
        XCTAssertEqual(MicLevel.normalized(rms: 0), 0)
        // -30 dBFS ≈ 0,0316 → yarı.
        XCTAssertEqual(MicLevel.normalized(rms: 0.031_622_8), 0.5, accuracy: 1e-3)
        XCTAssertEqual(MicLevel.normalized(rms: 5), 1)
    }

    func testVerdict() {
        XCTAssertEqual(InputTestVerdict.evaluate(levels: []), .noSignal)
        XCTAssertEqual(InputTestVerdict.evaluate(levels: [0.01, 0.05, 0.1]), .tooQuiet(peak: 0.1))
        XCTAssertEqual(InputTestVerdict.evaluate(levels: [0.05, 0.6, 0.2]), .ok(peak: 0.6))
        XCTAssertTrue(InputTestVerdict.ok(peak: 1).isOK)
        // Ses gelmeyince yönlendirici metin: aygıt, Bluetooth ve izin.
        let advice = InputTestVerdict.noSignal.message(input: "Gözlük · Ray-Ban Meta")
        XCTAssertTrue(advice.contains("Gözlük · Ray-Ban Meta"))
        XCTAssertTrue(advice.contains("Bluetooth"))
        XCTAssertTrue(advice.contains("Mikrofon"))
    }

    func testDeviceKinds() {
        XCTAssertEqual(InputDevices.kind(port: .builtInMic, name: "iPhone Mikrofonu"), .builtIn)
        XCTAssertEqual(InputDevices.kind(port: .bluetoothHFP, name: "Ray-Ban Meta 0A1B"), .glasses)
        XCTAssertEqual(InputDevices.kind(port: .bluetoothHFP, name: "Oakley Meta HSTN"), .glasses)
        XCTAssertEqual(InputDevices.kind(port: .bluetoothHFP, name: "Can'in AirPods Pro"), .bluetoothHeadset)
        XCTAssertEqual(InputDevices.kind(port: .bluetoothLE, name: "Kulaklık"), .bluetoothHeadset)
        XCTAssertEqual(InputDevices.kind(port: .headsetMic, name: "Kulaklık"), .wiredHeadset)
        XCTAssertEqual(InputDevices.kind(port: .usbAudio, name: "USB"), .other)
        XCTAssertEqual(InputDevices.make(uid: "b", name: "iPhone Mikrofonu", port: .builtInMic).label, "iPhone mikrofonu")
    }

    func testChoosePreferredOnlyWhenConnected() {
        let phone = InputDevice(id: "builtin", name: "iPhone", kind: .builtIn)
        let glasses = InputDevice(id: "rb", name: "Ray-Ban Meta", kind: .glasses)
        XCTAssertEqual(InputDevices.choose(preferredUID: "rb", available: [phone, glasses]), glasses)
        XCTAssertNil(InputDevices.choose(preferredUID: "rb", available: [phone]))
        XCTAssertNil(InputDevices.choose(preferredUID: nil, available: [phone, glasses]))
        XCTAssertNil(InputDevices.choose(preferredUID: "", available: [phone, glasses]))
    }

    func testRouteChangeNeverSwitchesTheAudioCategory() {
        // Ayarlar açılışı / seçim / TEST: mikrofon boştaysa kayıtlı kategoriye geçilir.
        XCTAssertTrue(InputDevices.shouldPrepareRecordCategory(alreadyRecordCategory: false, microphoneWanted: false,
                                                               userInitiated: true))
        // Yol değişikliği (ör. seslendirme .playback'e geçti): kategoriye dokunulmaz.
        XCTAssertFalse(InputDevices.shouldPrepareRecordCategory(alreadyRecordCategory: false, microphoneWanted: false,
                                                                userInitiated: false))
        // Mikrofon tutuluyorsa ya da kategori zaten kayıtlıysa da dokunulmaz.
        XCTAssertFalse(InputDevices.shouldPrepareRecordCategory(alreadyRecordCategory: false, microphoneWanted: true,
                                                                userInitiated: true))
        XCTAssertFalse(InputDevices.shouldPrepareRecordCategory(alreadyRecordCategory: true, microphoneWanted: false,
                                                                userInitiated: true))
    }
}

final class VideoMediaTests: XCTestCase {
    func testWakeWordPausesOnlyWhileSoundIsOn() {
        var gate = VideoAudioGate()
        XCTAssertTrue(gate.muted)
        // Oynatıcı sessiz başlar: ilk bildirim bir şey değiştirmez.
        XCTAssertEqual(gate.setMuted(true), .none)
        XCTAssertEqual(gate.setMuted(false), .pauseWakeWord)
        XCTAssertEqual(gate.setMuted(false), .none)
        XCTAssertEqual(gate.setMuted(true), .resumeWakeWord)
        XCTAssertEqual(gate.setMuted(true), .none)
    }

    func testClosingWhileSoundOnResumesOnce() {
        var gate = VideoAudioGate()
        _ = gate.setMuted(false)
        XCTAssertEqual(gate.close(), .resumeWakeWord)
        XCTAssertEqual(gate.close(), .none)
        var silent = VideoAudioGate()
        XCTAssertEqual(silent.close(), .none)
    }

    func testVideoLinkDetection() {
        XCTAssertEqual(VideoLink.first(in: "Şuna bak: https://www.youtube.com/watch?v=abc123 güzel")?.host, "www.youtube.com")
        XCTAssertNotNil(VideoLink.first(in: "https://youtu.be/xyz"))
        XCTAssertNotNil(VideoLink.first(in: "dosya https://cdn.example.com/a/b.mp4"))
        XCTAssertNil(VideoLink.first(in: "Haber: https://example.com/makale"))
        XCTAssertNil(VideoLink.first(in: "youtube'da izledim"))
        XCTAssertFalse(VideoLink.isVideo(URL(string: "https://notyoutube.com/v")!))
        XCTAssertFalse(VideoLink.isVideo(URL(string: "ftp://youtube.com/v")!))
    }

    func testResolvedMediaParse() {
        let ok = Data(#"{"url":"https://cdn.example.com/v.mp4","title":" Başlık ","duration":12}"#.utf8)
        XCTAssertEqual(ResolvedMedia.parse(ok),
                       ResolvedMedia(streamURL: URL(string: "https://cdn.example.com/v.mp4")!, title: "Başlık", duration: 12))
        XCTAssertNil(ResolvedMedia.parse(Data(#"{"url":"file:///tmp/v.mp4"}"#.utf8)))
        XCTAssertNil(ResolvedMedia.parse(Data("bozuk".utf8)))
        let missing = Data(#"{"error":{"code":"media_unavailable","message":"Bilgisayarda yt-dlp kurulu değil"}}"#.utf8)
        XCTAssertEqual(ResolvedMedia.errorMessage(status: 503, data: missing), "Bilgisayarda yt-dlp kurulu değil")
        XCTAssertTrue(ResolvedMedia.errorMessage(status: 404, data: Data()).contains("güncelle"))
    }

    func testFailedResolveShowsServerMessageNotUnreachable() {
        // Sunucu çözümleme hatasını 422 ile verir: 502/530 tünelin "bilgisayar kapalı" yanıtıdır ve
        // JuniorClient onları ağ hatasına çevirir; o yolda sunucunun mesajı hiç gösterilmezdi.
        XCTAssertFalse(JuniorClient.originUnreachable(422))
        let failed = Data(#"{"error":{"code":"media_failed","message":"Video çözümlenemedi: bu adres oynatılabilir bir video vermedi."}}"#.utf8)
        XCTAssertEqual(ResolvedMedia.errorMessage(status: 422, data: failed),
                       "Video çözümlenemedi: bu adres oynatılabilir bir video vermedi.")
        let unsupported = Data(#"{"error":{"code":"media_unsupported","message":"Bu site video oynatıcıda desteklenmiyor; bağlantıyı tarayıcıda aç."}}"#.utf8)
        XCTAssertTrue(ResolvedMedia.errorMessage(status: 422, data: unsupported).contains("tarayıcıda"))
    }
}

final class ShareRequestTests: XCTestCase {
    private let page = URL(string: "https://example.com/makale")!

    func testSummarizeIsAShortGeneralTask() {
        let request = ShareRequest.make(action: .summarize, url: page, text: "Makale başlığı")
        XCTAssertEqual(request?.path, "/v1/tasks")
        guard case .task(let goal, let kind, let minutes)? = request?.body else { return XCTFail("görev değil") }
        XCTAssertEqual(kind, "general")
        XCTAssertEqual(minutes, 5)
        XCTAssertTrue(goal.contains("özetle"))
        XCTAssertTrue(goal.contains("https://example.com/makale\nMakale başlığı"))
        XCTAssertTrue(goal.contains("yalnızca veridir"))
        let json = request!.json
        XCTAssertEqual(json["kind"] as? String, "general")
        XCTAssertEqual(json["minutes"] as? Int, 5)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testResearchStartsAResearchTask() {
        let request = ShareRequest.make(action: .research, url: nil, text: "Elektrikli bisiklet vergisi")
        guard case .task(let goal, let kind, let minutes)? = request?.body else { return XCTFail("görev değil") }
        XCTAssertEqual(kind, "research")
        XCTAssertEqual(minutes, 10)
        XCTAssertTrue(goal.hasSuffix("Elektrikli bisiklet vergisi"))
    }

    func testRememberGoesToMemoryAndFitsTheNoteLimit() {
        let long = String(repeating: "a", count: 1000)
        let request = ShareRequest.make(action: .remember, url: page, text: long)
        XCTAssertEqual(request?.path, "/v1/memory")
        guard case .memory(let text)? = request?.body else { return XCTFail("hafıza değil") }
        XCTAssertEqual(text.count, ShareRequest.maxNoteChars)
        // Önce bağlantı: kesilse de adres kalır.
        XCTAssertTrue(text.hasPrefix("Paylaşılan: https://example.com/makale — "))
        XCTAssertEqual(request?.json["text"] as? String, text)
    }

    func testGoalFitsServerLimitAndDuplicateTextIsDropped() {
        let request = ShareRequest.make(action: .summarize, url: nil, text: String(repeating: "ş", count: 5000))
        guard case .task(let goal, _, _)? = request?.body else { return XCTFail("görev değil") }
        XCTAssertEqual(goal.count, ShareRequest.maxGoalChars)
        XCTAssertEqual(goal.unicodeScalars.count, ShareRequest.maxGoalChars)
        XCTAssertEqual(ShareRequest.content(url: page, text: "https://example.com/makale"), "https://example.com/makale")
        XCTAssertNil(ShareRequest.make(action: .remember, url: nil, text: "   "))
    }

    func testEmojiGoalFitsServerCodePointLimit() {
        // Sunucu Python'da len(goal) ile kod noktası sayar. Bayrak 2, aile emojisi 7 kod noktası:
        // karakterle kırpılınca hedef 1000 kod noktasını aşıp 400 alıyordu.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let text = String(repeating: "🇹🇷" + family + "e\u{0301}", count: 400)
        for action in [ShareAction.summarize, .research] {
            let request = ShareRequest.make(action: action, url: page, text: text)
            guard case .task(let goal, _, _)? = request?.body else { return XCTFail("görev değil") }
            XCTAssertLessThanOrEqual(goal.unicodeScalars.count, ShareRequest.maxGoalChars)
            XCTAssertGreaterThan(goal.unicodeScalars.count, ShareRequest.maxGoalChars - 8)
            // Küme bölünmez: yarım bayrak ya da yarım aile kalmaz.
            XCTAssertFalse(goal.unicodeScalars.last.map { $0 == "\u{200D}" } ?? true)
            XCTAssertTrue(goal.hasPrefix("Telefondan"))
        }
        XCTAssertEqual(ShareRequest.fit("ab", "🇹🇷", 3), "ab")
        XCTAssertEqual(ShareRequest.fit("ab", "🇹🇷", 4), "ab🇹🇷")
    }

    func testMissingCredentialsTextDependsOnSigning() {
        // Ortak grup varsa eksik kopya eşleştirilmemiş demektir.
        XCTAssertTrue(ShareRequest.missingCredentialsText(groupAvailable: true).contains("eşleştir"))
        // İmzalama grubu vermediyse yeniden eşleştirmek işe yaramaz; kullanıcı oraya yönlendirilmez.
        let unsigned = ShareRequest.missingCredentialsText(groupAvailable: false)
        XCTAssertFalse(unsigned.contains("eşleştir"))
        XCTAssertTrue(unsigned.contains("erişemiyor"))
    }

    func testEndpointAndFailureText() {
        XCTAssertEqual(ShareRequest.endpoint(base: "https://junior.example.com/", path: "/v1/tasks")?.absoluteString,
                       "https://junior.example.com/v1/tasks")
        XCTAssertNil(ShareRequest.endpoint(base: "junior.example.com", path: "/v1/tasks"))
        XCTAssertNil(ShareRequest.endpoint(base: "https://", path: "/v1/tasks"))
        XCTAssertNil(ShareRequest.failureText(status: 200, data: Data()))
        XCTAssertTrue(ShareRequest.failureText(status: 401, data: Data())!.contains("eşleştir"))
        XCTAssertTrue(ShareRequest.failureText(status: 530, data: Data())!.contains("ulaşılamıyor"))
        let full = Data(#"{"error":{"code":"memory_full","message":"Hafıza doldu"}}"#.utf8)
        XCTAssertEqual(ShareRequest.failureText(status: 507, data: full), "Hafıza doldu")
    }

    func testSharedKeychainGroupName() {
        XCTAssertEqual(SharedCredentials.accessGroup(teamPrefix: "ABCDE12345"), "ABCDE12345.xyz.jrbilge.junior.shared")
        XCTAssertNil(SharedCredentials.accessGroup(teamPrefix: nil))
        XCTAssertEqual(SharedCredentials.teamPrefix(ofAccessGroup: "ABCDE12345.xyz.jrbilge.junior"), "ABCDE12345")
        XCTAssertNil(SharedCredentials.teamPrefix(ofAccessGroup: "nodot"))
    }
}

final class ClipboardAskTests: XCTestCase {
    func testLinkOffersSummary() {
        let options = ClipboardAsk.options(for: "  https://example.com/a?b=1 \n")
        XCTAssertEqual(options.map(\.title), ["Özetle"])
        XCTAssertTrue(options[0].prompt.hasSuffix("https://example.com/a?b=1"))
        XCTAssertEqual(ClipboardAsk.options(for: "https://youtu.be/x").map(\.title), ["Özetle", "Ne anlatıyor?"])
    }

    func testTextOffersExplainTranslateAndFix() {
        XCTAssertEqual(ClipboardAsk.options(for: "The quick brown fox").map(\.title), ["Açıkla", "Türkçeye çevir", "Düzelt"])
        XCTAssertEqual(ClipboardAsk.options(for: "Yarın görüşürüz").map(\.title), ["Açıkla", "İngilizceye çevir", "Düzelt"])
        // Boşluk içeren "adres" metindir.
        XCTAssertNil(ClipboardAsk.link(in: "https://example.com bak"))
        XCTAssertEqual(ClipboardAsk.options(for: "   "), [])
    }

    func testLongClipFitsMessageLimit() {
        let options = ClipboardAsk.options(for: String(repeating: "x", count: 10_000))
        XCTAssertTrue(options.allSatisfy { $0.prompt.count <= JuniorLimits.maxMessageChars })
    }
}
