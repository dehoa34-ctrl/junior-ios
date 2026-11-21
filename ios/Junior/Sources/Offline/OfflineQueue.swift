import Foundation

/// Sunucuya ulaşılamazken yazılan ya da söylenen komut. İlk denemenin `request_id`'siyle
/// gönderilir: ilk deneme sunucuya ulaşmışsa sunucu aynı yanıtı döndürür, eylem ikinci kez yapılmaz.
struct QueuedCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let target: String?
    let requestID: String
    let createdAt: Date
    /// Zamana bağlı ve eskimiş: gönderilmeden kullanıcıya soruldu, yanıt bekliyor.
    var held: Bool
    /// Kullanıcı "yine de gönder" dedi; bir daha sorulmaz.
    var approved: Bool

    init(id: UUID = UUID(), text: String, target: String?, requestID: String = UUID().uuidString,
         createdAt: Date = Date(), held: Bool = false, approved: Bool = false) {
        self.id = id
        self.text = text
        self.target = target
        self.requestID = requestID
        self.createdAt = createdAt
        self.held = held
        self.approved = approved
    }
}

/// Çevrimdışı komut kuyruğu: en çok 50 komut, 24 saat. Bağlantı gelince sırayla gönderilir;
/// zamana bağlı ("şimdi", "hemen", "5 dakika sonra") ve 10 dakikadan eski komut sorulur. Saf mantık.
struct OfflineQueue: Equatable {
    static let maxItems = 50
    static let maxAge: TimeInterval = 24 * 3600
    static let staleAfter: TimeInterval = 10 * 60

    enum Decision: Equatable { case send, ask, drop }

    struct Step: Equatable {
        /// Şimdi gönderilecek komut (kuyruktan çıkarıldı); yoksa nil.
        var next: QueuedCommand?
        /// Bu adımda sorulmak üzere bekletilenler.
        var newlyHeld: [QueuedCommand] = []
        /// 24 saati geçtiği için atılanlar.
        var dropped: [QueuedCommand] = []
    }

    private(set) var items: [QueuedCommand]

    init(items: [QueuedCommand] = []) {
        self.items = items
    }

    var isEmpty: Bool { items.isEmpty }
    /// Sırada gönderilmeyi bekleyen (sorulanlar hariç).
    var waiting: [QueuedCommand] { items.filter { !$0.held } }
    /// Kullanıcıya sorulmuş, yanıt bekleyenler.
    var held: [QueuedCommand] { items.filter(\.held) }

    /// Komutu sıraya ekler (`atFront`: gönderilirken yine düşen komut başa döner). 50'yi aşınca
    /// en eskiler atılır; dönüş atılanlar.
    @discardableResult
    mutating func enqueue(_ item: QueuedCommand, now: Date = Date(), atFront: Bool = false) -> [QueuedCommand] {
        var dropped = prune(now: now)
        items.removeAll { $0.id == item.id }
        if atFront { items.insert(item, at: 0) } else { items.append(item) }
        if items.count > Self.maxItems {
            let overflow = items.count - Self.maxItems
            let oldest = items.sorted { $0.createdAt < $1.createdAt }.prefix(overflow).map(\.id)
            dropped += items.filter { oldest.contains($0.id) }
            items.removeAll { oldest.contains($0.id) }
        }
        return dropped
    }

    /// 24 saati geçenleri atar.
    @discardableResult
    mutating func prune(now: Date = Date()) -> [QueuedCommand] {
        let old = items.filter { now.timeIntervalSince($0.createdAt) >= Self.maxAge }
        if !old.isEmpty { items.removeAll { now.timeIntervalSince($0.createdAt) >= Self.maxAge } }
        return old
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Kullanıcı sorulan komutu yine de göndermek istedi.
    mutating func approve(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].held = false
        items[index].approved = true
    }

