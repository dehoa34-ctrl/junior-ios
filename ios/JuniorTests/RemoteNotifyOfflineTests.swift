import XCTest
@testable import Junior

/// Uzak komut sonucu, telefondan onay, kategorili bildirim ve çevrimdışı kuyruğun saf parçaları.
/// Ağ, bildirim merkezi ve UIKit kullanılmaz.
final class RemoteOutcomeTests: XCTestCase {
    func testEveryOutcomeHasHonestWording() {
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .done, message: "Spotify kapatıldı."),
                       "Bilgisayarda yapıldı: Spotify kapatıldı.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .done, message: ""), "Bilgisayarda yapıldı.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .unverified, message: "Geri alma denendi."),
                       "Bilgisayara gönderildi ama yapıldığı doğrulanamadı. Geri alma denendi.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .unverified, message: "Spotify'ı kapattım.", acted: false),
                       "Bilgisayarda bir işlem yapılmadı. Spotify'ı kapattım.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .failed, message: "Spotify açık değil."),
                       "Bilgisayarda olmadı: Spotify açık değil.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .failed, message: ""), "Bilgisayarda olmadı.")
        XCTAssertEqual(RemoteOutcomeText.phrase(outcome: .ask, message: "Hangi klasör?"),
                       "Bilgisayardaki Junior'ın sorusu: Hangi klasör?")
        XCTAssertTrue(RemoteOutcomeText.phrase(outcome: .expired, message: "").hasPrefix("Bilgisayar yanıt vermedi"))
        XCTAssertTrue(RemoteOutcomeText.phrase(outcome: .expired, message: "", claimed: true)
            .hasPrefix("Bilgisayar işi aldı ama yanıt vermedi"))
        // "Oldu" yalnız done'da: diğer durumların hiçbiri "yapıldı" demez.
        for outcome in JuniorOutcome.allCases where outcome != .done {
            XCTAssertFalse(RemoteOutcomeText.phrase(outcome: outcome, message: "x").contains("yapıldı:"), outcome.rawValue)
        }
    }

    func testTagsAndBoldAreStripped() {
        XCTAssertEqual(RemoteOutcomeText.clean("[done] **Spotify** kapatıldı."), "Spotify kapatıldı.")
        XCTAssertEqual(RemoteOutcomeText.clean("  [failed]  izin yok "), "izin yok")
    }

    func testParsesFinishedJobFromServer() throws {
        let json = """
        {"job": {"id": "9f2c1e0a7b3d4c55", "text": "Spotify'ı kapat", "state": "done",
                 "created": 1794463200.1, "claimed_at": 1794463201.3, "finished": 1794463209.8,
                 "progress": null,
                 "result": {"outcome": "done", "message": "Spotify kapatıldı.", "reply": "Spotify kapatıldı."},
                 "confirm": null}}
        """
        let job = try XCTUnwrap(RemoteJob.parse(Data(json.utf8)))
        XCTAssertEqual(job.id, "9f2c1e0a7b3d4c55")
        XCTAssertEqual(job.outcome, .done)
        XCTAssertTrue(job.claimed)
        XCTAssertNil(job.progress)
        XCTAssertNil(job.confirm)
        XCTAssertEqual(RemoteOutcomeText.phrase(job), "Bilgisayarda yapıldı: Spotify kapatıldı.")
    }

    func testRunningJobIsNotFinalAndCarriesConfirm() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let json = """
        {"job": {"id": "abc", "state": "claimed", "claimed_at": 10, "progress": "Kapatılıyor",
                 "result": null,
                 "confirm": {"id": "c1c1c1c1", "job_id": "abc", "title": "Onay gerekiyor: Uygulama kapatma",
                             "detail": "Uygulama kapatılacak: Spotify", "expires_in": 42, "decision": null, "decided_by": null}}}
        """
        let job = try XCTUnwrap(RemoteJob.parse(Data(json.utf8), now: now))
        XCTAssertEqual(job.state, .claimed)
        XCTAssertFalse(job.isFinal)
        XCTAssertNil(RemoteOutcomeText.phrase(job))
        XCTAssertEqual(job.progress, "Kapatılıyor")
        XCTAssertEqual(job.confirm?.id, "c1c1c1c1")
        XCTAssertEqual(job.confirm?.expiresAt, now.addingTimeInterval(42))
        XCTAssertEqual(job.confirm?.summary, "Onay gerekiyor: Uygulama kapatma · Uygulama kapatılacak: Spotify")
    }

    func testExpiredQueuedJobAndUnverifiedWithoutAction() throws {
        let expired = try XCTUnwrap(RemoteJob.parse(Data("""
        {"job": {"id": "e1", "state": "expired", "claimed_at": null,
                 "result": {"outcome": "expired", "message": "", "reply": "Bilgisayar şu an yanıt vermiyor."}}}
        """.utf8)))
        XCTAssertFalse(expired.claimed)
        XCTAssertTrue(RemoteOutcomeText.phrase(expired)?.hasPrefix("Bilgisayar yanıt vermedi") ?? false)

        let idle = try XCTUnwrap(RemoteJob.parse(Data("""
        {"job": {"id": "u1", "state": "unverified", "claimed_at": 5,
                 "result": {"outcome": "unverified", "message": "Kapattım.", "reply": "", "acted": false}}}
        """.utf8)))
        XCTAssertEqual(RemoteOutcomeText.phrase(idle), "Bilgisayarda bir işlem yapılmadı. Kapattım.")
        XCTAssertNil(RemoteJob.parse(Data("{\"job\": {\"state\": \"done\"}}".utf8)))
        XCTAssertEqual(RemoteJob.parse(Data("{\"job\": {\"id\": \"x\", \"state\": \"yeni\"}}".utf8))?.state, .unknown("yeni"))
    }

    func testBubbleReplacesPromiseWithResult() {
        let relayed = "Bilgisayara ilettim: Spotify uygulamasını kapat. Sonucu birazdan söylerim."
        XCTAssertEqual(RemoteOutcomeText.relayHead(relayed), "Bilgisayara ilettim: Spotify uygulamasını kapat.")
        let first = RemoteOutcomeText.bubble(relayed: relayed, result: RemoteOutcomeText.unreachable)
        XCTAssertEqual(first, "Bilgisayara ilettim: Spotify uygulamasını kapat.\n→ " + RemoteOutcomeText.unreachable)
        // Ara sonuçtan sonra gelen kesin sonuç onun yerine geçer.
        XCTAssertEqual(RemoteOutcomeText.bubble(relayed: first, result: "Bilgisayarda yapıldı."),
                       "Bilgisayara ilettim: Spotify uygulamasını kapat.\n→ Bilgisayarda yapıldı.")
        XCTAssertEqual(RemoteOutcomeText.bubble(relayed: "", result: "Sonuç"), "Sonuç")
    }

    func testRemoteStartedStatusAndJobID() {
        XCTAssertEqual(CommandStatus(raw: "remote_started"), .remoteStarted)
        XCTAssertTrue(JuniorClient.originUnreachable(502))
        XCTAssertTrue(JuniorClient.originUnreachable(530))
        XCTAssertFalse(JuniorClient.originUnreachable(503))
        XCTAssertFalse(JuniorClient.originUnreachable(404))
    }
}

