import AVFoundation
import Foundation

/// Ayarlar'daki giriş aygıtı seçimi: iPhone mikrofonu, Bluetooth kulaklık, gözlük.
enum InputDeviceKind: String, Equatable {
    case builtIn
    case bluetoothHeadset
    case glasses
    case wiredHeadset
    case other

    var title: String {
        switch self {
        case .builtIn: return "iPhone mikrofonu"
        case .bluetoothHeadset: return "Bluetooth kulaklık"
        case .glasses: return "Gözlük"
        case .wiredHeadset: return "Kablolu kulaklık"
        case .other: return "Diğer giriş"
        }
    }

    var symbol: String {
        switch self {
        case .builtIn: return "iphone"
        case .bluetoothHeadset: return "airpods"
        case .glasses: return "eyeglasses"
        case .wiredHeadset: return "headphones"
        case .other: return "mic"
        }
    }
}

struct InputDevice: Identifiable, Equatable {
    /// AVAudioSessionPortDescription.uid: aygıt yeniden bağlansa da aynı kalır.
    let id: String
    let name: String
    let kind: InputDeviceKind

    /// Listede görünen ad: gözlük ve kulaklıkta aygıtın kendi adı da yazılır.
    var label: String {
        kind == .builtIn ? kind.title : "\(kind.title) · \(name)"
    }
}

/// Giriş aygıtlarının sınıflandırılması ve seçimi. Saf mantık; ses oturumuna dokunmaz.
enum InputDevices {
    /// Seçilen girişin kimliği (UserDefaults). Yoksa otomatik: gözlük/kulaklık varsa ondan.
    static let preferredKey = "junior.preferredInputUID"

    /// Bluetooth girişinin gözlük olduğunu ele veren ad parçaları (Ray-Ban Meta, Oakley Meta …).
    private static let glassesHints = ["ray-ban", "rayban", "ray ban", "meta", "oakley", "glasses", "gözlük", "gozluk"]

    static func kind(port: AVAudioSession.Port, name: String) -> InputDeviceKind {
        switch port {
        case .builtInMic:
            return .builtIn
        case .bluetoothHFP, .bluetoothLE:
            let folded = name.lowercased(with: Locale(identifier: "tr_TR"))
            return glassesHints.contains(where: { folded.contains($0) }) ? .glasses : .bluetoothHeadset
        case .headsetMic:
            return .wiredHeadset
        default:
            return .other
        }
    }

    static func make(uid: String, name: String, port: AVAudioSession.Port) -> InputDevice {
        InputDevice(id: uid, name: name, kind: kind(port: port, name: name))
    }

    /// Kayıtlı tercih bağlıysa o aygıt; tercih yoksa ya da aygıt şu an bağlı değilse nil
    /// (MicrophoneHub o zaman eski kuralla seçer: gözlük/kulaklık varsa ondan).
    static func choose(preferredUID: String?, available: [InputDevice]) -> InputDevice? {
        guard let preferredUID, !preferredUID.isEmpty else { return nil }
        return available.first { $0.id == preferredUID }
    }

    /// Giriş listesini okumak için ses oturumu kayıtlı kategoriye (.playAndRecord) çevrilsin mi.
    ///
    /// Yalnız kullanıcının başlattığı okumada (Ayarlar'ın açılışı, seçim, TEST) ve mikrofonu
    /// kimse tutmuyorken. Yol değişikliği bildirimindeki okuma kategoriye dokunmaz: seslendirme
    /// .playback'e geçince bir yol değişikliği doğar; orada geri çevirmek Ayarlar açıkken
    /// Junior'ın sesini konuşmanın ortasında kayıt kategorisine (alçak, A2DP'siz) düşürürdü.
    static func shouldPrepareRecordCategory(alreadyRecordCategory: Bool, microphoneWanted: Bool,
                                            userInitiated: Bool) -> Bool {
        userInitiated && !alreadyRecordCategory && !microphoneWanted
    }
}

/// Mikrofon seviyesinin hesabı. Saf mantık: TEST çubuğu ve "ses gelmiyor" kararı bundan çıkar.
enum MicLevel {
    /// Çubuğun alt sınırı (dBFS); bunun altı boş görünür.
    static let floorDB: Float = -60

    /// Örneklerin karekök ortalaması (RMS), 0…1.
    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// 16 bit tam sayı örnekler (bazı girişler bu biçimde verir).
    static func rms<C: Collection>(int16 samples: C) -> Float where C.Element == Int16 {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample) / Float(Int16.max)
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-6))
    }

    /// Çubuk için 0…1: -60 dBFS → 0, 0 dBFS → 1.
    static func normalized(rms: Float) -> Float {
        let db = decibels(rms: rms)
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
}

/// TEST'in sonucu.
enum InputTestVerdict: Equatable {
    /// Ses geldi.
    case ok(peak: Float)
    /// Mikrofon açıldı ama ses çok zayıf (konuşma duyulmadı).
    case tooQuiet(peak: Float)
    /// Girişten hiç ses verisi gelmedi (aygıt bağlı değil, izin yok, motor açılamadı).
    case noSignal

    /// Konuşma bu seviyenin üstünde görünür (~-50 dBFS).
    static let speechLevel: Float = 0.17

    static func evaluate(levels: [Float]) -> InputTestVerdict {
        guard !levels.isEmpty else { return .noSignal }
        let peak = levels.max() ?? 0
        return peak >= speechLevel ? .ok(peak: peak) : .tooQuiet(peak: peak)
    }

    /// Kullanıcıya gösterilen yönlendirici metin.
    func message(input: String) -> String {
        switch self {
        case .ok:
            return "Ses geliyor (\(input)). Junior seni bu girişten duyacak."
        case .tooQuiet:
            return "\(input) açık ama sesin çok zayıf geldi. Mikrofona yakın konuş; kulaklık ya da "
                + "gözlükse takılı ve açık olduğundan emin ol, olmazsa başka bir giriş seç."
        case .noSignal:
            return "\(input) üzerinden hiç ses gelmedi. Aygıt bağlı mı? Bluetooth'u kapatıp açmayı ya da "
                + "\"iPhone mikrofonu\"nu seçmeyi dene; Ayarlar > Gizlilik > Mikrofon'da Junior'a izin verildiğini kontrol et."
        }
    }

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// Ses iş parçacığında seviyeyi ölçen tüketici (MicrophoneHub'ın tap'ine eklenir).
/// Son dilimin seviyesi kilit altında tutulur; ana iş parçacığı okur.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Float = 0
    private var buffers = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var value: Float = 0
        if let channel = buffer.floatChannelData {
            value = MicLevel.rms(UnsafeBufferPointer(start: channel[0], count: frames))
        } else if let channel = buffer.int16ChannelData {
            value = MicLevel.rms(int16: UnsafeBufferPointer(start: channel[0], count: frames))
        }
        lock.lock()
        latest = value
        buffers += 1
        lock.unlock()
    }

    /// (son RMS, şimdiye dek gelen dilim sayısı)
    var snapshot: (rms: Float, buffers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (latest, buffers)
    }
}
