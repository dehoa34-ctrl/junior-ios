import Foundation
import UIKit

/// Sorunun yanıtı için **görüntü** gerekip gerekmediği.
///
/// Saf mantık: aktör izolasyonu yok, testten doğrudan çağrılabilir.
///
/// Amaç, "hey junior bu gördüğüm ne" dendiğinde kullanıcının ekrana dokunup
/// fotoğraf seçmek zorunda kalmaması. Bu yüzden karar konuşmanın metninden
/// veriliyor; modelin çıktısından değil.
enum VisionIntent {
    /// Görüntü isteyen kalıplar. Katlanmış (Türkçe karakterler sadeleşmiş) halde
    /// aranır, bu yüzden burada da katlanmış yazılırlar.
    private static let triggers = [
        "bu ne", "bu nedir", "su ne", "sunlar ne", "bunlar ne", "bu kim", "su kim",
        "gordugum ne", "gordugum sey", "ne goruyorum", "ne goruyorsun", "ne goruyoruz",
        "onumde ne", "karsimda ne", "elimde ne", "onumdeki ne", "karsimdaki ne",
        "bunu oku", "sunu oku", "ne yaziyor", "yaziyi oku", "sunu tarif et",
        "suna bak", "buna bak", "baksana", "bak bakalim", "bir bak",
        "bu hangi", "su hangi", "bu marka", "bu model", "bu yemek", "bu bitki",
        "fotograf cek", "resim cek", "kare al", "cek de bak",
    ]

    /// "bu ne demek" bir kelime sorusudur, görüntü sorusu değil. Bu kalıplar
    /// tetikleyicilerden **önce** bakılır, çünkü "bu ne" onun içinde de geçer.
    private static let exclusions = [
        "ne demek", "ne anlama", "nasil yazilir", "ne kadar surer",
        "ne zaman", "ne haber", "napiyorsun", "ne yapiyorsun",
    ]

    static func needsPhoto(_ text: String) -> Bool {
        let folded = WakeWord.fold(text)
        if exclusions.contains(where: { folded.contains($0) }) { return false }
        return triggers.contains { folded.contains($0) }
    }
}

/// Sürekli konuşmayı bitiren ifadeler.
///
/// Meta AI her soru için yeniden "Hey Meta" istiyor; kullanıcı bunu istemiyor.
/// Sürekli modda yanıttan sonra doğrudan dinlemeye dönülür ve ancak bu
/// ifadelerden biri duyulunca (ya da sessiz kalınca) uyandırma sözcüğüne
/// geri dönülür.
enum ConversationControl {
    private static let stopWords: Set<String> = [
        "kapat", "dur", "yeter", "bitir", "sus", "tamamdir", "iptal",
        "bosver", "sagol", "tesekkurler", "tesekkur", "kapanabilirsin", "gorusuruz",
    ]

    /// Kapatma sözcüğünün yanında durabilecek nezaket/dolgu sözcükleri.
    private static let fillers: Set<String> = [
        "tamam", "artik", "hadi", "lutfen", "junior", "hey", "ok", "peki",
        "simdilik", "ederim", "cok",
    ]

    /// Yalnız **bütün söylenen** bir kapatma ifadesiyse sohbeti bitirir.
    ///
    /// Önce kara liste denenmişti ("içinde 'ışık' geçiyorsa komuttur") ama
    /// Türkçe ünsüz yumuşaması yüzünden tutmuyor: "ışık" ekli hâlde "ışığı"
    /// oluyor ve liste ıskalıyor, "ışığı kapat" sohbeti bitiriyordu. Kuralı
    /// tersine çevirmek daha sağlam: cümlede kapatma sözcüğü ve nezaket
    /// sözcüklerinden başka bir şey varsa bu bir komuttur, veda değil.
    static func wantsToStop(_ text: String) -> Bool {
        let words = WakeWord.fold(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        var sawStop = false
        for word in words {
            if stopWords.contains(word) { sawStop = true }
            else if !fillers.contains(word) { return false }
        }
        return sawStop
    }
}


/// "Hey Junior" → dinle → (gerekirse gözlükten kare) → gönder → kulağa yanıt →
/// tekrar dinle. Telefon cepte, ekran kapalı.
///
/// Döngünün tek sahibi burasıdır. Daha önce bu mantık RootView'a dağılmıştı ve
/// iki hata üretiyordu: yanıt seslendirilirken uyandırma dinlemesi yeniden
/// açıldığı için Junior kendi sesindeki "Junior" kelimesiyle kendini
/// tetikleyebiliyordu; ve konuşma bittiğinde döngü kendini kurmuyordu.
///
/// Ekran kapalıyken çalışması `UIBackgroundModes: audio` sayesindedir: ses
/// oturumu açık kaldığı sürece iOS uygulamayı askıya almaz. Uygulamanın
/// **açık** olması (arka planda da olsa) gerekir; iOS üçüncü taraf uygulamalara
/// sistem düzeyinde uyandırma sözcüğü vermiyor, o katman Siri'ye ayrılmış.
@MainActor
final class HandsFreeSession: ObservableObject {
    enum Phase: Equatable {
        case off
        case waiting
        case listening
        case capturing
        case thinking
        case speaking
    }

