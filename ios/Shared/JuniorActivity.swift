import ActivityKit
import Foundation

/// Junior'ın Live Activity'si: Dynamic Island'da ve kilit ekranında görünür.
///
/// Uygulama ile widget eklentisi bu dosyayı paylaşır; iki taraf aynı tipi
/// kodlayıp çözdüğü için alanlar yalnızca burada tanımlanır.
struct JuniorActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Döngünün adımı: bkz. `JuniorActivityPhase`
        var phase: String
        /// Son soru ya da yanıttan kısa bir parça
        var detail: String
        /// Son turda gözlük kamerası kullanıldı mı
        var glasses: Bool
        var updatedAt: Date
        /// Bilgisayardaki Junior'ın beklettiği onay isteği; doluyken adada Onayla/Reddet görünür.
        /// İsteğe bağlı: eski sürümün yazdığı durum da çözülür.
        var confirmID: String? = nil
        /// Kedinin yüz ifadesi (`CatExpression` ham değeri); boşsa adımdan türetilir.
        var expression: String? = nil
    }

    var startedAt: Date
}

/// Adadaki onay düğmelerinin kuralı. Saf mantık: uygulama durumu yazarken, widget çizerken kullanır.
///
/// Onay gösterilirken etkinliğin "eski" anı onayın sona erme anıdır. Uygulama askıdayken
/// süre dolarsa kimse güncelleme yapamaz; sistem etkinliği eski sayar ve widget düğmeleri
/// gizler, kullanıcı ölü bir isteğe karar vermez.
enum JuniorConfirmDisplay {
    /// Onay yokken: 15 dk güncelleme gelmezse etkinlik eski görünür.
    static let idleStaleAfter: TimeInterval = 15 * 60

    static func staleDate(now: Date, confirmExpiresAt: Date?) -> Date {
        if let confirmExpiresAt { return max(now, confirmExpiresAt) }
        return now.addingTimeInterval(idleStaleAfter)
    }

    /// Düğmeleri çizilecek onay; eskimiş etkinlikte nil.
    static func buttonsID(confirmID: String?, isStale: Bool) -> String? {
        guard let confirmID, !confirmID.isEmpty, !isStale else { return nil }
        return confirmID
    }

    /// Gösterilecek adım: süresi geçmiş onay "Onay bekliyor" demez.
    static func phase(raw: String, isStale: Bool) -> JuniorActivityPhase {
        let phase = JuniorActivityPhase(raw: raw)
        return phase == .confirm && isStale ? .done : phase
    }

    /// Adadaki kedinin ifadesi: uygulamanın yazdığı ifade, yoksa (eski sürüm) adımdan.
    /// Eskimiş etkinlikte yazılan ifade de bayattır; gösterilen adımdan türetilir.
    static func expression(raw: String?, phase: JuniorActivityPhase, isStale: Bool) -> CatExpression {
        if !isStale, let written = CatExpression(raw: raw) { return written }
        return CatExpression(phase: phase)
    }
}

/// Live Activity'de gösterilen adımlar. Ham değerler ContentState'e yazılır.
enum JuniorActivityPhase: String, CaseIterable {
    case waiting
    case listening
    case looking
    case thinking
    case speaking
    case done
    case error
    /// Bilgisayardaki Junior telefondan onay bekliyor.
    case confirm

    init(raw: String) {
        self = JuniorActivityPhase(rawValue: raw) ?? .waiting
    }

    /// Adadaki kısa başlık.
    var title: String {
        switch self {
        case .waiting: return "\"Hey Junior\" de"
        case .listening: return "Dinliyorum"
        case .looking: return "Gözlükten bakıyorum"
        case .thinking: return "Düşünüyorum"
        case .speaking: return "Konuşuyorum"
        case .done: return "Junior"
        case .error: return "Bir sorun oldu"
        case .confirm: return "Onay bekliyor"
        }
    }

    /// Kompakt adanın sağındaki kısa etiket (en fazla birkaç harf).
    var badge: String {
        switch self {
        case .waiting: return "Hazır"
        case .listening: return "Dinliyor"
        case .looking: return "Bakıyor"
        case .thinking: return "…"
        case .speaking: return "Konuşuyor"
        case .done: return "Bitti"
        case .error: return "Hata"
        case .confirm: return "Onay"
        }
    }

    /// SF Symbol adı.
    var symbol: String {
        switch self {
        case .waiting: return "ear"
        case .listening: return "waveform"
        case .looking: return "eyeglasses"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .done: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        case .confirm: return "checkmark.shield.fill"
        }
    }

    /// Kedinin rengi (RGB 0...1). Masaüstü adasındaki durum renkleriyle aynı.
    var rgb: (Double, Double, Double) {
        switch self {
        case .waiting: return (0.62, 0.66, 0.72)
        case .listening: return (0.62, 0.91, 1.0)
        case .looking: return (0.13, 0.83, 0.93)
        case .thinking: return (0.65, 0.55, 0.98)
        case .speaking: return (0.62, 0.91, 1.0)
        case .done: return (0.20, 0.83, 0.60)
        case .error: return (0.96, 0.31, 0.37)
        case .confirm: return (1.0, 0.62, 0.26)
        }
    }

    /// Kedi gözleri kapalı mı (beklerken uykulu).
    var eyesClosed: Bool { self == .waiting }
}

/// Noktalı kedi yüzü: birim karede (-1...1) bir noktanın ağırlığı.
/// 0 = nokta yok, 1 = normal, >1 = parlak (göz bebeği, burun).
/// Masaüstü simgesindeki (desktop/build/make-icons.mjs) şeklin aynısıdır.
enum JuniorDots {
    static func weight(x: Double, y: Double, eyesClosed: Bool) -> Double {
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let dx = (x - cx) / rx
            let dy = (y - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        func triangle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Bool {
            func s(_ p: (Double, Double), _ q: (Double, Double), _ r: (Double, Double)) -> Double {
                (p.0 - r.0) * (q.1 - r.1) - (q.0 - r.0) * (p.1 - r.1)
            }
            let p = (x, y)
            let d1 = s(p, a, b)
            let d2 = s(p, b, c)
            let d3 = s(p, c, a)
            let neg = d1 < 0 || d2 < 0 || d3 < 0
            let pos = d1 > 0 || d2 > 0 || d3 > 0
            return !(neg && pos)
        }
        let inEye = ellipse(-0.3, 0.04, 0.17, 0.13) || ellipse(0.3, 0.04, 0.17, 0.13)
        if inEye {
            if eyesClosed {
                // Kapalı göz: ortada tek sıra nokta
                return abs(y - 0.04) < 0.05 ? 1.1 : 0
            }
            let pupil = ellipse(-0.3, 0.04, 0.06, 0.1) || ellipse(0.3, 0.04, 0.06, 0.1)
            return pupil ? 1.25 : 0
        }
        if ellipse(0, 0.25, 0.07, 0.04) { return 1.2 }
        if ellipse(0, 0.1, 0.72, 0.6) { return 0.85 }
        if triangle((-0.72, -0.05), (-0.2, -0.42), (-0.64, -0.92)) { return 0.95 }
        if triangle((0.72, -0.05), (0.2, -0.42), (0.64, -0.92)) { return 0.95 }
        return 0
    }
}