final class PhoneOutcomeTests: XCTestCase {
    func testPhoneResultsUseTheSameFiveStates() {
        XCTAssertEqual(PhoneActionResult.done.outcome, .done)
        XCTAssertEqual(PhoneActionResult.failed("izin yok").outcome, .failed)
        XCTAssertEqual(PhoneActionResult(kind: .deferred, message: nil).outcome, .ask)
        XCTAssertEqual(PhoneActionResult(kind: .needsRetry, message: nil).outcome, .unverified)
    }

    func testPhoneWording() {
        // Hatırlatıcı kuruldu: sunucunun cümlesi kalır.
        XCTAssertEqual(PhoneActionResult.done.spoken(serverReply: "Hatırlatıcı kuruyorum."), "Hatırlatıcı kuruyorum.")
        // İzin yok: neden söylenir.
        XCTAssertEqual(PhoneActionResult.failed("Hatırlatıcılara erişim izni yok.").spoken(serverReply: "Kuruyorum."),
                       "Telefonda olmadı: Hatırlatıcılara erişim izni yok.")
        XCTAssertEqual(PhoneActionResult.failed("").spoken(serverReply: "x"), "Telefonda olmadı.")
        XCTAssertEqual(PhoneActionResult(kind: .deferred, message: nil).spoken(serverReply: "x"),
                       "Bunu bildirim olarak bıraktım; dokununca yapacağım.")
    }

