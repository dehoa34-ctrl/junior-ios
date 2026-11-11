import Foundation

/// Sunucunun telefona yaptırdığı iş (`status: "phone_action"`).
///
/// Sözleşme: `{"phone_action": {"name": "...", "arguments": {...}}}`. Bilinmeyen
/// ad ya da bozuk bağımsız değişken `nil` döner; uygulama çökmez, kullanıcıya
/// "bunu yapamıyorum" der. Saf mantık: UIKit/EventKit'e dokunmaz.
enum PhoneAction: Equatable {
    case reminder(title: String, due: Date?)
    case event(title: String, start: Date, end: Date)
    case timer(seconds: Int, label: String?)
    case call(contact: String?, number: String?)
    case message(contact: String?, number: String?, text: String, channel: Channel)
    case openApp(String)
    case torch(on: Bool)
    case appleMusic(MusicCommand, query: String?)
    case spotify(SpotifyCommand, query: String?, level: Int?)

    enum Channel: String, Equatable { case sms, whatsapp }
    enum MusicCommand: String, Equatable { case play, pause, next, previous }
    enum SpotifyCommand: String, Equatable {
        case play, resume, pause, next, previous, volume
        case volumeUp = "volume_up"
        case volumeDown = "volume_down"
    }

    /// Sunucunun `phone_action` nesnesinden çözer.
    static func parse(_ payload: [String: Any]) -> PhoneAction? {
        guard let name = (payload["name"] as? String)?.lowercased() else { return nil }
        let args = payload["arguments"] as? [String: Any] ?? [:]

        func text(_ key: String, max: Int = 400) -> String? {
            guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return String(value.prefix(max))
        }
        func integer(_ key: String) -> Int? {
            if let value = args[key] as? Int { return value }
            if let value = args[key] as? Double { return Int(value) }
            if let value = args[key] as? String { return Int(value) }
            return nil
        }
        func date(_ key: String, epoch epochKey: String) -> Date? {
            if let raw = args[key] as? String, let parsed = PhoneActionDates.parse(raw) { return parsed }
            if let epoch = integer(epochKey), epoch > 0 { return Date(timeIntervalSince1970: TimeInterval(epoch)) }
            return nil
        }

        switch name {
        case "reminder":
            guard let title = text("title", max: 200) else { return nil }
            return .reminder(title: title, due: date("due", epoch: "due_epoch"))
        case "event":
            guard let title = text("title", max: 200), let start = date("start", epoch: "start_epoch") else { return nil }
            var end = date("end", epoch: "end_epoch")
            if end == nil {
                end = start.addingTimeInterval(TimeInterval(max(1, integer("duration_minutes") ?? 60)) * 60)
            }
            guard let finish = end, finish > start else { return nil }
            return .event(title: title, start: start, end: finish)
        case "timer":
            guard let seconds = integer("seconds"), (1...86_400).contains(seconds) else { return nil }
            return .timer(seconds: seconds, label: text("label", max: 80))
        case "call":
            let contact = text("contact", max: 120), number = text("number", max: 40)
            guard contact != nil || number != nil else { return nil }
            return .call(contact: contact, number: number)
        case "message":
            let contact = text("contact", max: 120), number = text("number", max: 40)
            guard contact != nil || number != nil, let body = text("text", max: 2000) else { return nil }
            let channel = Channel(rawValue: (text("channel") ?? "sms").lowercased()) ?? .sms
            return .message(contact: contact, number: number, text: body, channel: channel)
        case "open_app":
            guard let app = text("app", max: 60) else { return nil }
            return .openApp(app)
        case "torch":
            guard let on = args["on"] as? Bool else { return nil }
            return .torch(on: on)
        case "apple_music":
            guard let command = MusicCommand(rawValue: (text("action") ?? "play").lowercased()) else { return nil }
            return .appleMusic(command, query: command == .play ? text("query", max: 200) : nil)
        case "spotify":
            guard let command = SpotifyCommand(rawValue: (text("action") ?? "play").lowercased()) else { return nil }
            return .spotify(command, query: text("query", max: 200), level: integer("level"))
        default:
            return nil
        }
    }

    /// Bu eylem telefonu ön plana getirir mi (bildirim dokunuşu gerekir mi).
    /// Hatırlatıcı, takvim, zamanlayıcı ve müzik denetimi arka planda da çalışır.
    var needsForeground: Bool {
        switch self {
        case .call, .message, .openApp, .torch, .spotify: return true
        case .reminder, .event, .timer, .appleMusic: return false
        }
    }
}

/// Sunucunun zaman damgaları: saat dilimsiz yerel saat ("2026-11-12T09:30:00").
/// Telefon bunu **kendi** yerel saatiyle yorumlar; `+03:00`/`Z` varsa onu da anlar.
enum PhoneActionDates {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") || text.range(of: "[+-]\\d{2}:?\\d{2}$", options: .regularExpression) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Rehberde isim eşleme ve telefon numarası düzeni. Saf mantık.
enum ContactMatching {
    struct Entry: Equatable {
        let name: String
        let nickname: String
        /// (etiket, numara); etiket "mobile", "iPhone", "home" …
        let numbers: [(label: String, number: String)]

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.name == rhs.name && lhs.nickname == rhs.nickname
                && lhs.numbers.map(\.number) == rhs.numbers.map(\.number)
        }
    }

    /// Türkçe harfleri sadeleştirip küçültür ("Şükrü" → "sukru").
    static func fold(_ text: String) -> String {
        let map: [Character: Character] = ["ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g",
                                           "ü": "u", "Ü": "u", "ö": "o", "Ö": "o", "ç": "c", "Ç": "c"]
        let mapped = String(text.map { map[$0] ?? $0 })
        return mapped.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
    }

