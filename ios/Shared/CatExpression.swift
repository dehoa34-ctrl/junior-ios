import Foundation

/// Noktalı kedinin yüz ifadesi. Uygulama da Dynamic Island da aynı kuralla seçer; ham değer
/// Live Activity durumuna yazılır (`ContentState.expression`).
///
/// Saf mantık: aktör yok, testten doğrudan çağrılır.
enum CatExpression: String, CaseIterable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case happy
    case sad
    case sleepy

    /// Son sonucun yüzde kalma süresi: "oldu" dedikten sonra kedi bir süre gülümser.
    static let outcomeShownFor: TimeInterval = 12
    /// Bu kadar süre hiçbir şey olmazsa kedi uyuklar.
    static let sleepyAfter: TimeInterval = 5 * 60

    init?(raw: String?) {
        guard let raw, let value = CatExpression(rawValue: raw) else { return nil }
        self = value
    }

    /// Adımın kendi ifadesi (son sonuç bilinmiyorsa). Eski davranış: beklerken gözler kapalı.
    init(phase: JuniorActivityPhase) {
        switch phase {
        case .waiting: self = .sleepy
        case .listening, .looking: self = .listening
        case .thinking, .confirm: self = .thinking
        case .speaking: self = .speaking
        case .done: self = .happy
        case .error: self = .sad
        }
    }

    /// Sohbetin o anki adımından ve son sonucun durumundan ifade.
    ///
    /// - phase: ekranın ya da adanın adımı (dinliyor, düşünüyor …).
    /// - outcome: son işin sonucu (`done` → mutlu, `failed` → üzgün); diğerleri yüzü değiştirmez.
    /// - outcomeAge: sonucun üstünden geçen süre; `outcomeShownFor`'dan eskiyse sayılmaz.
    /// - idleFor: son etkinlikten bu yana geçen süre; uzun boşlukta kedi uyuklar.
    static func derive(phase: JuniorActivityPhase, outcome: JuniorOutcomeMood?,
                       outcomeAge: TimeInterval = 0, idleFor: TimeInterval = 0) -> CatExpression {
        switch phase {
        case .listening, .looking: return .listening
        case .thinking, .confirm: return .thinking
        case .speaking: return .speaking
        case .error: return .sad
        case .waiting, .done:
            // Etkin bir adım yok: yakın zamandaki sonuç yüzde görünür.
            if let outcome, outcomeAge >= 0, outcomeAge < outcomeShownFor {
                switch outcome {
                case .done: return .happy
                case .failed: return .sad
                }
            }
            if phase == .done { return .happy }
            return idleFor >= sleepyAfter ? .sleepy : .idle
        }
    }

    /// Gözler kapalı mı (uykulu).
    var eyesClosed: Bool { self == .sleepy }
}

/// Yüzü değiştiren sonuçlar. `JuniorOutcome` yalnız uygulamada derlenir; widget de bu türü
/// çözebilsin diye ayrı ve küçük tutuldu.
enum JuniorOutcomeMood: String, Equatable {
    case done
    case failed

    /// Uzak işin ve telefon eyleminin ham durum adından ("done", "failed" …); diğerleri nil.
    init?(outcome raw: String) {
        guard let value = JuniorOutcomeMood(rawValue: raw) else { return nil }
        self = value
    }
}

extension JuniorDots {
    /// İfadeye göre noktanın ağırlığı. Gözler ve ağız değişir; kafa ve kulaklar aynı kalır.
    /// `eyesClosed` göz kırpışı içindir: ağız ifadede kalır, yalnız gözler kapanır.
    ///
    /// Izgara seyrek (15 sütunda adım ~0,14): her biçim en az bir sıra nokta yakalayacak
    /// kalınlıkta tutuldu; 9 sütunlu küçük adada ifade çoğunlukla renkten okunur.
    static func weight(x: Double, y: Double, expression: CatExpression, eyesClosed: Bool = false) -> Double {
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let dx = (x - cx) / rx
            let dy = (y - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        for cx in [-0.3, 0.3] where ellipse(cx, 0.04, 0.17, 0.13) {
            if eyesClosed || expression == .sleepy {
                return abs(y - 0.04) < 0.05 ? 1.1 : 0
            }
            switch expression {
            case .happy:
                // "^ ^": tepesi yukarıda ters V.
                return abs(y - (-0.05 + 0.94 * abs(x - cx))) < 0.08 ? 1.15 : 0
            case .thinking:
                // Göz bebekleri yukarı bakar.
                return ellipse(cx, -0.03, 0.06, 0.1) ? 1.25 : 0
            default:
                return ellipse(cx, 0.04, 0.06, 0.1) ? 1.25 : 0
            }
        }
        if ellipse(0, 0.25, 0.07, 0.04) { return 1.2 }
        switch expression {
        case .happy where abs(x) <= 0.3 && abs(y - (0.5 - 0.9 * x * x)) < 0.07:
            return 1.15
        case .sad where abs(x) <= 0.3 && abs(y - (0.4 + 0.9 * x * x)) < 0.07:
            return 1.15
        case .speaking where ellipse(0, 0.45, 0.18, 0.1):
            return 1.15
        case .thinking where x >= 0.05 && x <= 0.3 && abs(y - 0.47) < 0.07:
            return 1.15
        default:
            break
        }
        let base = weight(x: x, y: y, eyesClosed: false)
        // Dinlerken kulaklar dikilir (parlak). Kulaklar yüz elipsinin dışında kalan üçgenlerdir.
        if expression == .listening, base == 0.95 { return 1.1 }
        return base
    }
}