    func testPhoneCannotQuitOtherApps() throws {
        let action = try XCTUnwrap(PhoneAction.parse(["name": "quit_app", "arguments": ["app": "Spotify"]]))
        XCTAssertEqual(action, .quitApp("Spotify"))
        XCTAssertFalse(action.needsForeground)
        let reason = try XCTUnwrap(action.notAllowedReason)
        XCTAssertTrue(reason.hasPrefix("iOS buna izin vermiyor"))
        XCTAssertTrue(reason.contains("Spotify"))
        XCTAssertEqual(PhoneActionResult.failed(reason).spoken(serverReply: "").prefix(37), "Telefonda olmadı: iOS buna izin vermi")
        XCTAssertNil(PhoneAction.torch(on: true).notAllowedReason)
        XCTAssertEqual(PhoneAction.parse(["name": "quit_app", "arguments": [String: Any]()]), .quitApp("Bu uygulama"))
    }
}

final class RemoteConfirmTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func confirm(_ id: String, in seconds: TimeInterval = 60) -> RemoteConfirm {
        RemoteConfirm(id: id, jobID: "j", title: "Onay gerekiyor", detail: "", expiresAt: now.addingTimeInterval(seconds))
    }

    func testPendingParseSkipsDecidedAndBroken() throws {
        let json = """
        {"confirms": [
          {"id": "aaaaaaaa", "job_id": "j1", "title": "Onay gerekiyor: Uygulama kapatma", "detail": "Spotify", "expires_in": 30, "decision": null},
          {"id": "bbbbbbbb", "job_id": "j2", "title": "Onay", "detail": "", "expires_in": 30, "decision": "approve"},
          {"job_id": "j3", "title": "Kimliksiz"}
        ]}
        """
        let list = try XCTUnwrap(RemoteConfirm.parsePending(Data(json.utf8), now: now))
        XCTAssertEqual(list.map(\.id), ["aaaaaaaa"])
        XCTAssertEqual(list.first?.expiresAt, now.addingTimeInterval(30))
        XCTAssertNil(RemoteConfirm.parsePending(Data("{}".utf8)))
    }

    func testReconcileAddsRemovesAndExpires() {
        let a = confirm("a"), b = confirm("b"), old = confirm("old", in: -1)
        let first = RemoteConfirmDiff.reconcile(current: [], fetched: [a, b], now: now)
        XCTAssertEqual(first.added.map(\.id), ["a", "b"])
        XCTAssertEqual(first.removedIDs, [])
        // a karara bağlandı (listeden düştü): bildirimi kaldırılır; b yeniden bildirilmez.
        let second = RemoteConfirmDiff.reconcile(current: first.pending, fetched: [b], now: now)
        XCTAssertEqual(second.pending.map(\.id), ["b"])
        XCTAssertEqual(second.added, [])
        XCTAssertEqual(second.removedIDs, ["a"])
        // Sunucuya ulaşılamadı: liste korunur ama süresi geçen düşer.
        let offline = RemoteConfirmDiff.reconcile(current: [b, old], fetched: nil, now: now)
        XCTAssertEqual(offline.pending.map(\.id), ["b"])
        XCTAssertEqual(offline.removedIDs, ["old"])
        // Sunucunun listesinde olsa da süresi geçmiş istek gösterilmez; çift kayıt teke iner.
        XCTAssertEqual(RemoteConfirmDiff.reconcile(current: [], fetched: [old, b, b], now: now).pending.map(\.id), ["b"])
    }

    func testDecisionWording() {
        XCTAssertEqual(RemoteConfirmText.decision(status: 200, approve: true, serverMessage: nil),
                       .init(text: "Onayladım; bilgisayar işleme devam ediyor.", resolved: true))
        XCTAssertEqual(RemoteConfirmText.decision(status: 200, approve: false, serverMessage: nil).text,
                       "Reddettim; bilgisayar bu işlemi yapmayacak.")
        XCTAssertEqual(RemoteConfirmText.decision(status: 409, approve: true, serverMessage: "Bu istek zaten bilgisayardan yanıtlandı."),
                       .init(text: "Bu istek zaten bilgisayardan yanıtlandı.", resolved: true))
        XCTAssertEqual(RemoteConfirmText.decision(status: 410, approve: true, serverMessage: nil),
                       .init(text: "Onay isteğinin süresi doldu; işlem yapılmadı.", resolved: true))
        XCTAssertTrue(RemoteConfirmText.decision(status: 404, approve: true, serverMessage: nil).resolved)
        XCTAssertFalse(RemoteConfirmText.decision(status: nil, approve: true, serverMessage: nil).resolved)
        XCTAssertFalse(RemoteConfirmText.decision(status: 401, approve: true, serverMessage: nil).resolved)
        XCTAssertEqual(RemoteConfirmText.serverMessage(Data("{\"error\": {\"code\": \"x\", \"message\": \"m\"}}".utf8)), "m")
    }

    func testLiveActivityStateCarriesConfirmAndOldStateStillDecodes() throws {
        let state = JuniorActivityAttributes.ContentState(phase: "confirm", detail: "Onay gerekiyor", glasses: false,
                                                          updatedAt: Date(timeIntervalSince1970: 1_000), confirmID: "c1c1c1c1")
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(JuniorActivityAttributes.ContentState.self, from: data), state)
        let old = Data("{\"phase\": \"speaking\", \"detail\": \"\", \"glasses\": false, \"updatedAt\": 0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(JuniorActivityAttributes.ContentState.self, from: old).confirmID)
        XCTAssertEqual(JuniorActivityPhase(raw: "confirm"), .confirm)
    }
}

