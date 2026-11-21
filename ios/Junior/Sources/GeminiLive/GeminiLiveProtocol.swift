import Foundation

// Gemini Live'ın iPhone tarafının saf parçaları (ağ ve ses yok, XCTest'te denenir).
//
// Telefon Google'a doğrudan bağlanmaz: bilgisayardaki Junior sunucusunun köprüsüne
// (GET /v1/live/gemini/ws, tünelden belirteçle) bağlanır. Anahtar ve günlük dakika defteri
// sunucuda durur; telefona hiçbir zaman anahtar gelmez. İleti biçimi
// mobile_api/gemini_live.py başındaki açıklamadadır; masaüstü karşılığı
// desktop/src/main/geminiLive.ts ve renderer/src/audio/geminiClient.ts.

/// Ayarlar > Ses motoru. UserDefaults'ta ham değerle durur (masaüstündeki voice.engine ile aynı adlar).
enum VoiceEngine: String, CaseIterable, Identifiable {
    case classic
    case geminiLive = "gemini_live"

    static let storageKey = "junior.voiceEngine"

    var id: String { rawValue }
    var title: String { self == .classic ? "Klasik" : "Gemini Live" }
}

/// Köprünün "fallback" nedenleri; bağlantı hatası, zaman aşımı ve ret de `.error` sayılır.
enum GeminiFallbackReason: String, Equatable {
    case noKey = "no_key"
    case auth
    case quota
    case cap
    case error

    init(wire: String?) {
        self = wire.flatMap(GeminiFallbackReason.init(rawValue:)) ?? .error
    }

    /// Geri düşüşte sesli söylenen tek cümle: ne oldu, ne yapılacak. Bilerek "Junior"
    /// kelimesi geçmez; uyandırma dinlemesi kendi sesini duyup kendini tetiklemesin.
    var notice: String {
        switch self {
        case .cap:
            return "Gemini'nin bugünkü süre sınırı doldu, normal sese geçtim; sınırı bilgisayardaki Ayarlar > Ses bölümünden yükseltebilirsin."
        case .quota:
            return "Gemini kotası doldu, normal sese geçtim; birkaç dakika sonra yeniden dene."
        case .auth:
            return "Gemini anahtarı reddedildi, normal sese geçtim; bilgisayardaki Ayarlar > Ses bölümünden anahtarı yenile."
        case .noKey:
            return "Gemini anahtarı ayarlanmamış, normal sese geçtim; bilgisayardaki Ayarlar > Ses bölümünden anahtarı gir."
        case .error:
            return "Gemini bağlantısı kurulamadı ya da koptu, normal sese geçtim."
        }
    }
}

enum GeminiRole: String, Equatable {
    case user
    case model
}

/// Köprüden gelen bir ileti.
enum GeminiServerMessage: Equatable {
    case ready
    /// Mono PCM16 (little-endian), `rate` Hz; köprü 24000 gönderir.
    case audio(Data, rate: Int)
    case transcript(role: GeminiRole, text: String)
    case turnComplete
    /// Kullanıcı modelin sözünü kesti (sunucu tarafı VAD): çalan ses hemen susmalı.
    case interrupted
    case toolCall(id: String, name: String)
    case toolCancel([String])
    case fallback(GeminiFallbackReason, message: String)
    /// Köprü ilk iletiyi reddetti (sürüm uyumsuzluğu vb.).
    case error(String)

    static func decode(_ text: String) -> GeminiServerMessage? {
        decode(Data(text.utf8))
    }

