import AVFoundation
import Foundation

/// Konuşma parçasını yüklemeye hazır sese çevirir.
enum LiveEncoder {
    /// AAC (.m4a, 16 kHz tek kanal, 24 kbps ≈ 3 KB/sn). Kodlayıcı çalışmazsa
    /// 16 bit WAV'a düşer: 5 kat büyük ama sunucu ikisini de kabul ediyor, yani
    /// kodlama sorunu yüzünden konuşma kaybolmaz.
    static func encode(_ segment: LiveSegment) -> (data: Data, ext: String)? {
        guard !segment.samples.isEmpty else { return nil }
        if let aac = encodeAAC(segment.samples) { return (aac, "m4a") }
        let body = segment.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return (WAVFile.pcm16(body, sampleRate: SpeechSegmenter.sampleRate), "wav")
    }

    static func encodeAAC(_ samples: [Int16]) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(SpeechSegmenter.sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            // Dosya kapsam bitince (nil'e eşitlenince) kapanır; veri ancak o zaman tamamlanır.
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
            guard let format = file?.processingFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            for (index, value) in samples.enumerated() { channel[index] = Float(value) / 32768 }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file?.write(from: buffer)
            file = nil
            let data = try Data(contentsOf: url)
            return data.count > 64 ? data : nil
        } catch {
            return nil
        }
    }
}

/// Mikrofon tap'inden gelen sesi 16 kHz tek kanal 16 bit'e çevirir.
/// İş parçacığı güvenli değildir; çağıran kilit altında kullanır.
final class PCM16Converter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SpeechSegmenter.sampleRate),
                                       channels: 1, interleaved: true)
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let target, buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return [] }
        // Gözlük bağlanınca/kopunca giriş biçimi değişir; çevirici yeniden kurulur.
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}

/// MicrophoneHub'ın ses iş parçacığından beslediği sürekli dinleme tüketicisi.
///
/// `append` gerçek zamanlı ses iş parçacığında çalışır; orada yalnız çevirme ve
/// kesme yapılır. Kodlama ve diske yazma ayrı bir seri kuyrukta olur, böylece
/// ses hiç takılmaz.
final class LiveTap: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = PCM16Converter()
    private var segmenter = SpeechSegmenter()
    private var suppressed = false
    private let work = DispatchQueue(label: "xyz.jrbilge.junior.live-encode", qos: .utility)
    private let onSegment: @Sendable (LiveSegment, Data, String) -> Void

    /// - Parameter onSegment: kodlanmış parça (ses verisi ve uzantı); ses iş parçacığında **değil**, seri kuyrukta çağrılır.
    init(onSegment: @escaping @Sendable (LiveSegment, Data, String) -> Void) {
        self.onSegment = onSegment
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !suppressed else { lock.unlock(); return }
        let samples = converter.convert(buffer)
        let segments = samples.isEmpty
            ? []
            : segmenter.feed(samples, endMs: Int64(Date().timeIntervalSince1970 * 1000))
        lock.unlock()
        emit(segments)
    }

    /// Junior konuşurken kendi sesi kaydedilmesin; açık parça atılmaz, bitirilir.
    func setSuppressed(_ value: Bool) {
        lock.lock()
        guard suppressed != value else { lock.unlock(); return }
        suppressed = value
        let tail = value ? segmenter.flush() : nil
        if !value { segmenter.reset() }
        lock.unlock()
        if let tail { emit([tail]) }
    }

    /// Dinleme durdurulurken açık parçayı bitirir.
    func flush() {
        lock.lock()
        let tail = segmenter.flush()
        lock.unlock()
        if let tail { emit([tail]) }
    }

    private func emit(_ segments: [LiveSegment]) {
        for segment in segments {
            work.async { [onSegment] in
                guard let encoded = LiveEncoder.encode(segment) else { return }
                onSegment(segment, encoded.data, encoded.ext)
            }
        }
    }
}
