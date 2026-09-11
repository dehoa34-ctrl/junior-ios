import AVFoundation
import Foundation
import Speech

/// Tanıma isteğini ses iş parçacığıyla paylaşan kilitli kutu.
///
/// Mikrofon kanalı (tap) bir kez kurulup açık kaldığı için kapanış her
/// seferinde **farklı** bir isteğe yazmak zorunda. Kapanış gerçek zamanlı ses
/// iş parçacığında koşuyor; `@MainActor` bir özelliğe doğrudan erişmek veri
/// yarışı olurdu.
final class RequestBox: @unchecked Sendable {
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

/// Mikrofonun **tek sahibi**.
///
/// Neden ayrı bir sınıf: iOS kilitli telefonda *yeni* bir kayıt oturumu
/// açılmasına izin vermiyor, zaten açık olanı sürdürmeye izin veriyor. Önceden
/// uyandırma dinlemesi ve konuşma tanıma ayrı ses motorları kullanıyordu;
/// "Hey Junior" duyulduğunda biri mikrofonu bırakıp öteki yeniden almaya
/// çalışıyordu. Ekran kapalıyken bu devralma başarısız oluyor ve kullanıcı
/// "mikrofon başlatılamadı" hatası alıyordu.
///
/// Artık motor bir kez başlar ve uyandırma kapatılana kadar açık kalır; iki
/// servis yalnız **hangi tanıma isteğine yazıldığını** değiştirir. Devralma
/// sırasında mikrofon hiç bırakılmaz.
@MainActor
final class MicrophoneHub {
    static let shared = MicrophoneHub()

    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private(set) var isRunning = false

    private init() {}

    /// Ses oturumunu ve motoru yalnız kapalıysa başlatır.
    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // allowBluetooth = HFP; gözlük mikrofonunun yönlendirilebilmesi için gerekli.
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
        isRunning = true
    }

    /// Gelen sesi bu isteğe yazmaya başlar. Motor kapalıysa açar.
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) throws {
        try start()
        box.set(request)
    }

    /// Yazmayı durdurur ama **mikrofonu bırakmaz**: sıradaki servis devralacak.
    func detach() {
        box.set(nil)
    }

    /// Mikrofonu gerçekten bırakır.
    ///
    /// Yalnız uyandırma tamamen kapatılırken çağrılmalı: kilitli telefonda
    /// yeniden almak mümkün olmayabilir, dolayısıyla bırakmak geri dönüşü
    /// olmayan bir karar sayılmalı.
    func stop() {
        box.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isRunning = false
        // Oturumu pasifleştirmiyoruz: başka sesler (seslendirme) aynı
        // oturumdan çalıyor ve kapatmak onları da keserdi.
    }
}
