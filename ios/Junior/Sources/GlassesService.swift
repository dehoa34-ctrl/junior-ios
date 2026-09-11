import Foundation
import MWDATCore
import MWDATCamera

/// Ray-Ban Meta gözlüğünden fotoğraf almak için Meta DAT köprüsü.
///
/// Kamera oturumu **istek anında** açılır ve kare alınınca kapatılır. Önbellekten
/// eski kare gönderilmez: "şu an ne görüyorum" sorusunun karşılığı o anki
/// görüntü olmalı.
///
/// Meta AI uygulamasında Developer Mode açık olmalı (Settings > App Info >
/// sürüm numarasına beş kez dokun). Developer Mode'da uygulama doğrulaması
/// yapılmadığı için Wearables Developer Center kimlikleri gerekmez.
@MainActor
final class GlassesService: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case capturing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Meta AI'daki kayit durumunun ham aciklamasi. Enum adlarini SDK
    /// belgelerinden dogrulayamadigimiz icin String(describing:) ile
    /// tasinir; yalniz ekranda gosterilir, karar verilmez.
    @Published private(set) var registrationInfo = "bilinmiyor"
    /// Kamera izninin son bilinen durumu. Kayıt ile **ayrı** bir adım.
    @Published private(set) var permissionInfo = "bilinmiyor"
    /// SDK'nın gördüğü cihazlar. Boşsa sorun izinde değil, eşleşmede.
    @Published private(set) var deviceInfo = "bilinmiyor"

    private var session: DeviceSession?
    private var camera: Camera?
    private var pendingCapture: CheckedContinuation<Data, Error>?

    /// Gozlukten kare beklenecek en uzun sure. Gozluk kamerayi acip (beyaz
    /// isik) kareyi gondermesi birkac saniye surebiliyor.
    private static let captureTimeout: Double = 20

    /// Fotograf dinleyicisinin jetonu. **Saklanmak zorunda**: birakilirsa
    /// abonelik cop toplanip iptal oluyor ve kare hic ulasmiyor. Belirtisi
    /// tam da gozlukte beyaz isigin yanip sonmesi ve ardindan zaman asimi.

    /// Her cekime bir numara verilir. Zaman asimi gorevi hangi cekime ait
    /// oldugunu bilmezse, erken biten bir cekimin gorevi 12 saniye sonra
    /// uyanip **sonraki** cekimi haksiz yere iptal eder.
    private var photoToken: Any?

    private var captureGeneration = 0

    var isReady: Bool { state == .ready }

    /// Uygulama acilisinda bir kez cagrilir.
    static func configureOnLaunch() {
        Task {
            do {
                try await Wearables.configure()
            } catch {
                // Yapilandirma basarisizsa gozluk ozelligi kapali kalir; uygulamanin
                // geri kalani (sohbet, Spotify, medya tuslari) etkilenmez.
            }
        }
    }

    /// Meta AI uygulamasina gidip uygulamayi kaydeder. Kullanici bir kez yapar.
    /// Meta AI onay ekranini acar; onaydan sonra junior:// ile geri doner ve
    /// URL handleCallback ile SDK'ya iletilmelidir - iletilmezse kayit ASLA
    /// tamamlanmaz. Ilk surumde eksik olan buydu: dugme de yoktu, URL de
    /// islenmiyor idi, yani kamera oturumu hicbir zaman kurulamazdi.
    func register() async {
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            state = .failed("Gözlük kaydı başlatılamadı. Meta AI uygulamasında Developer Mode açık mı?")
        }
    }

    /// Kamera iznini ister. **Kayıttan ayrı bir adım**: Meta AI kayıt
    /// tamamlandığında "bağlandı" der ama kamera izni ayrıca verilmemişse
    /// oturum yine kurulamaz. İlk sürümde eksik olan buydu; kullanıcı
    /// kaydı yapıp "Meta AI'a bağlanmış" görüyor, sonrasında hiçbir şey
    /// çalışmıyordu.
    func requestCameraPermission() async {
        do {
            let wearables = Wearables.shared
            // Izin istegi BAGLI bir cihaz gerektiriyor (PermissionError
            // .noDeviceWithConnection). Gozluk uykudaysa hemen hata veriyordu;
            // once akisin bir cihaz bildirmesini bekle.
            state = .connecting
            await waitForDevice(wearables)

            var status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                status = try await wearables.requestPermission(.camera)
            }
            permissionInfo = status == .granted ? "verildi" : "verilmedi"
            if case .failed = state {} else { state = .idle }
        } catch {
            permissionInfo = "istenemedi"
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed("Kamera izni istenemedi: \(detail)\(Self.hint(for: error))")
        }
    }

    /// Meta AI'dan donen adresi SDK'ya iletir. JuniorApp onOpenURL'den cagirir.
    static func handleCallback(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else {
            return
        }
        Task { _ = try? await Wearables.shared.handleUrl(url) }
    }

    private var observingRegistration = false

    /// Kayit durumunu izler; Ayarlar ekrani gosterir. Ayarlar her acilista
    /// onAppear kostugu icin ikinci cagri sessizce yok sayilir.
    func observeRegistration() {
        guard !observingRegistration else { return }
        observingRegistration = true
        Task { [weak self] in
            for await status in Wearables.shared.registrationStateStream() {
                let text = Self.describe(status)
                await MainActor.run { self?.registrationInfo = text }
            }
        }
    }

    func connect() async {
        guard session == nil else { return }
        state = .connecting
        // Hangi adimda dustugunu bilmeden tahmin yurutuyorduk: bes adimin
        // hepsi ayni genel mesaji veriyordu. Artik adim adi ve SDK'nin kendi
        // hata metni ekranda gorunuyor.
        var step = "hazırlık"
        do {
            let wearables = Wearables.shared

            step = "cihaz listesi"
            // devices bir metot degil, ozellik: [DeviceIdentifier] (aka [String]).
            // try/await gereksizse yalnizca uyari uretir, eksikse hata.
            let devices = try await wearables.devices
            deviceInfo = devices.isEmpty
                ? "gözlük görünmüyor"
                : devices.map { String(describing: $0) }.joined(separator: ", ")
            guard !devices.isEmpty else {
                state = .failed("Gözlük görünmüyor. Takılı ve Meta AI'a bağlı olmalı; "
                                + "Meta AI uygulamasını bir kez açıp kapat.")
                return
            }

            step = "kamera izni"
            var permission = try await wearables.checkPermissionStatus(.camera)
            if permission != .granted {
                permission = try await wearables.requestPermission(.camera)
            }
            permissionInfo = permission == .granted ? "verildi" : "verilmedi"

            // Seciciyi **beklemeden once** kur: listesini devicesStream()'den
            // dolduruyor, dolayisiyla akisi dinlemeye simdi baslamali.
            let selector = AutoDeviceSelector(wearables: wearables)

            step = "gözlüğün hazır olması"
            // Secici olusturulur olusturulmaz createSession cagirmak "no
            // eligible device available" veriyordu: wearables.devices dolu
            // olsa bile secici baglanti durumuna gore eleme yapiyor ve o
            // bilgi akistan geliyor. Akis bir cihaz verene kadar bekle.
            await waitForDevice(wearables)

            step = "oturum oluşturma"
            let session = try await createSessionWithRetry(wearables, selector)

            step = "oturum başlatma"
            try await session.start()
            self.session = session

            // start() donmesi oturumun hazir oldugu anlamina gelmiyor.
            step = "oturumun hazır olması"
            await waitUntilStarted(session)
            state = .ready
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed("\(step) adımında takıldı: \(detail)\(Self.hint(for: error))")
            await disconnect()
        }
    }

    /// Kayıt durumunu okunabilir hâle getirir.
    ///
    /// String(describing:) yalnız `RegistrationState(rawValue: 3)` basıyor ve
    /// ham değerlerin anlamı belgelerde yok; karşılaştırma isimlerle yapılıyor
    /// ki sıralama değişse bile doğru kalsın.
    nonisolated private static func describe(_ status: RegistrationState) -> String {
        switch status {
        case .registered: return "kayıtlı"
        case .available: return "kayda hazır"
        case .registering: return "kayıt sürüyor"
        case .unavailable: return "kullanılamıyor"
        @unknown default: return String(describing: status)
        }
    }

    /// SDK'nın İngilizce hatasını kullanıcının yapabileceği bir şeye çevirir.
    ///
    /// "all discovered devices are powered off or disconnected" gibi mesajlar
    /// teknik olarak doğru ama ne yapılacağını söylemiyor; sorun neredeyse her
    /// zaman gözlüğün kutuda ya da uykuda olması.
    private static func hint(for error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("nodevicewithconnection") || text.contains("no device with connection") {
            return " Gözlük eşleşmiş ama bağlı değil: kutudan çıkar, tak ve "
                + "Meta AI'da şarj yüzdesinin göründüğünü doğrula."
        }
        if text.contains("nodevice") {
            return " Gözlük bulunamadı. Meta AI'da eşleşmiş görünüyor mu?"
        }
        if text.contains("powered off") || text.contains("disconnected") {
            return " Gözlük kapalı ya da bağlı değil: kutudan çıkar, tak, "
                + "sapına dokunup uyandır ve Meta AI'da bağlı göründüğünü doğrula."
        }
        if text.contains("eligible") {
            return " Gözlüğü tak, bir tuşuna dokunup uyandır ve Meta AI'da bağlı göründüğünü doğrula."
        }
        if text.contains("permission") || text.contains("denied") {
            return " Meta AI > Ayarlar > App connections > Developer mode apps bölümünden "
                + "Junior'a kamera izni ver."
        }
        return ""
    }

    /// Cihaz akışı bir gözlük bildirene kadar bekler; en fazla 15 saniye.
    private func waitForDevice(_ wearables: any WearablesInterface) async {
        await withDeadline(seconds: 15) { [weak self] in
            for await devices in wearables.devicesStream() where !devices.isEmpty {
                self?.deviceInfo = devices.map { String(describing: $0) }.joined(separator: ", ")
                return
            }
        }
    }

    /// Oturumu kurar; seçici hâlâ hazır değilse kısa aralıklarla yeniden dener.
    ///
    /// Beklemeye rağmen zamanlama kaçabiliyor ve tek denemede vazgeçmek
    /// kullanıcıyı "no eligible device available" ile baş başa bırakıyor.
    private func createSessionWithRetry(_ wearables: any WearablesInterface,
                                        _ selector: AutoDeviceSelector) async throws -> DeviceSession {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await wearables.createSession(deviceSelector: selector)
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError ?? GlassesError.notConnected
    }

    /// Oturum başlayana kadar bekler; en fazla 10 saniye. Süre dolarsa yine de
    /// denenir - beklemek hiç denememekten iyi ama sonsuz olmamalı.
    private func waitUntilStarted(_ session: DeviceSession) async {
        await withDeadline(seconds: 10) {
            for await sessionState in session.stateStream() {
                let text = String(describing: sessionState).lowercased()
                // "starting" de "start" içeriyor; yalnız tamamlanmış hâli say.
                if text == "started" || text.hasSuffix(".started") { return }
            }
        }
    }

    func disconnect() async {
        await camera?.stream.stop()
        camera = nil
        photoToken = nil
        await session?.stop()
        session = nil
        if case .failed = state {} else { state = .idle }
    }

    /// İstek anında tek kare alır. Çağıran taraf bunu doğrudan Junior'a gönderir.
    func capturePhoto() async throws -> Data {
        if session == nil { await connect() }
        guard let session else { throw GlassesError.notConnected }
        guard pendingCapture == nil else { throw GlassesError.busy }

        state = .capturing
        defer { if self.session != nil { state = .ready } }

        // Kamera oturum boyunca bir kez eklenir ve yeniden kullanılır. Her
        // soruda yeniden eklemek ikinci soruda "kamera zaten var" riskiydi;
        // yalnız akış durdurulup yeniden başlatılıyor.
        let camera: Camera
        if let existing = self.camera {
            camera = existing
        } else {
            let configuration = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
            guard let added = try await session.addCamera(config: configuration) else {
                throw GlassesError.cameraUnavailable
            }
            camera = added
            self.camera = added
            // Jeton kameranın ömrü boyunca tutulur; bırakılırsa abonelik iptal oluyor.
            photoToken = added.stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in await self?.finishCapture(with: photo.data) }
            }
        }
        await camera.stream.start()

        captureGeneration += 1
        let generation = captureGeneration

        return try await withCheckedThrowingContinuation { continuation in
            pendingCapture = continuation
            Task { [weak self] in await self?.requestFrame(camera, generation: generation) }
            // Gözlük kareyi hiç göndermezse (menzil dışı, pil, uyku) devam
            // noktası asla sürmez ve çağıran taraf sonsuza kadar bekler.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.captureTimeout * 1_000_000_000))
                await self?.failCaptureIfPending(generation: generation)
            }
        }
    }

    /// Kare ister; gözlük kabul etmezse kısa aralıklarla yeniden dener.
    ///
    /// capturePhoto isteği kabul edip etmediğini döndürüyor (akış henüz
    /// ısınmadıysa hayır). Dönüş değeri atılıyordu: reddedilen istek için 20
    /// saniye boşuna beklenip "kare gelmedi" deniyordu.
    private func requestFrame(_ camera: Camera, generation: Int) async {
        for attempt in 0..<8 {
            guard generation == captureGeneration, pendingCapture != nil else { return }
            let outcome = await camera.stream.capturePhoto(format: .jpeg)
            // Belgelerde Bool; başka bir tip dönerse kabul edilmiş sayılır.
            if (outcome as Any) as? Bool ?? true { return }
            if attempt < 7 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        await failCaptureIfPending(generation: generation, error: .rejected)
    }

    /// Bekleyen isteği hatayla kapatır. finishCapture ile aynı devam noktasını
    /// paylaşır; hangisi önce gelirse pendingCapture'ı alır, diğeri guard'a
    /// takılır. `generation`, erken biten bir çekimin gecikmiş görevinin
    /// sıradaki çekimi iptal etmesini engeller.
    ///
    /// Kare gelmediyse ya da reddedildiyse oturum tamamen bırakılır: bir sonraki
    /// soru temiz bir oturumla başlasın. Uykuya dalmış oturum ya da yarım kalmış
    /// kamera üzerine yeniden denemek aynı hatayı tekrarlıyordu.
    private func failCaptureIfPending(generation: Int, error: GlassesError = .timedOut) async {
        guard generation == captureGeneration, let continuation = pendingCapture else { return }
        pendingCapture = nil
        await disconnect()
        continuation.resume(throwing: error)
    }

    private func finishCapture(with data: Data) async {
        guard let continuation = pendingCapture else { return }
        pendingCapture = nil
        // Kare alındı: akışı durdur (gözlük ışığı sönsün, pil gitmesin) ama
        // kamerayı bırakma; sonraki soruda yeniden eklemek gerekmesin.
        await camera?.stream.stop()
        continuation.resume(returning: data)
    }
}