final class NotificationGateTests: XCTestCase {
    func testServerCategoriesMapToSettings() {
        XCTAssertEqual(NotificationCategory.from(server: "task", builtin: nil, kind: "note"), .task)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: nil, kind: "note"), .routine)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: "checkin", kind: "note"), .checkin)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: "watch", kind: "note"), .watch)
        XCTAssertEqual(NotificationCategory.from(server: "routine", builtin: "briefing", kind: "note"), .briefing)
        XCTAssertEqual(NotificationCategory.from(server: nil, builtin: nil, kind: "reminder"), .routine)
        // Bilgisayardaki ekran olayı kuralı (mobile_api/screen_events.py): ayrı açılıp kapatılır.
        XCTAssertEqual(NotificationCategory.from(server: "screen", builtin: nil, kind: "note"), .screen)
        // Bilgisayardan açıkça gönderilen not / bağlantı: kategorisiz, her zaman gösterilir.
        XCTAssertNil(NotificationCategory.from(server: nil, builtin: nil, kind: "note"))
        XCTAssertNil(NotificationCategory.from(server: nil, builtin: nil, kind: "link"))
    }

    func testPhoneTaskReadsCategoryAndBuiltin() {
        let json = """
        {"tasks": [{"id": "1", "kind": "note", "text": "Su içtin mi?", "category": "routine", "builtin": "checkin"},
                   {"id": "2", "kind": "note", "text": "Görev bitti", "category": "task"},
                   {"id": "3", "kind": "link", "text": "", "url": "https://ornek.com"}]}
        """
        let tasks = PhoneTask.parse(Data(json.utf8))
        XCTAssertEqual(tasks.map(\.notificationCategory), [.checkin, .task, nil])
    }

    func testClosedCategoryNeverDelivers() {
        let all = Set(NotificationCategory.allCases)
        for category in NotificationCategory.allCases {
            XCTAssertTrue(NotificationGate.shouldDeliver(category, enabled: all, quietNow: false, userScheduled: false))
            XCTAssertFalse(NotificationGate.shouldDeliver(category, enabled: all.subtracting([category]),
                                                          quietNow: false, userScheduled: true), category.rawValue)
        }
        // Kategorisiz bildirim her zaman.
        XCTAssertTrue(NotificationGate.shouldDeliver(nil, enabled: [], quietNow: true, userScheduled: false))
    }

    func testQuietHoursSilenceOnlyCheckinAndWatch() {
        let all = Set(NotificationCategory.allCases)
        XCTAssertFalse(NotificationGate.shouldDeliver(.checkin, enabled: all, quietNow: true, userScheduled: false))
        XCTAssertFalse(NotificationGate.shouldDeliver(.watch, enabled: all, quietNow: true, userScheduled: false))
        // Kullanıcının kurduğu saatli hatırlatma sessiz saatte de gelir.
        XCTAssertTrue(NotificationGate.shouldDeliver(.routine, enabled: all, quietNow: true, userScheduled: true))
        XCTAssertTrue(NotificationGate.shouldDeliver(.routine, enabled: all, quietNow: true, userScheduled: false))
        XCTAssertTrue(NotificationGate.shouldDeliver(.task, enabled: all, quietNow: true, userScheduled: false))
        XCTAssertTrue(NotificationGate.shouldDeliver(.remote, enabled: all, quietNow: true, userScheduled: false))
    }

    func testPreferencesDefaultOnAndPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "junior.tests.notify.\(UUID().uuidString)"))
        XCTAssertEqual(NotificationPreferences.enabledSet(defaults: defaults), Set(NotificationCategory.allCases))
        NotificationPreferences.set(.watch, enabled: false, defaults: defaults)
        XCTAssertFalse(NotificationPreferences.isEnabled(.watch, defaults: defaults))
        XCTAssertFalse(NotificationPreferences.enabledSet(defaults: defaults).contains(.watch))
        NotificationPreferences.set(.watch, enabled: true, defaults: defaults)
        XCTAssertTrue(NotificationPreferences.isEnabled(.watch, defaults: defaults))
    }

    private func at(_ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: hour, minute: minute))!
    }

    func testQuietHoursAcrossMidnightMatchServerRule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let night = QuietHours(enabled: true, from: "23:00", to: "07:00")
        XCTAssertTrue(night.contains(at(23, 0, calendar: calendar), calendar: calendar))
        XCTAssertTrue(night.contains(at(3, 30, calendar: calendar), calendar: calendar))
        XCTAssertFalse(night.contains(at(7, 0, calendar: calendar), calendar: calendar))
        XCTAssertFalse(night.contains(at(12, 0, calendar: calendar), calendar: calendar))
        let day = QuietHours(enabled: true, from: "13:00", to: "14:30")
        XCTAssertTrue(day.contains(at(14, 29, calendar: calendar), calendar: calendar))
        XCTAssertFalse(day.contains(at(14, 30, calendar: calendar), calendar: calendar))
        XCTAssertFalse(QuietHours(enabled: false, from: "00:00", to: "23:59").contains(at(12, 0, calendar: calendar), calendar: calendar))
        XCTAssertFalse(QuietHours(enabled: true, from: "08:00", to: "08:00").contains(at(8, 0, calendar: calendar), calendar: calendar))
        XCTAssertFalse(QuietHours(enabled: true, from: "bozuk", to: "07:00").contains(at(3, 0, calendar: calendar), calendar: calendar))
    }

    func testQuietSnapshotPrefersFreshServerAnswer() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let fetched = at(12, 0, calendar: calendar)
        // Sunucu "şu an sessiz" dedi (ör. az önce açıldı) ve aralık 23–07: ilk dakika sunucuya uyulur.
        let snapshot = QuietHoursSource.Snapshot(enabled: true, from: "23:00", to: "07:00", quietNow: true, fetchedAt: fetched)
        XCTAssertTrue(QuietHoursSource.quiet(snapshot, now: fetched.addingTimeInterval(30), calendar: calendar))
        // Sonra aralık telefon saatiyle uygulanır.
        XCTAssertFalse(QuietHoursSource.quiet(snapshot, now: fetched.addingTimeInterval(120), calendar: calendar))
        XCTAssertTrue(QuietHoursSource.quiet(snapshot, now: at(23, 30, calendar: calendar), calendar: calendar))
        XCTAssertFalse(QuietHoursSource.quiet(nil, now: fetched))
    }
}

