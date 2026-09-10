import Foundation

/// Konuşmayı cihazda saklar. Sunucu geçmişi tutmuyor; uygulama kapanınca
/// sohbet de kayboluyordu.
///
/// Yalnız bu cihazda kalır: buluta gitmez, yedeğe alınmaz. Sunucuya ancak
/// bir sonraki istekte `history` alanıyla, tamamlanmış çiftler halinde gider.
struct ConversationArchive {
    /// Sunucu en çok 12 ileti kabul ediyor; birkaç tur fazlasını tutmak
    /// ekranda süreklilik hissi verir, gönderim sırasında zaten kırpılır.
    static let maxStored = 40

    private let url: URL

    init(fileName: String = "conversation.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(fileName)
    }

    func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return Array(messages.suffix(Self.maxStored))
    }

    func save(_ messages: [ChatMessage]) {
        let trimmed = Array(messages.suffix(Self.maxStored))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        // Yedeğe alınmasın ve cihaz kilitliyken okunmasın.
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(resource)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
