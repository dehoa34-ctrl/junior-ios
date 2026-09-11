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

enum MicrophoneError: Error {
    /// Donanım o an giriş vermiyor (Bluetooth yolu değişirken olabiliyor).
    case noInput
}

/// Mikrofonun **tek sahibi**.
///
/// iOS kilitli telefonda *yeni* bir kayıt oturumu açılmasına izin vermiyor,
/// zaten açık olanı sürdürmeye izin veriyor. Uyandırma dinlemesi ve konuşma
/// tanıma bu yüzden aynı motoru paylaşır; devralma sırasında mikrofon hiç
/// bırakılmaz, yalnız hangi tanıma isteğine yazıldığı değişir.
///
/// Motor dışarıdan da durabilir: telefon çağrısı, Siri, alarm, ya da gözlüğün
/// bağlanıp kopması (Bluetooth yolu değişince iOS motoru durdurur). Önceden
/// bunu fark eden yoktu; `isRunning` "açık" demeye devam ediyor, `start()`
/// bayrağa bakıp hiçbir şey yapmıyordu ve uyandırma bir daha hiç duymuyordu.
/// Artık bu olaylar dinleniyor ve motor istendiği sürece geri açılıyor.
@MainActor
final class MicrophoneHub {
    static let shared = MicrophoneHub()

    private var engine = AVAudioEngine()
    private let box = RequestBox()
    private(set) var isRunning = false
    /// Mikrofonun açık kalması isteniyor mu. stop() çağrılmadıkça true.
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?

    /// Mikrofon bir servis tarafından tutuluyor mu (o an motor durmuş olsa bile).
    /// Seslendirme bunu sorar: tutulurken ses kategorisi değiştirilmemeli.
    var isWanted: Bool { wanted }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            Task { @MainActor in MicrophoneHub.shared.handleInterruption(began: began) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                             object: nil, queue: .main) { _ in
            Task { @MainActor in MicrophoneHub.shared.recover() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { _ in
            Task { @MainActor in MicrophoneHub.shared.handleMediaReset() }
        })
    }

    /// Ses oturumunu ve motoru başlatır; zaten gerçekten çalışıyorsa dokunmaz.
    func start() throws {
        wanted = true
        // Bayrak tek başına yetmez: dış bir olay motoru durdurmuş olabilir.
        guard !(isRunning && engine.isRunning) else { return }
        let session = AVAudioSession.sharedInstance()
        // allowBluetooth = HFP; gözlük mikrofonunun yönlendirilebilmesi için gerekli.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        // Biçim her seferinde yeniden okunur: gözlük bağlanınca donanım örnekleme
        // hızı değişiyor. Yol değişirken bir an 0 kanal / 0 Hz gelebiliyor; o
        // biçimle kanal kurmak uygulamayı çökertir, bu yüzden hata verip sonra
        // yeniden deneniyor.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInput }
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

    /// Mikrofonu gerçekten bırakır. Yalnız uyandırma tamamen kapatılırken ya da
    /// uyandırma kapalıyken tur bittiğinde çağrılmalı.
    func stop() {
        wanted = false
        retryTask?.cancel()
        box.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isRunning = false
        // Oturumu pasifleştirmiyoruz: seslendirme aynı oturumdan çalıyor.
    }

    private func handleInterruption(began: Bool) {
        if began {
            // Sistem motoru durdurdu (çağrı, Siri, alarm). Bayrağı doğru tut.
            isRunning = false
        } else {
            recover()
        }
    }

    private func handleMediaReset() {
        // Ses hizmetleri sıfırlandı: eski motor geçersiz, yenisi kurulmalı.
        isRunning = false
        engine = AVAudioEngine()
        recover()
    }

    /// Dışarıdan durdurulan motoru, istendiği sürece yeniden açar. Kesinti
    /// bittikten hemen sonra oturum açılamayabiliyor; birkaç kez tekrar denenir.
    private func recover(attempt: Int = 0) {
        guard wanted, !engine.isRunning else { return }
        isRunning = false
        retryTask?.cancel()
        do {
            try start()
        } catch {
            guard attempt < 5 else { return }
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.recover(attempt: attempt + 1)
            }
        }
    }
}
