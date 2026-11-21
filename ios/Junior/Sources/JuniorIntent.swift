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
    // Kilit açtırmadan çalışır; açıkça yazıldı ki kilitli ekrandaki kısayol bir varsayılana
    // bağlı kalmasın. Belirteç Keychain'de "ilk kilit açılışından sonra" sınıfında: ekran
    // kilitliyken de okunur (Config).
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

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
                                                 image: nil, target: nil, followsRemote: true)
            var spoken = response.reply
            // "Pomodoro durdur" Siri'den de gelir: eski pomodoro bildirimleri kalmasın.
            if PomodoroAlerts.touches(response.actionsExecuted) {
                await PomodoroAlertSync.refresh()
            }
            // Sunucu işi telefona bıraktıysa (hatırlatıcı, zamanlayıcı …) burada yapılır.
            // Uygulama öne gelmediği için ön plan isteyenler dokunulacak bildirim bırakır.
            if response.status == .phoneAction {
                if let action = response.phoneAction, let payload = response.phoneActionPayload {
                    let result = await PhoneActionService.shared.perform(action, payload: payload, retryText: question)
                    spoken = result.spoken(serverReply: response.reply)
                } else {
                    spoken = "Bunu telefonda nasıl yapacağımı anlayamadım."
                }
            }
            // Bilgisayara iletildi: Siri'nin süresi kısa; bir kez (en çok 20 sn) sonucu bekle.
            if response.status == .remoteStarted, let jobID = response.remoteJobID {
                spoken = await Self.remoteResult(jobID: jobID, relayed: response.reply, client: client,
                                                 baseURL: settings.url, token: settings.token)
            }
            return .result(dialog: IntentDialog(stringLiteral: spoken))
        } catch let error as JuniorError {
            throw JuniorIntentError.failed(error.errorDescription ?? "Junior yanıt vermedi.")
        }
    }

    /// Uzak komutun sonucunu tek bir uzun yoklamayla sorar; bitmediyse dürüstçe söyler.
    private static func remoteResult(jobID: String, relayed: String, client: JuniorClient,
                                     baseURL: URL, token: String) async -> String {
        let head = RemoteOutcomeText.relayHead(relayed)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return relayed }
        // /v1/command → /v1/remote/{id}
        components.path = components.path.replacingOccurrences(of: "/v1/command", with: "/v1/remote/\(jobID)")
        components.queryItems = [URLQueryItem(name: "wait", value: "20")]
        guard let url = components.url,
              let response = try? await client.jsonResponse(method: "GET", url: url, token: token, timeout: 25) else {
            return "\(head) \(RemoteOutcomeText.unreachable)"
        }
        if response.status == 404 { return "\(head) \(RemoteOutcomeText.notFound)" }
        guard response.status == 200, let job = RemoteJob.parse(response.data) else {
            return "\(head) Sonucunu öğrenemedim; bilgisayardan kontrol et."
        }
        if let result = RemoteOutcomeText.phrase(job) { return result }
        return "\(head) Sonucu henüz gelmedi; olup olmadığını bilgisayardan kontrol et."
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
