import AVFoundation
import Combine
import Foundation
import SwiftUI
import WebKit

/// Telefondaki oynatıcıya sesle verilen komut (JKA-İG-194): "30 saniye ileri", "1:20'ye git",
/// "duraklat", "sesi kıs". Saf mantık: sabit sözlük, eylem modelden doğmaz.
///
/// Oynatıcı açıkken bu cümleler sunucuya gitmez, telefonda yerelde yapılır (ConversationStore).
/// Sunucu da "telefonda 30 saniye ileri" için aynı komutu `video_control` telefon eylemiyle verir.
enum VideoVoiceCommand: Equatable {
    /// Göreli sarma (saniye; geri eksi).
    case seek(Double)
    /// Videonun şu saniyesine git.
    case seekTo(Double)
    case pause
    case play
    case volumeDown
    case volumeUp
    case mute
    case unmute
    case close

    /// Türkçe karakterleri katlar, küçültür, baştaki "Junior", "telefonda", "lütfen" sözlerini atar.
    static func fold(_ raw: String) -> String {
        let map: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u", "’": "'"]
        let lowered = raw.replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "I", with: "ı").lowercased()
        var text = String(lowered.map { map[$0] ?? $0 })
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        let prefixes = ["hey junior ", "hey junior, ", "junior, ", "junior ", "telefonda ", "telefonumda ", "lutfen ", "hadi "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        if text.hasSuffix(" lutfen") { text = String(text.dropLast(" lutfen".count)) }
        return text
    }

    private static let exact: [String: VideoVoiceCommand] = [
        "duraklat": .pause, "durdur": .pause, "dur": .pause, "videoyu duraklat": .pause, "videoyu durdur": .pause,
        "bekle": .pause,
        "devam et": .play, "devam": .play, "oynat": .play, "videoyu oynat": .play, "videoyu devam ettir": .play,
        "devam ettir": .play, "baslat": .play,
        "sesi kis": .volumeDown, "sesi azalt": .volumeDown, "sesi dusur": .volumeDown, "sesi biraz kis": .volumeDown,
        "videonun sesini kis": .volumeDown, "videonun sesini azalt": .volumeDown,
        "sesi ac": .volumeUp, "sesi artir": .volumeUp, "sesi yukselt": .volumeUp, "sesi biraz ac": .volumeUp,
        "videonun sesini ac": .volumeUp, "videonun sesini artir": .volumeUp,
        "sessize al": .mute, "sesi kapat": .mute, "sustur": .mute, "videoyu sessize al": .mute, "sesi kes": .mute,
        "videoyu sesli yap": .unmute,
        "videoyu kapat": .close, "oynaticiyi kapat": .close,
    ]

    private static let words: [String: Double] = [
        "bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9,
        "on": 10, "on bes": 15, "onbes": 15, "yirmi": 20, "otuz": 30, "kirk": 40, "kirk bes": 45,
        "elli": 50, "altmis": 60, "doksan": 90,
    ]
    private static let number = #"(\d{1,4}|on bes|onbes|kirk bes|bir|iki|uc|dort|bes|alti|yedi|sekiz|dokuz|on|yirmi|otuz|kirk|elli|altmis|doksan)"#
    private static let onVideo = #"(?:(?:videoyu|videoda|videonun) )?"#

