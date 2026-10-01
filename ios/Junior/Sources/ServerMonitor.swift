import Foundation

/// Bilgisayardaki sunucuya (`/health`) ulaşılıp ulaşılamadığını izler.
///
/// Önceden yalnız açılışta, öne dönüşte ve "Yeniden dene"de bir kez
/// bakılıyordu. Ayarlar'da adres girilip pencere kapatılınca yeniden
/// bakılmadığı için uyarı, sunucu açıkken de "Yeniden dene"ye basılana dek
/// ekranda kalıyordu. Üstelik aynı anda başlayan iki kontrolden yavaş ve
/// başarısız olanı sonra bitince, yeni ve başarılı sonucun üzerine yazıyordu.
///
/// Şimdi her kontrol bir kuşak numarası taşır; yalnız en son başlayanın sonucu
/// uygulanır. Ulaşılamıyorsa birkaç saniyede bir kendiliğinden yeniden bakılır,
/// sunucu gelince uyarı dokunmadan kalkar.
@MainActor
final class ServerMonitor: ObservableObject {
    /// nil = henüz bakılmadı ya da adres yok. false ise bilgisayar kapalı ya da tünel düşük.
    @Published private(set) var serverUp: Bool?

    private let healthURL: @MainActor () -> URL?
    private let probe: (URL) async -> Bool
    private let retryInterval: TimeInterval
    private let debounceInterval: TimeInterval

    /// Her yeni kontrolde artar. Sonuç geldiğinde hâlâ aynıysa uygulanır.
    private var generation = 0
    private var checkTask: Task<Void, Never>?
    /// Bekleyen gecikmeli kontrol: adres yazılırken bekleme ya da yeniden deneme.
    private var waitTask: Task<Void, Never>?

    init(healthURL: @escaping @MainActor () -> URL?,
         probe: ((URL) async -> Bool)? = nil,
         retryInterval: TimeInterval = 10,
         debounceInterval: TimeInterval = 1) {
        self.healthURL = healthURL
        if let probe {
            self.probe = probe
        } else {
            // Tek istemci: döngü her denemede yeni bir URLSession açmasın.
            let client = JuniorClient()
            self.probe = { await client.isReachable(url: $0) }
        }
        self.retryInterval = retryInterval
        self.debounceInterval = debounceInterval
    }

    /// Hemen bakar. Bekleyen gecikmeli kontrol ve yarıdaki istek geçersiz olur;
    /// Ayarlar kapanınca ya da "Yeniden dene"ye basılınca beklemeye gerek yok.
    func check() {
        invalidate()
        guard let url = healthURL() else {
            // Adres yoksa söylenecek bir şey yok; eksik adres uyarısı ayrı gösteriliyor.
            serverUp = nil
            return
        }
        let current = generation
        checkTask = Task { [weak self] in
            guard let probe = self?.probe else { return }
            let up = await probe(url)
            self?.finish(up, generation: current)
        }
    }

    /// Adres değişti. Her tuşta ağa çıkılmaz; yazma bir an durunca bakılır.
    /// Eski adresin sonucu yeni adres için geçerli değil, o yüzden unutulur.
    func addressChanged() {
        invalidate()
        serverUp = nil
        schedule(after: debounceInterval)
    }

    /// Arka plana geçerken: döngü ve yarıdaki istek bırakılır. Telefon cepteyken
    /// birkaç saniyede bir ağa çıkmanın anlamı yok; öne dönünce `check()` yeniden başlatır.
    func pause() {
        invalidate()
    }

    private func finish(_ up: Bool, generation current: Int) {
        // Bu arada daha yeni bir kontrol başladıysa bu sonuç eskidir.
        guard current == generation else { return }
        serverUp = up
        if !up { schedule(after: retryInterval) }
    }

    private func schedule(after seconds: TimeInterval) {
        waitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func invalidate() {
        generation += 1
        checkTask?.cancel()
        checkTask = nil
        waitTask?.cancel()
        waitTask = nil
    }
}
