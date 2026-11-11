import Foundation

/// Yükleme yeniden deneme beklemesi. Saf mantık; saat ya da ağ yok.
///
/// Bilgisayar kapalıyken telefon her 3 saniyede sunucuyu yoklamasın: bekleme
/// 5 sn ile başlar, her başarısızlıkta ikiye katlanır, 5 dakikada durur. Bir
/// yükleme başarılı olunca sıfırlanır.
struct UploadBackoff: Equatable {
    static let base: TimeInterval = 5
    static let cap: TimeInterval = 300

    private(set) var failures = 0

    var delay: TimeInterval {
        guard failures > 0 else { return 0 }
        return min(Self.cap, Self.base * pow(2, Double(min(failures - 1, 10))))
    }

    mutating func failed() { failures += 1 }
    mutating func succeeded() { failures = 0 }
}

/// Sunucu yanıtının ne anlama geldiği.
enum LiveUploadOutcome: Equatable {
    /// Kabul edildi (tekrar gönderim de dahil): parça silinebilir.
    case accepted
    /// Geçici sorun (ağ, 5xx, hız sınırı): sonra yeniden dene.
    case retry
    /// Sunucu parçayı kesinlikle kabul etmeyecek (bozuk, çok büyük): atılır, yoksa kuyruk sonsuza kadar tıkanır.
    case reject
    /// Belirteç geçersiz: kullanıcı düzeltene dek yavaş dene.
    case unauthorized
    /// Uç nokta yok (404/405): bilgisayardaki Junior sunucusu eski. Yavaş dene ve uyar.
    case unsupported
}

enum LiveUpload {
    static let path = "/v1/live/segment"

    /// Sunucu kimlik uzunluğu 16–100 karakter ister. "ph-<t0>-<8 hex>" = 25 karakter.
    static func makeID(t0: Int64, random: String = UUID().uuidString) -> String {
        let suffix = random.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "ph-\(t0)-\(suffix)"
    }

    static func classify(status: Int) -> LiveUploadOutcome {
        switch status {
        case 200..<300: return .accepted
        case 401, 403: return .unauthorized
        case 404, 405: return .unsupported
        case 400, 413, 415, 422: return .reject
        default: return .retry
        }
    }

    /// Sözleşmedeki başlıklarla istek. Gövde ayrıca `upload(for:fromFile:)` ile verilir.
    static func request(url: URL, token: String, item: LiveQueueItem) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(item.id, forHTTPHeaderField: "X-Live-Id")
        request.setValue(String(item.t0), forHTTPHeaderField: "X-Live-T0")
        // T1 > T0 ve süre <= 60 sn: sunucu bunu doğrular, bozuk saat yüzünden parça reddedilmesin.
        let t1 = min(max(item.t1, item.t0 + 1), item.t0 + 60_000)
        request.setValue(String(t1), forHTTPHeaderField: "X-Live-T1")
        if let rms = item.rms {
            request.setValue(String(format: "%.4f", rms), forHTTPHeaderField: "X-Live-Rms")
        }
        request.setValue(item.contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
}
