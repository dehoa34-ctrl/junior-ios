import AVFoundation
import Combine
import Foundation
import UIKit

/// Telefonda sürekli dinleme: mikrofondan konuşmayı kesip kuyruğa yazar ve
/// bilgisayara yükler.
///
/// Akış: `MicrophoneHub` (tek ses motoru) → `LiveTap` (16 kHz'e çevirir,
/// `SpeechSegmenter` ile konuşmayı keser, AAC'ye kodlar) → `LiveQueue` (disk) →
/// bu sınıfın yükleyicisi (`POST /v1/live/segment`). Yazıya çevirme, konuşmacı
/// ayrımı ve arşiv bilgisayarda yapılır; telefon yalnız kaydeder ve taşır.
///
/// Arka planda/kilitli ekranda çalışması mevcut `audio` arka plan kipine
/// dayanır (uyandırma sözcüğüyle aynı). iOS çağrı/Siri gibi durumlarda
/// mikrofonu keser; `MicrophoneHub` bitince geri açar ve durum "kesintide"
/// olarak görünür.
@MainActor
final class LiveListenService: ObservableObject {
    enum State: Equatable {
        case off
        case recording
        /// Kullanıcı duraklattı.
        case paused
        /// Açık ama mikrofon şu an kesintide (çağrı, Siri, ses yolu değişimi).
        case interrupted
        case needsPermission
    }

    static let pausedKey = "junior.phoneLivePaused"

    @Published private(set) var state: State = .off
    @Published private(set) var queueCount = 0
    @Published private(set) var queueBytes = 0
    @Published private(set) var lastUpload: Date?
    @Published private(set) var uploadedCount = 0
    /// Bilgisayara son ulaşma denemesinin sonucu; nil = henüz denenmedi.
    @Published private(set) var serverReachable: Bool?
    /// Kullanıcıya gösterilecek uyarı (kuyruk doldu, belirteç geçersiz …).
    @Published private(set) var warning: String?
    @Published private(set) var droppedCount = 0

    private let config: Config
    private let speech: SpeechService
    private let queue: LiveQueue
    private let client = JuniorClient()
    private var tap: LiveTap?
    private var loop: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var backoff = UploadBackoff()
    private(set) var isDemo = false

