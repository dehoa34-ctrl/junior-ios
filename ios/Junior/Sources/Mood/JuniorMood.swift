import Foundation

/// Kedinin yüzünü belirleyen son sonuç ve son etkinlik anı.
///
/// Uzak komutun ve telefon eyleminin sonucu buraya yazılır (`done` → mutlu, `failed` → üzgün);
/// ekrandaki kedi ve Dynamic Island aynı `CatExpression.derive` kuralıyla ifade seçer.
@MainActor
final class JuniorMood: ObservableObject {
    static let shared = JuniorMood()

    struct Outcome: Equatable {
        let mood: JuniorOutcomeMood
        let at: Date
    }

    @Published private(set) var last: Outcome?
    /// Kullanıcının ya da Junior'ın son etkinliği; uzun süre boşta kalınca kedi uyuklar.
    @Published private(set) var lastActivity = Date()
    private var fadeTask: Task<Void, Never>?

    /// Sonucun ham durum adı (`done`, `failed`, `unverified` …): yüzü değiştirmeyenler yok sayılır.
    func record(outcome raw: String, at now: Date = Date()) {
        lastActivity = now
        guard let mood = JuniorOutcomeMood(outcome: raw) else { return }
        last = Outcome(mood: mood, at: now)
        // Gösterim süresi dolunca ekran ve ada eski yüze dönsün (başka bir şey değişmese de).
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((CatExpression.outcomeShownFor + 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            JuniorLiveActivity.shared.refreshExpression()
        }
    }

    func touch(at now: Date = Date()) {
        lastActivity = now
    }

    func expression(phase: JuniorActivityPhase, now: Date = Date()) -> CatExpression {
        CatExpression.derive(phase: phase, outcome: last?.mood,
                             outcomeAge: last.map { now.timeIntervalSince($0.at) } ?? 0,
                             idleFor: now.timeIntervalSince(lastActivity))
    }
}
