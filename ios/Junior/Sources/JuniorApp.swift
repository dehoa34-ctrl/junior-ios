import SwiftUI
import UserNotifications

@main
struct JuniorApp: App {
    @StateObject private var config = Config()
    @StateObject private var speech = SpeechService()
    @State private var pairingFailed = false
    @State private var pairingResult: PairingResult?

    struct PairingResult: Identifiable {
        let id = UUID()
        let ok: Bool
        let message: String
    }

    init() {
        // Gozluk koprusu acilista bir kez yapilandirilir; basarisiz olursa
        // uygulamanin geri kalani etkilenmez.
        GlassesService.configureOnLaunch()
        // Bilgisayardan gelen notlar uygulama acikken de bildirim olarak gorunsun.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(config: config, speech: speech)
                .preferredColorScheme(.dark)
                // junior://pair bilgisayardaki QR koddan gelir. Digerleri Meta AI
                // kayit onayindan doner; SDK'ya iletilmezse kayit tamamlanmaz.
                .onOpenURL { url in
                    if url.host == "pair" {
                        config.pendingPairing = Config.parsePairing(url)
                        if config.pendingPairing == nil { pairingFailed = true }
                    } else {
                        GlassesService.handleCallback(url)
                    }
                }
                .alert(item: $config.pendingPairing) { request in
                    Alert(title: Text("Bilgisayara bağlanılsın mı?"),
                          message: Text("Junior bu sunucuyu kullanacak:\n\(request.host)\n\nBu kodu kendi bilgisayarındaki Junior uygulamasından okuttuysan onayla."),
                          primaryButton: .default(Text("Bağlan")) {
                              config.applyPairing(request)
                              verifyPairing()
                          },
                          secondaryButton: .cancel(Text("Vazgeç")) { config.pendingPairing = nil })
                }
                // Eslestirme sessizce kaydedilmesin: baglanti hemen denenir,
                // sonucu soylenir; bilgisayardaki QR penceresi de "baglandi" der.
                .alert(item: $pairingResult) { result in
                    Alert(title: Text(result.ok ? "Bağlandı ✓" : "Bağlanamadı"),
                          message: Text(result.message),
                          dismissButton: .default(Text("Tamam")))
                }
                .alert("Eşleştirme kodu geçersiz", isPresented: $pairingFailed) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text("Bilgisayardaki Junior uygulamasında Telefon bölümündeki QR kodu yeniden okut.")
                }
        }
    }

    /// Yeni adres ve belirtecle bilgisayara "eslestim" der. Basariliysa belirtec
    /// ve tunel calisiyor demektir; degilse sebebi soylenir.
    private func verifyPairing() {
        Task { @MainActor in
            // Onay penceresi kapanirken yenisi acilmaya calisilirsa gorunmeyebiliyor.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let url = config.url(path: "/v1/link/confirm"), let token = config.token else {
                pairingResult = PairingResult(ok: false, message: JuniorError.notConfigured.localizedDescription)
                return
            }
            do {
                let providers = try await JuniorClient().confirmPairing(
                    url: url, token: token, fallback: config.url(path: "/v1/capabilities"))
                let via = providers.isEmpty ? "" : "\nYanıtlar: " + providers.joined(separator: " → ")
                pairingResult = PairingResult(ok: true, message: "Bilgisayardaki Junior’a ulaşıldı. Artık konuşabilirsin." + via)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                pairingResult = PairingResult(ok: false, message: reason + "\n\nAdres ve belirteç kaydedildi; bilgisayar açılınca tekrar dener.")
            }
        }
    }
}
