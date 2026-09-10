import SwiftUI

@main
struct JuniorApp: App {
    @StateObject private var config = Config()
    @StateObject private var speech = SpeechService()

    init() {
        // Gozluk koprusu acilista bir kez yapilandirilir; basarisiz olursa
        // uygulamanin geri kalani etkilenmez.
        GlassesService.configureOnLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView(config: config, speech: speech)
                .preferredColorScheme(.dark)
                // Meta AI kayit onayindan junior:// ile doner; SDK'ya iletilmezse
                // kayit tamamlanmaz ve gozluk kamerasi hic acilamaz.
                .onOpenURL { url in GlassesService.handleCallback(url) }
        }
    }
}
