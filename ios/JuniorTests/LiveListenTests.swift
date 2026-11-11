import XCTest
@testable import Junior

/// Sürekli dinlemenin saf parçaları: konuşma kesici, kuyruk, bekleme, başlıklar.
/// Mikrofon, ağ ya da gerçek ses motoru kullanmaz.
final class SpeechSegmenterTests: XCTestCase {
    private let rate = SpeechSegmenter.sampleRate

    /// `seconds` süren, tam ölçeğin `amplitude` oranında 220 Hz sinüs.
    private func tone(_ seconds: Double, amplitude: Double = 0.25) -> [Int16] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            Int16(sin(2 * Double.pi * 220 * Double(index) / Double(rate)) * amplitude * 32767)
        }
    }

    private func silence(_ seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// Örnekleri 100 ms'lik dilimlerle besler; saat 1_000_000 ms'den başlar.
    private func run(_ samples: [Int16], flush: Bool = true) -> [LiveSegment] {
        var segmenter = SpeechSegmenter()
        var out: [LiveSegment] = []
        let chunk = rate / 10
        var clock: Int64 = 1_000_000
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            clock += Int64(end - offset) * 1000 / Int64(rate)
            out += segmenter.feed(Array(samples[offset..<end]), endMs: clock)
            offset = end
        }
        if flush, let tail = segmenter.flush() { out.append(tail) }
        return out
    }

    func testSilenceMakesNoSegment() {
        XCTAssertTrue(run(silence(10)).isEmpty)
    }

    func testOneBurstMakesOneSegmentWithPrerollAndTrimmedTail() {
        let samples = silence(1) + tone(2) + silence(3)
        let segments = run(samples)
        XCTAssertEqual(segments.count, 1)
        let segment = segments[0]
        // 2 sn konuşma + 0,3 sn öncesi + 0,3 sn sonrası kırpılmış sessizlik.
        XCTAssertGreaterThan(segment.duration, 2.4)
        XCTAssertLessThan(segment.duration, 3.0)
        XCTAssertGreaterThan(segment.t1, segment.t0)
        XCTAssertGreaterThan(segment.rms, 0.1)
    }

    func testTwoBurstsFarApartMakeTwoOrderedSegments() {
        let samples = silence(1) + tone(1) + silence(2) + tone(1) + silence(2)
        let segments = run(samples)
        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThan(segments[0].t1, segments[1].t0)
        XCTAssertLessThan(segments[0].t0, segments[0].t1)
    }

    func testShortPauseKeepsOneSegment() {
        // 0,4 sn nefes arası hangover'dan (0,7 sn) kısa: tek cümle.
        let samples = silence(0.5) + tone(1) + silence(0.4) + tone(1) + silence(2)
        XCTAssertEqual(run(samples).count, 1)
    }

    func testShortClickIsDiscarded() {
        let samples = silence(1) + tone(0.06) + silence(3)
        XCTAssertTrue(run(samples).isEmpty)
    }

    func testVeryQuietNoiseBelowFloorIsIgnored() {
        // Tam ölçeğin %0,3'ü: mutlak alt sınırın (%0,6) altında.
        XCTAssertTrue(run(tone(5, amplitude: 0.004) + silence(2)).isEmpty)
    }

    func testContinuousSpeechIsCutAtMaximumLength() {
        let segments = run(tone(60))
        XCTAssertGreaterThanOrEqual(segments.count, 3)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.duration, 25.01)
            XCTAssertGreaterThan(segment.t1, segment.t0)
        }
        // Zaman damgaları geriye gitmez.
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertLessThanOrEqual(a.t1, b.t0 + 1) }
    }

    func testFlushClosesOpenSegment() {
        let open = run(silence(0.5) + tone(2), flush: false)
        XCTAssertTrue(open.isEmpty, "konuşma sürerken parça henüz bitmemeli")
        XCTAssertEqual(run(silence(0.5) + tone(2), flush: true).count, 1)
    }

    func testTimestampsFollowTheWallClock() {
        // Konuşma kayıdın 1. saniyesinde başlıyor; t0 yaklaşık 1_000_000 + 700 (öncesi 0,3 sn).
        let segments = run(silence(1) + tone(1) + silence(2))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(Double(segments[0].t0), 1_000_000 + 700, accuracy: 120)
    }

    func testResetForgetsOpenSpeech() {
        var segmenter = SpeechSegmenter()
        _ = segmenter.feed(tone(2), endMs: 5_000)
        XCTAssertTrue(segmenter.isInSpeech)
        segmenter.reset()
        XCTAssertFalse(segmenter.isInSpeech)
        XCTAssertNil(segmenter.flush())
    }
}