    static func parse(_ raw: String) -> VideoVoiceCommand? {
        let text = fold(raw)
        guard !text.isEmpty, text.count <= 80 else { return nil }
        if let command = exact[text] { return command }
        // "30 saniye ileri", "on saniye geri al", "2 dakika ileri sar"
        if let groups = match(onVideo + number + #" ?(saniye|sn|dakika|dk) (ileri|geri)(?: (?:sar|al|git|gec|atla))?"#, text),
           let amount = value(groups[0]), amount > 0 {
            let seconds = amount * (groups[1].hasPrefix("d") ? 60 : 1)
            return .seek(groups[2] == "ileri" ? seconds : -seconds)
        }
        // "1:20'ye git", "1.20'ye al"
        if let groups = match(onVideo + #"(\d{1,3})[:.]([0-5]\d)(?:'?y?[ae])? (?:git|gec|atla|sar|al|getir|don)"#, text),
           let minutes = Double(groups[0]), let seconds = Double(groups[1]) {
            return .seekTo(minutes * 60 + seconds)
        }
        // "1 dakika 20 saniyeye git", "2 dakikaya git", "30 saniyeye git"
        if let groups = match(onVideo + "(?:" + number + #" ?(?:dakika|dk) ?)?(?:"# + number + #" ?(?:saniye|sn))?'?y?[ae] (?:git|gec|atla|don)"#, text),
           !(groups[0].isEmpty && groups[1].isEmpty) {
            let minutes: Double? = groups[0].isEmpty ? 0 : value(groups[0])
            let seconds: Double? = groups[1].isEmpty ? 0 : value(groups[1])
            if let minutes, let seconds { return .seekTo(minutes * 60 + seconds) }
        }
        return nil
    }

    /// Sunucunun `video_control` eyleminden (`{"action": "seek", "seconds": 30}`).
    static func fromServer(action: String, seconds: Double?) -> VideoVoiceCommand? {
        switch action {
        case "seek":
            guard let seconds, seconds != 0, seconds.isFinite else { return nil }
            return .seek(seconds)
        case "seek_to":
            guard let seconds, seconds >= 0, seconds.isFinite else { return nil }
            return .seekTo(seconds)
        case "pause": return .pause
        case "play": return .play
        case "volume_down": return .volumeDown
        case "volume_up": return .volumeUp
        case "mute": return .mute
        case "unmute": return .unmute
        default: return nil
        }
    }

    private static func value(_ raw: String) -> Double? {
        if let number = Double(raw) { return number }
        return words[raw]
    }

    /// Tam eşleşmenin yakalanan grupları (eşleşmeyen grup boş metin).
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            guard let groupRange = Range(found.range(at: index), in: text) else { return "" }
            return String(text[groupRange])
        }
    }
}

/// Sarma ve süre metni. Saf mantık.
enum VideoSeekMath {
    /// Göreli sarmanın hedefi: 0'ın altına ve (biliniyorsa) sonun yarım saniye öncesinin ötesine geçmez.
    static func target(current: Double, delta: Double, duration: Double?) -> Double {
        let now = current.isFinite ? current : 0
        var value = max(0, now + delta)
        if let duration, duration.isFinite, duration > 0 { value = min(value, max(0, duration - 0.5)) }
        return value
    }

    /// 80 → "1:20", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// Yerel akış çözülemeyince (ör. bilgisayarda yt-dlp yok) gömülü oynatıcı adresi. Saf mantık.
/// Yalnız bilinen sitelerin resmî gömme adresleri; kimlik yalnız güvenli karakterlerden oluşur.
enum VideoEmbed {
    static func embedURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        func safe(_ id: String?) -> String? {
            guard let id, !id.isEmpty, id.count <= 64,
                  id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
            return id
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            var id: String?
            if path == "/watch" { id = components?.queryItems?.first(where: { $0.name == "v" })?.value }
            else if path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || path.hasPrefix("/embed/") {
                id = path.split(separator: "/").dropFirst().first.map(String.init)
            }
            return safe(id).flatMap { URL(string: "https://www.youtube.com/embed/\($0)?playsinline=1") }
        }
        if host == "youtu.be" {
            return safe(path.split(separator: "/").first.map(String.init)).flatMap { URL(string: "https://www.youtube.com/embed/\($0)?playsinline=1") }
        }
        if host == "vimeo.com" || host.hasSuffix(".vimeo.com") {
            let id = path.split(separator: "/").last.map(String.init)
            guard let id, id.allSatisfy(\.isNumber) else { return nil }
            return URL(string: "https://player.vimeo.com/video/\(id)")
        }
        if host == "dailymotion.com" || host.hasSuffix(".dailymotion.com"), path.hasPrefix("/video/") {
            return safe(path.split(separator: "/").dropFirst().first.map(String.init))
                .flatMap { URL(string: "https://www.dailymotion.com/embed/video/\($0)") }
        }
        return nil
    }
}

/// Açık oynatıcının telefon geneli kaydı: telefon eylemi videoyu açtırır, sesli komutlar
/// oynatıcıya buradan ulaşır. Oynatıcı yoksa sesli komut sunucuya gider (yerel eylem yok).
@MainActor
final class VideoPlaybackCenter: ObservableObject {
    static let shared = VideoPlaybackCenter()

