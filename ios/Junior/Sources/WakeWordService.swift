import Foundation
import AVFoundation
import Speech

/// Uyandırma ifadesinin metinde geçip geçmediği. Saf mantık: aktör
/// izolasyonu yok, testten ve ses kuyruğundan doğrudan çağrılabilir.
enum WakeWord {
    /// Konuşma tanıma aynı ifadeyi farklı yazabiliyor; hepsi kabul edilir.
    static let phrases = ["hey junior", "hey jünior", "hey cunior", "junior", "jünior",
                          "junyor", "juniyor", "cuniyor", "jonior", "cünyor", "junior'un"]
        .map(WakeWord.fold)

    /// Türkçe karakterleri katlayıp karşılaştırmayı sağlamlaştırır.
    static func fold(_ text: String) -> String {
        let lowered = text.replacingOccurrences(of: "İ", with: "i").lowercased()
        let map: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u"]
        return String(lowered.map { map[$0] ?? $0 })
    }

    static func matches(_ transcript: String) -> Bool {
        let folded = fold(transcript)
        return phrases.contains { folded.contains($0) }
    }
}

/// "Hey Junior" uyandırma sözcüğü — iOS'un kendi konuşma tanımasıyla.
///
/// Sürekli dinler, gelen metinde uyandırma ifadesini arar. Porcupine gibi
/// özel bir motor kullanmaz: Picovoice kişisel kullanım için ücretsiz plan
/// sunmayı bıraktı ve ek bağımlılık CI'da 371 MB'lık bir depo demekti.
///
/// **Sınır:** iOS sistem düzeyinde özel uyandırma sözcüğüne izin vermiyor; o
/// katman Siri'ye ayrılmış. Bu yüzden yalnız uygulama çalışırken duyar.
/// Telefon kilitliyken ve uygulama kapatılmışken çalışmaz.
@MainActor
final class WakeWordService: ObservableObject {
    /// Apple sürekli tanımayı belli bir süreden sonra kesiyor; kendimiz
    /// yenilemezsek dinleme sessizce ölür.
    /// Yedek yenileme. Asil yenileme tanima oturumu bittiginde (isFinal ya da
    /// hata) aninda oluyor; bu yalniz hicbiri gelmezse devreye giren emniyet.
    /// Apple sureyi 1 dakika civarinda sinirliyor, altinda kalmali.
    private static let restartAfter: TimeInterval = 45

    /// Gecici bir aksaklikta yeniden deneme araligi. 50 saniye beklemek,
    /// telefon cepteyken uyandirma sozcugunu pratikte olu birakir.
    private static let retryAfter: TimeInterval = 5

    @Published private(set) var running = false
    @Published var message: String?
    /// En son duyulan metin parcasi. Uyandirma neden tetiklenmiyor sorusunun
    /// tek pratik cevabi: tanima hic bir sey mi duymuyor, yoksa farkli mi
    /// yaziyor? Ekranda gosterilir, hicbir yere gonderilmez.
    @Published private(set) var lastHeard: String?
    /// Su anki cevrimde cihaz ustu tanima mi kullaniliyor.
    @Published private(set) var usingOnDevice = false

    /// Uyandırma sözcüğü duyulduğunda çağrılır.
    var onDetected: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var paused = false
    /// Cihaz ustu tanima "destekleniyor" deyip calismayabiliyor: gorev aninda
    /// hata veriyor ve hicbir metin gelmiyor. Elle mikrofon calisirken
    /// uyandirmanin hic duymamasinin en olasi sebebi bu. Iki kez ust uste
    /// erken ve sessiz olen cevrimden sonra sunucu tanimasina gecilir.
    /// Cihaz ustu tanimanin bu telefonda calisip calismadigi hatirlanir.
    /// Hatirlanmazsa her aciliste once bozuk olan deneniyor ve ilk iki cevrim
    /// bosa gidiyor - "Hey Junior" o sirada hic duyulmuyor.
    private static let onDeviceBrokenKey = "junior.onDeviceRecognitionBroken"

    private var preferOnDevice = !UserDefaults.standard.bool(forKey: WakeWordService.onDeviceBrokenKey)
    private var quickSilentFailures = 0
    private var sawTranscript = false
    private var cycleStarted = Date()

    var supported: Bool { recognizer != nil }

    /// Cihaz üstü tanıma varsa ses buluta gitmez ve istek sınırı işlemez.
    var onDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() {
        guard !running else { return }
        running = true
        paused = false
        message = nil
        Task { [weak self] in
            // Izin hic sorulmamissa burada sorulur; reddedildiyse sebep yazilir.
            // Izinsiz motor kurmak sessizce basarisiz oluyordu.
            let allowed = await Self.ensurePermissions()
            guard let self, self.running else { return }
            if allowed {
                self.beginCycle()
            } else {
                self.message = "Mikrofon veya konuşma tanıma izni yok. Ayarlar > Junior."
                self.running = false
            }
        }
    }

