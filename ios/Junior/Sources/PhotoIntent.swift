import AppIntents
import Foundation
import UIKit

/// Bir fotoğrafı Junior'a sorar. Kestirmeler'den çağrılır.
///
/// Asıl değeri şu: Kestirmeler "Son Fotoğrafları Al" eylemiyle birleştirilince
/// **kilit ekranından** çalışır. Gözlükle çekilen kare Meta AI uygulaması
/// üzerinden Fotoğraflar'a düşer; "Hey Siri, Junior son fotoğrafa baksın"
/// dendiğinde ekrana dokunmadan yanıt alınır.
///
/// Gözlükten anlık kare çekmek DAT gerektirir; o ayrı bir yol.
struct AskAboutPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Fotoğrafı Junior'a sor"
    static var description = IntentDescription(
        "Verilen fotoğrafı Junior'a gönderir ve yanıtı Siri seslendirir.")
    static var openAppWhenRun = false

    // supportedContentTypes iOS 18+ olduğu için kullanılmıyor; hedef 17.0.
    // Kestirmeler zaten görüntü eylemlerinden dosya geçiriyor.
    @Parameter(title: "Fotoğraf")
    var photo: IntentFile

    @Parameter(title: "Soru", default: "Bu fotoğrafta ne görüyorsun? Kısa anlat.")
    var question: String

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = try await MainActor.run { () throws -> (url: URL, token: String) in
            let config = Config()
            guard let url = config.url(path: "/v1/command"), let token = config.token else {
                throw JuniorIntentError.notConfigured
            }
            return (url, token)
        }

        // Sunucu 2 MiB sinirini uyguluyor; kareyi kucultmeden gondermek 400 doner.
        guard let image = UIImage(data: photo.data), let jpeg = image.juniorJPEGData() else {
            throw JuniorIntentError.failed("Fotoğraf okunamadı ya da çok büyük.")
        }

        let client = JuniorClient()
        do {
            let response = try await client.send(url: settings.url, token: settings.token,
                                                 message: question, history: [],
                                                 image: jpeg, target: nil)
            return .result(dialog: IntentDialog(stringLiteral: response.reply))
        } catch let error as JuniorError {
            throw JuniorIntentError.failed(error.errorDescription ?? "Junior yanıt vermedi.")
        }
    }
}
