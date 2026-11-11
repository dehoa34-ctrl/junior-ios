import Foundation

/// Konuşmadan kesilmiş tek parça: 16 kHz tek kanal 16 bit PCM ve zaman damgaları.
struct LiveSegment: Equatable {
    var samples: [Int16]
    /// Parçanın başladığı an (epoch, milisaniye).
    var t0: Int64
    /// Parçanın bittiği an (epoch, milisaniye); her zaman `t0`'dan büyük.
    var t1: Int64
    /// Konuşulan karelerin ortalama ses düzeyi (0...1, tam ölçeğe göre RMS).
    var rms: Double

    var duration: Double { Double(samples.count) / Double(SpeechSegmenter.sampleRate) }
}

/// Enerji + "asılı kalma" (hangover) tabanlı basit konuşma kesici.
///
/// Mikrofondan akan 16 kHz sesi alır, konuşmayı sessizlikten ayırır ve
/// 0,6–25 saniyelik parçalar üretir. Saf mantıktır: ses motoruna, saate ya da
/// diske dokunmaz; bu yüzden birim testle denenebilir.
///
/// Neden bu kadar basit: telefon gün boyu açık kalacak, işlemciyi ve pili
/// yoran bir model istemiyoruz. Asıl yazıya çevirme ve konuşmacı ayrımı
/// bilgisayarda yapılıyor; burada tek iş "sessiz saatleri yüklememek" ve
/// konuşmayı cümle ortasında bölmemek.
///
/// Davranış:
/// - Gürültü tabanı yavaşça öğrenilir; eşik = max(mutlak alt sınır, taban × 3).
/// - Ardışık 4 kare (80 ms) eşiği aşarsa konuşma başlar; öncesindeki 300 ms
///   de parçaya girer ki ilk hece kesilmesin.
/// - 700 ms sessizlik konuşmayı bitirir; sondaki sessizlik 300 ms'ye kırpılır.
/// - 20 saniyeden sonra kısa bir duraklamada, 25 saniyede ne olursa olsun kesilir.
/// - 0,3 saniyeden az gerçek konuşma içeren parçalar (kapı çarpması, öksürük) atılır.
struct SpeechSegmenter {
    static let sampleRate = 16_000

    struct Parameters: Equatable {
        var frameMs = 20
        /// Eşiğin altına inemeyeceği mutlak düzey (tam ölçeğin oranı).
        var minThreshold = 0.006
        /// Gürültü tabanının kaç katı konuşma sayılır.
        var noiseRatio = 3.0
        var onsetFrames = 4
        var prerollFrames = 15
        var hangoverFrames = 35
        var keepTailFrames = 15
        var minSegmentSeconds = 0.6
        var minVoicedSeconds = 0.3
        var softMaxSeconds = 20.0
        var softCutSilenceFrames = 10
        var maxSeconds = 25.0
    }

    private struct Frame {
        var samples: [Int16]
        var time: Int64
        var level: Double
    }

    let parameters: Parameters
    private var pending: [Int16] = []
    private var ring: [Frame] = []
    private var voicedRun = 0
    private var active = false
    private var buffer: [Int16] = []
    private var startMs: Int64 = 0
    private var silenceRun = 0
    private var voicedFrames = 0
    private var levelSum = 0.0
    private(set) var noiseFloor = 0.002

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    private var frameSize: Int { Self.sampleRate * parameters.frameMs / 1000 }

    /// Konuşma sürüyor mu (açık bir parça birikiyor mu).
    var isInSpeech: Bool { active }