    /// Sıradaki adım: eskiyenleri atar, eskimiş zamana bağlı komutları bekletir, ilk
    /// gönderilebilir komutu kuyruktan çıkarıp döndürür.
    mutating func takeNext(now: Date = Date()) -> Step {
        var step = Step(dropped: prune(now: now))
        for index in items.indices where !items[index].held {
            switch Self.decision(for: items[index], now: now) {
            case .drop: continue  // prune zaten attı
            case .ask:
                items[index].held = true
                step.newlyHeld.append(items[index])
            case .send:
                if step.next == nil { step.next = items[index] }
            }
        }
        if let next = step.next { remove(id: next.id) }
        return step
    }

    static func decision(for item: QueuedCommand, now: Date) -> Decision {
        let age = now.timeIntervalSince(item.createdAt)
        if age >= maxAge { return .drop }
        if !item.approved, age >= staleAfter, isTimeSensitive(item.text) { return .ask }
        return .send
    }

    /// "Şimdi", "hemen", "5 dakika sonra" gibi söylendiği ana bağlı ifade var mı.
    static func isTimeSensitive(_ text: String) -> Bool {
        let folded = fold(text)
        // Sözcük sınırı: "şimdilik", "hemencecik değil" gibi uzantılar eşleşmez.
        let words = "simdi|hemen|derhal|birazdan|az sonra|su an|su anda|bu dakika|aninda"
        if folded.range(of: "\\b(?:\(words))\\b", options: .regularExpression) != nil { return true }
        let number = "\\d+|bir|iki|uc|dort|bes|alti|yedi|sekiz|dokuz|on|yirmi|otuz|kirk|elli|yarim|birkac|bucuk"
        let pattern = "\\b(?:\(number))(?:\\s+(?:\(number)))*\\s*(?:saniye|sn|dakika|dk|saat)\\s+(?:sonra|icinde|icerisinde)\\b"
        return folded.range(of: pattern, options: .regularExpression) != nil
    }

    /// Küçük harf, Türkçe karakterler katlanmış (ç→c, ğ→g, ı→i, ö→o, ş→s, ü→u).
    static func fold(_ text: String) -> String {
        let lowered = text.lowercased(with: Locale(identifier: "tr_TR"))
        let map: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u", "â": "a", "î": "i", "û": "u"]
        return String(lowered.map { map[$0] ?? $0 })
    }

    /// Sunucuya ulaşılamayan her denemeden sonra bekleme: 15, 30, 60, 120 sn (en çok 2 dk).
    /// Bağlantı geri gelince (ServerMonitor) beklemeden boşaltılır; bu yalnız yedek zamanlayıcı.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let step = min(max(1, failures), 8) - 1
        return min(120, 15 * pow(2, Double(step)))
    }

    /// "12 dakika önce", "3 saat önce".
    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "az önce" }
        if minutes < 60 { return "\(minutes) dakika önce" }
        return "\(minutes / 60) saat önce"
    }

    /// Eskimiş zamana bağlı komut için kullanıcıya sorulan cümle.
    static func staleQuestion(_ item: QueuedCommand, now: Date = Date()) -> String {
        "\"\(item.text)\" komutunu \(ageText(now.timeIntervalSince(item.createdAt))) vermiştin ama bilgisayara ulaşamamıştım. "
            + "Zamana bağlı olduğu için kendiliğinden göndermedim; şimdi göndereyim mi?"
    }
}

/// Kuyruğun kalıcı dosyası (Application Support/Junior/offline-queue.json).
struct OfflineQueueFile {
    let url: URL

    static var standard: OfflineQueueFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OfflineQueueFile(url: base.appendingPathComponent("Junior", isDirectory: true)
            .appendingPathComponent("offline-queue.json"))
    }

    func load() -> [QueuedCommand] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([QueuedCommand].self, from: data)) ?? []
    }

    func save(_ items: [QueuedCommand]) {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Komut metni kişisel olabilir: cihaz kilitliyken okunmasın, yedeğe gitmesin.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}
