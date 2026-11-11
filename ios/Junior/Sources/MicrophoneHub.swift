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
    private var capture: PCMCapture?
    private var live: LiveTap?
    private var recorder: AllDayRecorder?

    func set(_ value: SFSpeechAudioBufferRecognitionRequest?, capture: PCMCapture? = nil) {
        lock.lock(); defer { lock.unlock() }
        request = value
        self.capture = capture
    }

    /// Sürekli dinleme tüketicisi; tanıma isteğinden bağımsızdır (`set` ona dokunmaz).
    func setLive(_ value: LiveTap?) {
        lock.lock(); defer { lock.unlock() }
        live = value
    }

    /// Açık kalmış konuşmayı hemen kapatıp kuyruğa verir (kesinti başlarken).
    func flushLive() {
        lock.lock()
        let tap = live
        lock.unlock()
        tap?.flush()
    }

    func setRecorder(_ value: AllDayRecorder?) {
        lock.lock(); defer { lock.unlock() }
        recorder = value
    }

    var hasConsumer: Bool {
        lock.lock(); defer { lock.unlock() }
        return request != nil || capture != nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        let copy = capture
        let tap = live
        let allDay = recorder
        lock.unlock()
        current?.append(buffer)
        copy?.append(buffer)
        tap?.append(buffer)
        allDay?.append(buffer)
    }
}

/// Konuşmanın kopyası: sunucudaki whisper'a gönderilmek üzere 16 kHz tek kanal
/// 16 bit PCM'e çevrilip biriktirilir. Ses iş parçacığından yazılır.
///
/// Apple'ın Türkçe tanıması gözlüğün dar bantlı (HFP) sesinde ve uzun
/// cümlelerde çok yanılıyor; whisper-large-v3 aynı sesi belirgin biçimde
/// daha doğru yazıyor.
final class PCMCapture: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private static let maxSeconds = 60.0
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PCMCapture.sampleRate,
                                       channels: 1, interleaved: true)
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var pcm = Data()

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let target, Double(pcm.count) < Self.maxSeconds * Self.sampleRate * 2,
              buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        // Gözlük bağlanınca/kopunca giriş biçimi değişir; çevirici yeniden kurulur.
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        pcm.append(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(pcm.count) / 2 / Self.sampleRate
    }

    /// Biriken sesin WAV hali.
    func wav() -> Data {
        lock.lock()
        let body = pcm
        lock.unlock()
        return WAVFile.pcm16(body, sampleRate: Int(Self.sampleRate))
    }
}

