import AVFoundation
import Foundation
import UIKit

/// iPhone'da Gemini Live sesli oturumu (Ayarlar > Ses motoru: Gemini Live).
///
///  mikrofon (MicrophoneHub, 16 kHz PCM16, 100 ms) → köprü (wss://…/v1/live/gemini/ws) → Gemini
///  Gemini → köprü → 24 kHz PCM16 → GeminiPCMPlayer (kesintisiz)
///
/// Anahtar ve günlük dakika sınırı bilgisayardaki sunucuda durur; telefon yalnız kendi
/// belirteciyle köprüye bağlanır. Köprü "fallback" derse, bağlantı koparsa ya da zamanında
/// hazır olmazsa oturum kapanır, kullanıcıya tek cümle söylenir ve konuşma klasik yolla
/// (dinle → sunucu → seslendir) sürer; yanıtlanmamış son söz klasik yolda yeniden sorulur.
///
/// Telefon araç bildirmez: canlı oturumda telefonda ya da bilgisayarda iş yapılmaz. Model yine
/// de araç çağırırsa "[failed]" yanıtı gider ve kartta yalnız durum görünür.
@MainActor
final class GeminiLiveSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
    }

    /// Klasik yolla ilgili işler RootView'dan bağlanır (uyandırma ve eller serbest döngüsü orada).
    struct Hooks {
        /// Oturum açılırken: "Hey Junior" dinlemesi kendi sesimizi duymasın, mikrofonu paylaşalım.
        var pauseWake: @MainActor () -> Void
        /// Oturum bitince (geri düşüş değilse): uyandırma dinlemesine dön.
        var resumeWake: @MainActor () -> Void
        /// Uyandırma kapalıysa mikrofonu bırak.
        var releaseMic: @MainActor () -> Void
        /// Geri düşüşten sonra klasik yol: soruyu gönder ya da dinlemeye başla.
        var classic: @MainActor (GeminiFallbackPolicy.ClassicStep) -> Void
    }

    @Published private(set) var phase: Phase = .idle
    /// Junior şu an konuşuyor mu (kedi ve kart için).
    @Published private(set) var modelSpeaking = false
    /// Kartın alt satırı: o an duyulan/söylenen ya da araç durumu.
    @Published private(set) var detail: String?
    /// Son geri düşüşün engeli: süresi dolana ya da sorun bilgisayarda çözülene kadar klasik yol.
    @Published private(set) var block: GeminiBlock?

    var hooks: Hooks?
    let statusModel: GeminiStatusModel

    /// Köprü bu sürede "ready" demezse klasik yola dönülür (ağ çağrılarının 30 sn sınırının altında).
    static let readyTimeout: TimeInterval = 20
    /// Bağlanırken söylenenler kaybolmasın: en çok ~5 sn ses bekletilir.
    static let maxPendingChunks = 50
    /// Tünel boşta kapanmasın ve kopma erken anlaşılsın diye ping aralığı.
    static let pingInterval: TimeInterval = 15

    private let config: Config
    private let speech: SpeechService
    private let store: ConversationStore
    private let player = GeminiPCMPlayer()
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var tap: GeminiMicTap?
    private var turns = GeminiTurnBuffer()
    private var audioGate = GeminiModelAudioGate()
    private var pendingAudio: [Data] = []
    /// Bağlanırken yazılanlar: "ready" gelince gider.
    private var pendingText: [String] = []
    private var generation = 0
    private var tasks: [Task<Void, Never>] = []

    init(config: Config, speech: SpeechService, store: ConversationStore, hooks: Hooks? = nil) {
        self.config = config
        self.speech = speech
        self.store = store
        self.hooks = hooks
        statusModel = GeminiStatusModel(config: config)
        let configuration = URLSessionConfiguration.ephemeral
        // El sıkışmanın kendi sınırı readyTimeout; canlı oturum dakikalarca açık kalabildiği için
        // istek sınırı uzun (boşta kalan oturumu ping yoklar).
        configuration.timeoutIntervalForRequest = 300
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration)
    }

    var isActive: Bool { phase != .idle }

    func route(for engine: VoiceEngine) -> GeminiFallbackPolicy.Route {
        GeminiFallbackPolicy.route(engine: engine, block: block, now: Date())
    }

    /// Kullanıcı motoru yeniden seçti: engel kalkar, bir sonraki konuşma Gemini'yi dener.
    func allow() {
        block = nil
    }

    /// Durum ucunu okur; sorun bilgisayarda çözüldüyse (anahtar girildi, sınır yükseltildi, yeni gün) engeli kaldırır.
    func refreshStatus() async {
        guard let status = await statusModel.load(), let block else { return }
        if GeminiFallbackPolicy.clears(block, with: status) { self.block = nil }
    }

    // MARK: - Açma / kapama

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard phase == .idle else { return }
        generation += 1
        let current = generation
        phase = .connecting
        detail = "Gemini'ye bağlanıyor…"
        turns = GeminiTurnBuffer()
        audioGate = GeminiModelAudioGate()
        pendingAudio = []
        pendingText = []
        hooks?.pauseWake()
        speech.stopSpeaking()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let begin = Task { [weak self] in
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard let self, self.generation == current else { return }
            guard granted else {
                self.endWithoutFallback(message: "Mikrofon izni verilmedi. Ayarlar > Junior bölümünden açabilirsin.")
                return
            }
            self.connect(current)
        }
        tasks.append(begin)
    }

    /// Kullanıcı oturumu bitirdi: yarım tur geçmişe yazılır, köprüye "end" gider.
    func stop() {
        guard phase != .idle else { return }
        write(turns.flush(all: true))
        let socket = self.socket
        self.socket = nil
        teardown()
        if let socket {
            socket.send(.string(GeminiWire.end)) { _ in
                socket.cancel(with: .normalClosure, reason: nil)
            }
            // "end" gidemezse de bağlantı en geç 2 sn sonra kapanır.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
        hooks?.resumeWake()
        hooks?.releaseMic()
    }

    private func connect(_ current: Int) {
        guard let url = GeminiWire.bridgeURL(from: config.url(path: "/v1/live/gemini/ws")) else {
            endWithoutFallback(message: JuniorError.badAddress.localizedDescription)
            return
        }
        guard let token = config.token, !token.isEmpty else {
            endWithoutFallback(message: JuniorError.notConfigured.localizedDescription)
            return
        }
        // Mikrofon kolu: çalma sırasında yankı kapısı, söze girince çalma durur.
        let player = self.player
        let tap = GeminiMicTap(
            isPlaying: { player.isPlaying },
            send: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.sendAudio(chunk, generation: current) }
            },
            bargeIn: { [weak self] in
                player.stop()
                // Turun kalan sesi köprüden gelmeyi sürdürür; "interrupted" gelene kadar çalınmaz.
                Task { @MainActor [weak self] in self?.localBargeIn(generation: current) }
            }
        )
        do {
            try MicrophoneHub.shared.attachGemini(tap)
        } catch {
            endWithoutFallback(message: "Mikrofon başlatılamadı. Başka bir uygulama sesi kullanıyor olabilir.")
            return
        }
        self.tap = tap

        // 30 sn: ağ çağrılarının ortak sınırı. Bağlantı açıkken her 15 sn'lik ping boşta sayılmasını önler.
        var request = URLRequest(url: url, timeoutInterval: 30)
        // Belirteç başlıkta gider (adreste değil): günlüklere sızmasın.
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Junior-iOS", forHTTPHeaderField: "User-Agent")
        let socket = urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket
        socket.resume()
        send(GeminiWire.start(), generation: current)
        receive(socket, generation: current)

        tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeout * 1_000_000_000))
            guard let self, self.generation == current, self.phase == .connecting else { return }
            self.fallback(.error, unreachable: true)
        })
        tasks.append(Task { [weak self] in
            var ticks = 0
            let pingEvery = Int(Self.pingInterval / 0.3)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.generation == current else { return }
                let speaking = self.player.isPlaying
                if self.modelSpeaking != speaking { self.modelSpeaking = speaking }
                ticks += 1
                if ticks % pingEvery == 0 { self.ping(generation: current) }
            }
        })
    }

    // MARK: - Köprü

    private func receive(_ socket: URLSessionWebSocketTask, generation current: Int) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    guard let self, self.generation == current else { return }
                    if let http = socket.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                        // Belirteç geçersiz: klasik yol da aynı nedenle çalışmaz, geri düşmek anlamsız.
                        self.endWithoutFallback(message: JuniorError.unauthorized.localizedDescription)
                        return
                    }
                    // Bağlantı koptu ya da el sıkışma kurulamadı (tünel kapalı, ağ yok).
                    self.fallback(.error, unreachable: self.phase == .connecting)
                    return
                }
                guard let self, self.generation == current else { return }
                let decoded: GeminiServerMessage?
                switch message {
                case .string(let text): decoded = GeminiServerMessage.decode(text)
                case .data(let data): decoded = GeminiServerMessage.decode(data)
                @unknown default: decoded = nil
                }
                if let decoded { self.handle(decoded) }
            }
        })
    }

    private func handle(_ message: GeminiServerMessage) {
        switch message {
        case .ready:
            guard phase == .connecting else { return }
            phase = .live
            detail = "Dinliyorum — konuşabilirsin"
            // "Seni duydum" sesi bilerek çalınmaz: açık mikrofon onu da Gemini'ye gönderirdi.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let waiting = pendingAudio
            pendingAudio = []
            for chunk in waiting { sendAudio(chunk, generation: generation) }
            let typed = pendingText
            pendingText = []
            for text in typed { if let wire = GeminiWire.text(text) { send(wire, generation: generation) } }
        case .audio(let pcm, let rate):
            turns.modelAudio()
            // Telefonda söze girildiyse bu turun kalanı atılır (sunucunun VAD'ı geç kalabilir).
            guard audioGate.audio() else { return }
            player.enqueue(pcm, rate: rate)
            modelSpeaking = true
        case .transcript(let role, let text):
            if role == .user {
                turns.user(text)
                detail = "Sen: " + Self.tail(turns.pendingUserText)
            } else {
                turns.model(text)
                detail = Self.tail(turns.modelText)
            }
        case .interrupted:
            // Kullanıcı sözü kesti: çalan ses hemen susar, söylenmiş kadarı geçmişe yazılır.
            player.stop()
            audioGate.turnEnded()
            write(turns.flush(all: false))
        case .turnComplete:
            audioGate.turnEnded()
            write(turns.flush(all: true))
        case .toolCall(let id, let name):
            turns.modelAudio()
            detail = "“\(name)” telefondaki canlı oturumda yapılamıyor"
            send(GeminiWire.toolResult(id: id, name: name, output: GeminiWire.unavailableToolOutput(name)), generation: generation)
        case .toolCancel:
            break
        case .fallback(let reason, let message):
            fallback(reason, serverMessage: message)
        case .error(let message):
            fallback(.error, serverMessage: message)
        }
    }

    /// Kullanıcı telefonda söze girdi (yankı kapısı). Çalar zaten durdu; aradaki birkaç ms'de
    /// sıraya giren ses de silinir.
    private func localBargeIn(generation current: Int) {
        guard generation == current, phase == .live else { return }
        audioGate.localBargeIn()
        if audioGate.suppressed { player.stop() }
        modelSpeaking = false
    }

    /// Oturum açıkken yazılan mesaj (GeminiComposerRoute): köprüye metin olarak gider. Yazılanın
    /// dökümü gelmez; soru olarak tura burada eklenir (GeminiTurnBuffer.typed), geri düşüşte de
    /// klasik yolda yeniden sorulur.
    func sendText(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isActive else { return }
        turns.typed(clean)
        detail = "Sen: " + Self.tail(turns.pendingUserText)
        if phase == .connecting {
            if pendingText.count < 5 { pendingText.append(clean) }
            return
        }
        if let wire = GeminiWire.text(clean) { send(wire, generation: generation) }
    }

    private func sendAudio(_ chunk: Data, generation current: Int) {
        guard generation == current else { return }
        switch phase {
        case .connecting:
            if pendingAudio.count < Self.maxPendingChunks { pendingAudio.append(chunk) }
        case .live:
            if let text = GeminiWire.audio(chunk) { send(text, generation: current) }
        case .idle:
            break
        }
    }

    private func send(_ text: String, generation current: Int) {
        guard let socket, generation == current else { return }
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.fallback(.error, unreachable: self.phase == .connecting)
            }
        }
    }

    private func ping(generation current: Int) {
        guard let socket, generation == current else { return }
        socket.sendPing { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.fallback(.error)
            }
        }
    }

    /// `finished` ya boştur ya da tam soru + yanıt çiftidir (GeminiTurnBuffer.flush): tek kalan
    /// mesaj klasik isteklerin geçmiş çiftlerini bozmasın.
    private func write(_ finished: [GeminiTurn]) {
        for turn in finished { store.appendLiveTurn(role: turn.role, text: turn.text) }
    }

    // MARK: - Kapanış

    /// Motor kapanır, kullanıcıya tek cümle söylenir, konuşma klasik yolla sürer.
    private func fallback(_ reason: GeminiFallbackReason, serverMessage: String = "", unreachable: Bool = false) {
        guard phase != .idle else { return }
        // Yanıtı yarıda kalan soru ve sonrasında söylenen: klasik yolda yeniden sorulur
        // (geçmişe burada yazılmaz; klasik yol kendi kaydını tutar).
        let pending = turns.pendingUserText
        let socket = self.socket
        self.socket = nil
        teardown()
        socket?.cancel(with: .goingAway, reason: nil)
        block = GeminiFallbackPolicy.block(for: reason, at: Date(), keyHint: statusModel.status?.apiKeyHint ?? "")
        if reason == .auth, statusModel.status == nil {
            // Reddedilen anahtarın maskesi bilinmiyorsa durum okunur: engel ancak anahtar değişince kalksın.
            Task { [weak self] in
                guard let self, let status = await self.statusModel.load(),
                      let current = self.block, current.reason == .auth, current.keyHint.isEmpty else { return }
                self.block = GeminiBlock(reason: .auth, until: current.until, keyHint: status.apiKeyHint)
            }
        }
        let notice = unreachable && reason == .error
            ? "Bilgisayara ulaşılamadığı için Gemini açılamadı, normal sese geçtim."
            : reason.notice
        // Ayarlar'daki kartın "son hata" satırı: köprüye ulaşılamadı, zaman aşımı, tünel koptu gibi
        // durumları sunucu hiç duymaz; sunucunun mesajı varsa (ne yapılacak) o yazılır.
        GeminiPhoneError.save(reason: reason, message: serverMessage.isEmpty ? notice : serverMessage, at: Date())
        store.errorText = notice
        hooks?.releaseMic()
        speech.speak(notice)
        let step = GeminiFallbackPolicy.next(afterFallbackWith: pending)
        let classicHooks = self.hooks
        let voice = self.speech
        Task {
            // Bildirim bitsin (en çok 20 sn), sonra klasik yol; yoksa kendi sesimizi dinlerdik.
            for _ in 0..<80 where voice.state == .speaking {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            classicHooks?.classic(step)
        }
    }

    /// Geri düşmeden kapanış (izin yok, adres/belirteç eksik): klasik yol da aynı nedenle çalışmaz.
    private func endWithoutFallback(message: String) {
        teardown()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        GeminiPhoneError.save(reason: .error, message: message, at: Date())
        store.errorText = message
        hooks?.resumeWake()
        hooks?.releaseMic()
    }

    private func teardown() {
        generation += 1
        phase = .idle
        modelSpeaking = false
        detail = nil
        for task in tasks { task.cancel() }
        tasks = []
        tap?.close()
        tap = nil
        // Gemini kolu hemen çıkar: oturum dışında tek bir örnek bile köprüye gitmez.
        MicrophoneHub.shared.detachGemini()
        player.close()
        pendingAudio = []
        pendingText = []
        turns = GeminiTurnBuffer()
        audioGate = GeminiModelAudioGate()
    }

    private static func tail(_ text: String, limit: Int = 120) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? "…" + String(clean.suffix(limit)) : clean
    }
}