final class LiveQueueTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("livequeue-\(UUID().uuidString)", isDirectory: true)
    }

    private func item(_ id: String, t0: Int64, bytes: Int) -> LiveQueueItem {
        LiveQueueItem(id: id, t0: t0, t1: t0 + 1000, rms: nil, ext: "m4a", bytes: bytes)
    }

    func testOverflowDropsOldestFirstUntilUnderCap() {
        let items = [item("c", t0: 30, bytes: 400), item("a", t0: 10, bytes: 400), item("b", t0: 20, bytes: 400)]
        let dropped = LiveQueuePolicy.overflow(items, capBytes: 900)
        XCTAssertEqual(dropped.map(\.id), ["a"])
        XCTAssertEqual(LiveQueuePolicy.overflow(items, capBytes: 500).map(\.id), ["a", "b"])
        XCTAssertTrue(LiveQueuePolicy.overflow(items, capBytes: 1200).isEmpty)
    }

    func testEnqueueKeepsChronologicalOrderAndFirstIsOldest() {
        let queue = LiveQueue(directory: makeDirectory(), capBytes: 1_000_000)
        queue.enqueue(id: "ph-2", audio: Data(repeating: 1, count: 10), ext: "m4a", t0: 2_000, t1: 3_000, rms: 0.1)
        queue.enqueue(id: "ph-1", audio: Data(repeating: 1, count: 10), ext: "m4a", t0: 1_000, t1: 1_500, rms: nil)
        XCTAssertEqual(queue.items().map(\.id), ["ph-1", "ph-2"])
        XCTAssertEqual(queue.first()?.id, "ph-1")
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.totalBytes, 20)
    }

    func testRemoveDeletesFilesAndIndex() throws {
        let directory = makeDirectory()
        let queue = LiveQueue(directory: directory)
        let result = try XCTUnwrap(queue.enqueue(id: "ph-x", audio: Data([1, 2, 3]), ext: "wav", t0: 5, t1: 10, rms: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.audioURL(result.item).path))
        queue.remove(result.item)
        XCTAssertEqual(queue.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.audioURL(result.item).path))
    }

    func testCapDropsOldestAndReportsCount() {
        let queue = LiveQueue(directory: makeDirectory(), capBytes: 25)
        queue.enqueue(id: "ph-1", audio: Data(count: 10), ext: "m4a", t0: 1, t1: 2, rms: nil)
        queue.enqueue(id: "ph-2", audio: Data(count: 10), ext: "m4a", t0: 2, t1: 3, rms: nil)
        let third = queue.enqueue(id: "ph-3", audio: Data(count: 10), ext: "m4a", t0: 3, t1: 4, rms: nil)
        XCTAssertEqual(third?.dropped, 1)
        XCTAssertEqual(queue.items().map(\.id), ["ph-2", "ph-3"])
        XCTAssertLessThanOrEqual(queue.totalBytes, 25)
    }

    func testQueueSurvivesRestartAndCleansHalfWrittenFiles() throws {
        let directory = makeDirectory()
        do {
            let queue = LiveQueue(directory: directory)
            queue.enqueue(id: "ph-keep", audio: Data(count: 8), ext: "m4a", t0: 7, t1: 9, rms: 0.2)
        }
        // Yarım yazma: json'suz ses dosyası.
        try Data(count: 5).write(to: directory.appendingPathComponent("ph-orphan.m4a"))
        let reopened = LiveQueue(directory: directory)
        XCTAssertEqual(reopened.items().map(\.id), ["ph-keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ph-orphan.m4a").path))
    }
}