    /// "Ali'yi", "annemi", "Ayşe Hanım'ı" gibi çekimli söylenişten rehberdeki kaydı bulur.
    ///
    /// Sırayla: tam ad/takma ad eşitliği, ad önekle başlıyor, ad sorguyu içeriyor,
    /// son olarak sorgunun ekleri kırpılıp (≥3 harf) bir ad sözcüğünün başına uyması.
    /// Birden çok aday eşit iyiyse `.ambiguous`: yanlış kişiyi aramaktansa sormak yeğdir.
    enum Match: Equatable {
        case found(Entry)
        case ambiguous([Entry])
        case none
    }

    static func best(for query: String, in entries: [Entry]) -> Entry? {
        if case .found(let entry) = match(for: query, in: entries) { return entry }
        return nil
    }

    static func match(for query: String, in entries: [Entry]) -> Match {
        let raw = fold(query)
        // Kesme işaretinden sonrası ektir: "ali'yi" → "ali".
        let base = raw.split(whereSeparator: { "'’`".contains($0) }).first.map(String.init) ?? raw
        let wanted = base.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return .none }

        func words(_ entry: Entry) -> [String] {
            (fold(entry.name) + " " + fold(entry.nickname))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let tiers: [(Entry) -> Bool] = [
            { fold($0.name) == wanted || (!$0.nickname.isEmpty && fold($0.nickname) == wanted) },
            { words($0).contains(wanted) },
            { fold($0.name).hasPrefix(wanted) },
            { fold($0.name).contains(wanted) },
            { entry in
                guard wanted.count > 3 else { return false }
                // Ekleri kırp: "annemi" → "annem", "anne".
                for cut in 1...min(3, wanted.count - 3) {
                    let stem = String(wanted.dropLast(cut))
                    if words(entry).contains(stem) { return true }
                }
                return false
            },
        ]
        for tier in tiers {
            let hits = entries.filter(tier)
            if hits.count == 1 { return .found(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits) }
        }
        return .none
    }

    /// Önce cep/iPhone etiketli numara, yoksa ilki.
    static func preferredNumber(_ entry: Entry) -> String? {
        let mobile = entry.numbers.first { label in
            let folded = fold(label.label)
            return folded.contains("mobile") || folded.contains("iphone") || folded.contains("cep")
        }
        return (mobile ?? entry.numbers.first)?.number
    }

    /// Aranabilir numara: boşluk/tire/parantez atılır, baştaki + korunur.
    static func dialable(_ number: String) -> String {
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let digits = number.filter(\.isNumber)
        return (plus ? "+" : "") + digits
    }

    /// WhatsApp/wa.me için uluslararası rakamlar (baştaki + ve 00 yok): "0532 123 45 67" → "905321234567".
    static func international(_ number: String) -> String {
        var digits = number.filter(\.isNumber)
        if digits.hasPrefix("00") { digits.removeFirst(2); return digits }
        if number.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return digits }
        if digits.hasPrefix("0"), digits.count == 11 { return "90" + digits.dropFirst() }
        if digits.hasPrefix("5"), digits.count == 10 { return "90" + digits }
        return digits
    }
}

/// "open_app" adını URL şemasına eşler (küçük harf, Türkçe söylenmiş ad).
enum PhoneAppCatalog {
    struct App: Equatable {
        let display: String
        let url: String
    }

    private static let table: [String: App] = {
        var map: [String: App] = [:]
        func add(_ names: [String], _ display: String, _ url: String) {
            for name in names { map[ContactMatching.fold(name)] = App(display: display, url: url) }
        }
        add(["spotify"], "Spotify", "spotify://")
        add(["whatsapp", "vatsap", "whats app"], "WhatsApp", "whatsapp://")
        add(["harita", "haritalar", "maps", "apple haritalar"], "Haritalar", "maps://")
        add(["youtube", "yutup"], "YouTube", "youtube://")
        add(["instagram", "insta"], "Instagram", "instagram://")
        add(["telegram"], "Telegram", "tg://")
        add(["twitter", "x"], "X", "twitter://")
        add(["mail", "eposta", "e-posta", "posta"], "Mail", "message://")
        add(["mesajlar", "mesaj", "sms"], "Mesajlar", "sms:")
        add(["telefon", "ara"], "Telefon", "tel:")
        add(["muzik", "apple muzik"], "Müzik", "music://")
        add(["fotograflar", "galeri", "foto"], "Fotoğraflar", "photos-redirect://")
        add(["takvim"], "Takvim", "calshow://")
        add(["hatirlaticilar", "hatirlatici"], "Hatırlatıcılar", "x-apple-reminderkit://")
        add(["notlar", "not defteri"], "Notlar", "mobilenotes://")
        add(["safari", "tarayici"], "Safari", "https://www.apple.com")
        add(["ayarlar"], "Ayarlar", "app-settings:")
        return map
    }()

    static func lookup(_ name: String) -> App? {
        let key = ContactMatching.fold(name).trimmingCharacters(in: .whitespaces)
        if let app = table[key] { return app }
        // "spotify'ı", "whatsapp'ı" gibi çekimler.
        let stem = key.split(whereSeparator: { "'’".contains($0) }).first.map(String.init) ?? key
        return table[stem]
    }
}

/// Bildirimde taşınacak eylemin ham hali (dokununca yeniden çözülür).
enum PhoneActionPayload {
    static func encode(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
