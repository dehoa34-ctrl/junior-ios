import Foundation
import UIKit

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false {
        // Eller serbest kapalıyken de istek sürdükçe Dynamic Island'da görünsün.
        didSet {
            guard isSending != oldValue else { return }
            JuniorLiveActivity.shared.request(sending: isSending, detail: messages.last?.text ?? "")
        }
    }
    @Published var errorText: String?
    /// Sunucu "bilgisayarda mi telefonda mi" diye sordugunda son mesaji saklariz.
    @Published private(set) var pendingTargetQuestion: String?
    /// Basarisiz istegi yeniden gondermek icin; kullanici bastan yazmak zorunda kalmasin.
    @Published private(set) var retryable: Bool = false

    private var lastAttempt: (text: String, target: String?)?

    /// Galeriden secilmis, gonderilmeyi bekleyen video. Doluyken gonderilen
    /// mesaj ("bunu editle") bilgisayardaki Junior'a kurgu isi olarak gider.
    @Published var pendingVideo: PickedVideo?
    let videoJobs = VideoJobService()
    private var videoTask: Task<Void, Never>?

    /// Bir tur bittiğinde çağrılır. `nil` yalnız **tek bir anlama** gelir:
    /// yanıt geldi ve `speech` onu seslendirmeye başlıyor. Dolu değer,
    /// söylenecek/gösterilecek metindir.
    ///
    /// **Değişmez:** `send(...)` her çıkış yolunda bunu tam olarak bir kez
    /// çağırmalı. Çağırmayan bir yol eller serbest döngüsünü "düşünüyor"
    /// adımında bırakır; uyandırma dinlemesi duraklatılmış olduğu için
    /// asistan sessizce ölür. Seslendirilecek bir şey olmayan çıkışlarda
    /// `nil` geçmek de aynı sonucu verir.
    var onTurnEnded: ((String?) -> Void)?

    private let client = JuniorClient()
    private let config: Config
    private let speech: SpeechService
    private let archive: ConversationArchive

    init(config: Config, speech: SpeechService, archive: ConversationArchive = ConversationArchive()) {
        self.config = config
        self.speech = speech
        self.archive = archive
        messages = archive.load()
    }

    var canSend: Bool { config.hasToken && config.url(path: "/v1/command") != nil }

    func send(text: String, image: UIImage? = nil, target: String? = nil) {
        // Her erken cikis onTurnEnded ile bildirilmeli. Bildirilmezse eller
        // serbest dongusu "dusunuyor" adiminda takili kalir: uyandirma
        // dinlemesi duraklatilmis durumdadir ve bir daha geri alinmaz, yani
        // token girilmemisken ilk "Hey Junior"dan sonra asistan sessizce olur.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let video = pendingVideo {
            sendVideo(video, text: trimmed)
            return
        }
        guard !trimmed.isEmpty, !isSending else {
            // nil "yanit geliyor, seslendiriliyor" demek; burada seslendirilecek
            // bir sey yok, o yuzden her iki durum da metinle bildirilir.
            onTurnEnded?(isSending ? "Önceki isteğim hâlâ sürüyor." : "Seni duyamadım.")
            return
        }
        guard let url = config.url(path: "/v1/command") else {
            let message = JuniorError.badAddress.localizedDescription
            errorText = message
            onTurnEnded?(message)
            return
        }
        guard let token = config.token else {
            let message = JuniorError.notConfigured.localizedDescription
            errorText = message
            onTurnEnded?(message)
            return
        }

        var imageData: Data?
        if let image {
            imageData = image.juniorJPEGData()
            if imageData == nil {
                let message = "Fotograf kucultulemedi. Baska bir kare dene."
                errorText = message
                onTurnEnded?(message)
                return
            }
        }

        let history = messages
        messages.append(ChatMessage(role: .user, text: trimmed))
        pendingTargetQuestion = nil
        isSending = true
        errorText = nil
        retryable = false
        // Goruntu tekrar gonderilmez: yeniden denemede eski kare kullanilmamali.
        lastAttempt = imageData == nil ? (trimmed, target) : nil

        Task {
            defer { isSending = false }
            do {
                let response = try await client.send(url: url, token: token, message: trimmed,
                                                     history: history, image: imageData, target: target)
                messages.append(ChatMessage(role: .assistant, text: response.reply))
                if response.status == .needsTarget { pendingTargetQuestion = trimmed }
                archive.save(messages)
                // Once dongu haber alsin: seslendirme baslamadan uyandirma
                // dinlemesi duraklatilmali, yoksa Junior kendi sesindeki
                // "Junior" kelimesini duyar.
                onTurnEnded?(nil)
                speech.speak(response.reply, chunks: response.speech)
            } catch {
                let description = (error as? JuniorError)?.localizedDescription ?? error.localizedDescription
                errorText = description
                // Yanitsiz kalan kullanici mesaji gecmisi bozmasin diye geri alinir.
                if messages.last?.role == .user { messages.removeLast() }
                retryable = lastAttempt != nil
                archive.save(messages)
                onTurnEnded?(description)
            }
        }
    }

    // MARK: - Video: telefondan sec, bilgisayarda kurgulat

    private func sendVideo(_ video: PickedVideo, text: String) {
        guard videoTask == nil else {
            onTurnEnded?("Önceki video hâlâ işleniyor; bitince yenisini gönderebilirsin.")
            return
        }
        pendingVideo = nil
        errorText = nil
        let request = text.isEmpty ? "Bunu editle" : text
        messages.append(ChatMessage(role: .user, text: "🎬 \(video.name) · \(video.sizeLabel)\n\(request)"))
        archive.save(messages)
        // Tur hemen biter: kurgu dakikalar surebilir, eller serbest dongusu beklemesin.
        onTurnEnded?("Videoyu bilgisayara gönderiyorum; kurgu bitince haber vereceğim.")
        videoTask = Task { [weak self] in
            guard let self else { return }
            defer { self.videoTask = nil }
            do {
                let jobID = try await self.videoJobs.submit(video, prompt: text, config: self.config)
                try await self.finishVideo(jobID)
            } catch {
                self.videoFailed(error)
            }
        }
    }

    /// Uygulama yeniden acildiginda yarim kalan kurgu isini izlemeye devam eder.
    func resumeVideoJob() {
        guard videoTask == nil, let jobID = videoJobs.pendingJobID else { return }
        videoTask = Task { [weak self] in
            guard let self else { return }
            defer { self.videoTask = nil }
            do {
                try await self.finishVideo(jobID)
            } catch {
                self.videoFailed(error)
            }
        }
    }

    private func finishVideo(_ jobID: String) async throws {
        let reply = try await videoJobs.follow(jobID: jobID, config: config)
        messages.append(ChatMessage(role: .assistant, text: reply))
        archive.save(messages)
        VideoJobService.notifyDone(reply)
    }

    private func videoFailed(_ error: Error) {
        if case VideoJobError.cancelled = error { return }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let text = videoJobs.pendingJobID != nil
            ? "Bilgisayara şu an ulaşılamıyor; video orada işleniyor olabilir. Uygulamayı açınca tekrar bakacağım."
            : "Video işi tamamlanamadı: \(description)"
        messages.append(ChatMessage(role: .assistant, text: text))
        archive.save(messages)
    }

    /// "Bilgisayarda mi telefonda mi?" sorusuna cevap: ayni komutu hedefle tekrar gonderir.
    func answerTarget(_ target: String) {
        guard let question = pendingTargetQuestion else { return }
        pendingTargetQuestion = nil
        if messages.last?.role == .assistant { messages.removeLast() }
        if messages.last?.role == .user { messages.removeLast() }
        send(text: question, target: target)
    }

    /// Basarisiz istegi ayni metinle yeniden gonderir. Yeni request_id uretilir,
    /// bu yuzden sunucu tarafinda cift islem riski yoktur.
    func retry() {
        guard let attempt = lastAttempt, !isSending else { return }
        retryable = false
        send(text: attempt.text, target: attempt.target)
    }

    func clear() {
        lastAttempt = nil
        retryable = false
        messages.removeAll()
        archive.clear()
        pendingTargetQuestion = nil
        errorText = nil
        speech.stopSpeaking()
    }

    func testConnection() async -> String {
        guard let url = config.url(path: "/v1/capabilities") else { return JuniorError.badAddress.localizedDescription }
        guard let token = config.token else { return JuniorError.notConfigured.localizedDescription }
        do {
            let capabilities = try await client.capabilities(url: url, token: token)
            let provider = capabilities["provider"] as? String ?? "?"
            let spotify = (capabilities["spotify"] as? [String: Any])?["configured"] as? Bool ?? false
            return "Baglanti tamam. Saglayici: \(provider). Spotify: \(spotify ? "bagli" : "bagli degil")."
        } catch {
            return (error as? JuniorError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