    /// Telefon eyleminin açtırmak istediği video; RootView oynatıcı sayfasını açar ve sıfırlar.
    @Published var request: PlayableVideo?

    private(set) weak var player: AVPlayer?
    /// Gömülü oynatıcı açık: sesle sarma yapılamaz (sayfanın kendi düğmeleri kullanılır).
    private(set) var embedded = false
    private var closer: (() -> Void)?

    static let volumeStep: Float = 0.2

    var isActive: Bool { player != nil || embedded }

    func present(url: URL) {
        request = PlayableVideo(url: url)
    }

    /// Kaydı yapan oynatıcı sayfası: yeni sayfa açılıp eskisi sonra kapanırsa yenisinin kaydı silinmez.
    private var owner: UUID?

    func attach(_ player: AVPlayer, owner: UUID, close: @escaping () -> Void) {
        self.player = player
        self.owner = owner
        embedded = false
        closer = close
    }

    func attachEmbedded(owner: UUID, close: @escaping () -> Void) {
        player = nil
        self.owner = owner
        embedded = true
        closer = close
    }

    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        player = nil
        self.owner = nil
        embedded = false
        closer = nil
    }

    /// Yerel sözlük: oynatıcı açıksa ve cümle video komutuysa yapar, söylenecek cümleyi döner.
    func handleVoice(_ text: String) -> String? {
        guard isActive, let command = VideoVoiceCommand.parse(text) else { return nil }
        return apply(command)
    }

    /// Komutu açık oynatıcıya uygular. Dönüş: söylenecek cümle; oynatıcı yoksa nil.
    @discardableResult
    func apply(_ command: VideoVoiceCommand) -> String? {
        if case .close = command {
            guard isActive else { return nil }
            closer?()
            return "Videoyu kapattım."
        }
        guard let player else {
            return embedded
                ? "Bu video gömülü oynatıcıda açık; sesle sarma ve ses ayarı yalnız Junior oynatıcısında çalışıyor. Ekrandaki düğmeleri kullan."
                : nil
        }
        let duration = player.currentItem?.duration.seconds
        switch command {
        case .seek(let delta):
            let target = VideoSeekMath.target(current: player.currentTime().seconds, delta: delta,
                                              duration: duration)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            return "Videoyu \(Int(abs(delta))) saniye \(delta >= 0 ? "ileri" : "geri") sardım; şimdi \(VideoSeekMath.clock(target))."
        case .seekTo(let seconds):
            if let duration, duration.isFinite, duration > 0, seconds > duration {
                return "Video \(VideoSeekMath.clock(duration)) sürüyor; \(VideoSeekMath.clock(seconds)) noktasına gidemem."
            }
            player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
            return "Videoyu \(VideoSeekMath.clock(seconds)) noktasına aldım."
        case .pause:
            player.pause()
            return "Videoyu duraklattım."
        case .play:
            player.play()
            return "Videoyu sürdürüyorum."
        case .volumeDown:
            if player.isMuted || player.volume <= 0 { return "Video zaten sessiz." }
            player.volume = max(0, player.volume - Self.volumeStep)
            return "Videonun sesini kıstım."
        case .volumeUp:
            if player.isMuted {
                player.isMuted = false
                if player.volume <= 0 { player.volume = Self.volumeStep }
                return "Videonun sesini açtım."
            }
            player.volume = min(1, player.volume + Self.volumeStep)
            return "Videonun sesini artırdım."
        case .mute:
            player.isMuted = true
            return "Videoyu sessize aldım."
        case .unmute:
            player.isMuted = false
            if player.volume <= 0 { player.volume = Self.volumeStep }
            return "Videonun sesini açtım."
        case .close:
            return nil
        }
    }
}

/// Gömülü oynatıcı (YouTube/Vimeo/Dailymotion'ın resmî gömme sayfası). Oynatmayı kullanıcı başlatır.
struct EmbeddedVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