    static func decode(_ data: Data) -> GeminiServerMessage? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = raw["type"] as? String else { return nil }
        let text = raw["text"] as? String ?? ""
        switch type {
        case "ready":
            return .ready
        case "audio":
            guard let encoded = raw["data"] as? String, !encoded.isEmpty,
                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty else { return nil }
            let rate = (raw["rate"] as? NSNumber)?.intValue ?? 24_000
            return .audio(pcm, rate: (8_000...48_000).contains(rate) ? rate : 24_000)
        case "transcript":
            guard !text.isEmpty, let role = (raw["role"] as? String).flatMap(GeminiRole.init(rawValue:)) else { return nil }
            return .transcript(role: role, text: text)
        case "turn_complete":
            return .turnComplete
        case "interrupted":
            return .interrupted
        case "tool_call":
            guard let id = raw["id"] as? String, !id.isEmpty,
                  let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return .toolCall(id: id, name: name)
        case "tool_cancel":
            return .toolCancel((raw["ids"] as? [Any])?.compactMap { $0 as? String } ?? [])
        case "fallback":
            return .fallback(GeminiFallbackReason(wire: raw["reason"] as? String), message: raw["message"] as? String ?? "")
        case "error":
            let message = raw["message"] as? String ?? ""
            return .error(message.isEmpty ? "Köprü isteği reddetti." : message)
        default:
            return nil
        }
    }
}

/// Telefondan köprüye giden iletiler (JSON metin çerçeveleri).
enum GeminiWire {
    /// Telefon araç bildirmez: telefonda canlı oturumda iş yapılmaz, model bunu bilsin ve uydurmasın.
    static let phoneSystem = "Kullanıcıyla iPhone'dan sesli konuşuyorsun. Bu oturumda hiçbir aracın yok: "
        + "bilgisayarda ya da telefonda bir iş (müzik, hatırlatıcı, mesaj, dosya, arama) istenirse yapamadığını "
        + "açıkça söyle ve Gemini kapalıyken normal sesli modda ya da yazarak isteyebileceğini belirt; "
        + "yaptım deme."
    /// Köprünün tek ses iletisi sınırı 256 KiB base64; 100 ms'lik parça (3200 bayt) çok altında.
    static let maxAudioBytes = 64 * 1024
    static let maxTextChars = 4_000

    static func start(system: String = GeminiWire.phoneSystem) -> String {
        encode(["type": "start", "tools": [Any](), "system": system, "client": "phone"])
    }

    /// 16 kHz mono PCM16 parça. Boşsa ya da sınırı aşıyorsa nil (köprü zaten atardı).
    static func audio(_ pcm: Data) -> String? {
        guard !pcm.isEmpty, pcm.count <= maxAudioBytes else { return nil }
        return encode(["type": "audio", "data": pcm.base64EncodedString()])
    }

    static func text(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return encode(["type": "text", "text": String(clean.prefix(maxTextChars))])
    }

    static func toolResult(id: String, name: String, output: String) -> String {
        encode(["type": "tool_result", "id": id, "name": name, "output": output])
    }

    /// Telefonda yürütülmeyen araç çağrısına giden yanıt: model kullanıcıya dürüstçe söylesin.
    static func unavailableToolOutput(_ name: String) -> String {
        "[failed] \"\(name)\" aracı telefondaki sesli oturumda yok; hiçbir şey yapılmadı. "
            + "Kullanıcıya bunu normal sesli modda ya da yazarak istemesini söyle."
    }

    static let end = encode(["type": "end"])

    /// https://host → wss://host/v1/live/gemini/ws (http → ws). Bozuk adreste nil.
    static func bridgeURL(from httpURL: URL?) -> URL? {
        guard let httpURL, var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        return components.url
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - PCM

enum PCM16 {
    /// Köprüye giden sesin biçimi: 16 kHz, tek kanal, 16 bit little-endian.
    static let inputRate = 16_000
    /// 100 ms'lik parça: gecikme düşük kalsın (masaüstündeki GEMINI_BATCH ile aynı).
    static let chunkBytes = 3_200

    /// Little-endian Int16 örnekleri.
    static func samples(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out: [Int16] = []
        out.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            out.append(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)))
            index += 2
        }
        return out
    }

    /// -1…1 aralığında kayan noktalı örnekler (çalar bunları kullanır).
    static func floats(_ data: Data) -> [Float] {
        samples(data).map { Float($0) / 32_768 }
    }

    /// Örneklerin -1…1 ölçeğinde kök ortalama karesi (ses düzeyi).
    static func rms(_ data: Data) -> Double {
        let values = samples(data)
        guard !values.isEmpty else { return 0 }
        var sum = 0.0
        for value in values {
            let x = Double(value) / 32_768
            sum += x * x
        }
        return (sum / Double(values.count)).squareRoot()
    }

    /// Int16 örnekleri little-endian baytlara çevirir (testte ve sessizlik üretmede).
    static func data(_ samples: [Int16]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            out.append(UInt8(bits & 0xff))
            out.append(UInt8(bits >> 8))
        }
        return out
    }
}

