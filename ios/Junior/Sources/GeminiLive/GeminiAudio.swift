import AVFoundation
import Foundation

/// MicrophoneHub'ın tek ses kanalından Gemini Live oturumuna giden kol. Ses iş parçacığından yazılır.
///
/// GİZLİLİK: Bu tüketici yalnız kullanıcı konuş düğmesiyle Gemini oturumu açtığında
/// MicrophoneHub'a bağlanır ve oturum kapanınca (ya da geri düşüşte) hemen çıkarılır.
/// Telefonda sürekli dinleme (LiveTap → bilgisayara yükleme) ve gün boyu kayıt
/// (AllDayRecorder → yerel WAV) ayrı tüketicilerdir; onların biriktirdiği ses ve dosyalar
/// hiçbir zaman buraya verilmez, dolayısıyla Gemini'ye (Google'a) gitmez.
final class GeminiMicTap: @unchecked Sendable {
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.inputRate),
                                       channels: 1, interleaved: true)
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var chunker = PCMChunker()
    private var gate = BargeInGate()
    private var closed = false

    private let isPlaying: @Sendable () -> Bool
    private let send: @Sendable (Data) -> Void
    private let bargeIn: @Sendable () -> Void

    /// - isPlaying: Junior'ın sesi çalıyor mu (yankı kapısı)
    /// - send: 100 ms'lik 16 kHz PCM16 parça köprüye gitsin
    /// - bargeIn: kullanıcı söze girdi, çalan ses hemen sussun
    init(isPlaying: @escaping @Sendable () -> Bool,
         send: @escaping @Sendable (Data) -> Void,
         bargeIn: @escaping @Sendable () -> Void) {
        self.isPlaying = isPlaying
        self.send = send
        self.bargeIn = bargeIn
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var outgoing: [Data] = []
        var interrupted = false
        lock.lock()
        guard !closed, let target, buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
            lock.unlock()
            return
        }
        // Gözlük bağlanınca/kopunca giriş biçimi değişir; çevirici yeniden kurulur (PCMCapture ile aynı).
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        if let converter {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            if let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) {
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
                if error == nil, out.frameLength > 0, let channel = out.int16ChannelData {
                    let pcm = Data(bytes: channel[0], count: Int(out.frameLength) * 2)
                    let playing = isPlaying()
                    for chunk in chunker.push(pcm) {
                        switch gate.decide(chunk, rms: PCM16.rms(chunk), playing: playing) {
                        case .send(let parts):
                            outgoing += parts
                        case .hold:
                            break
                        case .bargeIn(let parts):
                            outgoing += parts
                            interrupted = true
                        }
                    }
                }
            }
        }
        lock.unlock()
        if interrupted { bargeIn() }
        for chunk in outgoing { send(chunk) }
    }

    /// Oturum bitti: bundan sonra gelen ses hiçbir yere gitmez.
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        chunker.reset()
    }
}

/// Köprüden gelen PCM16 sesi (24 kHz) kesintisiz çalar.
///
/// Kendi AVAudioEngine'i ve AVAudioPlayerNode'u vardır; ses oturumuna dokunmaz: MicrophoneHub
/// oturumu .playAndRecord olarak açık tutuyor, bu kategori çalmayı da destekler (SpeechService'in
/// kuralı: mikrofon tutulurken kategori değiştirilmez). Parçalar sıraya konur, biri biterken
/// sıradaki hazırdır; `stop()` sıradaki her şeyi hemen siler (söz kesilince).
///
/// "Çalıyor mu" bilgisi tamamlanma geri çağrılarından değil, sıraya konan sesin süresinden
/// hesaplanır: ses yolu değişip motor durursa geri çağrılar hiç gelmeyebilir ve yankı kapısı
/// mikrofonu sonsuza dek bekletirdi.
final class GeminiPCMPlayer: @unchecked Sendable {
    /// Çalma bittikten sonra odadaki yankı ve çıkış gecikmesi bu süre daha "çalıyor" sayılır.
    static let echoTail: TimeInterval = 0.35

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// Sıraya konan son parçanın tahmini bitiş anı.
    private var playsUntil = Date.distantPast

    /// Sırada ya da çalmakta ses var mı (yankı kuyruğu dahil). Ses iş parçacığından da okunur.
    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < playsUntil.addingTimeInterval(Self.echoTail)
    }

    func enqueue(_ pcm: Data, rate: Int) {
        let samples = PCM16.floats(pcm)
        guard !samples.isEmpty, rate > 0 else { return }
        lock.lock()
        guard let prepared = prepare(rate: Double(rate)),
              let buffer = AVAudioPCMBuffer(pcmFormat: prepared.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else {
            lock.unlock()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let out = channel[0]
        for index in 0..<samples.count { out[index] = samples[index] }
        let now = Date()
        playsUntil = max(now, playsUntil).addingTimeInterval(Double(samples.count) / Double(rate))
        lock.unlock()
        // Düğüm çağrıları kilit dışında: stop() düğümün kendi geri çağrılarını eşzamanlı tetikleyebilir.
        prepared.node.scheduleBuffer(buffer, completionHandler: nil)
        if prepared.engine.isRunning, !prepared.node.isPlaying { prepared.node.play() }
    }

    /// Çalanı ve sıradakileri hemen susturur (kullanıcı söze girdi ya da oturum bitti). Yankı
    /// beklemesi yok: kullanıcı konuşuyor, sesi hemen köprüye gitmeli.
    func stop() {
        lock.lock()
        playsUntil = .distantPast
        let node = self.node
        lock.unlock()
        node?.stop()
    }

    /// Oturum kapandı: motor da kapanır (bir sonraki oturumda yeniden kurulur).
    func close() {
        stop()
        lock.lock()
        let engine = self.engine
        self.engine = nil
        node = nil
        format = nil
        lock.unlock()
        engine?.stop()
    }

    /// Kilit tutulurken çağrılır. Motoru kurar ya da durmuşsa (ses yolu değişti) yeniden açar.
    private func prepare(rate: Double) -> (engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat)? {
        let engine = self.engine ?? AVAudioEngine()
        let node = self.node ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(node)
            self.engine = engine
            self.node = node
        }
        if format?.sampleRate != rate {
            guard let wanted = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
            if engine.isRunning { engine.stop() }
            // Karıştırıcı örnekleme hızını donanımınkine kendisi çevirir.
            engine.connect(node, to: engine.mainMixerNode, format: wanted)
            format = wanted
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return nil
            }
        }
        guard let ready = self.format else { return nil }
        return (engine, node, ready)
    }
}
