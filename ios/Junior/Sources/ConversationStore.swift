import Foundation
import UIKit

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false {
        // Eller serbest kapalıyken de istek sürdükçe Dynamic Island'da görünsün.
        didSet {
            // Kuyruktan arka planda gönderilen komut adayı "Düşünüyorum" ile açıp kapatmasın.
            guard isSending != oldValue, !sendingQueued else { return }
            JuniorLiveActivity.shared.request(sending: isSending, detail: messages.last?.text ?? "")
        }
    }
    /// Şu an süren istek çevrimdışı kuyruktan mı (balon ve ada başarıya kadar gösterilmez).
    private var sendingQueued = false
    /// Yanıtı gelmeyen (`noReply`) komutun kimliği: "yeniden dene" aynı kimlikle gider,
    /// ilk istek sunucuya ulaşmışsa eylem ikinci kez yapılmaz.
    private var retryRequestID: String?
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

    private let phoneActions: PhoneActionService
    private var retryTask: Task<Void, Never>?

    /// Bilgisayara iletilen komutların sonucunu bekler (`remote_started`).
    private let remote: RemoteCommandFollower
    /// Sunucuya ulaşılamazken verilen komutlar; bağlantı gelince sırayla gönderilir.
    @Published private(set) var offlineQueue: OfflineQueue
    private let queueFile: OfflineQueueFile
    private var flushTask: Task<Void, Never>?
    private var flushWait: Task<Void, Never>?
    /// Kuyruktan gönderilen son komut yine ulaşamadı mı (boşaltma döngüsü durur).
    private var lastSendQueuedAgain = false
    /// Art arda ulaşılamayan deneme sayısı: yedek zamanlayıcı giderek seyrekleşir.
    private var flushFailures = 0

    init(config: Config, speech: SpeechService, archive: ConversationArchive = ConversationArchive(),
         phoneActions: PhoneActionService = .shared, queueFile: OfflineQueueFile = .standard) {
        self.config = config
        self.speech = speech
        self.archive = archive
        self.phoneActions = phoneActions
        self.queueFile = queueFile
        remote = RemoteCommandFollower(config: config)
        offlineQueue = OfflineQueue(items: queueFile.load())
        messages = archive.load()
        remote.onResult = { [weak self] messageID, bubble, result, settled in
            self?.remoteFinished(messageID: messageID, bubble: bubble, result: result, settled: settled)
        }
        // Telefon cepteyken bırakılan bildirime dokunulunca eylem yapılır; sonucu burada söylenir.
        phoneActions.onFollowUp = { [weak self] message, retryText in
            guard let self else { return }
            if let message { self.announce(message) }
            if let retryText { self.retryAfterLaunch(retryText) }
        }
    }

    var canSend: Bool { config.hasToken && config.url(path: "/v1/command") != nil }

    /// - queued: çevrimdışı kuyruktan gelen komut; ilk denemenin `request_id`'siyle gider.
    /// - reusing: yanıtı gelmeyen komutu yeniden denerken onun `request_id`'si.
    func send(text: String, image: UIImage? = nil, target: String? = nil, queued: QueuedCommand? = nil,
              reusing reusedRequestID: String? = nil) {
        // Her erken cikis onTurnEnded ile bildirilmeli. Bildirilmezse eller
        // serbest dongusu "dusunuyor" adiminda takili kalir: uyandirma
        // dinlemesi duraklatilmis durumdadir ve bir daha geri alinmaz, yani
        // token girilmemisken ilk "Hey Junior"dan sonra asistan sessizce olur.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let video = pendingVideo {
            sendVideo(video, text: trimmed)
            return
        }
        // Telefonda video açıkken "30 saniye ileri", "duraklat", "sesi kıs": sabit sözlükten yerel
        // eylem; sunucuya gitmez (Media/VideoControl.swift).
        if !trimmed.isEmpty, image == nil, queued == nil, reusedRequestID == nil,
           let said = VideoPlaybackCenter.shared.handleVoice(trimmed) {
            messages.append(ChatMessage(role: .user, text: trimmed))
            messages.append(ChatMessage(role: .assistant, text: said))
            archive.save(messages)
            onTurnEnded?(nil)
            speech.speak(said, chunks: [])
            return
        }
        // Kuyruktaki komut gönderilirken gelen yeni komut reddedilmez, sıranın sonuna girer.
        if !trimmed.isEmpty, isSending, sendingQueued, queued == nil, image == nil {
            onTurnEnded?(queueBehind(text: trimmed, target: target))
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
        // Kuyruktan gelen komutun balonu ancak sunucu yanıt verince eklenir: ulaşılamazsa
        // sohbette balon eklenip silinmez, arşiv boşuna yazılmaz.
        let quiet = queued != nil
        if !quiet { messages.append(ChatMessage(role: .user, text: trimmed)) }
        pendingTargetQuestion = nil
        sendingQueued = quiet
        isSending = true
        errorText = nil
        retryable = false
        // Goruntu tekrar gonderilmez: yeniden denemede eski kare kullanilmamali.
        lastAttempt = imageData == nil ? (trimmed, target) : nil
        retryRequestID = nil
        // Kuyruktan gelen komut ilk denemenin kimliğiyle gider: ilk deneme sunucuya ulaşmışsa
        // sunucu aynı yanıtı döndürür, eylem ikinci kez yapılmaz.
        let requestID = queued?.requestID ?? reusedRequestID ?? UUID().uuidString
        let healthURL = config.url(path: "/health")

        Task {
            defer {
                isSending = false
                sendingQueued = false
            }
            do {
                let response = try await client.send(url: url, token: token, message: trimmed,
                                                     history: history, image: imageData, target: target,
                                                     requestID: requestID, followsRemote: true,
                                                     healthURL: healthURL)
                if quiet { messages.append(ChatMessage(role: .user, text: trimmed)) }
                var reply = response.reply
                var chunks = response.speech
                // "Pomodoro durdur/başlat" telefondaki eski pomodoro bildirimlerini geçersiz kılar.
                if PomodoroAlerts.touches(response.actionsExecuted) {
                    Task { await PomodoroAlertSync.refresh(config: config) }
                }
                // Sunucu işi telefona bıraktı: önce yap, sonucu (izin yok, bildirim bırakıldı …) söyle.
                if response.status == .phoneAction, let spoken = await runPhoneAction(response, userText: trimmed) {
                    reply = spoken
                    chunks = []
                }
                let answer = ChatMessage(role: .assistant, text: reply)
                messages.append(answer)
                JuniorMood.shared.touch()
                if response.status == .needsTarget { pendingTargetQuestion = trimmed }
                // Bilgisayara iletildi: balon "Bilgisayara ilettim…" der, sonuç gelince güncellenir.
                if response.status == .remoteStarted, let jobID = response.remoteJobID {
                    remote.follow(jobID: jobID, messageID: answer.id, relayed: reply)
                }
                archive.save(messages)
                // Kuyruktan giden komutun yanıtı adada kısa süre görünsün ("Düşünüyorum" gösterilmedi).
                if quiet { JuniorLiveActivity.shared.request(sending: false, detail: reply) }
                // Once dongu haber alsin: seslendirme baslamadan uyandirma
                // dinlemesi duraklatilmali, yoksa Junior kendi sesindeki
                // "Junior" kelimesini duyar.
                onTurnEnded?(nil)
                speech.speak(reply, chunks: chunks)
                flushFailures = 0
                // Bağlantı var: sırada bekleyen komut varsa sırayla gönderilir.
                if queued == nil { flushOfflineQueue() }
            } catch JuniorError.network where imageData == nil {
                // Bilgisayara ulaşılamıyor (istek gitmedi): komut kaybolmasın, sıraya girsin.
                if !quiet {
                    if messages.last?.role == .user { messages.removeLast() }
                    archive.save(messages)
                }
                retryable = false
                let spoken = queueOffline(text: trimmed, target: target, requestID: requestID, original: queued)
                onTurnEnded?(spoken)
            } catch {
                var description = (error as? JuniorError)?.localizedDescription ?? error.localizedDescription
                // Yanıt gecikti: komut ulaşmış olabilir. Kuyruğa girmez; "yeniden dene" aynı kimlikle gider.
                if case JuniorError.noReply = error { retryRequestID = requestID }
                if quiet { description = "Sıradaki \"\(trimmed)\" komutu: \(description)" }
                errorText = description
                JuniorMood.shared.record(outcome: "failed")
                // Yanitsiz kalan kullanici mesaji gecmisi bozmasin diye geri alinir.
                if !quiet, messages.last?.role == .user { messages.removeLast() }
                retryable = lastAttempt != nil
                archive.save(messages)
                onTurnEnded?(description)
            }
        }
    }

    /// Kuyruktan bir komut gönderilirken gelen yeni komut: sıranın sonuna girer.
    private func queueBehind(text: String, target: String?) -> String {
        let dropped = offlineQueue.enqueue(QueuedCommand(text: text, target: target))
        queueFile.save(offlineQueue.items)
        var spoken = "Sırada bekleyen komutları gönderiyorum; bunu da arkalarına ekledim (\(offlineQueue.waiting.count) bekliyor)."
        if !dropped.isEmpty { spoken += " Sıra dolduğu ya da süresi geçtiği için \(dropped.count) eski komut silindi." }
        return spoken
    }

    // MARK: - Uzak komut sonucu

    /// Öne dönünce: arka planda yarıda kalan uzak komutların son durumuna bakar.
    func resumeRemoteResults() {
        remote.resumePending()
    }

    /// - settled: sonuç kesin (iş bitti / bilinmiyor); false ise ara durum ("ulaşılamıyor").
    private func remoteFinished(messageID: UUID, bubble: String, result: String, settled: Bool) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].text = bubble
            archive.save(messages)
        } else if settled {
            // Sohbet bu arada temizlendiyse sonuç yine kaybolmasın.
            messages.append(ChatMessage(role: .assistant, text: result))
            archive.save(messages)
        }
        guard settled, UIApplication.shared.applicationState == .active else { return }
        // "İlettim" cümlesi hâlâ okunuyorsa bitmesini bekle; başka bir tur sürüyorsa araya girme.
        Task { [weak self] in
            for _ in 0..<80 {
                guard let self, self.speech.state == .speaking else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, !self.isSending, self.speech.state == .idle,
                  UIApplication.shared.applicationState == .active else { return }
            self.onTurnEnded?(nil)
            self.speech.speak(result)
        }
    }

    // MARK: - Çevrimdışı kuyruk

    /// Komutu sıraya koyar; söylenecek cümleyi döndürür.
    private func queueOffline(text: String, target: String?, requestID: String, original: QueuedCommand?) -> String {
        let item = original ?? QueuedCommand(text: text, target: target, requestID: requestID)
        let dropped = offlineQueue.enqueue(item, atFront: original != nil)
        queueFile.save(offlineQueue.items)
        lastSendQueuedAgain = true
        // Asıl tetik ServerMonitor'ın "bağlantı geldi" haberi; bu giderek seyrekleşen yedek.
        flushFailures += 1
        scheduleFlush(after: OfflineQueue.retryDelay(afterFailures: flushFailures))
        let count = offlineQueue.waiting.count
        var spoken = original == nil
            ? "Bilgisayara şu an ulaşılamıyor; komutunu sıraya aldım. Bağlantı gelince sırayla göndereceğim (\(count) bekliyor)."
            : "Bilgisayara yine ulaşılamadı; \(count) komut sırada bekliyor."
        if !dropped.isEmpty { spoken += " Sıra dolduğu ya da süresi geçtiği için \(dropped.count) eski komut silindi." }
        return spoken
    }

    /// Bağlantı geldi (ya da bir istek başarılı oldu): sıradaki komutları sırayla gönderir.
    func flushOfflineQueue() {
        guard flushTask == nil, !offlineQueue.waiting.isEmpty, canSend else { return }
        flushWait?.cancel()
        flushWait = nil
        flushTask = Task { [weak self] in
            await self?.drainOfflineQueue()
            self?.flushTask = nil
        }
    }

    private func drainOfflineQueue() async {
        var probed = false
        while !Task.isCancelled {
            // Önceki tur, okunan yanıt ya da seçilmiş video bitsin (en çok 30 sn).
            for _ in 0..<120 where isSending || speech.state != .idle || pendingVideo != nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !isSending, speech.state == .idle, pendingVideo == nil, canSend else {
                scheduleFlush(after: 10)
                return
            }
            // Tam komut göndermeden önce ucuz bir yoklama: sunucu yoksa sohbete, adaya
            // ve 100 sn'lik komut isteğine dokunmadan bekle.
            if !probed {
                guard await serverReachable() else {
                    flushFailures += 1
                    scheduleFlush(after: OfflineQueue.retryDelay(afterFailures: flushFailures))
                    return
                }
                probed = true
                flushFailures = 0
                guard !isSending else { continue }
            }
            let step = offlineQueue.takeNext(now: Date())
            if !step.newlyHeld.isEmpty {
                // Önce soru sorulsun (okunsun); sıradaki komut başa döner, bir sonraki turda gider.
                if let next = step.next { offlineQueue.enqueue(next, atFront: true) }
                queueFile.save(offlineQueue.items)
                for item in step.newlyHeld { askAboutStale(item) }
                continue
            }
            queueFile.save(offlineQueue.items)
            guard let item = step.next else { return }
            lastSendQueuedAgain = false
            send(text: item.text, target: item.target, queued: item)
            // send() isSending'i hemen açar; tur bitene kadar bekle (yanıt 90 sn sürebilir).
            for _ in 0..<480 where isSending {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Yine ulaşılamadı: komut başa döndü, zamanlayıcı kuruldu.
            if lastSendQueuedAgain { return }
        }
    }

    /// Bilgisayardaki sunucu ayakta mı (`/health`, token istemez, en çok 6 sn).
    private func serverReachable() async -> Bool {
        guard let url = config.url(path: "/health") else { return false }
        return await client.isReachable(url: url)
    }

    private func scheduleFlush(after seconds: Double) {
        flushWait?.cancel()
        flushWait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushWait = nil
            self?.flushOfflineQueue()
        }
    }

    /// Zamana bağlı, eskimiş komut: göndermeden sor.
    private func askAboutStale(_ item: QueuedCommand) {
        let question = OfflineQueue.staleQuestion(item)
        if UIApplication.shared.applicationState == .active, !isSending, speech.state == .idle {
            announce(question)
        } else {
            messages.append(ChatMessage(role: .assistant, text: question))
            archive.save(messages)
        }
    }

    /// Sorulan komut için "Gönder".
    func sendStale(_ item: QueuedCommand) {
        offlineQueue.approve(id: item.id)
        queueFile.save(offlineQueue.items)
        flushOfflineQueue()
    }

    /// Sorulan ya da sıradaki komut için "Sil".
    func dropQueued(_ item: QueuedCommand) {
        offlineQueue.remove(id: item.id)
        queueFile.save(offlineQueue.items)
    }

    // MARK: - Telefon eylemleri

    /// Eylemi yürütür. Dönüş: sunucunun cümlesinin yerine söylenecek metin; `nil` ise sunucunun cümlesi kalır.
    private func runPhoneAction(_ response: CommandResponse, userText: String) async -> String? {
        guard let action = response.phoneAction, let payload = response.phoneActionPayload else {
            return "Bunu telefonda nasıl yapacağımı anlayamadım."
        }
        let result = await phoneActions.perform(action, payload: payload, retryText: userText)
        if result.kind == .needsRetry { retryAfterLaunch(userText) }
        if result.kind == .done { JuniorMood.shared.record(outcome: "done") }
        if result.kind == .failed { JuniorMood.shared.record(outcome: "failed") }
        // Aynı beş durum: yapıldıysa sunucunun cümlesi (nil: ses parçaları da kalır),
        // olmadıysa "Telefonda olmadı: neden".
        return result.replacement(serverReply: response.reply)
    }

    /// Spotify açıldıktan sonra aynı komut bir kez daha gönderilir: sunucu artık çalan cihazı bulur.
    /// İkinci kez de telefona bırakılırsa döngüye girmez, durumu söyler.
    func retryAfterLaunch(_ text: String) {
        retryTask?.cancel()
        // Spotify açılınca Junior arka plana düşer; ses kipi kapalıysa iOS bizi askıya alır
        // ve 4,5 sn'lik bekleme ile yeniden gönderme geç kalır ya da hiç olmazdı.
        var background = UIApplication.shared.beginBackgroundTask(withName: "junior-spotify-retry")
        let finish: @MainActor () -> Void = {
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        }
        retryTask = Task { [weak self] in
            defer { finish() }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.resend(text)
        }
    }

    private func resend(_ text: String) async {
        // Önceki tur bitsin, kendi yanıtını okuyup bitirsin.
        for _ in 0..<40 where isSending || speech.state == .speaking {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let url = config.url(path: "/v1/command"), let token = config.token else { return }
        do {
            let response = try await client.send(url: url, token: token, message: text,
                                                 history: [], image: nil, target: nil)
            if response.status == .phoneAction {
                announce("Spotify açıldı ama çalamadım. Spotify'da bir şarkıyı bir kez elle başlatıp tekrar söyle.")
            } else {
                announce(response.reply, chunks: response.speech)
            }
        } catch {
            let description = (error as? JuniorError)?.localizedDescription ?? error.localizedDescription
            announce("Spotify açıldı ama komutu yeniden gönderemedim. \(description)")
        }
    }

    /// Sohbete bir Junior cümlesi ekler ve sesli okur (kullanıcı mesajı olmadan).
    private func announce(_ text: String, chunks: [String] = []) {
        messages.append(ChatMessage(role: .assistant, text: text))
        archive.save(messages)
        // Uyandırma dinlemesi duraksasın: Junior kendi sesindeki "Junior"u duymasın.
        onTurnEnded?(nil)
        speech.speak(text, chunks: chunks)
    }

    /// Gemini Live dökümü sohbet geçmişine yazılır. Sunucuya istek gitmez: konuşma zaten
    /// köprüden geçti, burada yalnız ekranda ve sonraki klasik isteklerin geçmişinde görünür.
    func appendLiveTurn(role: ChatMessage.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: role, text: trimmed))
        archive.save(messages)
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

    /// Basarisiz istegi ayni metinle yeniden gonderir. Yanıtı gelmeyen (`noReply`) istek
    /// ilk kimliğiyle gider: sunucuya ulaşmışsa aynı yanıt döner, eylem ikinci kez yapılmaz.
    func retry() {
        guard let attempt = lastAttempt, !isSending else { return }
        retryable = false
        send(text: attempt.text, target: attempt.target, reusing: retryRequestID)
    }

    #if DEBUG
    /// Ekran görüntüsü için örnek konuşma; arşive yazılmaz.
    func loadDemo(_ demo: [ChatMessage]) {
        messages = demo
    }
    #endif

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
