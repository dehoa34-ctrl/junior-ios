import AVFoundation
import Contacts
import EventKit
import Foundation
import MediaPlayer
import MessageUI
import UIKit
import UserNotifications

/// Bir telefon eyleminin sonucu.
struct PhoneActionResult: Equatable {
    enum Kind: Equatable {
        /// Yapıldı.
        case done
        /// Telefon cepte/arka planda: dokununca yapılacak bir bildirim bırakıldı.
        case deferred
        /// Yapılamadı; `message` sebebi söyler.
        case failed
        /// Uygulama açıldı; birazdan aynı komut yeniden denenmeli (Spotify).
        case needsRetry
    }

    let kind: Kind
    /// Söylenecek/gösterilecek Türkçe metin. `nil` ise sunucunun yanıt cümlesi kullanılır.
    let message: String?

    static let done = PhoneActionResult(kind: .done, message: nil)
    static func doneSaying(_ message: String) -> PhoneActionResult { .init(kind: .done, message: message) }
    static func failed(_ message: String) -> PhoneActionResult { .init(kind: .failed, message: message) }
}

/// Sunucunun gönderdiği telefon eylemlerini yürütür: hatırlatıcı, takvim,
/// zamanlayıcı, arama, mesaj, uygulama açma, el feneri ve müzik.
///
/// Ön plan/arka plan kuralı: hatırlatıcı, takvim, zamanlayıcı ve Apple Music
/// denetimi arka planda da çalışır. Arama, mesaj, uygulama açma, el feneri ve
/// Spotify iOS'ta yalnız uygulama **ön plandayken** başka uygulamayı açabilir;
/// telefon cepteyken bunlar için dokunulunca eylemi yapan bir bildirim bırakılır.
@MainActor
final class PhoneActionService {
    static let shared = PhoneActionService()

    /// Bildirime dokunulup eylem yapıldıktan sonra çağrılır: (söylenecek metin, yeniden denenecek komut).
    var onFollowUp: ((_ message: String?, _ retryText: String?) -> Void)?

    private let notifications = UNUserNotificationCenter.current()

    // MARK: - Giriş

    /// Eylemi yürütür. `payload` ham `phone_action` nesnesidir (bildirime konur);
    /// `retryText` Spotify açıldıktan sonra yeniden gönderilecek kullanıcı cümlesidir.
    func perform(_ action: PhoneAction, payload: [String: Any], retryText: String?) async -> PhoneActionResult {
        if action.needsForeground, UIApplication.shared.applicationState != .active {
            return await defer_(action, payload: payload, retryText: retryText)
        }
        return await execute(action)
    }

    /// Bildirime dokunulunca: uygulama öne gelince eylemi yapar.
    func handleNotification(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["phoneAction"] as? String,
              let payload = PhoneActionPayload.decode(raw),
              let action = PhoneAction.parse(payload) else { return }
        let retryText = userInfo["retryText"] as? String
        Task { @MainActor in
            // Dokunuş anında uygulama henüz "active" olmayabilir; açılmasını bekle.
            for _ in 0..<30 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let result = await execute(action)
            switch result.kind {
            case .needsRetry: onFollowUp?(result.message, retryText)
            default: onFollowUp?(result.message, nil)
            }
        }
    }

    private func execute(_ action: PhoneAction) async -> PhoneActionResult {
        switch action {
        case .reminder(let title, let due): return await addReminder(title: title, due: due)
        case .event(let title, let start, let end): return await addEvent(title: title, start: start, end: end)
        case .timer(let seconds, let label): return await startTimer(seconds: seconds, label: label)
        case .call(let contact, let number): return await call(contact: contact, number: number)
        case .message(let contact, let number, let text, let channel):
            return await message(contact: contact, number: number, text: text, channel: channel)
        case .openApp(let name): return await openApp(name)
        case .torch(let on): return setTorch(on)
        case .appleMusic(let command, let query): return await appleMusic(command, query: query)
        case .spotify(let command, let query, _): return await spotify(command, query: query)
        }
    }

    // MARK: - Bildirim

