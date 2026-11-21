import XCTest
@testable import Junior

/// Eşleştirme şifrelemesi: PBKDF2 türetme, AES-256-GCM zarfı ve sunucuyla ortak test vektörü.
/// Ağ ve Keychain kullanılmaz; vektör tests_mobile/test_pairing_crypto.py ile aynıdır.
/// Anahtar Bearer belirtecinden değil, QR'daki ayrı sırdan (`k`) türer.
final class PairingCryptoTests: XCTestCase {
    private let secret = "junior-test-vector-token-0123456789abcdef"
    private let salt = Data(0..<16)
    private let keyHex = "ae3902747df3092ca7dc3f1830c05a825ad34d5fe4636f83d310d23e3567a45c"
    private let nonce = Data(1...12)
    private let plaintext = Data(#"{"t":1800000000,"p":{"message":"merhaba"}}"#.utf8)
    private let sealedBase64 = "fonHYh0wm4Pr8geVfm9VOaadJUadVtkZvooUqB6bAKfBirCL3E7fHTpO+TZebSILq2eUeyM7cmcFDw=="
    private let kid = "k0123456789ab"

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func vectorKey() throws -> Data {
        try XCTUnwrap(PairingCrypto.deriveKey(secret: secret, salt: salt, iterations: 200_000))
    }

    func testPBKDF2MatchesServerVector() throws {
        XCTAssertEqual(hex(try vectorKey()), keyHex)
        XCTAssertNil(PairingCrypto.deriveKey(secret: secret, salt: salt, iterations: 1000))
        XCTAssertNil(PairingCrypto.deriveKey(secret: secret, salt: Data(), iterations: 200_000))
    }

    func testAADBindsDirectionMethodAndPath() {
        XCTAssertEqual(String(decoding: PairingCrypto.aad(kid: kid, direction: "req", method: "post", path: "/v1/command"), as: UTF8.self),
                       "junior-enc-1|k0123456789ab|req|POST /v1/command")
    }

    func testAESGCMMatchesServerVector() throws {
        let key = try vectorKey()
        let aad = PairingCrypto.aad(kid: kid, direction: "req", method: "POST", path: "/v1/command")
        let sealed = try PairingCrypto.sealBytes(plaintext, key: key, nonce: nonce, aad: aad)
        XCTAssertEqual(sealed.base64EncodedString(), sealedBase64)
        let opened = try PairingCrypto.openBytes(try XCTUnwrap(Data(base64Encoded: sealedBase64)), key: key, nonce: nonce, aad: aad)
        XCTAssertEqual(opened, plaintext)
    }

    func testWrongKeyOrPathFailsToOpen() throws {
        let key = try vectorKey()
        let sealed = try XCTUnwrap(Data(base64Encoded: sealedBase64))
        let aad = PairingCrypto.aad(kid: kid, direction: "req", method: "POST", path: "/v1/command")
        XCTAssertThrowsError(try PairingCrypto.openBytes(sealed, key: Data(repeating: 1, count: 32), nonce: nonce, aad: aad)) {
            XCTAssertEqual($0 as? PairingCrypto.Failure, .openFailed)
        }
        let moved = PairingCrypto.aad(kid: kid, direction: "req", method: "POST", path: "/v1/remote/confirm/abc12345")
        XCTAssertThrowsError(try PairingCrypto.openBytes(sealed, key: key, nonce: nonce, aad: moved))
        XCTAssertThrowsError(try PairingCrypto.openBytes(Data([1, 2]), key: key, nonce: nonce, aad: aad)) {
            XCTAssertEqual($0 as? PairingCrypto.Failure, .badEnvelope)
        }
    }

    func testSealedRequestHasServerFormat() throws {
        let key = Data(repeating: 7, count: 32)
        let body = try PairingCrypto.seal(["message": "ışığı aç"], key: key, kid: kid, method: "POST", path: "/v1/command",
                                          now: Date(timeIntervalSince1970: 1_800_000_000))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), ["enc", "kid", "n", "c"])
        XCTAssertEqual(envelope["enc"] as? Int, 1)
        XCTAssertEqual(envelope["kid"] as? String, kid)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("ışığı"))
        let nonceData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["n"] as? String)))
        XCTAssertEqual(nonceData.count, 12)
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["c"] as? String)))
        let opened = try PairingCrypto.openBytes(sealed, key: key, nonce: nonceData,
                                                 aad: PairingCrypto.aad(kid: kid, direction: "req", method: "POST", path: "/v1/command"))
        let inner = try XCTUnwrap(try JSONSerialization.jsonObject(with: opened) as? [String: Any])
        XCTAssertEqual(inner["t"] as? Int, 1_800_000_000)
        XCTAssertEqual((inner["p"] as? [String: Any])?["message"] as? String, "ışığı aç")
        // Her istek yeni nonce taşır.
        let again = try PairingCrypto.seal(["message": "ışığı aç"], key: key, kid: kid, method: "POST", path: "/v1/command")
        XCTAssertNotEqual(again, body)
    }

    func testOpensServerResponseAndRejectsForgeries() throws {
        let key = Data(repeating: 9, count: 32)
        let responseNonce = Data(repeating: 3, count: 12)
        let inner = Data(#"{"t":1800000001,"p":{"reply":"Tamam","status":"dispatched"}}"#.utf8)
        func envelope(direction: String, kid envelopeKid: String) throws -> Data {
            let sealed = try PairingCrypto.sealBytes(inner, key: key, nonce: responseNonce,
                                                     aad: PairingCrypto.aad(kid: envelopeKid, direction: direction, method: "POST", path: "/v1/command"))
            return try JSONSerialization.data(withJSONObject: ["enc": 1, "kid": envelopeKid,
                                                               "n": responseNonce.base64EncodedString(), "c": sealed.base64EncodedString()])
        }
        let good = try envelope(direction: "res", kid: kid)
        XCTAssertTrue(PairingCrypto.isEnvelope(good))
        XCTAssertFalse(PairingCrypto.isEnvelope(Data(#"{"reply":"düz"}"#.utf8)))
        let opened = try PairingCrypto.openResponse(good, key: key, kid: kid, method: "POST", path: "/v1/command")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: opened) as? [String: Any])
        XCTAssertEqual(payload["reply"] as? String, "Tamam")
        // İstek yönündeki şifreli gövde yanıt diye geri yollanamaz; başka kid kabul edilmez.
        XCTAssertThrowsError(try PairingCrypto.openResponse(try envelope(direction: "req", kid: kid), key: key, kid: kid,
                                                            method: "POST", path: "/v1/command"))
        XCTAssertThrowsError(try PairingCrypto.openResponse(try envelope(direction: "res", kid: "kffffffffffff"), key: key, kid: kid,
                                                            method: "POST", path: "/v1/command")) {
            XCTAssertEqual($0 as? PairingCrypto.Failure, .badEnvelope)
        }
    }

    func testAADPathFromURL() throws {
        let command = try XCTUnwrap(URL(string: "https://junior.example.com/v1/command"))
        XCTAssertEqual(PairingCrypto.aadPath(command), "/v1/command")
        let confirm = try XCTUnwrap(URL(string: "https://junior.example.com/v1/remote/confirm/confirm-0123456789"))
        XCTAssertEqual(PairingCrypto.aadPath(confirm), "/v1/remote/confirm/confirm-0123456789")
    }

    private func seedItems(k: String? = nil, kid: String? = "k0123456789ab", s: String? = "000102030405060708090a0b0c0d0e0f",
                           i: String? = "200000") -> [URLQueryItem] {
        var items = [URLQueryItem(name: "u", value: "https://junior.example.com"),
                     URLQueryItem(name: "t", value: "abcdefghijklmnopqrstuvwxyz_0123456789-ABCDEF")]
        let parts: [(String, String?)] = [("k", k ?? secret), ("kid", kid), ("s", s), ("i", i)]
        for (name, value) in parts {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        return items
    }

    func testSeedFromQRDerivesTheServerVectorKey() throws {
        let seed = try XCTUnwrap(try PairingSeed.parse(seedItems()))
        XCTAssertEqual(seed, PairingSeed(secret: secret, kid: kid, salt: salt, iterations: 200_000))
        let key = try XCTUnwrap(PairingCrypto.deriveKey(secret: seed.secret, salt: seed.salt, iterations: seed.iterations))
        XCTAssertEqual(hex(key), keyHex)
        // Belirteçten türeyen anahtar QR sırrından türeyenle aynı değildir.
        let fromToken = try XCTUnwrap(PairingCrypto.deriveKey(secret: "abcdefghijklmnopqrstuvwxyz_0123456789-ABCDEF",
                                                              salt: seed.salt, iterations: seed.iterations))
        XCTAssertNotEqual(fromToken, key)
    }

    func testSeedIsOptionalButNeverHalfValid() throws {
        let plain = [URLQueryItem(name: "u", value: "https://junior.example.com"), URLQueryItem(name: "t", value: "x")]
        XCTAssertNil(try PairingSeed.parse(plain))
        let broken: [[URLQueryItem]] = [
            seedItems(k: "kisa"), seedItems(k: secret + " "), seedItems(kid: nil), seedItems(kid: "K0123456789AB"),
            seedItems(kid: "k01234"), seedItems(s: "zz"), seedItems(s: "000102030405060708090A0B0C0D0E0F"), seedItems(s: nil),
            seedItems(i: "1000"), seedItems(i: "abc"), seedItems(i: nil),
        ]
        for items in broken {
            XCTAssertThrowsError(try PairingSeed.parse(items)) {
                XCTAssertEqual($0 as? PairingCrypto.Failure, .badPairing)
            }
        }
        XCTAssertEqual(PairingCrypto.hexData("00ff10"), Data([0, 255, 16]))
        XCTAssertNil(PairingCrypto.hexData("0"))
        XCTAssertNil(PairingCrypto.hexData("0g"))
    }

    @MainActor
    func testPairingLinkCarriesTheSeed() throws {
        var components = URLComponents(string: "junior://pair")!
        components.queryItems = seedItems()
        let request = try XCTUnwrap(Config.parsePairing(try XCTUnwrap(components.url)))
        XCTAssertEqual(request.seed?.kid, kid)
        XCTAssertEqual(request.seed?.salt, salt)
        // Yarım şifreleme parçası eşleştirmeyi geçersiz kılar; hiç yoksa eski QR gibi kabul edilir.
        components.queryItems = seedItems(s: "zz")
        XCTAssertNil(Config.parsePairing(try XCTUnwrap(components.url)))
        components.queryItems = Array(seedItems().prefix(2))
        let legacy = try XCTUnwrap(Config.parsePairing(try XCTUnwrap(components.url)))
        XCTAssertNil(legacy.seed)
    }

    func testRequestBodyIsSealedWheneverAKeyExists() throws {
        let key = PairingKey(kid: kid, key: Data(repeating: 5, count: 32), tokenTag: "t")
        let sealed = try PairingCrypto.requestBody(["decision": "approve"], key: key, method: "POST",
                                                   path: "/v1/remote/confirm/confirm-0123456789")
        XCTAssertTrue(PairingCrypto.isEnvelope(sealed))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("approve"))
        let plain = try PairingCrypto.requestBody(["decision": "approve"], key: nil, method: "POST",
                                                  path: "/v1/remote/confirm/confirm-0123456789")
        XCTAssertFalse(PairingCrypto.isEnvelope(plain))
    }

    func testKeyIsBoundToToken() {
        let token = "abcdefghijklmnopqrstuvwxyz_0123456789-ABCDEF"
        XCTAssertEqual(PairingKeyStore.tag(token), PairingKeyStore.tag(token))
        XCTAssertEqual(PairingKeyStore.tag(token).count, 16)
        XCTAssertNotEqual(PairingKeyStore.tag(token), PairingKeyStore.tag(token + "x"))
    }
}
