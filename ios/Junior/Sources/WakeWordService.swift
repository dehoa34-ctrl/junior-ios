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

/// Tanıma isteğini ses iş parçacığıyla paylaşan kilitli kutu.
///
/// Mikrofon kanalı (tap) artık döngüler arasında ayakta kalıyor, dolayısıyla
/// kapanış her seferinde **farklı** bir isteğe yazmak zorunda. Kapanış gerçek
/// zamanlı ses iş parçacığında koşuyor; @MainActor bir özelliğe doğrudan
/// erişmek veri yarışı olurdu.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request = value
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
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
    private static let restartAfter: TimeInterval = 50

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
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var paused = false
    private let box = RequestBox()
    /// Ses motoru calisiyor mu. Motor dongular arasinda **kapatilmiyor**:
    /// telefon kilitliyken iOS yeni bir kayit oturumu acmaya izin vermiyor,
    /// dolayisiyla her yenilemede mikrofonu birakip yeniden almak ilk
    /// yenilemede uyandirmayi olduruyordu.
    private var engineRunning = false
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

    /// Konuşma tanıma mikrofonu isteyince bırakılmalı; iki tanıma oturumu
    /// aynı anda mikrofonu tutamaz.
    func pauseForRecording() {
        guard running else { return }
        paused = true
        teardown()
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
            try startEngineIfNeeded()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Varsa cihaz üstünde kalsın: sesi buluta göndermemek hem gizlilik
            // hem de Apple'ın istek sınırlarına takılmamak için önemli. Ama
            // cihaz üstü mod çalışmıyorsa (art arda sessiz hatalar) sunucuya
            // düşülür; hiç duymayan bir uyandırma sözcüğünün gizliliği anlamsız.
            usingOnDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = usingOnDevice
            self.request = request
            box.set(request)
            sawTranscript = false
            cycleStarted = Date()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.sawTranscript = true
                        self.quickSilentFailures = 0
                        self.inspect(result.bestTranscription.formattedString)
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
        // Devraliacak olan konusma tanima mikrofonu isteyecek; burada tam
        // birakmak gerekiyor.
        // Aynı oturumda tekrar tetiklenmesin: dinlemeyi bırakıp haber ver.
        teardown()
        onDetected?()
    }

    // Varsayilan argumanda Self kullanilamiyor (covariant Self); tur adi acik yazilir.
    /// Ses motorunu yalnız kapalıysa başlatır. Ses oturumu bir kez açılır ve
    /// açık kalır; kilitli telefonda mikrofonu yeniden istemek başarısız oluyor.
    private func startEngineIfNeeded() throws {
        guard !engineRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [box] buffer, _ in
            box.append(buffer)
        }
        engine.prepare()
        try engine.start()
        engineRunning = true
    }

    private func stopEngine() {
        box.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engineRunning = false
    }

    /// Yalnız tanımayı bitirir; mikrofon elde kalır.
    private func endRecognition() {
        restartTimer?.invalidate()
        restartTimer = nil
        box.set(nil)
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
        stopEngine()
    }
}