/// Gelen baytları sabit boylu parçalara böler; artan kısım bir sonraki çağrıya kalır.
struct PCMChunker {
    let size: Int
    private var buffer = Data()

    init(size: Int = PCM16.chunkBytes) {
        self.size = max(2, size)
    }

    var pendingBytes: Int { buffer.count }

    mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while buffer.count >= size {
            out.append(Data(buffer.prefix(size)))
            buffer = Data(buffer.dropFirst(size))
        }
        return out
    }

    mutating func reset() {
        buffer = Data()
    }
}

/// Junior konuşurken mikrofonun ne yapacağı.
///
/// iPhone'da yankı giderme yok: ses oturumunun kipi MicrophoneHub'ın kuralı gereği değiştirilmez
/// (.playAndRecord + .spokenAudio). Çalma sırasında mikrofon sesi köprüye gitseydi Gemini
/// hoparlörden gelen kendi sesini duyup kendi sözünü keserdi. Bu yüzden çalarken parçalar
/// bekletilir; ardışık birkaç parça yüksek sesli konuşma olursa kullanıcı söze giriyor
/// sayılır (barge-in): çalma durur ve bekletilen son parçalar da gönderilir ki ilk heceler kaybolmasın.
struct BargeInGate {
    /// Bu düzeyin (RMS, -1…1) üstündeki parça "yüksek sesli konuşma" sayılır.
    static let threshold = 0.06
    /// Bu kadar ardışık yüksek parça (≈300 ms) söze girmek sayılır.
    static let needed = 3
    /// Söze girince gönderilecek en çok bekletilmiş parça (≈500 ms).
    static let keep = 5

    enum Decision: Equatable {
        case send([Data])
        case hold
        case bargeIn([Data])
    }

    private(set) var held: [Data] = []
    private var loud = 0

    mutating func decide(_ chunk: Data, rms: Double, playing: Bool) -> Decision {
        guard playing else {
            // Çalma bitti: bekletilenler yankıydı, atılır.
            held.removeAll()
            loud = 0
            return .send([chunk])
        }
        held.append(chunk)
        if held.count > Self.keep { held.removeFirst(held.count - Self.keep) }
        loud = rms >= Self.threshold ? loud + 1 : 0
        guard loud >= Self.needed else { return .hold }
        let out = held
        held.removeAll()
        loud = 0
        return .bargeIn(out)
    }
}

/// Köprüden gelen model sesi çalınsın mı.
///
/// Telefonda söze girildiğinde (BargeInGate) çalma hemen durur, ama köprü sunucunun VAD'ı
/// kesintiyi anlayana dek yanıtın kalanını göndermeyi sürdürür. O ses çalınsaydı yanıt
/// kaldığı yerden devam eder, yankı kapısı da kullanıcının sesini yeniden bekletirdi. Bu yüzden
/// yerel söze girişten sonra o turun sesi "interrupted" ya da "turn_complete" gelene kadar atılır.
/// Tur zaten bitmişse (yalnız sıradaki ses çalıyordu) bir şey atılmaz: yeni sorunun yanıtı çalmalı.
struct GeminiModelAudioGate {
    /// Modelin sesi geliyor ve tur henüz bitmedi.
    private(set) var turnOpen = false
    /// Yerel söze girişten sonra bu turun sesi atılıyor.
    private(set) var suppressed = false

    /// Ses geldi: çalınacaksa true.
    mutating func audio() -> Bool {
        guard !suppressed else { return false }
        turnOpen = true
        return true
    }

    /// Kullanıcı telefonda söze girdi.
    mutating func localBargeIn() {
        suppressed = turnOpen
    }

    /// Köprü "interrupted" ya da "turn_complete" dedi: sonraki ses yeni turundur.
    mutating func turnEnded() {
        turnOpen = false
        suppressed = false
    }
}

