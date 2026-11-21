import Foundation

/// Sohbet ekranındaki mikrofon düğmesinin bas-konuş durum makinesi.
///
/// - Kısa dokunuş eski davranıştır (tıkla-konuş: dinlemeyi aç ya da kapat).
/// - Basılı tutunca (`holdThreshold`) dinleme başlar; bırakınca söylenen gönderilir.
/// - Basılıyken yukarı kaydırıp (`cancelDistance`) bırakmak iptaldir: hiçbir şey gönderilmez.
///   Parmak geri inerse iptal kalkar.
/// - Junior konuşurken basmak onu susturur; o dokunuş ayrıca dinleme açıp kapatmaz,
///   basılı tutulursa susturduktan sonra dinlemeye geçer (söz kesme).
///
/// Saf mantık: zamanlayıcı ve ses yok; görünüm olayları verir, dönen eylemi uygular.
struct PushToTalk: Equatable {
    enum Phase: Equatable {
        case idle
        /// Parmak düğmede, süre henüz dolmadı.
        case pressed
        /// Basılı tutuluyor, dinleme açık.
        case holding
        /// Basılı tutuluyor ama yukarı kaydırıldı: bırakılırsa iptal.
        case cancelArmed
    }

    enum Action: Equatable {
        case none
        /// Junior konuşuyordu: sesi kes.
        case silence
        /// Kısa dokunuş: eski tıkla-konuş.
        case tap
        /// Basılı tutma başladı: dinlemeyi aç.
        case startRecording
        /// Bırakıldı: dinlemeyi bitir ve söyleneni gönder.
        case send
        /// Yukarı kaydırılıp bırakıldı: dinlemeyi bitir, gönderme.
        case cancel
    }

    static let holdThreshold: TimeInterval = 0.35
    /// Yukarı kaydırma eşiği (nokta). Negatif yön yukarıdır.
    static let cancelDistance: Double = 70
    /// Basılı tutmanın dinlemeyi açık tutabileceği en uzun süre (dinleme başından). Yalnız
    /// unutulan ya da takılan basış için: eller serbest bekçisi turu 60 sn'de kapatır, söylenen
    /// ondan önce gönderilsin.
    static let holdLimit: TimeInterval = 50

    /// Dinlemeyi kendiliğinden bitirecek sessizlik süresi (SpeechService'in zamanlayıcısı).
    ///
    /// `normal` serbest dinlemedeki bekleme (konuştuktan sonra 2,8 sn, hiç konuşulmadıysa 6 sn).
    /// Basılıyken sessizlik dinlemeyi bitirmez: cümle ortasında duraksamak yarım cümle
    /// göndermesin, duraksadıktan sonra yukarı kaydırıp bırakmak da hâlâ iptal edebilsin.
    /// Gönderen bırakmak, iptal eden yukarı kaydırıp bırakmaktır; yalnız `holdLimit` kalır.
    /// `elapsed`: dinleme açılalı geçen süre.
    static func silenceWait(normal: TimeInterval, holding: Bool, elapsed: TimeInterval) -> TimeInterval {
        guard holding else { return normal }
        return max(0, holdLimit - max(0, elapsed))
    }

    private(set) var phase: Phase = .idle
    /// Bu basış Junior'ı susturdu mu (kısa bırakış dinleme açmaz).
    private(set) var silenced = false

    var isHolding: Bool { phase == .holding || phase == .cancelArmed }

    /// Parmak düğmeye değdi.
    mutating func press(speaking: Bool) -> Action {
        guard phase == .idle else { return .none }
        phase = .pressed
        silenced = speaking
        return speaking ? .silence : .none
    }

    /// Basılı tutma süresi doldu (görünümün zamanlayıcısı çağırır).
    mutating func holdElapsed() -> Action {
        guard phase == .pressed else { return .none }
        phase = .holding
        return .startRecording
    }

    /// Parmak kaydı; `dy` basış noktasına göre dikey fark (yukarı negatif).
    mutating func move(dy: Double) -> Action {
        switch phase {
        case .holding where dy <= -Self.cancelDistance:
            phase = .cancelArmed
        case .cancelArmed where dy > -Self.cancelDistance:
            phase = .holding
        default:
            break
        }
        return .none
    }

    /// Parmak kalktı.
    mutating func release() -> Action {
        defer {
            phase = .idle
            silenced = false
        }
        switch phase {
        case .idle: return .none
        case .pressed: return silenced ? .none : .tap
        case .holding: return .send
        case .cancelArmed: return .cancel
        }
    }

    /// Dokunuş sistemce kesildi (ör. gelen arama): basılı tutma iptal sayılır.
    mutating func interrupt() -> Action {
        let wasHolding = isHolding
        phase = .idle
        silenced = false
        return wasHolding ? .cancel : .none
    }
}
