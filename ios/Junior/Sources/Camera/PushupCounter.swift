import CoreGraphics
import Foundation

/// Kamerayla şınav sayımının saf mantığı: üç eklem noktasından dirsek açısı ve açı dizisinden
/// tekrar sayısı. Kamera ve Vision yok; hepsi XCTest ile denenir (CameraSkillTests).
enum PushupGeometry {
    /// `vertex` köşeli, `a` ve `c` kolların uçları olan açı (derece, 0…180). Bir kol sıfır
    /// uzunluktaysa (iki nokta üst üste) açı tanımsızdır: nil.
    static func angle(a: CGPoint, vertex: CGPoint, c: CGPoint) -> Double? {
        let ux = Double(a.x - vertex.x), uy = Double(a.y - vertex.y)
        let vx = Double(c.x - vertex.x), vy = Double(c.y - vertex.y)
        let lengthU = (ux * ux + uy * uy).squareRoot()
        let lengthV = (vx * vx + vy * vy).squareRoot()
        guard lengthU > 1e-6, lengthV > 1e-6 else { return nil }
        let cosine = max(-1, min(1, (ux * vx + uy * vy) / (lengthU * lengthV)))
        return acos(cosine) * 180 / .pi
    }

    /// Bir kolun (omuz, dirsek, bilek) güvenilir noktalarından dirsek açısı. Güven eşiğin altındaki
    /// nokta varsa nil: bulanık kare sayıma karışmaz.
    static func elbowAngle(shoulder: JointSample, elbow: JointSample, wrist: JointSample,
                           minConfidence: Double = 0.3) -> Double? {
        guard shoulder.confidence >= minConfidence, elbow.confidence >= minConfidence,
              wrist.confidence >= minConfidence else { return nil }
        return angle(a: shoulder.point, vertex: elbow.point, c: wrist.point)
    }

    /// İki kol da görünüyorsa ortalaması, biri görünüyorsa o; yan çekimde tek kol yeter.
    static func combined(_ left: Double?, _ right: Double?) -> Double? {
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }
}

/// Vision'dan gelen bir eklem: normalleştirilmiş (en-boy oranıyla düzeltilmiş) konum ve güven.
struct JointSample: Equatable {
    var point: CGPoint
    var confidence: Double
}

/// Açı dizisini şınav tekrarına çevirir. Histerezis: yukarı eşiği (varsayılan 150°) ile aşağı
/// eşiği (100°) arası ölü bölgedir; açı bu aralıkta titreyince sayı değişmez. Bir tekrar =
/// kollar önce açık (yukarı) görülür, sonra yeterince bükülür (aşağı), sonra yeniden açılır.
/// Aşağıda başlayan kullanıcı ilk açılışta sayılmaz (yukarıyı görmeden tekrar yok).
struct PushupCounter: Equatable {
    enum Phase: Equatable { case unknown, up, down }

    let downThreshold: Double
    let upThreshold: Double
    let smoothing: Int
    private(set) var phase: Phase = .unknown
    private(set) var count = 0
    private var window: [Double] = []

    init(downThreshold: Double = 100, upThreshold: Double = 150, smoothing: Int = 3) {
        // Eşikler ters ya da aynıysa histerezis olmaz; güvenli varsayılana dön.
        if downThreshold < upThreshold {
            self.downThreshold = downThreshold
            self.upThreshold = upThreshold
        } else {
            self.downThreshold = 100
            self.upThreshold = 150
        }
        self.smoothing = max(1, smoothing)
    }

    /// Yeni açıyı işler (nil = bu karede kol görünmedi, yok sayılır). Bir tekrar tamamlandıysa true.
    @discardableResult
    mutating func feed(_ angle: Double?) -> Bool {
        guard let angle, angle.isFinite else { return false }
        window.append(angle)
        if window.count > smoothing { window.removeFirst(window.count - smoothing) }
        let value = window.reduce(0, +) / Double(window.count)
        switch phase {
        case .unknown:
            if value >= upThreshold { phase = .up }
        case .up:
            if value <= downThreshold { phase = .down }
        case .down:
            if value >= upThreshold {
                phase = .up
                count += 1
                return true
            }
        }
        return false
    }

    mutating func reset() {
        phase = .unknown
        count = 0
        window.removeAll()
    }

    /// Ekranda yazan yönerge: "kollarını aç", "in", "kalk".
    var hint: String {
        switch phase {
        case .unknown: return "Kollarını tamamen aç"
        case .up: return "Aşağı in"
        case .down: return "Yukarı it"
        }
    }
}
