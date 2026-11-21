import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Telefon ↔ bilgisayar komut şifrelemesi (sunucuda mobile_api/pairing_crypto.py, aynı biçim).
///
/// - Anahtar: Bearer belirtecinden DEĞİL, QR koddaki ayrı sırdan (`k`) PBKDF2-HMAC-SHA256 ile
///   türetilir (en az 200 000 yineleme; tuz `s` ve kid de QR'da). Belirteç her istekte başlıkta
///   gider, TLS'i sonlandıran uç onu görür; sır ise ağdan hiç geçmez. Anahtar Keychain'de bu cihaza
///   bağlı (yedeğe gitmez) saklanır.
/// - Zarf: `{"enc":1,"kid":…,"n":nonce_b64,"c":şifreli_metin+etiket_b64}`; açık metin
///   `{"t":unix_saniye,"p":{…gövde…}}`. AAD yönü (req/res), yöntemi ve yolu bağlar.
/// - İsteğe bağlı: QR'da sır yoksa (eski bilgisayar uygulaması) istek eskisi gibi düz gider. Anahtar
///   varken istek hiçbir durumda düz gönderilmez (bkz. JuniorClient.sealedExchange).
enum PairingCrypto {
    static let version = 1
    static let minIterations = 200_000
    static let keyBytes = 32
    static let nonceBytes = 12
    static let tagBytes = 16
    static let aadPrefix = "junior-enc-1"

    enum Failure: Error, Equatable {
        case badEnvelope
        case openFailed
        case badPairing
    }

    /// PBKDF2-HMAC-SHA256, 32 bayt. Yineleme 200 000'den azsa ya da tuz boşsa nil.
    static func deriveKey(secret: String, salt: Data, iterations: Int) -> Data? {
        guard iterations >= minIterations, iterations <= 10_000_000, !salt.isEmpty, !secret.isEmpty else { return nil }
        var derived = Data(count: keyBytes)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.utf8.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     out.bindMemory(to: UInt8.self).baseAddress, keyBytes)
            }
        }
        return Int(status) == Int(kCCSuccess) ? derived : nil
    }

    /// direction: "req" (telefon → sunucu) ya da "res" (sunucu → telefon).
    static func aad(kid: String, direction: String, method: String, path: String) -> Data {
        Data("\(aadPrefix)|\(kid)|\(direction)|\(method.uppercased()) \(path)".utf8)
    }

    /// Sunucunun gördüğü yol: adresteki "/v1/…" kısmı.
    static func aadPath(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/v1/") { return String(path[range.lowerBound...]) }
        return path
    }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        if SecRandomCopyBytes(kSecRandomDefault, nonceBytes, &bytes) != errSecSuccess {
            return AES.GCM.Nonce().withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }

    /// AES-256-GCM: şifreli metin + 16 baytlık etiket (Python `AESGCM.encrypt` ile aynı dizilim).
    static func sealBytes(_ plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func openBytes(_ sealed: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count >= tagBytes, nonce.count == nonceBytes else { throw Failure.badEnvelope }
        let bytes = Data(sealed)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: bytes.prefix(bytes.count - tagBytes),
                                            tag: bytes.suffix(tagBytes))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw Failure.openFailed
        }
    }

    /// İstek gövdesini zarfa koyar; dönen veri doğrudan `httpBody` olur.
    static func seal(_ payload: [String: Any], key: Data, kid: String, method: String, path: String,
                     now: Date = Date(), nonce: Data? = nil) throws -> Data {
        let inner: [String: Any] = ["t": Int(now.timeIntervalSince1970), "p": payload]
        let plaintext = try JSONSerialization.data(withJSONObject: inner)
        let nonceData = nonce ?? randomNonce()
        let sealed = try sealBytes(plaintext, key: key, nonce: nonceData,
                                   aad: aad(kid: kid, direction: "req", method: method, path: path))
        let envelope: [String: Any] = ["enc": version, "kid": kid,
                                       "n": nonceData.base64EncodedString(), "c": sealed.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    /// Yanıt bir zarf mı (`enc` alanı taşıyan JSON nesnesi).
    static func isEnvelope(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["enc"] != nil
    }

    /// Sunucunun şifreli yanıtını açar; asıl JSON gövdesini döner.
    static func openResponse(_ data: Data, key: Data, kid: String, method: String, path: String) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["enc", "kid", "n", "c"],
              (object["enc"] as? Int) == version,
              let envelopeKid = object["kid"] as? String, envelopeKid == kid,
              let nonceText = object["n"] as? String, let nonce = Data(base64Encoded: nonceText),
              let sealedText = object["c"] as? String, let sealed = Data(base64Encoded: sealedText)
        else { throw Failure.badEnvelope }
        let plaintext = try openBytes(sealed, key: key, nonce: nonce,
                                      aad: aad(kid: kid, direction: "res", method: method, path: path))
        guard let inner = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              inner["t"] is NSNumber, let payload = inner["p"] as? [String: Any] else { throw Failure.badEnvelope }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// İstek gövdesi: anahtar varsa zarf, yoksa düz JSON.
    static func requestBody(_ payload: [String: Any], key: PairingKey?, method: String, path: String) throws -> Data {
        guard let key else { return try JSONSerialization.data(withJSONObject: payload) }
        return try seal(payload, key: key.key, kid: key.kid, method: method, path: path)
    }

    static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }

    /// Küçük harfli onaltılık metni baytlara çevirir; bozuksa nil.
    static func hexData(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0, bytes.allSatisfy(isLowerHex) else { return nil }
        var data = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        return data
    }
}

