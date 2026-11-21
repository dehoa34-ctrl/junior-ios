import XCTest
@testable import Junior

/// Tarifle video, sesle sarma ve "bilgisayar açılınca" kuyruğu: saf parçalar. Ağ ve oynatıcı yok.
final class VideoVoiceCommandTests: XCTestCase {
    func testSeekPhrases() {
        XCTAssertEqual(VideoVoiceCommand.parse("30 saniye ileri"), .seek(30))
        XCTAssertEqual(VideoVoiceCommand.parse("Hey Junior, on saniye geri al."), .seek(-10))
        XCTAssertEqual(VideoVoiceCommand.parse("2 dakika ileri sar"), .seek(120))
        XCTAssertEqual(VideoVoiceCommand.parse("telefonda otuz saniye ileri"), .seek(30))
    }

    func testSeekToPhrases() {
        XCTAssertEqual(VideoVoiceCommand.parse("1:20'ye git"), .seekTo(80))
        XCTAssertEqual(VideoVoiceCommand.parse("1 dakika 20 saniyeye git"), .seekTo(80))
        XCTAssertEqual(VideoVoiceCommand.parse("2 dakikaya git"), .seekTo(120))
        XCTAssertEqual(VideoVoiceCommand.parse("30 saniyeye git"), .seekTo(30))
    }

    func testPauseVolumeAndClose() {
        XCTAssertEqual(VideoVoiceCommand.parse("Duraklat"), .pause)
        XCTAssertEqual(VideoVoiceCommand.parse("devam et"), .play)
        XCTAssertEqual(VideoVoiceCommand.parse("Sesi kıs"), .volumeDown)
        XCTAssertEqual(VideoVoiceCommand.parse("sesi aç"), .volumeUp)
        XCTAssertEqual(VideoVoiceCommand.parse("sessize al"), .mute)
        XCTAssertEqual(VideoVoiceCommand.parse("videoyu kapat"), .close)
    }

    func testOtherSentencesAreNotVideoCommands() {
        // "bilgisayarda …" sunucuya gider (adadaki video); sohbet cümleleri de.
        XCTAssertNil(VideoVoiceCommand.parse("bilgisayarda 30 saniye ileri"))
        XCTAssertNil(VideoVoiceCommand.parse("yarın hava nasıl"))
        XCTAssertNil(VideoVoiceCommand.parse("ileri git"))
        XCTAssertNil(VideoVoiceCommand.parse(""))
    }

    func testServerActions() {
        XCTAssertEqual(VideoVoiceCommand.fromServer(action: "seek", seconds: -15), .seek(-15))
        XCTAssertEqual(VideoVoiceCommand.fromServer(action: "seek_to", seconds: 80), .seekTo(80))
        XCTAssertEqual(VideoVoiceCommand.fromServer(action: "volume_down", seconds: nil), .volumeDown)
        XCTAssertNil(VideoVoiceCommand.fromServer(action: "seek", seconds: nil))
        XCTAssertNil(VideoVoiceCommand.fromServer(action: "format", seconds: nil))
    }

    func testSeekMathAndClock() {
        XCTAssertEqual(VideoSeekMath.target(current: 10, delta: 30, duration: 155), 40)
        XCTAssertEqual(VideoSeekMath.target(current: 10, delta: -60, duration: 155), 0)
        XCTAssertEqual(VideoSeekMath.target(current: 150, delta: 30, duration: 155), 154.5)
        XCTAssertEqual(VideoSeekMath.target(current: .nan, delta: 30, duration: nil), 30)
        XCTAssertEqual(VideoSeekMath.clock(80), "1:20")
        XCTAssertEqual(VideoSeekMath.clock(3725), "1:02:05")
    }

