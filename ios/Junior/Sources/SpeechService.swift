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
    private let engine = AVAudioEngine()
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
    private var remoteSpeakTask: Task<Void, Never>?

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
            let session = AVAudioSession.sharedInstance()
            // allowBluetooth = HFP; gozluk mikrofonunun yonlendirilebilmesi icin gerekli.
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
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
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        state = .idle
    }

    func speak(_ text: String) {
        guard !text.isEmpty else {
            // Yanit bos gelirse de dongu ilerlemeli, yoksa sonsuza kadar bekler.
            onSpeakingFinished?()
            return
        }
        stopSpeaking()
        state = .speaking
        guard let remoteTTS else {
            speakLocally(text)
            return
        }
        // Sunucudaki noral ses cok daha dogal; getirilemezse yerlesik ses
        // devreye girer. Dongu state'e bakar, iki yol da ayni bitisi bildirir.
        remoteSpeakTask = Task { [weak self] in
            var audio: Data?
            do { audio = try await remoteTTS(text) } catch { audio = nil }
            guard let self, self.state == .speaking, !Task.isCancelled else { return }
            if let audio, self.playRemote(audio) { return }
            self.speakLocally(text)
        }
    }

    /// MP3'u calar; kurulamazsa false doner ve yerlesik ses kullanilir.
    private func playRemote(_ data: Data) -> Bool {
        configurePlayback()
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        self.player = player
        guard player.play() else { self.player = nil; return false }
        return true
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
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                            options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Ses oturumu kurulamazsa yanit yine ekranda okunur; sessizce devam et.
        }
    }

    func stopSpeaking() {
        remoteSpeakTask?.cancel()
        remoteSpeakTask = nil
        if let player { player.stop(); self.player = nil }
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
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Bozuk ses verisi; dongu kilitlenmesin, konusma bitmis sayilir.
        Task { @MainActor in self.finishSpeaking() }
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
