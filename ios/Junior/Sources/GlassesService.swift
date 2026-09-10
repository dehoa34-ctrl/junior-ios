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

    /// Gozlukten kare beklenecek en uzun sure.
    private static let captureTimeout: Double = 12

    /// Her cekime bir numara verilir. Zaman asimi gorevi hangi cekime ait
    /// oldugunu bilmezse, erken biten bir cekimin gorevi 12 saniye sonra
    /// uyanip **sonraki** cekimi haksiz yere iptal eder.
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
            var status = try await wearables.checkPermissionStatus(.camera)
            permissionInfo = String(describing: status)
            if String(describing: status).lowercased().contains("granted") == false {
                status = try await wearables.requestPermission(.camera)
                permissionInfo = String(describing: status)
            }
        } catch {
            permissionInfo = "istenemedi"
            state = .failed("Kamera izni istenemedi. Meta AI uygulaması açık ve gözlük bağlı mı?")
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
                await MainActor.run { self?.registrationInfo = String(describing: status) }
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
            let permission = try await wearables.checkPermissionStatus(.camera)
            permissionInfo = String(describing: permission)
            if !permissionInfo.lowercased().contains("granted") {
                permissionInfo = String(describing: try await wearables.requestPermission(.camera))
            }

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
            let hint = String(describing: error).lowercased().contains("eligible")
                ? " Gözlüğü tak, bir tuşuna dokunup uyandır ve Meta AI'da bağlı göründüğünü doğrula."
                : ""
            state = .failed("\(step) adımında takıldı: \(detail)\(hint)")
            await disconnect()
        }
    }

    /// Cihaz akışı bir gözlük bildirene kadar bekler; en fazla 15 saniye.
    private func waitForDevice(_ wearables: any WearablesInterface) async {
        let deadline = Date().addingTimeInterval(15)
        for await devices in wearables.devicesStream() {
            if !devices.isEmpty {
                deviceInfo = devices.map { String(describing: $0) }.joined(separator: ", ")
                return
            }
            if Date() > deadline { return }
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

    /// Oturum `.started` olana kadar bekler; en fazla 10 saniye. Süre dolarsa
    /// yine de denenir - beklemek hiç denememekten iyi ama sonsuz olmamalı.
    private func waitUntilStarted(_ session: DeviceSession) async {
        let deadline = Date().addingTimeInterval(10)
        for await sessionState in session.stateStream() {
            if String(describing: sessionState).lowercased().contains("start") { return }
            if Date() > deadline { return }
        }
    }

    func disconnect() async {
        await camera?.stream.stop()
        camera = nil
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
        defer { state = .ready }

        let configuration = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
        guard let camera = try await session.addCamera(config: configuration) else {
            throw GlassesError.cameraUnavailable
        }
        self.camera = camera
        camera.stream.photoDataPublisher.listen { [weak self] photo in
            Task { @MainActor in await self?.finishCapture(with: photo.data) }
        }
        await camera.stream.start()

        captureGeneration += 1
        let generation = captureGeneration

        return try await withCheckedThrowingContinuation { continuation in
            pendingCapture = continuation
            Task { await camera.stream.capturePhoto(format: .jpeg) }
            // Gozluk kareyi hic gondermezse (menzil disi, pil, firmware)
            // continuation asla devam etmez ve cagiran taraf sonsuza kadar
            // bekler. Eller serbest dongusu icin bu sessiz olum demek.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.captureTimeout * 1_000_000_000))
                await self?.failCaptureIfPending(generation: generation)
            }
        }
    }

    /// Sure dolduysa bekleyen istegi hatayla kapatir. finishCapture ile ayni
    /// continuation'i paylasir; hangisi once gelirse pendingCapture'i alir,
    /// digeri guard'a takilir - continuation iki kez devam ettirilemez.
    ///
    /// `generation` kontrolu, erken biten bir cekimin gecikmis gorevinin
    /// siradaki cekimi iptal etmesini engeller.
    private func failCaptureIfPending(generation: Int) async {
        guard generation == captureGeneration, let continuation = pendingCapture else { return }
        pendingCapture = nil
        await camera?.stream.stop()
        camera = nil
        continuation.resume(throwing: GlassesError.timedOut)
    }

    private func finishCapture(with data: Data) async {
        guard let continuation = pendingCapture else { return }
        pendingCapture = nil
        // Kare alindi; kamerayi hemen birak, gozluk pili bosuna gitmesin.
        await camera?.stream.stop()
        camera = nil
        continuation.resume(returning: data)
    }
}

enum GlassesError: LocalizedError {
    case notConnected
    case busy
    case cameraUnavailable
    case timedOut

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
        }
    }
}
