import Foundation
import Security

/// Sunucu adresi UserDefaults'ta, erisim tokeni Keychain'de tutulur.
/// Token hicbir zaman loglanmaz veya ekranda acikca gosterilmez.
@MainActor
final class Config: ObservableObject {
    private enum Keys {
        static let baseURL = "junior.baseURL"
        static let keychainAccount = "mobile-api-token"
        static let wakeWordEnabled = "junior.wakeWordEnabled"
        static let naturalVoice = "junior.naturalVoice"
        static let continuous = "junior.continuousConversation"
        static let tokenAccessMigrated = "junior.tokenAccessAfterFirstUnlock"
    }

    /// Bilgisayardaki Junior uygulamasinin QR kodundan gelen, henuz onaylanmamis
    /// eslestirme. Kullanici onaylamadan uygulanmaz: aksi halde herhangi bir
    /// junior://pair baglantisi sorulari baska bir sunucuya yonlendirebilirdi.
    struct PairingRequest: Identifiable, Equatable {
        let id = UUID()
        let baseURL: String
        let token: String
        var host: String { URLComponents(string: baseURL)?.host ?? baseURL }
    }

    @Published var pendingPairing: PairingRequest?

    /// Kilit ekranindayken Keychain okunamayabiliyor; acilista okunan belirtec
    /// bellekte tutulur.
    private var cachedToken: String?

    /// Dynamic Island / kilit ekranında Live Activity gösterilsin mi.
    @Published var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: JuniorLiveActivity.enabledKey)
            if !liveActivityEnabled { JuniorLiveActivity.shared.endNow() }
        }
    }

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }

    @Published private(set) var hasToken: Bool

    /// Varsayılan açık: uygulamanın bütün amacı "Hey Junior". Kapalı başlarsa
    /// kullanıcı ayarı bulamıyor ve "çalışmıyor" sanıyor.
    @Published var wakeWordEnabled: Bool {
        didSet { UserDefaults.standard.set(wakeWordEnabled, forKey: Keys.wakeWordEnabled) }
    }

    /// Yanıtlar sunucudaki nöral Türkçe sesle okunur; kapalıyken ya da sunucuya
    /// ulaşılamayınca iOS'un yerleşik sesi kullanılır.
    @Published var naturalVoiceEnabled: Bool {
        didSet { UserDefaults.standard.set(naturalVoiceEnabled, forKey: Keys.naturalVoice) }
    }

    /// Açıkken yanıttan sonra doğrudan dinlemeye dönülür; her soru için
    /// "Hey Junior" demek gerekmez. "Kapat" denince ya da sessiz kalınca biter.
    @Published var continuousEnabled: Bool {
        didSet { UserDefaults.standard.set(continuousEnabled, forKey: Keys.continuous) }
    }

    init() {
        // Varsayilan yok: adres kisiye ozel. Bos birakilinca uygulama
        // "sunucu adresi eksik" uyarisini gosterip Ayarlar'a goturuyor.
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        let stored = Keychain.read(account: Keys.keychainAccount)
        cachedToken = stored
        hasToken = stored != nil
        // Eski kayit "yalniz kilit aciksa okunur" sinifindaydi: ekran kapaliyken
        // "Hey Junior" denince belirtec okunamiyor, istek yetkisiz gidiyordu.
        // Bir kez yeni sinifla yeniden yazilir.
        if let stored, !UserDefaults.standard.bool(forKey: Keys.tokenAccessMigrated) {
            if Keychain.write(account: Keys.keychainAccount, value: stored) {
                UserDefaults.standard.set(true, forKey: Keys.tokenAccessMigrated)
            }
        }
        wakeWordEnabled = (UserDefaults.standard.object(forKey: Keys.wakeWordEnabled) as? Bool) ?? true
        naturalVoiceEnabled = (UserDefaults.standard.object(forKey: Keys.naturalVoice) as? Bool) ?? true
        continuousEnabled = (UserDefaults.standard.object(forKey: Keys.continuous) as? Bool) ?? true
        liveActivityEnabled = (UserDefaults.standard.object(forKey: JuniorLiveActivity.enabledKey) as? Bool) ?? true
    }

    var token: String? {
        if let cachedToken { return cachedToken }
        let value = Keychain.read(account: Keys.keychainAccount)
        cachedToken = value
        return value
    }

    func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: Keys.keychainAccount)
            cachedToken = nil
            hasToken = false
        } else {
            Keychain.write(account: Keys.keychainAccount, value: trimmed)
            UserDefaults.standard.set(true, forKey: Keys.tokenAccessMigrated)
            cachedToken = trimmed
            hasToken = true
        }
    }

    /// junior://pair?u=<https adresi>&t=<belirtec> baglantisini cozer.
    /// Bicim bozuksa nil; gecerliyse onay icin bekletilir.
    static func parsePairing(_ url: URL) -> PairingRequest? {
        guard url.scheme == "junior", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let base = items.first(where: { $0.name == "u" })?.value,
              let token = items.first(where: { $0.name == "t" })?.value,
              let components = URLComponents(string: base), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              (components.path.isEmpty || components.path == "/"),
              components.query == nil,
              token.count >= 32, token.count <= 256,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        else { return nil }
        return PairingRequest(baseURL: base.hasSuffix("/") ? String(base.dropLast()) : base, token: token)
    }

    func applyPairing(_ request: PairingRequest) {
        baseURL = request.baseURL
        setToken(request.token)
        pendingPairing = nil
    }

    /// Gecerli bir istek adresi uretir; bicimi bozuksa nil doner.
    func url(path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // URLComponents "https://" icin host'u nil degil bos dize veriyor; bos
        // kontrolu olmadan "https:///v1/command" gibi anlamsiz bir adres uretiliyordu.
        guard var components = URLComponents(string: base), let scheme = components.scheme,
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum Keychain {
    private static let service = "app.junior.token"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func write(account: String, value: String) -> Bool {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Acilistan sonraki ilk kilit acmadan once okunamaz, yedege gitmez.
            // "WhenUnlocked" olunca ekran kilitliyken okunamiyor ve sesli
            // komutlar yetkisiz gidiyordu.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
