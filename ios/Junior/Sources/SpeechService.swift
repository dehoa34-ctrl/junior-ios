import Foundation
import AVFoundation
import Speech

/// Konusma tanima ve seslendirme. Whisper'a gerek yok: iOS'un kendi
/// Speech framework'u Turkce'yi tanir ve ucretsizdir.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    enum State: Equatable { case idle, listening, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialText: String = ""
    @Published var permissionMessage: String?

    /// Hangi mikrofonun kullanildigi; gozluk baglandiginda burada gorunur.
    let route = AudioRoute()

    /// Seslendirme bittiginde cagrilir. Eller serbest dongusu bunu bekler:
    /// yanit okunurken uyandirma dinlemesi acilirsa Junior kendi sesindeki
    /// "Junior" kelimesiyle kendini tetikler.
    var onSpeakingFinished: (() -> Void)?

    /// Sunucudan dogal ses (MP3) getirir. Ayarli degilse ya da hata verirse
    /// iOS'un yerlesik sesi kullanilir; Junior hicbir durumda sessiz kalmaz.
    var remoteTTS: ((String) async throws -> Data)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Konusma bittikten sonra beklenecek sessizlik. 1.6 saniye cok kisaydi:
    /// cumle ortasinda nefes almak kaydi bitiriyordu.
    private static let silenceAfterSpeech: TimeInterval = 2.8
    /// Kullanici daha hic konusmadiysa beklenecek sure. Uyandirma sozcugunden
    /// sonra toparlanmak birkac saniye surebiliyor.
    private static let silenceBeforeSpeech: TimeInterval = 6

    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?
    private var player: AVAudioPlayer?
    private var cuePlayer: AVAudioPlayer?
    private var remoteSpeakTask: Task<Void, Never>?
    /// Calan dogal ses parcasinin bitmesini bekleyen dongu.
    private var playbackContinuation: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// Cihazdaki en iyi Türkçe sesi seçer.
    ///
    /// iOS varsayılan olarak sıkıştırılmış "compact" sesle gelir ve robotik
    /// duyulur. Kullanıcı Ayarlar > Erişilebilirlik > Sözlü İçerik > Sesler
    /// bölümünden gelişmiş veya premium Türkçe sesi indirirse burada
    /// kendiliğinden o kullanılır.
    static func bestTurkishVoice() -> AVSpeechSynthesisVoice? {
        let turkish = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("tr") }
        let ranked: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]
        for quality in ranked {
            if let voice = turkish.first(where: { $0.quality == quality }) { return voice }
        }
        return AVSpeechSynthesisVoice(language: "tr-TR")
    }

    /// Daha iyi bir ses indirilebilir mi; Ayarlar'da kullanıcıya söylemek için.
    static var hasUpgradedVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices()
            .contains { $0.language.hasPrefix("tr") && $0.quality != .default }
    }

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            permissionMessage = "Konusma tanima izni verilmedi. Ayarlar > Junior bolumunden acabilirsin."
            return false
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else {
            permissionMessage = "Mikrofon izni verilmedi. Ayarlar > Junior bolumunden acabilirsin."
            return false
        }
        return true
    }

    /// Dinlemeye baslar. Konusma bitince (2.8 sn sessizlik) metni `onFinish` ile dondurur.
    func startListening(onFinish: @escaping (String) -> Void) async {
        guard state == .idle else { return }
        stopSpeaking()
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            permissionMessage = "Konusma tanima su an kullanilamiyor. Internet baglantisini kontrol et."
            return
        }

        self.onFinish = onFinish
        partialText = ""

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            // Mikrofon MicrophoneHub'in ve uyandirma dinlemesiyle paylasiliyor.
            // Kendi motorumuzu kurmak, kilitli telefonda yeni kayit oturumu
            // acmak demek olurdu - iOS buna izin vermiyor ve devralma
            // "mikrofon baslatilamadi" ile dusuyordu.
            try MicrophoneHub.shared.attach(request)
            state = .listening
            // Ses oturumu acildiktan sonra bakiyoruz: yol ancak o zaman kesinlesir.
            route.beginListening()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.partialText = result.bestTranscription.formattedString
                        self.restartSilenceTimer()
                        if result.isFinal { self.finishListening() }
                    }
                    if error != nil, self.state == .listening { self.finishListening() }
                }
            }
            restartSilenceTimer()
        } catch {
            permissionMessage = "Mikrofon baslatilamadi. Baska bir uygulama sesi kullaniyor olabilir."
            teardown()
        }
    }

    func stopListening() {
        guard state == .listening else { return }
        finishListening()
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        // Henuz tek kelime duyulmadiysa daha uzun bekle.
        let wait = partialText.isEmpty ? Self.silenceBeforeSpeech : Self.silenceAfterSpeech
        silenceTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishListening() }
        }
    }

    private func finishListening() {
        guard state == .listening else { return }
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        // Bos metinde de haber verilir. Eskiden verilmiyordu: "Hey Junior"
        // deyip susan biri dinlemeyi sessizlik zamanlayicisiyla bitiriyor,
        // cagiran taraf hicbir sey duymuyor ve eller serbest dongusu
        // .listening adiminda takili kaliyordu.
        let callback = onFinish
        onFinish = nil
        callback?(text)
    }

    private func teardown() {
        route.endListening()
        silenceTimer?.invalidate()
        silenceTimer = nil
        // Yalniz yazmayi birak; mikrofon uyandirma dinlemesine geri donecek.
        MicrophoneHub.shared.detach()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Yaniti seslendirir. Sunucudaki dogal ses parca parca istenir: ilk (kisa)
    /// parca gelir gelmez calar, sonraki parca o calarken hazirlanir. Butun
    /// yanitin seslendirilmesini beklemek uzun yanitlarda 10-15 saniye
    /// sessizlik demekti.
    ///
    /// `chunks` sunucunun bolup onden seslendirmeye basladigi parcalardir;
    /// yoksa metin burada ayni kurala gore bolunur.
    func speak(_ text: String, chunks: [String] = []) {
        guard !text.isEmpty else {
            // Yanit bos gelirse de dongu ilerlemeli, yoksa sonsuza kadar bekler.
            onSpeakingFinished?()
            return
        }
        stopSpeaking()
        state = .speaking
        let parts = chunks.isEmpty ? Self.speechChunks(text) : chunks
        guard let remoteTTS, !parts.isEmpty else {
            speakLocally(text)
            return
        }
        remoteSpeakTask = Task { [weak self] in
            var fetches: [Int: Task<Data?, Never>] = [:]
            func request(_ index: Int) {
                guard index < parts.count, fetches[index] == nil else { return }
                fetches[index] = Task { try? await remoteTTS(parts[index]) }
            }
            defer { fetches.values.forEach { $0.cancel() } }
            for index in parts.indices {
                // Yalniz bir sonraki parca onden istenir; fazlasi ilk parcayla yarisiyor.
                request(index)
                request(index + 1)
                let audio = await fetches[index]?.value ?? nil
                guard let self, !Task.isCancelled, self.state == .speaking else { return }
                guard let audio, await self.playRemoteAndWait(audio) else {
                    // Durdurulduysa hicbir sey okunmaz.
                    guard !Task.isCancelled, self.state == .speaking else { return }
                    // Dogal ses gelmedi: kalan kisim yerlesik sesle okunur. Ses iki
                    // kez degismesin diye bundan sonrasi tamamen yerel kalir.
                    self.speakLocally(parts[index...].joined(separator: " "))
                    return
                }
                guard !Task.isCancelled, self.state == .speaking else { return }
            }
            self?.finishSpeaking()
        }
    }

    /// Bir parcayi calar ve bitince doner. Kurulamazsa false doner.
    private func playRemoteAndWait(_ data: Data) async -> Bool {
        configurePlayback()
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        self.player = player
        return await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            if !player.play() {
                playbackContinuation = nil
                self.player = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Calan parca bitti (ya da durduruldu): bekleyen donguyu ilerletir.
    private func resumePlayback(_ played: Bool) {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        player = nil
        continuation.resume(returning: played)
    }

    /// Yaniti seslendirme parcalarina boler. Sunucudaki speech_chunks ve
    /// masaustundeki splitForSpeech ile ayni kural: ilk parca kisa (80), digerleri
    /// motorun tek seferde okuyabildigi sinirda (170).
    nonisolated static func speechChunks(_ text: String, first: Int = 80, rest: Int = 170) -> [String] {
        var cleaned = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (kod bloğu) ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "https?://\\S+", with: "bağlantı", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[*_#>|~`]+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        func limit() -> Int { out.isEmpty ? first : rest }
        func cutLong(_ sentence: String) -> String {
            var s = sentence
            while s.count > limit() {
                let maximum = limit()
                let head = String(s.prefix(maximum))
                var cut = head.range(of: ", ", options: .backwards).map { head.distance(from: head.startIndex, to: $0.lowerBound) + 1 }
                if (cut ?? 0) < maximum / 2 {
                    cut = head.range(of: " ", options: .backwards).map { head.distance(from: head.startIndex, to: $0.lowerBound) }
                }
                let at = max(1, (cut ?? 0) < maximum / 2 ? maximum : cut!)
                let piece = String(s.prefix(at)).trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append(piece) }
                s = String(s.dropFirst(at)).trimmingCharacters(in: .whitespaces)
            }
            return s
        }
        var current = ""
        var sentences: [String] = []
        var buffer = ""
        for character in cleaned {
            buffer.append(character)
            if ".!?…".contains(character) {
                sentences.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { sentences.append(buffer) }
        for raw in sentences {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { continue }
            if current.isEmpty {
                current = cutLong(sentence)
            } else if current.count + 1 + sentence.count <= limit() {
                current += " " + sentence
            } else {
                out.append(current)
                current = cutLong(sentence)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func speakLocally(_ text: String) {
        configurePlayback()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestTurkishVoice()
        // Varsayilan hiz sesli asistan icin biraz yavas; hafif hizlandirmak
        // ve tizligi dusurmek konusmayi daha dogal yapiyor.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.pitchMultiplier = 0.97
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    private func configurePlayback() {
        // Mikrofon acikken kategoriyi .playback'e cevirmek kayit kanalini
        // kapatir ve ekran kapaliyken geri acilamaz. Hub calisiyorsa oturuma
        // hic dokunmuyoruz: .playAndRecord zaten calmayi da destekliyor.
        // isRunning degil isWanted: bir kesinti motoru durdurmus olabilir ama
        // mikrofon hala istenir; kategori degisirse geri acilamaz.
        guard !MicrophoneHub.shared.isWanted else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                            options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Ses oturumu kurulamazsa yanit yine ekranda okunur; sessizce devam et.
        }
    }

    /// "Seni duydum" sesi.
    ///
    /// Ekran kapalıyken titreşim çalışmıyor (iOS arka planda titreşim
    /// vermiyor); cepteki telefonda uyandırmanın tuttuğunu anlamanın tek yolu
    /// kulak. Kısa, yükselen iki ton - konuşmayla karışmasın diye.
    func playCue() {
        guard let data = Self.cueData, let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.35
        cuePlayer = player
        player.play()
    }

    private static let cueData: Data? = {
        let rate = 44_100.0
        var samples: [Int16] = []
        for (frequency, duration) in [(660.0, 0.07), (880.0, 0.09)] {
            let count = Int(rate * duration)
            for index in 0..<count {
                // Kısa giriş/çıkış rampası: tık sesi olmasın.
                let edge = min(1.0, Double(min(index, count - index)) / (rate * 0.008))
                let value = sin(2 * Double.pi * frequency * Double(index) / rate) * edge * 0.6
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append((36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(bytes.littleEndian)
        for sample in samples { append(sample.littleEndian) }
        return data
    }()

    func stopSpeaking() {
        remoteSpeakTask?.cancel()
        remoteSpeakTask = nil
        if let player { player.stop(); self.player = nil }
        // stop() bitis bildirimi gondermiyor; bekleyen parca dongusu serbest kalsin.
        resumePlayback(false)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if state == .speaking { state = .idle }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Parca bitti; dongu bir sonrakine gecer (son parcadan sonra konusma biter).
        Task { @MainActor in self.resumePlayback(true) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Bozuk ses verisi: dongu kalan kismi yerlesik sesle okur, kilitlenmez.
        Task { @MainActor in self.resumePlayback(false) }
    }
}

private extension SpeechService {
    func finishSpeaking() {
        guard state == .speaking else { return }
        player = nil
        state = .idle
        onSpeakingFinished?()
    }
}