/// 16 bit tek kanal PCM'i WAV dosyasına sarar.
enum WAVFile {
    static func pcm16(_ body: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(body.count)
        data.append(contentsOf: Array("RIFF".utf8)); append((36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(bytes.littleEndian)
        data.append(body)
        return data
    }
}

/// Gün boyu kayıt için küçük, yerel WAV parçaları üretir.
///
/// Bu sınıf ses verisini bellekte günlerce tutmaz: her 60 saniyede bir dosyayı
/// `Documents/JuniorRecordings` içine yazar ve yeni parçaya geçer. Ses, bu
/// kayıt özelliği açıkça etkinleştirilmedikçe hiçbir zaman bu sınıfa ulaşmaz.
final class AllDayRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private static let chunkSeconds = 60.0
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "xyz.jrbilge.junior.all-day-recording", qos: .utility)
    private let directory: URL
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                       channels: 1, interleaved: true)
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var pcm = Data()
    private var stopped = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("JuniorRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var completed: Data?
        lock.lock()
        guard !stopped, let target, buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
            lock.unlock()
            return
        }
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        if let converter {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
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
                    pcm.append(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
                }
            }
        }
        let maxBytes = Int(Self.chunkSeconds * Self.sampleRate * 2)
        if pcm.count >= maxBytes {
            completed = pcm
            pcm.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if let completed { enqueue(completed) }
    }

    func stop() {
        var completed: Data?
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if !pcm.isEmpty { completed = pcm; pcm.removeAll(keepingCapacity: false) }
        lock.unlock()
        if let completed {
            enqueue(completed)
            writeQueue.sync {}
        }
    }

    private func enqueue(_ body: Data) {
        guard !body.isEmpty else { return }
        writeQueue.async { [directory] in
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970).replacingOccurrences(of: ".", with: "-")
            let url = directory.appendingPathComponent("junior-\(stamp)-\(UUID().uuidString.prefix(8)).wav")
            do {
                try WAVFile.pcm16(body, sampleRate: Int(Self.sampleRate)).write(to: url, options: .atomic)
            } catch {
                NSLog("Junior yerel kayıt yazılamadı: %@", String(describing: error))
            }
        }
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
    /// Ses yolunun en son değiştiği ya da motorun dışarıdan durduğu an. Hemen
    /// ardından düşen tanıma oturumları tanımanın değil yolun hatasıdır.
    private(set) var lastDisruption = Date.distantPast
    /// Mikrofonun açık kalması isteniyor mu. stop() çağrılmadıkça true.
    private var wanted = false
    /// Telefonda sürekli dinleme açık mı. Açıkken motor, uyandırma ve konuşma
    /// tanıma bıraksa bile kapanmaz; yalnız kullanıcı kapatınca/duraklatınca kapanır.
    private var liveWanted = false
    private var allDayRecordingWanted = false
    private var allDayRecorder: AllDayRecorder?
    private var observers: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?

    /// Ayarlardaki "Gözlük mikrofonu" anahtarı. Varsayılan açık.
    static let headsetMicKey = "junior.headsetMic"
    /// Mikrofonu bu girişlerden almak tercih edilir (gözlük, Bluetooth ya da kablolu kulaklık).
    private static let headsetPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .headsetMic]

    /// Mikrofon bir servis tarafından tutuluyor mu (o an motor durmuş olsa bile).
    /// Seslendirme bunu sorar: tutulurken ses kategorisi değiştirilmemeli.
    var isWanted: Bool { wanted || liveWanted || allDayRecordingWanted }

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
            Task { @MainActor in
                MicrophoneHub.shared.lastDisruption = Date()
                MicrophoneHub.shared.recover()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in MicrophoneHub.shared.lastDisruption = Date() }
            guard reason == .newDeviceAvailable else { return }
            // Gözlük dinleme sürerken bağlandı: mikrofonu ona geçir.
            Task { @MainActor in MicrophoneHub.shared.preferHeadsetMicIfWanted() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { _ in
            Task { @MainActor in MicrophoneHub.shared.handleMediaReset() }
        })
    }

    /// Ses oturumunu ve motoru başlatır; zaten gerçekten çalışıyorsa dokunmaz.
    func start() throws {
        wanted = true
        try startEngine()
    }

    private func startEngine() throws {
        // Bayrak tek başına yetmez: dış bir olay motoru durdurmuş olabilir.
        guard !(isRunning && engine.isRunning) else { return }
        let session = AVAudioSession.sharedInstance()
        // allowBluetooth = HFP; gözlük mikrofonunun yönlendirilebilmesi için gerekli.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: categoryOptions)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        preferHeadsetMic(session)

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

    /// Gelen sesi bu isteğe (ve verildiyse kayda) yazmaya başlar. Motor kapalıysa açar.
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest, capture: PCMCapture? = nil) throws {
        try start()
        box.set(request, capture: capture)
    }

    /// Gün boyu yerel kayıt için aynı ses tap'ine bir kayıt tüketicisi ekler.
    /// Uyandırma/konuşma durdurulsa bile motor bu tüketici için açık kalır.
    func setAllDayRecording(_ enabled: Bool) {
        if enabled {
            allDayRecordingWanted = true
            if allDayRecorder == nil { allDayRecorder = AllDayRecorder() }
            box.setRecorder(allDayRecorder)
            do { try start() } catch { recover() }
            return
        }
        allDayRecordingWanted = false
        box.setRecorder(nil)
        allDayRecorder?.stop()
        allDayRecorder = nil
        // Konuşma/uyandırma tanıması ya da sürekli dinleme hâlâ tüketici ise motoru bırakma.
        guard !box.hasConsumer, !liveWanted else { return }
        wanted = false
        stopEngine()
    }

    /// Gözlük bağlıysa mikrofonu ondan alır.
    ///
    /// `.allowBluetoothA2DP` açıkken iOS yanıtı gözlüğe A2DP ile çalıyor ama
    /// mikrofonu **telefondan** alıyordu: telefon cepteyken gözlükten "Junior"
    /// denince hiçbir şey duyulmuyordu. HFP girişi açıkça seçilince hem
    /// mikrofon hem hoparlör gözlüğe geçer (ses telefon görüşmesi kalitesinde).
    private func preferHeadsetMic(_ session: AVAudioSession) {
        let enabled = (UserDefaults.standard.object(forKey: Self.headsetMicKey) as? Bool) ?? true
        guard enabled else {
            if session.preferredInput != nil { try? session.setPreferredInput(nil) }
            return
        }
        guard let headset = session.availableInputs?.first(where: { Self.headsetPorts.contains($0.portType) }),
              session.preferredInput?.uid != headset.uid else { return }
        try? session.setPreferredInput(headset)
    }

    /// Ayar değişince ya da dinleme sürerken gözlük bağlanınca çağrılır. Giriş
    /// değişirse motor durur; yapılandırma bildirimi onu yeni girişle açar.
    func preferHeadsetMicIfWanted() {
        guard isWanted else { return }
        preferHeadsetMic(AVAudioSession.sharedInstance())
        recover()
    }

    /// Yazmayı durdurur ama **mikrofonu bırakmaz**: sıradaki servis devralacak.
    func detach() {
        box.set(nil)
    }

    /// Mikrofonu gerçekten bırakır. Yalnız uyandırma tamamen kapatılırken ya da
    /// uyandırma kapalıyken tur bittiğinde çağrılmalı.
    func stop() {
        wanted = allDayRecordingWanted
        retryTask?.cancel()
        box.set(nil)
        // Sürekli dinleme ya da gün boyu kayıt açıksa mikrofon bırakılmaz; yalnız tanıma bırakıldı.
        guard !liveWanted, !allDayRecordingWanted else {
            recover()
            return
        }
        stopEngine()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isRunning = false
        // Oturumu pasifleştirmiyoruz: seslendirme aynı oturumdan çalıyor.
    }

    /// Oturum seçenekleri. Sürekli dinleme açıkken `.mixWithOthers` eklenir: başka
    /// uygulama (Spotify, Apple Music) çalmaya başlayınca bizim oturum kesilmez
    /// ve mikrofon müzik çalarken de açık kalır. Kapalıyken eski davranış korunur.
    private var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        if liveWanted { options.insert(.mixWithOthers) }
        return options
    }

    /// Sürekli dinlemeyi bu tüketiciyle açar. Motor zaten çalışıyorsa kapatılmaz:
    /// yalnız oturum seçenekleri yerinde güncellenir.
    func enableLive(_ tap: LiveTap) throws {
        liveWanted = true
        box.setLive(tap)
        if isRunning, engine.isRunning {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: categoryOptions)
            return
        }
        do {
            try startEngine()
        } catch {
            // Yol değişiyor olabilir; motor kendini toparlasın.
            recover()
            throw error
        }
    }

    /// Sürekli dinlemeyi bırakır. Uyandırma/konuşma mikrofonu hâlâ istiyorsa motor açık kalır.
    func disableLive() {
        liveWanted = false
        box.setLive(nil)
        guard !wanted, !allDayRecordingWanted else {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: categoryOptions)
            return
        }
        retryTask?.cancel()
        stopEngine()
    }

    private func handleInterruption(began: Bool) {
        if began {
            // Sistem motoru durdurdu (çağrı, Siri, alarm). Bayrağı doğru tut.
            isRunning = false
            // Yarım kalan konuşma, ses geri gelene (belki hiç gelmeyene) kadar bellekte beklemesin.
            box.flushLive()
        } else {
            recover()
        }
    }

    /// İstenen mikrofon düşmüşse yeniden açmayı dener (öne dönünce ve bekçi
    /// görevinden). Kesinti bitti bildirimi hiç gelmediyse tek kurtarıcı budur.
    func reviveIfWanted() {
        guard isWanted, !engine.isRunning else { return }
        recover(attempt: 0)
    }

    private func handleMediaReset() {
        // Ses hizmetleri sıfırlandı: eski motor geçersiz, yenisi kurulmalı.
        isRunning = false
        engine = AVAudioEngine()
        recover()
    }

    /// Dışarıdan durdurulan motoru, istendiği sürece yeniden açar. Kesinti
    /// bittikten hemen sonra oturum açılamayabiliyor; birkaç kez tekrar denenir.
    /// Sürekli dinleme açıkken vazgeçilmez: aralık 2 sn'den 30 sn'ye kadar uzar.
    private func recover(attempt: Int = 0) {
        guard isWanted, !engine.isRunning else { return }
        isRunning = false
        retryTask?.cancel()
        do {
            try startEngine()
        } catch {
            guard attempt < 5 || liveWanted || allDayRecordingWanted else { return }
            let seconds = min(30, 2 * (attempt + 1))
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.recover(attempt: attempt + 1)
            }
        }
    }
}