final class LiveUploadTests: XCTestCase {
    func testBackoffGrowsAndCapsAndResets() {
        var backoff = UploadBackoff()
        XCTAssertEqual(backoff.delay, 0)
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            backoff.failed()
            delays.append(backoff.delay)
        }
        XCTAssertEqual(Array(delays.prefix(4)), [5, 10, 20, 40])
        XCTAssertEqual(delays.last, 300)
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        backoff.succeeded()
        XCTAssertEqual(backoff.delay, 0)
    }

    func testIDIsLongEnoughAndStablePrefix() {
        let id = LiveUpload.makeID(t0: 1_700_000_000_123, random: "ABCDEF12-3456-7890-ABCD-EF1234567890")
        XCTAssertEqual(id, "ph-1700000000123-abcdef12")
        XCTAssertTrue((16...100).contains(id.count))
        XCTAssertNotEqual(LiveUpload.makeID(t0: 5), LiveUpload.makeID(t0: 5))
    }

    func testRequestCarriesContractHeaders() throws {
        let item = LiveQueueItem(id: "ph-1700000000123-abcdef12", t0: 1_700_000_000_123, t1: 1_700_000_004_623,
                                 rms: 0.04321, ext: "m4a", bytes: 1234)
        let url = try XCTUnwrap(URL(string: "https://junior.example.com/v1/live/segment"))
        let request = LiveUpload.request(url: url, token: "tok", item: item)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Live-Id"), item.id)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Live-T0"), "1700000000123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Live-T1"), "1700000004623")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Live-Rms"), "0.0432")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
    }

    func testWavUsesWavContentTypeAndBadClockIsRepaired() throws {
        // t1 <= t0 ya da süre 60 sn'yi aşıyorsa sunucu reddederdi; başlık onarılır.
        let url = try XCTUnwrap(URL(string: "https://x.example.com/v1/live/segment"))
        let backwards = LiveQueueItem(id: "ph-aaaaaaaaaaaaaaaa", t0: 5_000, t1: 4_000, rms: nil, ext: "wav", bytes: 1)
        let request = LiveUpload.request(url: url, token: "t", item: backwards)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Live-T1"), "5001")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Live-Rms"))
        let long = LiveQueueItem(id: "ph-bbbbbbbbbbbbbbbb", t0: 0, t1: 200_000, rms: nil, ext: "m4a", bytes: 1)
        XCTAssertEqual(LiveUpload.request(url: url, token: "t", item: long).value(forHTTPHeaderField: "X-Live-T1"), "60000")
    }

    func testStatusClassification() {
        XCTAssertEqual(LiveUpload.classify(status: 200), .accepted)
        XCTAssertEqual(LiveUpload.classify(status: 401), .unauthorized)
        XCTAssertEqual(LiveUpload.classify(status: 413), .reject)
        XCTAssertEqual(LiveUpload.classify(status: 400), .reject)
        XCTAssertEqual(LiveUpload.classify(status: 429), .retry)
        XCTAssertEqual(LiveUpload.classify(status: 503), .retry)
        XCTAssertEqual(LiveUpload.classify(status: 404), .unsupported)
        XCTAssertEqual(LiveUpload.classify(status: 405), .unsupported)
    }

    func testFirstSkipsParkedItems() {
        let queue = LiveQueue(directory: FileManager.default.temporaryDirectory
                                .appendingPathComponent("junior-skip-\(UUID().uuidString)"),
                              capBytes: 1_000_000)
        queue.enqueue(id: "ph-1", audio: Data(repeating: 1, count: 10), ext: "m4a", t0: 1_000, t1: 1_500, rms: nil)
        queue.enqueue(id: "ph-2", audio: Data(repeating: 1, count: 10), ext: "m4a", t0: 2_000, t1: 2_500, rms: nil)
        XCTAssertEqual(queue.first(skipping: ["ph-1"])?.id, "ph-2")
        XCTAssertNil(queue.first(skipping: ["ph-1", "ph-2"]))
    }
}

final class LiveEncoderTests: XCTestCase {
    func testEncodesToSomethingUploadable() throws {
        // Kodlayıcı simülatörde AAC verir; vermezse WAV'a düşer. İkisi de geçerlidir.
        let samples = (0..<16_000).map { Int16(sin(Double($0) / 20) * 8000) }
        let segment = LiveSegment(samples: samples, t0: 1, t1: 1001, rms: 0.1)
        let encoded = try XCTUnwrap(LiveEncoder.encode(segment))
        XCTAssertTrue(["m4a", "wav"].contains(encoded.ext))
        XCTAssertGreaterThan(encoded.data.count, 100)
        if encoded.ext == "wav" {
            XCTAssertEqual(String(data: encoded.data.prefix(4), encoding: .ascii), "RIFF")
        }
    }

    func testLocalRecordingNameParsesToWindowEndingAtStamp() {
        // 60 sn = 1_920_000 bayt PCM + 44 bayt başlık
        let parsed = LocalRecording.parse(fileName: "junior-1762881234-567-ABCDEF12.wav", byteCount: 1_920_044)
        XCTAssertEqual(parsed?.t1, 1_762_881_234_567)
        XCTAssertEqual(parsed?.t0, 1_762_881_234_567 - 60_000)
        XCTAssertEqual(parsed?.id, "ph-\(1_762_881_234_567 - 60_000)-abcdef12")
        XCTAssertGreaterThanOrEqual(parsed?.id.count ?? 0, 16)
    }

    func testLocalRecordingShortAndOversizedChunks() {
        XCTAssertEqual(LocalRecording.parse(fileName: "junior-100000-000-ABCDEF12.wav", byteCount: 32_044)?.t0, 100_000_000 - 1000)
        // Biraz taşan parça 60 sn'ye kırpılır (sunucu sınırı).
        let long = LocalRecording.parse(fileName: "junior-100000-000-ABCDEF12.wav", byteCount: 1_930_044)
        XCTAssertEqual((long?.t1 ?? 0) - (long?.t0 ?? 0), 60_000)
    }

    func testLocalRecordingRejectsForeignNames() {
        XCTAssertNil(LocalRecording.parse(fileName: "notlar.wav", byteCount: 5000))
        XCTAssertNil(LocalRecording.parse(fileName: "junior-abc-1-ABCDEF12.wav", byteCount: 5000))
        XCTAssertNil(LocalRecording.parse(fileName: "junior-1762881234-567-ABCDEF12.wav", byteCount: 44))
        XCTAssertNil(LocalRecording.parse(fileName: "junior-1762881234-567-XYZ.wav", byteCount: 5000))
    }

    func testEmptySegmentIsNotEncoded() {
        XCTAssertNil(LiveEncoder.encode(LiveSegment(samples: [], t0: 1, t1: 2, rms: 0)))
    }
}
