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
        hasToken = Keychain.read(account: Keys.keychainAccount) != nil
        wakeWordEnabled = (UserDefaults.standard.object(forKey: Keys.wakeWordEnabled) as? Bool) ?? true
        naturalVoiceEnabled = (UserDefaults.standard.object(forKey: Keys.naturalVoice) as? Bool) ?? true
        continuousEnabled = (UserDefaults.standard.object(forKey: Keys.continuous) as? Bool) ?? true
    }

    var token: String? { Keychain.read(account: Keys.keychainAccount) }

    func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: Keys.keychainAccount)
            hasToken = false
        } else {
            Keychain.write(account: Keys.keychainAccount, value: trimmed)
            hasToken = true
        }
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
            // Cihaz kilidi acilmadan okunamaz ve yedege gitmez.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