    @Published private(set) var phase: Phase = .off {
        didSet { phaseChanged() }
    }
    /// Son turda gözlükten kare alındı mı; arayüzde göstermek için.
    @Published private(set) var usedGlasses = false

    /// Tur bittiğinde dönülecek durum. Uyandırma sözcüğü kapalıyken mikrofon
    /// düğmesi yine çalışır ama döngü beklemeye değil kapalıya döner.
    private var idlePhase: Phase = .off

    /// Sürekli konuşma açık mı; Ayarlar'dan gelir.
    var continuousEnabled = true
    /// Şu an sürekli bir sohbetin içinde miyiz. Uyandırma sözcüğüyle açılır,
    /// "kapat" denince ya da sessiz kalınca kapanır.
    @Published private(set) var continuousActive = false

    /// Bir adimin takilip kalabilecegi en uzun sure.
    private static let stallTimeout: Double = 60

    /// Adıma göre bekçi süresi. Sunucu Claude'u 90 saniyeye kadar bekliyor;
    /// 60 saniyelik bekçi yavaş ama geçerli bir yanıtı yarıda bırakıyordu.
    private static func timeout(for phase: Phase) -> Double {
        phase == .thinking ? 100 : stallTimeout
    }

    private var watchdog: Task<Void, Never>?

    private let wakeWord: WakeWordService
    private let speech: SpeechService
    private let glasses: GlassesService
    private let store: ConversationStore

    init(wakeWord: WakeWordService, speech: SpeechService,
         glasses: GlassesService, store: ConversationStore) {
        self.wakeWord = wakeWord
        self.speech = speech
        self.glasses = glasses
        self.store = store
        wire()
    }

    private func wire() {
        wakeWord.onDetected = { [weak self] in self?.beginTurn() }

        store.onTurnEnded = { [weak self] error in
            guard let self else { return }
            switch self.phase {
            case .thinking:
                // Eller serbest turu: ekran kapalı, hatayı görmesi mümkün
                // değil, duyması gerek.
                self.phase = .speaking
                if let error { self.speech.speak(error) }
            case .waiting:
                // Yazarak ya da kamera menüsünden gelen tur. Yanıt yine
                // seslendiriliyor, dolayısıyla uyandırma dinlemesi bu sırada
                // kapalı kalmalı; yoksa döngü dışındaki her yanıt kendini
                // tetikleyebilir. Hata metni seslendirilmez: ekranda görünüyor.
                guard error == nil else { return }
                self.phase = .speaking
                self.wakeWord.pauseForRecording()
            default:
                break
            }
        }

        speech.onSpeakingFinished = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.resumeWaiting()
        }
    }

    func start() {
        guard phase == .off else { return }
        idlePhase = .waiting
        phase = .waiting
        wakeWord.start()
    }

    func stop() {
        idlePhase = .off
        continuousActive = false
        phase = .off
        wakeWord.stop()
        speech.stopSpeaking()
    }