    private static func ensurePermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func stop() {
        running = false
        message = nil
        teardown()
    }

    /// Konuşma tanıma devralacak. **Mikrofon bırakılmaz**: iOS kilitli
    /// telefonda yeni bir kayıt oturumu açtırmıyor, dolayısıyla bırakıp
    /// yeniden almak ekran kapalıyken "mikrofon başlatılamadı" ile
    /// sonuçlanıyordu. Yalnız tanıma oturumu kapanır, kanal açık kalır.
    func pauseForRecording() {
        guard running else { return }
        paused = true
        endRecognition()
    }

    func resumeAfterRecording() {
        guard running, paused else { return }
        paused = false
        beginCycle()
    }

    private func beginCycle() {
        guard running, !paused else { return }
        guard let recognizer, recognizer.isAvailable else {
            // isAvailable gecici olarak false olabilir (sistem yuku, ag, baska
            // bir uygulama). Vazgecmek sessiz olum demek: ekran kapaliyken bu
            // mesaji kimse gormez ve "Hey Junior" bir daha hic calismaz.
            message = "Konuşma tanıma şu an kullanılamıyor; yeniden denenecek."
            scheduleRestart(after: Self.retryAfter)
            return
        }
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Varsa cihaz üstünde kalsın: sesi buluta göndermemek hem gizlilik
            // hem de Apple'ın istek sınırlarına takılmamak için önemli. Ama
            // cihaz üstü mod çalışmıyorsa (art arda sessiz hatalar) sunucuya
            // düşülür; hiç duymayan bir uyandırma sözcüğünün gizliliği anlamsız.
            usingOnDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = usingOnDevice
            self.request = request
            // Mikrofon hub'in; burada yalniz "gelen sesi bu istege yaz" deniyor.
            try MicrophoneHub.shared.attach(request)
            sawTranscript = false
            cycleStarted = Date()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.sawTranscript = true
                        self.quickSilentFailures = 0
                        self.inspect(result.bestTranscription.formattedString)
                        // Tanima bir duraklamadan sonra oturumu KENDISI
                        // bitiriyor (ozellikle sunucu tanimasi). Bu fark
                        // edilmezse servis 50 saniyelik zamanlayici gelene
                        // kadar sagir kaliyor: "uygulama acikken Hey Junior
                        // dedim ama duymadi" sikayetinin sebebi buydu.
                        if result.isFinal { self.restartCycle() }
                    }
                    if error != nil {
                        self.registerCycleError()
                        self.restartCycle()
                    }
                }
            }
            scheduleRestart()
        } catch {
            // Mikrofon baska bir uygulamadaysa (gelen cagri, sesli mesaj) bu
            // gecicidir; birakip olmek yerine yeniden dene.
            message = "Uyandırma dinlemesi başlatılamadı; yeniden denenecek."
            teardown()
            scheduleRestart(after: Self.retryAfter)
        }
    }

    /// Hizli ve sessiz olen cevrimler cihaz ustu modelin bozuk oldugunun
    /// isaretidir; sessiz bir odada 50 saniye metin gelmemesi ise normaldir.
    private func registerCycleError() {
        guard usingOnDevice, !sawTranscript,
              Date().timeIntervalSince(cycleStarted) < 10 else { return }
        quickSilentFailures += 1
        if quickSilentFailures >= 2 {
            preferOnDevice = false
            // Bir daha denemeyelim: sonraki aciliste dogrudan sunucu tanimasi.
            UserDefaults.standard.set(true, forKey: Self.onDeviceBrokenKey)
            message = "Cihaz üstü tanıma çalışmadı; sunucu tanımasına geçildi."
        }
    }

    private func inspect(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lastHeard = String(trimmed.suffix(40)) }
        guard WakeWord.matches(transcript) else { return }
        // Aynı oturumda tekrar tetiklenmesin: tanımayı bırak, mikrofonu değil.
        endRecognition()
        onDetected?()
    }

    // Varsayilan argumanda Self kullanilamiyor (covariant Self); tur adi acik yazilir.
    /// Yalnız tanımayı bitirir; mikrofon elde kalır.
    private func endRecognition() {
        restartTimer?.invalidate()
        restartTimer = nil
        MicrophoneHub.shared.detach()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    private func scheduleRestart(after seconds: TimeInterval = WakeWordService.restartAfter) {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restartCycle() }
        }
    }

    private func restartCycle() {
        guard running, !paused else { return }
        // Motor kapatilmiyor: 50 saniyelik yenileme yalniz tanima oturumunu
        // degistiriyor, mikrofon kesintisiz elde kaliyor.
        endRecognition()
        beginCycle()
    }


    /// Tam durdurma: tanıma **ve** mikrofon bırakılır. Yalnız stop() ve
    /// pauseForRecording() çağırır; konuşma tanıma mikrofonu isteyeceği için
    /// orada gerçekten bırakmak gerekiyor.
    private func teardown() {
        endRecognition()
        MicrophoneHub.shared.stop()
    }
}