    /// Bildirim izni yoksa ister; verilmemişse `false`.
    private func ensureNotifications() async -> Bool {
        (try? await notifications.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func post(title: String, body: String, userInfo: [String: Any] = [:],
                      after seconds: TimeInterval? = nil, id: String = UUID().uuidString) async -> Bool {
        guard await ensureNotifications() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        content.sound = .default
        content.userInfo = userInfo
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        do {
            try await notifications.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    /// Ön plan gerektiren eylem, telefon arka planda: dokununca yapan bildirim.
    private func defer_(_ action: PhoneAction, payload: [String: Any], retryText: String?) async -> PhoneActionResult {
        var info: [String: Any] = [:]
        if let raw = PhoneActionPayload.encode(payload) { info["phoneAction"] = raw }
        if let retryText { info["retryText"] = retryText }
        let body: String
        switch action {
        case .call(let contact, let number): body = "\(contact ?? number ?? "Kişi") aransın mı? Dokun."
        case .message(let contact, _, _, let channel):
            body = "\(contact ?? "Kişi") için \(channel == .whatsapp ? "WhatsApp" : "mesaj") hazır. Dokun, sonra gönder."
        case .openApp(let name): body = "\(name) açılsın. Dokun."
        case .torch(let on): body = on ? "El feneri açılsın. Dokun." : "El feneri kapatılsın. Dokun."
        case .spotify: body = "Spotify açılıp müzik başlatılsın. Dokun."
        default: body = "Dokun."
        }
        let posted = await post(title: "Junior", body: body, userInfo: info)
        guard posted else {
            return .failed("Telefon cepteyken bunu yapamıyorum ve bildirim izni de yok. Ayarlar'dan Junior'a bildirim izni ver.")
        }
        return PhoneActionResult(kind: .deferred,
                                 message: "Telefon kilitli olduğu için bunu bildirim olarak bıraktım. Dokununca yapacağım.")
    }

    // MARK: - Hatırlatıcı ve takvim

    private func addReminder(title: String, due: Date?) async -> PhoneActionResult {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else {
            // İzin yoksa zamanlı hatırlatıcı en azından bildirim olarak kurulur.
            if let due, due.timeIntervalSinceNow > 1,
               await post(title: "Hatırlatma", body: title, after: due.timeIntervalSinceNow) {
                return .doneSaying("Hatırlatıcılar izni yok; bunu bildirim olarak kurdum. Hatırlatıcılar uygulamasında görünmesi için Ayarlar > Junior > Hatırlatıcılar iznini aç.")
            }
            return .failed("Hatırlatıcılara erişim izni yok. Ayarlar > Junior > Hatırlatıcılar bölümünden izin ver.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .failed("Hatırlatıcılar uygulamasında kayıt yapılabilecek bir liste bulamadım.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return .done
        } catch {
            return .failed("Hatırlatıcıyı kaydedemedim: \(error.localizedDescription)")
        }
    }

    private func addEvent(title: String, start: Date, end: Date) async -> PhoneActionResult {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else {
            return .failed("Takvime erişim izni yok. Ayarlar > Junior > Takvim bölümünden izin ver.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failed("Takvimde etkinlik eklenebilecek bir takvim bulamadım.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        // Başlamadan on dakika önce haber ver.
        if start.timeIntervalSinceNow > 600 { event.addAlarm(EKAlarm(relativeOffset: -600)) }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .done
        } catch {
            return .failed("Etkinliği kaydedemedim: \(error.localizedDescription)")
        }
    }

    // MARK: - Zamanlayıcı

    /// Kilitliyken de çalar: yerel bildirim zamanı geldiğinde sistem gösterir.
    /// Tek bildirim kolay kaçırılır; 25 sn arayla iki kez daha çalar.
    private func startTimer(seconds: Int, label: String?) async -> PhoneActionResult {
        let text = label.map { "\($0) zamanlayıcısı bitti" } ?? "\(Self.spoken(seconds: seconds)) doldu"
        let group = UUID().uuidString
        var posted = true
        for repeatIndex in 0..<3 {
            let ok = await post(title: "Zamanlayıcı", body: repeatIndex == 0 ? text : "\(text) (tekrar)",
                                after: TimeInterval(seconds + repeatIndex * 25), id: "junior-timer-\(group)-\(repeatIndex)")
            if repeatIndex == 0, !ok { posted = false; break }
        }
        guard posted else {
            return .failed("Zamanlayıcı bildirimle çalar ama bildirim izni yok. Ayarlar > Junior > Bildirimler'den izin ver.")
        }
        return .done
    }

    /// 90 → "1 dakika 30 saniye".
    static func spoken(seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) saat") }
        if minutes > 0 { parts.append("\(minutes) dakika") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) saniye") }
        return parts.joined(separator: " ")
    }

    // MARK: - Rehber, arama, mesaj

    private enum Resolved {
        case number(String)
        case notFound
        case ambiguous([String])
        case denied
    }

    private func resolve(contact: String?, number: String?) async -> Resolved {
        if let number, !number.isEmpty { return .number(number) }
        guard let contact, !contact.isEmpty else { return .notFound }
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return .denied }
        let entries: [ContactMatching.Entry] = await Task.detached { () -> [ContactMatching.Entry] in
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                           CNContactFamilyNameKey as CNKeyDescriptor,
                                           CNContactNicknameKey as CNKeyDescriptor,
                                           CNContactPhoneNumbersKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var list: [ContactMatching.Entry] = []
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                let numbers: [(label: String, number: String)] = contact.phoneNumbers.map { phone in
                    let label = phone.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
                    return (label: label, number: phone.value.stringValue)
                }
                guard !numbers.isEmpty else { return }
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                list.append(ContactMatching.Entry(name: name, nickname: contact.nickname, numbers: numbers))
            }
            return list
        }.value
        switch ContactMatching.match(for: contact, in: entries) {
        case .found(let entry):
            if let value = ContactMatching.preferredNumber(entry) { return .number(value) }
            return .notFound
        case .ambiguous(let hits): return .ambiguous(hits.prefix(3).map(\.name))
        case .none: return .notFound
        }
    }

    private func call(contact: String?, number: String?) async -> PhoneActionResult {
        switch await resolve(contact: contact, number: number) {
        case .number(let value):
            let dial = ContactMatching.dialable(value)
            guard !dial.isEmpty, let url = URL(string: "tel://" + dial) else {
                return .failed("Numarayı anlayamadım.")
            }
            return await open(url) ? .done : .failed("Arama başlatılamadı. Bu cihazda telefon özelliği olmayabilir.")
        case .notFound:
            return .failed("Rehberde \(contact ?? "bu kişi") için kayıtlı numara bulamadım.")
        case .ambiguous(let names):
            return .failed("Rehberde birden fazla eşleşme var: \(names.joined(separator: ", ")). Soyadıyla söyler misin?")
        case .denied:
            return .failed("Rehbere erişim izni yok. Ayarlar > Junior > Kişiler bölümünden izin ver.")
        }
    }

    private func message(contact: String?, number: String?, text: String, channel: PhoneAction.Channel) async -> PhoneActionResult {
        let resolved = await resolve(contact: contact, number: number)
        var recipient: String?
        var note: String?
        switch resolved {
        case .number(let value): recipient = value
        case .notFound:
            note = "Rehberde \(contact ?? "bu kişi") için numara bulamadım; mesajı hazırladım, alıcıyı sen seç."
        case .ambiguous(let names):
            note = "Rehberde birden fazla eşleşme var (\(names.joined(separator: ", "))); mesajı hazırladım, alıcıyı sen seç."
        case .denied:
            note = "Rehbere erişim izni yok; mesajı hazırladım, alıcıyı sen seç. İzin için Ayarlar > Junior > Kişiler."
        }

        switch channel {
        case .whatsapp:
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            let phone = recipient.map(ContactMatching.international)
            var candidates: [String] = []
            if let phone, !phone.isEmpty {
                candidates = ["whatsapp://send?phone=\(phone)&text=\(encoded)", "https://wa.me/\(phone)?text=\(encoded)"]
            } else {
                candidates = ["whatsapp://send?text=\(encoded)"]
            }
            for raw in candidates {
                if let url = URL(string: raw), await open(url) {
                    return note.map { PhoneActionResult.doneSaying($0) } ?? .done
                }
            }
            return .failed("WhatsApp açılamadı. Yüklü olduğundan emin ol.")
        case .sms:
            let recipients = recipient.map { [ContactMatching.dialable($0)] } ?? []
            if MessageComposer.shared.present(recipients: recipients, body: text) {
                return note.map { PhoneActionResult.doneSaying($0) } ?? .done
            }
            // Oluşturucu açılamazsa sistem bağlantısı.
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            let target = recipients.first ?? ""
            if let url = URL(string: "sms:\(target)&body=\(encoded)"), await open(url) {
                return note.map { PhoneActionResult.doneSaying($0) } ?? .done
            }
            return .failed("Mesaj ekranı açılamadı. Bu cihaz mesaj gönderemiyor olabilir.")
        }
    }

    // MARK: - Uygulama, fener

    private func openApp(_ name: String) async -> PhoneActionResult {
        if ContactMatching.fold(name).contains("kamera") {
            return .failed("iOS, Kamera uygulamasını dışarıdan açtırmıyor. Kilit ekranındaki kamera simgesini kullanabilirsin.")
        }
        guard let app = PhoneAppCatalog.lookup(name) else {
            return .failed("\(name) uygulamasını tanımıyorum.")
        }
        let raw = app.url == "app-settings:" ? UIApplication.openSettingsURLString : app.url
        guard let url = URL(string: raw), await open(url) else {
            return .failed("\(app.display) açılamadı; yüklü olmayabilir.")
        }
        return .done
    }

    private func setTorch(_ on: Bool) -> PhoneActionResult {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            return .failed("Bu telefonda el feneri yok.")
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
            return .done
        } catch {
            return .failed("El fenerini açıp kapatamadım. Kamera başka bir şey tarafından kullanılıyor olabilir.")
        }
    }

    // MARK: - Müzik

    private func spotifyInstalled() -> Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Sunucu Web API'de çalan cihaz bulamadığında gelir. Spotify yüklüyse açılır ve
    /// komut bir kez yeniden denenir; yüklü değilse Apple Müzik'e düşülür.
    private func spotify(_ command: PhoneAction.SpotifyCommand, query: String?) async -> PhoneActionResult {
        guard spotifyInstalled() else {
            guard let mapped = Self.appleEquivalent(of: command) else {
                return .failed("Spotify yüklü değil. Ses düzeyini telefonun tuşlarından ayarlayabilirsin.")
            }
            let result = await appleMusic(mapped, query: query)
            if result.kind == .done, result.message == nil {
                return .doneSaying("Spotify yüklü olmadığı için Apple Müzik'i kullandım.")
            }
            return result
        }
        switch command {
        case .play, .resume:
            let raw = query.flatMap { Self.spotifySearchURL($0) } ?? "spotify:"
            guard let url = URL(string: raw), await open(url) else {
                return .failed("Spotify açılamadı.")
            }
            return PhoneActionResult(kind: .needsRetry, message: "Spotify'ı açıyorum, birazdan çalarım.")
        case .pause:
            return .doneSaying("Spotify kapalı; şu an çalan bir şey yok.")
        default:
            return .doneSaying("Spotify açık değil. Önce bir şey çalmamı söyle.")
        }
    }

    static func spotifySearchURL(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "spotify:search:" + encoded
    }

    static func appleEquivalent(of command: PhoneAction.SpotifyCommand) -> PhoneAction.MusicCommand? {
        switch command {
        case .play, .resume: return .play
        case .pause: return .pause
        case .next: return .next
        case .previous: return .previous
        case .volume, .volumeUp, .volumeDown: return nil
        }
    }

    private func appleMusic(_ command: PhoneAction.MusicCommand, query: String?) async -> PhoneActionResult {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch command {
        case .pause:
            player.pause()
            return .done
        case .next:
            player.skipToNextItem()
            return .done
        case .previous:
            player.skipToPreviousItem()
            return .done
        case .play:
            guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                player.play()
                return .done
            }
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else {
                return .failed("Müzik kitaplığına erişim izni yok. Ayarlar > Junior > Medya ve Apple Music bölümünden izin ver.")
            }
            let items = Self.libraryItems(matching: query)
            if !items.isEmpty {
                player.setQueue(with: MPMediaItemCollection(items: Array(items.prefix(50))))
                player.play()
                return .done
            }
            // Kitaplıkta yok: Apple Müzik'te aramayı aç (yalnız ön planda mümkün).
            let term = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            if UIApplication.shared.applicationState == .active,
               let url = URL(string: "https://music.apple.com/tr/search?term=\(term)"), await open(url) {
                return .doneSaying("Kitaplığında \(query) yok; Apple Müzik'te aramasını açtım.")
            }
            return .failed("Kitaplığında \(query) bulamadım.")
        }
    }

    private static func libraryItems(matching query: String) -> [MPMediaItem] {
        for property in [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle] {
            let media = MPMediaQuery.songs()
            media.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: property,
                                                               comparisonType: .contains))
            if let found = media.items, !found.isEmpty { return found }
        }
        return []
    }

    // MARK: - URL açma

    /// URL'yi açar. Sistem bazen (arama onayı gibi) geri çağrıyı geç verir; 2,5 sn sonra
    /// "istendi, sorun yok" sayılır ki sesli tur takılmasın.
    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            UIApplication.shared.open(url, options: [:]) { once.resume($0) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                once.resume(true)
            }
        }
    }
}

/// Devam noktasını yalnız bir kez sürer.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }
}

/// Sistem mesaj oluşturucusu: gönderme onayı kullanıcıdadır.
@MainActor
final class MessageComposer: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageComposer()

    func present(recipients: [String], body: String) -> Bool {
        guard MFMessageComposeViewController.canSendText(), let top = Self.topViewController() else { return false }
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = self
        controller.recipients = recipients
        controller.body = body
        top.present(controller, animated: true)
        return true
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                  didFinishWith result: MessageComposeResult) {
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