    /// Bir tur başlatır. **Tek giriş noktası**: uyandırma sözcüğü de mikrofon
    /// düğmesi de buradan geçer.
    ///
    /// İkiye ayrılmışken düğmeye basınca uyandırma dinlemesi duraklatılıyor
    /// ama bir daha hiç geri alınmıyordu; ilk "Hey Junior" çalışıyor, sonraki
    /// hiçbiri çalışmıyordu.
    func beginTurn() {
        guard phase == .waiting || phase == .off else { return }
        phase = .listening
        usedGlasses = false
        if continuousEnabled, idlePhase == .waiting { continuousActive = true }
        // İki tanıma oturumu aynı anda mikrofonu tutamaz.
        wakeWord.pauseForRecording()
        // Ekran açıkken titreşim, kapalıyken ses: iOS arka planda titreşim
        // vermiyor, dolayısıyla cepteki telefonda tek geri bildirim kulak.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        speech.playCue()

        Task {
            // Sesin bitmesini bekle; tanıma "bip"i yazıya dökmeye çalışmasın.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self.phase == .listening else { return }
            await self.speech.startListening { [weak self] text in
                self?.handle(text)
            }
            // Dinleme hiç başlamadıysa (izin, mikrofon meşgul, tanıma yok)
            // sürekli sohbeti bitir ve sesle söyle. Bitirilmeden resumeWaiting
            // hemen yeni bir tur açıyor, o da başarısız oluyordu: beklemesiz,
            // sonsuza dönen bir döngü - her turda da titreşim.
            if self.speech.state != .listening, self.phase == .listening {
                self.continuousActive = false
                self.phase = .speaking
                self.speech.speak("Mikrofonu açamadım.")
            }
        }
    }

    private func handle(_ text: String) {
        guard phase == .listening else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Sessizlik sürekli sohbeti bitirir. Sürekli modda "Seni duyamadım"
            // demek sonsuz bir döngü olurdu: söyler, dinler, yine duymaz.
            continuousActive = false
            resumeWaiting()
            return
        }
        if ConversationControl.wantsToStop(trimmed) {
            continuousActive = false
            phase = .speaking
            speech.speak("Tamam, kapatıyorum.")
            return
        }

        guard VisionIntent.needsPhoto(text) else {
            phase = .thinking
            store.send(text: text)
            return
        }

        phase = .capturing
        Task {
            do {
                let data = try await self.glasses.capturePhoto()
                guard let image = UIImage(data: data) else {
                    throw GlassesError.cameraUnavailable
                }
                self.usedGlasses = true
                self.phase = .thinking
                self.store.send(text: text, image: image)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "Gözlükten kare alınamadı."
                self.phase = .speaking
                self.speech.speak(reason)
            }
        }
    }

    /// Her adim icin taze bir bekci kurar; beklemeye/kapaliya donunce iptal
    /// edilir.
    ///
    /// Tek tek bulup kapattigim kilitlenmelerin ustune bir de bu var: DAT'in
    /// gercek cihazdaki davranisini deneyemedim ve seslendirme geri cagrisi
    /// hic gelmeyebilir. Bekci olmazsa boyle bir durumda asistan sessizce
    /// oluyor ve kullanicinin uyandirma sozcugunu kapatip acmasi gerekiyor.
    private func phaseChanged() {
        switch phase {
        case .off, .waiting:
            watchdog?.cancel()
            watchdog = nil
        case .listening, .capturing, .thinking, .speaking:
            watchdog?.cancel()
            let limit = Self.timeout(for: phase)
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.recoverFromStall()
            }
        }
    }

    private func recoverFromStall() {
        guard phase != .off, phase != .waiting else { return }
        // Takilmadan sonra dinlemeye devam etmek riskli; uyandirma sozcugune don.
        continuousActive = false
        // Once durumu geri al: stopListening/stopSpeaking geri cagri
        // tetikleyebilir ve bunlarin yeni bir tur baslatmasi istenmez.
        phase = idlePhase
        speech.stopSpeaking()
        speech.stopListening()
        releaseMicrophoneIfIdle()
        wakeWord.resumeAfterRecording()
    }

    private func resumeWaiting() {
        // Sürekli sohbet sürüyorsa uyandırma sözcüğüne dönmeden doğrudan
        // dinlemeye geç: kullanıcı her soru için "Hey Junior" demek istemiyor.
        if continuousEnabled, continuousActive, idlePhase == .waiting {
            phase = .waiting
            beginTurn()
            return
        }
        phase = idlePhase
        releaseMicrophoneIfIdle()
        // Uyandirma hic calismiyorsa bu cagri zaten bir sey yapmaz.
        wakeWord.resumeAfterRecording()
    }

    /// Uyandırma kapalıyken tur bitince mikrofonu bırakır. Bırakılmazsa elle
    /// sorulan tek bir sorudan sonra mikrofon açık kalıyordu: turuncu nokta,
    /// pil tüketimi ve kimsenin dinlemediği bir kanal.
    private func releaseMicrophoneIfIdle() {
        if idlePhase == .off { MicrophoneHub.shared.stop() }
    }
}
