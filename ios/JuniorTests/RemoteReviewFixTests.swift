import XCTest
@testable import Junior

/// Uzak komut / onay / çevrimdışı kuyruk gözden geçirmesinin düzeltmeleri: saf parçalar.
/// Ağ, bildirim merkezi ve ActivityKit kullanılmaz.
final class ConfirmIslandTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 50_000)

    func testConfirmMakesActivityStaleAtExpiry() {
        let expires = now.addingTimeInterval(60)
        XCTAssertEqual(JuniorConfirmDisplay.staleDate(now: now, confirmExpiresAt: expires), expires)
        // Onay yokken eski davranış: 15 dk.
        XCTAssertEqual(JuniorConfirmDisplay.staleDate(now: now, confirmExpiresAt: nil), now.addingTimeInterval(15 * 60))
        // Süresi zaten geçmiş onay: hemen eski.
        XCTAssertEqual(JuniorConfirmDisplay.staleDate(now: now, confirmExpiresAt: now.addingTimeInterval(-5)), now)
    }

    func testStaleActivityHidesButtonsAndConfirmTitle() {
        XCTAssertEqual(JuniorConfirmDisplay.buttonsID(confirmID: "c1", isStale: false), "c1")
        // Uygulama askıdayken onayın süresi doldu: ölü isteğe karar verilmesin.
        XCTAssertNil(JuniorConfirmDisplay.buttonsID(confirmID: "c1", isStale: true))
        XCTAssertNil(JuniorConfirmDisplay.buttonsID(confirmID: nil, isStale: false))
        XCTAssertNil(JuniorConfirmDisplay.buttonsID(confirmID: "", isStale: false))
        XCTAssertEqual(JuniorConfirmDisplay.phase(raw: "confirm", isStale: false), .confirm)
        XCTAssertEqual(JuniorConfirmDisplay.phase(raw: "confirm", isStale: true), .done)
        // Onay dışındaki adımlar eskise de aynı kalır.
        XCTAssertEqual(JuniorConfirmDisplay.phase(raw: "thinking", isStale: true), .thinking)
    }
}

final class PhoneReplacementTests: XCTestCase {
    func testDoneWithoutOwnMessageKeepsServerSentenceAndChunks() {
        // nil: sunucunun cümlesi ve önden seslendirilen parçaları kalır.
        XCTAssertNil(PhoneActionResult.done.replacement(serverReply: "Hatırlatıcı kuruyorum."))
        XCTAssertNil(PhoneActionResult.doneSaying("   ").replacement(serverReply: "Kuruyorum."))
    }

    func testOtherResultsReplaceTheServerSentence() {
        XCTAssertEqual(PhoneActionResult.doneSaying("Zamanlayıcı 5 dakikaya kuruldu.").replacement(serverReply: "x"),
                       "Zamanlayıcı 5 dakikaya kuruldu.")
        XCTAssertEqual(PhoneActionResult.failed("Hatırlatıcılara erişim izni yok.").replacement(serverReply: "Kuruyorum."),
                       "Telefonda olmadı: Hatırlatıcılara erişim izni yok.")
        XCTAssertEqual(PhoneActionResult(kind: .deferred, message: nil).replacement(serverReply: "x"),
                       "Bunu bildirim olarak bıraktım; dokununca yapacağım.")
        XCTAssertEqual(PhoneActionResult(kind: .needsRetry, message: nil).replacement(serverReply: "x"),
                       "Telefonda denedim ama yapıldığını doğrulayamadım.")
    }
}

final class CommandFailureTests: XCTestCase {
    private func isNetwork(_ error: JuniorError) -> Bool {
        if case .network = error { return true }
        return false
    }

    private func isNoReply(_ error: JuniorError) -> Bool {
        if case .noReply = error { return true }
        return false
    }

    func testOnlyUnreachableGoesToOfflineQueue() {
        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                    .dataNotAllowed, .internationalRoamingOff] {
            XCTAssertTrue(isNetwork(JuniorError.commandFailure(URLError(code))), "\(code.rawValue)")
        }
        // İstek gitmiş olabilir: kuyruğa girip kendiliğinden yeniden gönderilmez.
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cancelled, .badServerResponse] {
            XCTAssertTrue(isNoReply(JuniorError.commandFailure(URLError(code))), "\(code.rawValue)")
        }
        XCTAssertTrue(isNoReply(JuniorError.commandFailure(NSError(domain: "x", code: 1))))
    }

    func testJuniorErrorsPassThrough() {
        // Sunucunun kendi hatası (ör. 502/530 → .network, 401 → .unauthorized) olduğu gibi kalır.
        XCTAssertTrue(isNetwork(JuniorError.commandFailure(JuniorError.network)))
        if case .unauthorized = JuniorError.commandFailure(JuniorError.unauthorized) {} else {
            XCTFail("unauthorized korunmalı")
        }
    }

    func testNoReplySaysItMayHaveArrived() {
        let text = JuniorError.noReply.localizedDescription
        XCTAssertTrue(text.contains("gitmiş olabilir"), text)
        XCTAssertFalse(text.contains("ulaşılamıyor"), text)
    }
}

final class OfflineRetryTests: XCTestCase {
    func testRetryBacksOffUpToTwoMinutes() {
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 0), 15)
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 1), 15)
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 2), 30)
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 3), 60)
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 4), 120)
        XCTAssertEqual(OfflineQueue.retryDelay(afterFailures: 50), 120)
    }
}
