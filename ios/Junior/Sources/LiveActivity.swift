import ActivityKit
import Foundation

/// Live Activity'yi (Dynamic Island) yöneten tek nokta.
///
/// Eller serbest döngüsü açıkken döngünün adımı gösterilir; kapalıyken yalnız
/// bir istek sürerken (düşünüyor) ve yanıttan sonra kısa bir süre görünür.
///
/// iOS kuralı: Live Activity yalnızca uygulama **öndeyken** başlatılabilir.
/// Başladıktan sonra arka planda güncellenebilir (ses oturumu açık kaldıkça
/// uygulama çalışır). Arka planda başlatma denemesi sessizce atlanır.
@MainActor
final class JuniorLiveActivity {
    static let shared = JuniorLiveActivity()
    static let enabledKey = "liveActivityEnabled"

    private var activity: Activity<JuniorActivityAttributes>?
    private var endTask: Task<Void, Never>?
    /// Eller serbest döngüsü açıkken ConversationStore'un güncellemeleri yok sayılır.
    private var handsFreeOn = false
    private var lastDetail = ""
    private var lastGlasses = false

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    private init() {
        // Uygulama yeniden açıldıysa önceki oturumdan kalan etkinliği sahiplen.
        activity = Activity<JuniorActivityAttributes>.activities.first
    }

    // MARK: - Girdiler

    /// Eller serbest döngüsünün adımı değişti.
    func handsFree(phase raw: String?, detail: String, glasses: Bool) {
        lastGlasses = glasses
        if !detail.isEmpty { lastDetail = detail }
        guard let raw else {
            // Döngü kapandı.
            handsFreeOn = false
            finish(after: 2)
            return
        }
        handsFreeOn = true
        show(JuniorActivityPhase(raw: raw))
    }

    /// Eller serbest kapalıyken bir istek başladı / bitti.
    func request(sending: Bool, detail: String) {
        guard !handsFreeOn else {
            if !detail.isEmpty { lastDetail = detail }
            return
        }
        if !detail.isEmpty { lastDetail = detail }
        if sending {
            show(.thinking)
        } else {
            show(.done)
            finish(after: 8)
        }
    }

    /// Ayar kapatıldı ya da uygulama kapanıyor.
    func endNow() {
        endTask?.cancel()
        endTask = nil
        let current = activity
        activity = nil
        guard let current else { return }
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - İç işleyiş

    private func state(_ phase: JuniorActivityPhase) -> ActivityContent<JuniorActivityAttributes.ContentState> {
        let detail = String(lastDetail.replacingOccurrences(of: "\n", with: " ").prefix(160))
        let s = JuniorActivityAttributes.ContentState(phase: phase.rawValue, detail: detail, glasses: lastGlasses, updatedAt: Date())
        // 15 dk güncelleme gelmezse sistem etkinliği "eski" gösterir.
        return ActivityContent(state: s, staleDate: Date().addingTimeInterval(15 * 60))
    }

    private func show(_ phase: JuniorActivityPhase) {
        guard isEnabled else {
            endNow()
            return
        }
        endTask?.cancel()
        endTask = nil
        let content = state(phase)
        if let current = activity {
            Task { await current.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity<JuniorActivityAttributes>.request(
                attributes: JuniorActivityAttributes(startedAt: Date()),
                content: content,
                pushType: nil
            )
        } catch {
            // Arka plandayken ya da sınır dolmuşken başlatılamaz; bir sonraki
            // ön plan anında yeniden denenir. Asistanın kendisi etkilenmez.
            activity = nil
        }
    }

    private func finish(after seconds: Double) {
        endTask?.cancel()
        guard let current = activity else { return }
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let final = self?.state(.done)
            await current.end(final, dismissalPolicy: .immediate)
            self?.activity = nil
            self?.endTask = nil
        }
    }
}