    var paused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pausedKey)
            sync()
        }
    }

    init(config: Config, speech: SpeechService, queue: LiveQueue = LiveQueue.standard()) {
        self.config = config
        self.speech = speech
        self.queue = queue
        refreshCounts()
        // Junior konuşurken kendi sesi kaydedilmesin.
        speech.$state
            .removeDuplicates()
            .sink { [weak self] value in self?.tap?.setSuppressed(value == .speaking) }
            .store(in: &cancellables)
    }

    var isEnabled: Bool { config.phoneLiveEnabled }

    // MARK: - Durum

    /// Ayarlar ya da duraklatma değişince, açılışta ve öne dönünce çağrılır.
    func sync() {
        guard !isDemo else { return }
        startUploaderIfNeeded()
        guard config.phoneLiveEnabled else {
            stopRecording()
            state = .off
            return
        }
        if paused {
            stopRecording()
            state = .paused
            return
        }
        Task { await startRecording() }
    }

    func togglePause() {
        paused.toggle()
    }

    private func startRecording() async {
        guard tap == nil else { updateState(); return }
        let allowed = await Self.microphoneGranted()
        // İzin sorulurken kullanıcı kapatmış/duraklatmış olabilir.
        guard config.phoneLiveEnabled, !paused, tap == nil else { return }
        guard allowed else {
            state = .needsPermission
            return
        }
        let newTap = LiveTap { [weak self] segment, data, ext in
            self?.store(segment: segment, data: data, ext: ext)
        }
        do {
            try MicrophoneHub.shared.enableLive(newTap)
        } catch {
            // Hub kendini toparlayıp yeniden deneyecek; tüketici yine de bağlı kalır.
        }
        tap = newTap
        newTap.setSuppressed(speech.state == .speaking)
        updateState()
    }

    private func stopRecording() {
        guard let tap else { return }
        MicrophoneHub.shared.disableLive()
        tap.flush()
        self.tap = nil
    }

    private func updateState() {
        guard config.phoneLiveEnabled else { state = .off; return }
        if paused { state = .paused; return }
        guard tap != nil else { return }
        state = MicrophoneHub.shared.isRunning ? .recording : .interrupted
    }

    private static func microphoneGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: - Kuyruk

    /// Kodlayıcı kuyruğundan çağrılır (ana iş parçacığı değil).
    private nonisolated func store(segment: LiveSegment, data: Data, ext: String) {
        let id = LiveUpload.makeID(t0: segment.t0)
        let result = queue.enqueue(id: id, audio: data, ext: ext, t0: segment.t0, t1: segment.t1, rms: segment.rms)
        guard let result else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if result.dropped > 0 {
                self.droppedCount += result.dropped
                self.warning = "Kuyruk doldu: bilgisayara ulaşılamadığı için en eski \(self.droppedCount) konuşma silindi."
            }
            self.refreshCounts()
        }
    }

    private func refreshCounts() {
        queueCount = queue.count
        queueBytes = queue.totalBytes
    }

    // MARK: - Yükleyici

    private func startUploaderIfNeeded() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waitFor = await self.uploadStep()
                try? await Task.sleep(nanoseconds: UInt64(waitFor * 1_000_000_000))
            }
        }
    }

    /// Tek adım: varsa en eski parçayı yükler. Dönüş: bir sonraki adıma kadar beklenecek süre.
    private func uploadStep() async -> TimeInterval {
        updateState()
        refreshCounts()
        guard let item = queue.first() else {
            return 3
        }
        guard let healthURL = config.url(path: "/health"),
              let uploadURL = config.url(path: LiveUpload.path),
              let token = config.token, !token.isEmpty else {
            return 30
        }
        // Bilgisayar kapalıyken parça başına uzun zaman aşımı beklemeyelim.
        let up = await client.isReachable(url: healthURL)
        serverReachable = up
        guard up else {
            backoff.failed()
            return backoff.delay
        }
        let task = UIApplication.shared.beginBackgroundTask(withName: "junior-live-upload")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }

        let request = LiveUpload.request(url: uploadURL, token: token, item: item)
        let status = await client.uploadFile(request, file: queue.audioURL(item))
        let outcome: LiveUploadOutcome = status.map(LiveUpload.classify(status:)) ?? .retry
        switch outcome {
        case .accepted:
            queue.remove(item)
            backoff.succeeded()
            lastUpload = Date()
            uploadedCount += 1
            if warning?.hasPrefix("Belirteç") == true { warning = nil }
            refreshCounts()
            return 0.05
        case .reject:
            // Sunucu bu parçayı asla kabul etmeyecek; tutmak kuyruğu tıkar.
            queue.remove(item)
            refreshCounts()
            return 0.05
        case .unauthorized:
            warning = "Belirteç bilgisayarda kabul edilmedi. Ayarlar'dan yeniden eşleştir."
            backoff.failed()
            return max(30, backoff.delay)
        case .retry:
            backoff.failed()
            return backoff.delay
        }
    }

    func dismissWarning() { warning = nil }

    // MARK: - Metinler

    var statusTitle: String {
        switch state {
        case .off: return "Kapalı"
        case .recording: return "Dinliyor"
        case .paused: return "Duraklatıldı"
        case .interrupted: return "Mikrofon kesintide"
        case .needsPermission: return "Mikrofon izni yok"
        }
    }

    var statusDetail: String? {
        switch state {
        case .interrupted: return "Çağrı, Siri ya da başka bir uygulama mikrofonu tutuyor; bitince kendiliğinden devam eder."
        case .needsPermission: return "Ayarlar > Junior > Mikrofon izni ver."
        default: return nil
        }
    }

    var queueSummary: String {
        guard queueCount > 0 else { return "Bekleyen yok" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(queueBytes), countStyle: .file)
        return "\(queueCount) konuşma · \(size)"
    }

    var lastUploadSummary: String {
        guard let lastUpload else { return "Henüz yok" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastUpload, relativeTo: Date())
    }

    #if DEBUG
    /// Ekran görüntüsü için: mikrofon açmadan örnek durum gösterir.
    func loadDemo() {
        isDemo = true
        state = .recording
        queueCount = 3
        queueBytes = 412_000
        lastUpload = Date().addingTimeInterval(-42)
        uploadedCount = 18
        serverReachable = true
    }
    #endif
}
