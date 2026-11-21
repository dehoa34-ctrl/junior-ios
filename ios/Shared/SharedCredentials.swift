import Foundation
import Security

/// Paylaş eklentisinin bilgisayara ulaşması için sunucu adresi ve belirtecin ortak kopyası.
///
/// Belirteç uygulamada Keychain'de durur (`Config`, hizmet `app.junior.token`). Eklenti ayrı
/// bir süreçtir ve uygulamanın kendi Keychain grubunu okuyamaz; bu yüzden adres ve belirtecin
/// bir kopyası **ortak Keychain erişim grubuna** (`<takım>.xyz.jrbilge.junior.shared`, iki
/// hedefin entitlements dosyasında) yazılır. App group'lu UserDefaults kullanılmadı: belirteç
/// düz bir plist'e düşmesin, Keychain'de ve "bu cihaza özel" kalsın.
///
/// **Cihazda doğrulanmadı.** CI imzasız derler (`CODE_SIGNING_ALLOWED=NO`), dolayısıyla
/// entitlements ikiliye gömülmez; SideStore/AltStore'un grubu kendiliğinden vermesi beklenmez.
/// O durumda yazma `errSecMissingEntitlement` ile düşer. Uygulama bundan etkilenmez; eklenti
/// `sharedGroupAvailable()` ile bunu ayırt edip "yeniden eşleştir" yerine "bu kurulumda
/// belirtece erişemiyor" der. Bu yüzden eklenti .ipa'ya varsayılan olarak konmaz (ios.yml).
enum SharedCredentials {
    static let service = "app.junior.share"
    static let groupSuffix = "xyz.jrbilge.junior.shared"
    private static let tokenAccount = "token"
    private static let baseURLAccount = "baseURL"
    /// Yetki yoklaması için geçici kayıtlar; asıl kopyayla karışmasın diye ayrı hizmet.
    private static let probeService = "app.junior.share.probe"

    /// Eklenti: ortak gruba yazma yetkisi var mı. Takım önekini kendi varsayılan grubundaki
    /// geçici bir kayıttan öğrenir, ortak gruba geçici kayıt eklemeyi dener, ikisini de siler.
    static func sharedGroupAvailable() -> Bool {
        guard let group = accessGroup(teamPrefix: ownTeamPrefix()) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "group",
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = Data("1".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(match as CFDictionary)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    /// Sürecin varsayılan Keychain grubunun takım öneki (grup belirtmeden eklenen kayıttan).
    private static func ownTeamPrefix() -> String? {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "prefix",
        ]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = Data("1".utf8)
        add[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &item)
        SecItemDelete(match as CFDictionary)
        guard status == errSecSuccess, let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String else { return nil }
        return teamPrefix(ofAccessGroup: group)
    }

    /// Ortak grubun tam adı: takım öneki + sonek. Önek bilinmiyorsa nil.
    static func accessGroup(teamPrefix: String?) -> String? {
        guard let teamPrefix, !teamPrefix.isEmpty else { return nil }
        return teamPrefix + "." + groupSuffix
    }

    /// Bir Keychain grubunun (`ABCDE12345.xyz.jrbilge.junior`) takım öneki.
    static func teamPrefix(ofAccessGroup group: String) -> String? {
        guard let dot = group.firstIndex(of: "."), dot != group.startIndex else { return nil }
        return String(group[..<dot])
    }

    /// Uygulamanın kendi kaydının erişim grubundan takım öneki (uygulama tarafı).
    static func teamPrefix(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String else { return nil }
        return teamPrefix(ofAccessGroup: group)
    }

    /// Uygulama: kopyayı günceller; belirteç yoksa siler. Erişim grubu verilmemişse sessizce geçer.
    static func store(baseURL: String, token: String?, teamPrefix: String?) {
        guard let token, !token.isEmpty else {
            clear()
            return
        }
        guard let group = accessGroup(teamPrefix: teamPrefix) else { return }
        write(account: tokenAccount, value: token, group: group)
        write(account: baseURLAccount, value: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), group: group)
    }

    /// Eklenti: (adres, belirteç). Grup belirtilmeden aranır; eklentinin erişebildiği gruplarda bulunur.
    static func read() -> (baseURL: String, token: String)? {
        guard let token = value(account: tokenAccount), !token.isEmpty,
              let base = value(account: baseURLAccount), !base.isEmpty else { return nil }
        return (base, token)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func value(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Önce günceller, kayıt yoksa ekler: silip yeniden eklerken arada kopya kaybolmasın.
    private static func write(account: String, value: String, group: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = match
        add[kSecValueData as String] = data
        // Kilitliyken de okunur (ilk kilit açılışından sonra), yedeğe ve başka cihaza gitmez.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