/// Gemini Live oturumu açıkken yazı kutusundan gönderilen nereye gider.
///
/// Klasik yola gitseydi yanıtı SpeechService Gemini'nin sesiyle aynı anda okurdu: açık
/// mikrofon o okumayı Gemini'ye taşır (yankı kapısı yalnız Gemini çalarını bilir), tur sonu da
/// "Hey Junior" dinlemesini oturum sürerken yeniden açardı. Bu yüzden düz metin köprüye
/// {"type":"text"} olarak gider; canlı oturumda yapılamayan (video kurgusu, gözlükten kare
/// isteyen soru) için oturum kapanır, istek klasik yoldan sürer.
enum GeminiComposerRoute: Equatable {
    /// Oturum yok: her zamanki klasik gönderim.
    case classic
    /// Metin canlı oturuma gider.
    case gemini(String)
    /// Önce oturum kapanır, sonra klasik gönderim.
    case endSessionThenClassic
    /// Boş gönderim: oturum boşuna kapanmasın.
    case ignore

    static func decide(sessionActive: Bool, text: String, hasVideo: Bool) -> GeminiComposerRoute {
        guard sessionActive else { return .classic }
        if hasVideo { return .endSessionThenClassic }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .ignore }
        if VisionIntent.needsPhoto(clean) { return .endSessionThenClassic }
        return .gemini(clean)
    }
}

// MARK: - Konuşma turları

/// Sohbet geçmişine yazılacak bir tur.
struct GeminiTurn: Equatable {
    let role: ChatMessage.Role
    let text: String
}

/// Dökümleri turlara toplar (masaüstündeki GeminiLiveEngine.markModel/flushTurn ile aynı kural).
///
/// Dökümler model çıktısından bağımsız ve sırasız gelir: model konuşmaya başladığı ana kadar
/// söylenen, yanıtlanan sorudur; sonrasında gelen kullanıcı dökümü kesinti olmadıysa aynı
/// sorunun geç kalan parçası, kesinti olduysa yeni sorudur.
struct GeminiTurnBuffer {
    private(set) var userText = ""
    private(set) var askedText = ""
    private(set) var modelText = ""
    /// Model bu turda konuşmaya başladıktan sonra yazılan: yeni sorudur, sonraki turu bekler.
    private(set) var nextText = ""
    private var modelStarted = false

    mutating func user(_ text: String) {
        userText += text
    }

    /// Oturum sürerken yazı kutusundan gönderilen (dökümü gelmez). Model yanıtlamaya başlamadıysa
    /// bu turun sorusuna eklenir; başladıysa bu turun sorusuna karışmaz, sonraki turun sorusu olur.
    mutating func typed(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if modelStarted {
            nextText = Self.join(nextText, clean)
        } else {
            userText = Self.join(userText, clean)
        }
    }

    mutating func model(_ text: String) {
        markModel()
        modelText += text
    }

    /// Modelin sesi geldi (döküm henüz gelmemiş olabilir).
    mutating func modelAudio() {
        markModel()
    }

    private mutating func markModel() {
        guard !modelStarted else { return }
        modelStarted = true
        askedText = Self.join(askedText, userText)
        userText = ""
    }

    /// Soru dökümü hiç gelmeden yanıt geldiyse sorunun yerine yazılan.
    static let unheardQuestion = "(Sesli soru yazıya dökülemedi)"
    /// Model sesle yanıtladı ama yanıtın dökümü gelmediyse yanıtın yerine yazılan.
    static let unheardAnswer = "(Sesli yanıt yazıya dökülemedi)"