    func testEmbedAddresses() {
        XCTAssertEqual(VideoEmbed.embedURL(for: URL(string: "https://www.youtube.com/watch?v=abc123XYZ")!)?.absoluteString,
                       "https://www.youtube.com/embed/abc123XYZ?playsinline=1")
        XCTAssertEqual(VideoEmbed.embedURL(for: URL(string: "https://youtu.be/abc123XYZ")!)?.absoluteString,
                       "https://www.youtube.com/embed/abc123XYZ?playsinline=1")
        XCTAssertEqual(VideoEmbed.embedURL(for: URL(string: "https://vimeo.com/123456789")!)?.absoluteString,
                       "https://player.vimeo.com/video/123456789")
        XCTAssertNil(VideoEmbed.embedURL(for: URL(string: "https://www.youtube.com/watch?v=a%22b")!))
        XCTAssertNil(VideoEmbed.embedURL(for: URL(string: "https://example.com/watch?v=abc")!))
    }

    func testPlayVideoAndControlPhoneActions() {
        let play = PhoneAction.parse(["name": "play_video",
                                      "arguments": ["url": "https://www.youtube.com/watch?v=abc", "title": "Dune Fragman"]])
        XCTAssertEqual(play, .playVideo(url: URL(string: "https://www.youtube.com/watch?v=abc")!, title: "Dune Fragman"))
        XCTAssertEqual(play?.needsForeground, true)
        // Bilinmeyen site ya da adres olmayan değer eylem olmaz.
        XCTAssertNil(PhoneAction.parse(["name": "play_video", "arguments": ["url": "https://evil.example/x"]]))
        XCTAssertNil(PhoneAction.parse(["name": "play_video", "arguments": [String: Any]()]))
        let control = PhoneAction.parse(["name": "video_control", "arguments": ["action": "seek_to", "seconds": 80]])
        XCTAssertEqual(control, .videoControl(.seekTo(80)))
        XCTAssertEqual(control?.needsForeground, false)
    }

    @MainActor
    func testCenterWithoutPlayerLeavesSentenceToTheServer() {
        let center = VideoPlaybackCenter()
        XCTAssertFalse(center.isActive)
        XCTAssertNil(center.handleVoice("30 saniye ileri"))
        XCTAssertNil(center.apply(.pause))
        let owner = UUID()
        var closed = false
        center.attachEmbedded(owner: owner) { closed = true }
        XCTAssertTrue(center.isActive)
        XCTAssertTrue(center.handleVoice("30 saniye ileri")?.contains("gömülü oynatıcıda") ?? false)
        XCTAssertEqual(center.handleVoice("videoyu kapat"), "Videoyu kapattım.")
        XCTAssertTrue(closed)
        // Başka bir sayfanın kapanışı kaydı silmez.
        center.detach(owner: UUID())
        XCTAssertTrue(center.isActive)
        center.detach(owner: owner)
        XCTAssertFalse(center.isActive)
    }
}

final class RemoteQueueTests: XCTestCase {
    func testParseQueueKeepsOnlyQueuedJobs() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = try JSONSerialization.data(withJSONObject: ["jobs": [
            ["id": "a1", "text": "Bilgisayar açılınca Spotify'ı aç", "state": "queued", "deferred": true, "expires_in": 83_400],
            ["id": "b2", "text": "x", "state": "claimed", "deferred": true],
            ["text": "kimliksiz", "state": "queued"],
        ]])
        let items = try XCTUnwrap(RemoteQueueItem.parseList(data, now: now))
        XCTAssertEqual(items.map(\.id), ["a1"])
        XCTAssertEqual(items[0].expiresAt, now.addingTimeInterval(83_400))
        XCTAssertEqual(items[0].remainingText(now: now), "23 sa 10 dk içinde alınmazsa silinir")
        XCTAssertNil(RemoteQueueItem.parseList(Data("{}".utf8)))
    }

    func testCancelMessages() {
        XCTAssertNil(RemoteQueueItem.cancelMessage(status: 200))
        XCTAssertNil(RemoteQueueItem.cancelMessage(status: 404))
        XCTAssertEqual(RemoteQueueItem.cancelMessage(status: 409), "Bilgisayar bu işi az önce aldı; artık iptal edilemez.")
    }
}
