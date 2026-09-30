import SwiftUI

@main
struct JuniorApp: App {
    @StateObject private var config = Config()
    @StateObject private var speech = SpeechService()
    @State private var pairingFailed = false

    init() {
        // Gozluk koprusu acilista bir kez yapilandirilir; basarisiz olursa
        // uygulamanin geri kalani etkilenmez.
        GlassesService.configureOnLaunch()
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
                          primaryButton: .default(Text("Bağlan")) { config.applyPairing(request) },
                          secondaryButton: .cancel(Text("Vazgeç")) { config.pendingPairing = nil })
                }
                .alert("Eşleştirme kodu geçersiz", isPresented: $pairingFailed) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text("Bilgisayardaki Junior uygulamasında Telefon bölümündeki QR kodu yeniden okut.")
                }
        }
    }
}