/// QR koddaki şifreleme parçası: `k` (sır), `kid`, `s` (16 bayt tuz, onaltılık), `i` (yineleme).
/// Sunucu sırrı saklamaz; telefon anahtarı bundan kendisi türetir.
struct PairingSeed: Codable, Equatable {
    let secret: String
    let kid: String
    let salt: Data
    let iterations: Int

    /// Parçaların hiçbiri yoksa nil (eski bilgisayar uygulaması); biri bile varsa hepsi geçerli olmalı.
    static func parse(_ items: [URLQueryItem]) throws -> PairingSeed? {
        let names: Set<String> = ["k", "kid", "s", "i"]
        guard items.contains(where: { names.contains($0.name) }) else { return nil }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let secret = value("k"), secret.count >= 32, secret.count <= 256,
              secret.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }),
              let kid = value("kid"), kid.utf8.count == 13, kid.hasPrefix("k"),
              kid.utf8.dropFirst().allSatisfy(PairingCrypto.isLowerHex),
              let saltText = value("s"), saltText.utf8.count == 32, let salt = PairingCrypto.hexData(saltText),
              let iterationsText = value("i"), let iterations = Int(iterationsText),
              iterations >= PairingCrypto.minIterations, iterations <= 10_000_000
        else { throw PairingCrypto.Failure.badPairing }
        return PairingSeed(secret: secret, kid: kid, salt: salt, iterations: iterations)
    }
}

/// Türetilmiş anahtar; hangi belirteçten türetildiği özetle bağlanır (belirteç değişince kullanılmaz).
struct PairingKey: Codable, Equatable {
    let kid: String
    let key: Data
    let tokenTag: String
}

/// Keychain'de saklanan eşleştirme anahtarı (belirteçle aynı hizmet, ayrı hesap).
enum PairingKeyStore {
    static let account = "pairing-key"
    /// QR'dan gelen, anahtarı henüz türetilmemiş sır; anahtar yazılınca silinir.
    static let pendingAccount = "pairing-seed"

    private struct PendingSeed: Codable {
        let seed: PairingSeed
        let tokenTag: String
    }

    static func savePending(_ seed: PairingSeed, token: String) {
        guard let data = try? JSONEncoder().encode(PendingSeed(seed: seed, tokenTag: tag(token))),
              let text = String(data: data, encoding: .utf8) else { return }
        Keychain.write(account: pendingAccount, value: text)
    }

    static func loadPending(token: String) -> PairingSeed? {
        guard let text = Keychain.read(account: pendingAccount), let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(PendingSeed.self, from: data),
              stored.tokenTag == tag(token) else { return nil }
        return stored.seed
    }

    static func tag(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func load(token: String) -> PairingKey? {
        guard let text = Keychain.read(account: account), let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(PairingKey.self, from: data),
              stored.tokenTag == tag(token), stored.key.count == PairingCrypto.keyBytes else { return nil }
        return stored
    }

    static func save(_ key: PairingKey) {
        guard let data = try? JSONEncoder().encode(key), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.write(account: account, value: text)
    }

    static func clearPending() {
        Keychain.delete(account: pendingAccount)
    }

    static func clear() {
        Keychain.delete(account: account)
        clearPending()
    }
}