final class OfflineQueueTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func command(_ text: String, minutesAgo: Double = 0, now: Date? = nil) -> QueuedCommand {
        QueuedCommand(text: text, target: nil, createdAt: (now ?? start).addingTimeInterval(-minutesAgo * 60))
    }

    func testTimeSensitivePhrases() {
        for text in ["Şimdi Spotify'ı kapat", "hemen ışıkları kapat", "5 dakika sonra beni uyar",
                     "beş dakika sonra hatırlat", "yarım saat sonra su iç", "10 dk içinde ara",
                     "Birazdan çıkıyorum de", "ŞU AN ne çalıyor"] {
            XCTAssertTrue(OfflineQueue.isTimeSensitive(text), text)
        }
        for text in ["Spotify'ı kapat", "yarın 9'da hatırlat", "şimdilik bırak", "10 dakikalık zamanlayıcı kur",
                     "bugün hava nasıl"] {
            XCTAssertFalse(OfflineQueue.isTimeSensitive(text), text)
        }
        XCTAssertEqual(OfflineQueue.fold("ŞİMDİ Çık Iğdır"), "simdi cik igdir")
    }

    func testQueueKeepsAtMostFiftyDroppingOldest() {
        var queue = OfflineQueue()
        for index in 0..<55 {
            queue.enqueue(command("komut \(index)", now: start.addingTimeInterval(Double(index))), now: start.addingTimeInterval(60))
        }
        XCTAssertEqual(queue.items.count, OfflineQueue.maxItems)
        XCTAssertEqual(queue.items.first?.text, "komut 5")
        XCTAssertEqual(queue.items.last?.text, "komut 54")
    }

    func testOlderThanADayIsDropped() {
        var queue = OfflineQueue(items: [command("eski", minutesAgo: 24 * 60 + 1), command("yeni", minutesAgo: 5)])
        let step = queue.takeNext(now: start)
        XCTAssertEqual(step.dropped.map(\.text), ["eski"])
        XCTAssertEqual(step.next?.text, "yeni")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(OfflineQueue.decision(for: command("x", minutesAgo: 24 * 60), now: start), .drop)
    }

    func testSendsInOrderAndHoldsStaleTimeSensitive() {
        var queue = OfflineQueue(items: [command("5 dakika sonra beni uyar", minutesAgo: 15),
                                         command("Spotify'ı kapat", minutesAgo: 14),
                                         command("hemen ara", minutesAgo: 3)])
        let first = queue.takeNext(now: start)
        // Eskimiş zamana bağlı komut gönderilmez, sorulur; sıradaki gider.
        XCTAssertEqual(first.newlyHeld.map(\.text), ["5 dakika sonra beni uyar"])
        XCTAssertEqual(first.next?.text, "Spotify'ı kapat")
        let second = queue.takeNext(now: start)
        XCTAssertEqual(second.newlyHeld, [])
        XCTAssertEqual(second.next?.text, "hemen ara")  // 3 dk: henüz eskimedi
        XCTAssertNil(queue.takeNext(now: start).next)
        XCTAssertEqual(queue.held.map(\.text), ["5 dakika sonra beni uyar"])
        XCTAssertTrue(queue.waiting.isEmpty)
        // Kullanıcı "Gönder" dedi: bir daha sorulmadan gider.
        let held = queue.held[0]
        queue.approve(id: held.id)
        let third = queue.takeNext(now: start.addingTimeInterval(600))
        XCTAssertEqual(third.next?.id, held.id)
        XCTAssertEqual(third.newlyHeld, [])
        XCTAssertTrue(queue.isEmpty)
    }

    func testFailedSendReturnsToFrontWithSameRequestID() {
        var queue = OfflineQueue(items: [command("a", minutesAgo: 2), command("b", minutesAgo: 1)])
        let next = queue.takeNext(now: start).next!
        queue.enqueue(next, now: start, atFront: true)
        XCTAssertEqual(queue.items.map(\.text), ["a", "b"])
        XCTAssertEqual(queue.items.first?.requestID, next.requestID)
        // Aynı komut iki kez eklenmez.
        queue.enqueue(next, now: start, atFront: true)
        XCTAssertEqual(queue.items.count, 2)
        queue.remove(id: next.id)
        XCTAssertEqual(queue.items.map(\.text), ["b"])
    }

    func testStaleQuestionAndAgeText() {
        XCTAssertEqual(OfflineQueue.ageText(30), "az önce")
        XCTAssertEqual(OfflineQueue.ageText(25 * 60), "25 dakika önce")
        XCTAssertEqual(OfflineQueue.ageText(3 * 3600 + 5), "3 saat önce")
        let question = OfflineQueue.staleQuestion(command("hemen ara", minutesAgo: 12), now: start)
        XCTAssertTrue(question.contains("\"hemen ara\""))
        XCTAssertTrue(question.contains("12 dakika önce"))
        XCTAssertTrue(question.hasSuffix("şimdi göndereyim mi?"))
    }

    func testFileRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junior-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = OfflineQueueFile(url: folder.appendingPathComponent("offline-queue.json"))
        XCTAssertEqual(file.load(), [])
        var held = command("hemen ara", minutesAgo: 20)
        held.held = true
        let items = [command("Spotify'ı kapat"), held]
        file.save(items)
        XCTAssertEqual(file.load(), items)
        file.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }
}