    /// Yeni örnekleri işler; biten parçaları döndürür.
    /// - Parameter endMs: bu örneklerin **sonunun** duvar saati (epoch ms).
    mutating func feed(_ samples: [Int16], endMs: Int64) -> [LiveSegment] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)
        let size = frameSize
        // Bekleyen ilk örneğin duvar saati: sonu bilinen bir akışta geriye doğru sayılır.
        let pendingStart = endMs - Int64(pending.count) * 1000 / Int64(Self.sampleRate)
        var out: [LiveSegment] = []
        var offset = 0
        var index = 0
        while pending.count - offset >= size {
            let frame = Array(pending[offset..<offset + size])
            let time = pendingStart + Int64(index * parameters.frameMs)
            if let segment = process(frame, time: time) { out.append(segment) }
            offset += size
            index += 1
        }
        if offset > 0 { pending.removeFirst(offset) }
        return out
    }

    /// Akış kesilirken (duraklatma, kapatma) açık parçayı bitirir.
    mutating func flush() -> LiveSegment? {
        pending.removeAll(keepingCapacity: true)
        guard active else { reset(); return nil }
        let segment = finish(trailingSilence: silenceRun)
        reset()
        return segment
    }

    /// Her şeyi unutur (örneğin Junior'un kendi sesi çalarken).
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        buffer.removeAll(keepingCapacity: true)
        voicedRun = 0
        active = false
        silenceRun = 0
        voicedFrames = 0
        levelSum = 0
    }

    // MARK: - İç

    static func rms(_ frame: [Int16]) -> Double {
        guard !frame.isEmpty else { return 0 }
        var sum = 0.0
        for value in frame {
            let x = Double(value) / 32768.0
            sum += x * x
        }
        return (sum / Double(frame.count)).squareRoot()
    }

    private var threshold: Double { max(parameters.minThreshold, noiseFloor * parameters.noiseRatio) }

    private mutating func process(_ samples: [Int16], time: Int64) -> LiveSegment? {
        let level = Self.rms(samples)
        let voiced = level > threshold
        if !active {
            if voiced {
                voicedRun += 1
            } else {
                voicedRun = 0
                // Yalnız sessizken öğren; yoksa konuşma tabanı yukarı çeker.
                noiseFloor = min(0.05, noiseFloor * 0.97 + level * 0.03)
            }
            ring.append(Frame(samples: samples, time: time, level: level))
            let cap = parameters.prerollFrames + parameters.onsetFrames
            if ring.count > cap { ring.removeFirst(ring.count - cap) }
            if voicedRun >= parameters.onsetFrames {
                active = true
                buffer.removeAll(keepingCapacity: true)
                for frame in ring { buffer.append(contentsOf: frame.samples) }
                startMs = ring.first?.time ?? time
                let voicedTail = ring.suffix(voicedRun)
                voicedFrames = voicedTail.count
                levelSum = voicedTail.reduce(0) { $0 + $1.level }
                silenceRun = 0
                ring.removeAll(keepingCapacity: true)
            }
            return nil
        }

        buffer.append(contentsOf: samples)
        if voiced {
            voicedFrames += 1
            levelSum += level
            silenceRun = 0
        } else {
            silenceRun += 1
        }
        let seconds = Double(buffer.count) / Double(Self.sampleRate)
        let shouldCut = silenceRun >= parameters.hangoverFrames
            || (seconds >= parameters.softMaxSeconds && silenceRun >= parameters.softCutSilenceFrames)
            || seconds >= parameters.maxSeconds
        guard shouldCut else { return nil }
        let segment = finish(trailingSilence: silenceRun)
        // Sürekli konuşmada sınırda kesildiyse yeni parça birkaç kare sonra başlar.
        active = false
        voicedRun = 0
        ring.removeAll(keepingCapacity: true)
        return segment
    }

    private mutating func finish(trailingSilence: Int) -> LiveSegment? {
        defer {
            buffer.removeAll(keepingCapacity: true)
            silenceRun = 0
            voicedFrames = 0
            levelSum = 0
        }
        let extra = trailingSilence - parameters.keepTailFrames
        if extra > 0 {
            let drop = min(buffer.count, extra * frameSize)
            buffer.removeLast(drop)
        }
        let seconds = Double(buffer.count) / Double(Self.sampleRate)
        let voicedSeconds = Double(voicedFrames * parameters.frameMs) / 1000
        guard seconds >= parameters.minSegmentSeconds, voicedSeconds >= parameters.minVoicedSeconds else {
            return nil
        }
        let t1 = startMs + Int64(buffer.count) * 1000 / Int64(Self.sampleRate)
        let mean = voicedFrames > 0 ? levelSum / Double(voicedFrames) : 0
        return LiveSegment(samples: buffer, t0: startMs, t1: max(t1, startMs + 1), rms: mean)
    }
}
