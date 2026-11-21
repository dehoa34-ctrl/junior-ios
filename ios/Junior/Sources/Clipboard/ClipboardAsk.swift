import Foundation
import UIKit

/// "Panodakini sor": panodaki bağlantı ya da metin için öneriler. Saf mantık.
///
/// Pano yalnız kullanıcı düğmeye basınca okunur (iOS yapıştırma iznini o an sorar);
/// arka planda ya da açılışta pano okunmaz.
enum ClipboardAsk {
    struct Option: Identifiable, Equatable {
        var id: String { title }
        let title: String
        /// Junior'a gönderilecek mesaj.
        let prompt: String
        /// Düzelt: sohbete yazılmaz, sonuç ayrı sayfada gösterilir ve kopyalanır (ClipboardFix).
        var fix = false
    }

    /// Mesaja konacak pano metninin en uzun hâli (sunucu sınırı 4000; ön söz için pay bırakılır).
    static let maxClipChars = JuniorLimits.maxMessageChars - 200

    /// Tek bir http(s) adresinden oluşuyorsa o adres.
    static func link(in raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Türkçeye özgü harf varsa metin Türkçe sayılır (çeviri yönü için kaba ama yeterli).
    static func looksTurkish(_ text: String) -> Bool {
        text.contains { "çğıöşüÇĞİÖŞÜ".contains($0) }
    }

    static func options(for raw: String) -> [Option] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let url = link(in: trimmed) {
            var options = [Option(title: "Özetle", prompt: "Şu bağlantıyı Türkçe ve kısaca özetle: \(url.absoluteString)")]
            if VideoLink.isVideo(url) {
                options.append(Option(title: "Ne anlatıyor?", prompt: "Şu videoda ne anlatılıyor, kısaca söyle: \(url.absoluteString)"))
            }
            return options
        }
        let clip = String(trimmed.prefix(maxClipChars))
        let translate = looksTurkish(clip)
            ? Option(title: "İngilizceye çevir", prompt: "Şunu İngilizceye çevir:\n\n\(clip)")
            : Option(title: "Türkçeye çevir", prompt: "Şunu Türkçeye çevir:\n\n\(clip)")
        return [
            Option(title: "Açıkla", prompt: "Şunu kısaca açıkla:\n\n\(clip)"),
            translate,
            Option(title: "Düzelt", prompt: ClipboardFix.prompt(for: clip), fix: true),
        ]
    }

    /// Panoyu **şimdi** okur (kullanıcı düğmeye bastı). Bağlantı öncelikli; boşsa nil.
    @MainActor
    static func readNow() -> String? {
        let board = UIPasteboard.general
        guard board.hasStrings || board.hasURLs else { return nil }
        if let url = board.url { return url.absoluteString }
        return board.string
    }
}