enum GlassesError: LocalizedError {
    case notConnected
    case busy
    case cameraUnavailable
    case timedOut
    case rejected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Gözlük bağlı değil. Takılı olduğundan ve Meta AI'a eşleştiğinden emin ol."
        case .busy:
            return "Önceki fotoğraf isteği hâlâ sürüyor."
        case .cameraUnavailable:
            return "Gözlük kamerası açılamadı. Meta AI'da kamera izni verilmiş mi?"
        case .timedOut:
            return "Gözlükten kare gelmedi. Menzil dışında ya da pili bitmiş olabilir."
        case .rejected:
            return "Gözlük kare vermedi. Gözlüğü uyandırıp tekrar sor."
        }
    }
}

/// Tek sefer devam ettirilen devam noktası: iki görevden hangisi önce biterse
/// o devam ettirir, diğeri sessizce geçer.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Bir işi en fazla `seconds` saniye bekler.
///
/// `for await` içine konan süre kontrolü yalnız akıştan yeni bir değer
/// geldiğinde çalışıyordu: akış susarsa (gözlük uykudayken olabiliyor) bekleme
/// sonsuza uzuyor ve bağlantı hiç dönmüyordu. Burada iş iptali dinlemese bile
/// çağıran taraf zamanında döner.
@MainActor
private func withDeadline(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce(continuation)
        let job = Task { @MainActor in
            await work()
            once.resume()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            job.cancel()
            once.resume()
        }
    }
}
