import AppIntents
import Foundation

/// Siri ve Kestirmeler bağlantısı.
///
/// "Hey Siri, Junior'a sor …" dendiğinde uygulama **açılmadan** çalışır; kilit
/// ekranından, Aksiyon Düğmesi'nden ve Kestirmeler'den tetiklenebilir.
///
/// iOS'ta özel bir uyandırma sözcüğü ("Hey Junior") mümkün değil: üçüncü taraf
/// uygulamalar arka planda dinleyemez. Kilitli telefondan erişimin tek yolu bu.
struct AskJuniorIntent: AppIntent {
    static var title: LocalizedStringResource = "Junior'a sor"
    static var description = IntentDescription(
        "Junior'a bir şey sorar ya da komut verir; yanıtı Siri seslendirir.")
    // Uygulamayı öne getirmez: kilit ekranında da çalışsın.
    static var openAppWhenRun = false

    @Parameter(title: "Soru", requestValueDialog: "Ne sorayım?")
    var question: String

    init() {}

    init(question: String) {
        self.question = question
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = try await MainActor.run { () throws -> (url: URL, token: String) in
            let config = Config()
            guard let url = config.url(path: "/v1/command") else {
                throw JuniorIntentError.notConfigured
            }
            guard let token = config.token else {
                throw JuniorIntentError.notConfigured
            }
            return (url, token)
        }

        let client = JuniorClient()
        do {
            // Geçmiş gönderilmiyor: Siri çağrısı tek seferlik, uygulamadaki
            // sohbetin akışını bozmamalı.
            let response = try await client.send(url: settings.url, token: settings.token,
                                                 message: question, history: [],
                                                 image: nil, target: nil)
            var spoken = response.reply
            // Sunucu işi telefona bıraktıysa (hatırlatıcı, zamanlayıcı …) burada yapılır.
            // Uygulama öne gelmediği için ön plan isteyenler dokunulacak bildirim bırakır.
            if response.status == .phoneAction {
                if let action = response.phoneAction, let payload = response.phoneActionPayload {
                    let result = await PhoneActionService.shared.perform(action, payload: payload, retryText: question)
                    if let message = result.message { spoken = message }
                } else {
                    spoken = "Bunu telefonda nasıl yapacağımı anlayamadım."
                }
            }
            return .result(dialog: IntentDialog(stringLiteral: spoken))
        } catch let error as JuniorError {
            throw JuniorIntentError.failed(error.errorDescription ?? "Junior yanıt vermedi.")
        }
    }
}

enum JuniorIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "Önce Junior uygulamasını açıp sunucu adresini ve tokenı gir."
        case .failed(let message):
            return LocalizedStringResource(stringLiteral: message)
        }
    }
}

struct JuniorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJuniorIntent(),
            phrases: [
                "\(.applicationName)'a sor",
                "\(.applicationName)'a söyle",
                "\(.applicationName)",
            ],
            shortTitle: "Junior'a sor",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: AskAboutPhotoIntent(),
            phrases: [
                "\(.applicationName) fotoğrafa baksın",
                "\(.applicationName)'a fotoğraf sor",
            ],
            shortTitle: "Fotoğrafı sor",
            systemImageName: "photo.circle"
        )
    }
}