    /// Biten turu döndürür. `all`: tur tamamlandı (sonradan gelen kullanıcı dökümü de bu turun
    /// sorusu); `false`: söz kesildi (sonradan söylenen yeni sorudur, bekler).
    ///
    /// Dönüş ya boştur ya da tam bir soru + yanıt çiftidir. Sohbet geçmişine tek kalan mesaj
    /// yazılmaz: sunucuya giden geçmiş (JuniorClient.completedPairs) kullanıcı/Junior çiftlerinden
    /// oluşur; klasik yol da yanıtsız kalan soruyu geçmişten geri alır.
    mutating func flush(all: Bool) -> [GeminiTurn] {
        let asked = (all ? Self.join(askedText, userText) : askedText).trimmingCharacters(in: .whitespacesAndNewlines)
        let said = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty, !all {
            // Söz, yanıtın dökümü gelmeden kesildi: soru kaybolmaz, kesintiden sonra söylenenle
            // birleşip bir sonraki turun sorusu olur.
            modelStarted = false
            userText = Self.join(userText, nextText)
            nextText = ""
            return []
        }
        let answered = modelStarted
        askedText = ""
        modelText = ""
        modelStarted = false
        // Yanıt sırasında yazılan, sonraki turun sorusu olarak kalır.
        userText = all ? nextText : Self.join(userText, nextText)
        nextText = ""
        if said.isEmpty {
            // Model yalnız sesle yanıtladıysa yer tutucuyla yazılır; hiç yanıt yoksa (model
            // başlamadan Bitir) yanıtsız soru yazılmaz.
            guard answered, !asked.isEmpty else { return [] }
            return [GeminiTurn(role: .user, text: asked), GeminiTurn(role: .assistant, text: Self.unheardAnswer)]
        }
        return [GeminiTurn(role: .user, text: asked.isEmpty ? Self.unheardQuestion : asked),
                GeminiTurn(role: .assistant, text: said)]
    }

    /// Geri düşüşte normal hatta yeniden sorulacak, henüz yanıtı tamamlanmamış söz.
    var pendingUserText: String {
        Self.join(Self.join(askedText, userText), nextText)
    }

    private static func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Geri düşüş kararları

/// Geri düşüşten sonra Gemini ne zamana kadar denenmez.
struct GeminiBlock: Equatable {
    let reason: GeminiFallbackReason
    let until: Date
    /// Engel konduğu andaki anahtar maskesi ("…abcd"): reddedilen anahtar değişince engel kalkar.
    let keyHint: String
}

/// masaüstündeki geminiClient.ts (blockedUntil) + geminiRecovery.ts mantığının telefondaki eşdeğeri.
enum GeminiFallbackPolicy {
    /// Geçici hatadan (kota, bağlantı) sonra bu süre normal ses kullanılır, sonra yine denenir.
    static let retryAfter: TimeInterval = 5 * 60

    enum Route: Equatable {
        case gemini
        case classic
    }

    /// Geri düşüldükten sonra normal hatta ne yapılacak.
    enum ClassicStep: Equatable {
        /// Yanıtlanmamış son söz normal hatta (STT → sağlayıcı → TTS) sorulur.
        case send(String)
        /// Söz yoksa normal dinleme açılır: kullanıcı konuşmaya devam edebilsin.
        case listen
    }

    /// Anahtar yok / reddedildi / günlük sınır: ayar düzelene kadar; kota ve bağlantı: 5 dk.
    static func block(for reason: GeminiFallbackReason, at now: Date, keyHint: String = "") -> GeminiBlock {
        let until: Date
        switch reason {
        case .quota, .error: until = now.addingTimeInterval(retryAfter)
        case .noKey, .auth, .cap: until = .distantFuture
        }
        return GeminiBlock(reason: reason, until: until, keyHint: keyHint)
    }

    static func isBlocked(_ block: GeminiBlock?, now: Date) -> Bool {
        guard let block else { return false }
        return now < block.until
    }

    /// Konuş düğmesi Gemini'yi mi açar, klasik dinlemeyi mi.
    static func route(engine: VoiceEngine, block: GeminiBlock?, now: Date) -> Route {
        guard engine == .geminiLive, !isBlocked(block, now: now) else { return .classic }
        return .gemini
    }

    /// Sunucunun durum ucundan gelen yeni bilgi engeli kaldırır mı (sorun bilgisayarda çözüldü).
    static func clears(_ block: GeminiBlock, with status: GeminiStatus) -> Bool {
        switch block.reason {
        case .noKey: return status.configured
        case .cap: return status.configured && status.remainingMinutes > 0
        case .auth: return status.configured && status.apiKeyHint != block.keyHint
        case .quota, .error: return false
        }
    }

    static func next(afterFallbackWith lastUserText: String) -> ClassicStep {
        let text = lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .listen : .send(text)
    }
}
