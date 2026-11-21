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
    /// Bilgisayardan bekleyen onay: varken ada Onayla/Reddet düğmelerini gösterir ve kapanmaz.
    private var confirm: (id: String, text: String, expiresAt: Date)?
    /// Onay yokken gösterilecek adım (döngünün ya da isteğin son hâli).
    private var basePhase: JuniorActivityPhase = .done
    private var requestActive = false

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    private init() {
        // Uygulama yeniden açıldıysa önceki oturumdan kalan etkinliği sahiplen.
        activity = Activity<JuniorActivityAttributes>.activities.first
        // Süreç yeniden başladıysa (iOS sonlandırdı, ada ya da bildirim düğmesi uygulamayı arka
        // planda açtı) adada kalan onay da sahiplenilir: ilk yoklama ya da karar onu kaldırabilsin.
        if let content = activity?.content, let id = content.state.confirmID {
            confirm = (id, content.state.detail, content.staleDate ?? Date())
        }
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
        requestActive = sending
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

    /// Bilgisayardaki Junior onay istiyor: adada Onayla/Reddet (iOS 17 etkileşimli düğme).
    /// - expiresAt: onayın sona erme anı; ada o an "eski" sayılır ve düğmeler gizlenir.
    func showConfirm(id: String, text: String, expiresAt: Date) {
        if let current = confirm, current.id == id, current.text == text, current.expiresAt == expiresAt { return }
        confirm = (id, text, expiresAt)
        show(basePhase)
    }

    /// Onay kapandı (karar verildi, süresi doldu): ada önceki hâline döner.
    func clearConfirm() {
        // Bellekte onay olmasa da adada düğme kalmış olabilir (önceki süreçten).
        let leftover = activity?.content.state.confirmID != nil
        guard confirm != nil || leftover else { return }
        confirm = nil
        guard activity != nil else { return }
        show(basePhase)
        if !handsFreeOn, !requestActive { finish(after: 3) }
    }

    /// Kedinin ifadesi değişti (son sonucun gösterim süresi doldu): açık ada yeni yüzü alır.
    /// Kapanmak üzere olan (bitiş zamanlayıcısı kurulu) ada yeniden açılmaz.
    func refreshExpression() {
        guard activity != nil, endTask == nil else { return }
        show(basePhase)
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
        // Bekleyen onay her adımın önüne geçer: kullanıcı kararını adadan verebilsin.
        let shown = confirm == nil ? phase : .confirm
        let source = confirm?.text ?? lastDetail
        let detail = String(source.replacingOccurrences(of: "\n", with: " ").prefix(160))
        // Adadaki kedi uygulamadakiyle aynı yüzü taşır (son sonuç: mutlu / üzgün).
        let expression = JuniorMood.shared.expression(phase: shown)
        let s = JuniorActivityAttributes.ContentState(phase: shown.rawValue, detail: detail, glasses: lastGlasses,
                                                      updatedAt: Date(), confirmID: confirm?.id,
                                                      expression: expression.rawValue)
        // 15 dk güncelleme gelmezse sistem etkinliği "eski" gösterir; onay varken onayın
        // süresi dolunca (uygulama askıda kalsa da widget düğmeleri gizler).
        let now = Date()
        return ActivityContent(state: s, staleDate: JuniorConfirmDisplay.staleDate(now: now, confirmExpiresAt: confirm?.expiresAt))
    }

    private func show(_ phase: JuniorActivityPhase) {
        if phase != .confirm { basePhase = phase }
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
        // Onay beklerken ada kapanmaz; onay kapanınca clearConfirm bitirir.
        guard confirm == nil else { return }
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
