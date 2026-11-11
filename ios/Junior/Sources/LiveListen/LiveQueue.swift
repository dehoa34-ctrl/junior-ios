import Foundation

/// Diskte yüklenmeyi bekleyen tek konuşma parçası.
struct LiveQueueItem: Equatable, Codable {
    let id: String
    let t0: Int64
    let t1: Int64
    let rms: Double?
    /// "m4a" ya da "wav".
    let ext: String
    let bytes: Int

    var contentType: String { ext == "wav" ? "audio/wav" : "audio/mp4" }
}

/// Kuyruğun taşma kuralı; diske dokunmaz.
enum LiveQueuePolicy {
    /// Toplam boyut `capBytes`'ı aşıyorsa **en eskiden** başlayarak atılacak parçalar.
    /// Yeni konuşma eskisinden değerlidir: bilgisayar günlerce kapalı kaldıysa
    /// bile son günler kurtarılır.
    static func overflow(_ items: [LiveQueueItem], capBytes: Int) -> [LiveQueueItem] {
        var total = items.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        var dropped: [LiveQueueItem] = []
        for item in items.sorted(by: { $0.t0 < $1.t0 }) {
            guard total > capBytes else { break }
            dropped.append(item)
            total -= item.bytes
        }
        return dropped
    }
}

/// Bilgisayara gidecek konuşma parçalarının kalıcı kuyruğu.
///
/// Her parça iki dosyadır: `<id>.m4a|wav` (ses) ve `<id>.json` (üst veri). Üst
/// veri **en son** yazılır; yarım kalmış bir yazma (uygulama öldürüldü) json'suz
/// bir ses dosyası bırakır ve açılışta temizlenir. Böylece kuyrukta hiçbir
/// zaman yarım parça görünmez.
///
/// Uygulama kapanıp açılınca kuyruk diskten yüklenir; bilgisayar kapalıyken
/// biriken konuşma kaybolmaz. Boyut sınırı aşılırsa en eski parçalar atılır.
final class LiveQueue: @unchecked Sendable {
    static let defaultCapBytes = 1_500_000_000

    private let directory: URL
    private let capBytes: Int
    private let lock = NSLock()
    private var index: [LiveQueueItem] = []
    private var total = 0

    init(directory: URL, capBytes: Int = LiveQueue.defaultCapBytes) {
        self.directory = directory
        self.capBytes = capBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    /// Application Support/LiveQueue. Yedeğe (iCloud) girmesin diye hariç tutulur.
    static func standard() -> LiveQueue {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = base.appendingPathComponent("LiveQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return LiveQueue(directory: directory)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return index.count }
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return total }

    /// Yüklenecek sıradaki (en eski) parça.
    func first() -> LiveQueueItem? {
        lock.lock(); defer { lock.unlock() }
        return index.first
    }

    func items() -> [LiveQueueItem] {
        lock.lock(); defer { lock.unlock() }
        return index
    }

    func audioURL(_ item: LiveQueueItem) -> URL {
        directory.appendingPathComponent("\(item.id).\(item.ext)")
    }

    /// Parçayı diske yazar. Dönüş: kuyruğa giren parça ve boyut sınırı yüzünden atılan parça sayısı.
    @discardableResult
    func enqueue(id: String, audio: Data, ext: String, t0: Int64, t1: Int64, rms: Double?) -> (item: LiveQueueItem, dropped: Int)? {
        guard !audio.isEmpty, !id.isEmpty else { return nil }
        let item = LiveQueueItem(id: id, t0: t0, t1: max(t1, t0 + 1), rms: rms, ext: ext, bytes: audio.count)
        let audioFile = audioURL(item)
        let metaFile = directory.appendingPathComponent("\(id).json")
        do {
            try audio.write(to: audioFile, options: .atomic)
            let meta = try JSONEncoder().encode(item)
            try meta.write(to: metaFile, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: audioFile)
            try? FileManager.default.removeItem(at: metaFile)
            return nil
        }
        lock.lock()
        index.removeAll { $0.id == id }
        index.append(item)
        index.sort { $0.t0 < $1.t0 }
        total = index.reduce(0) { $0 + $1.bytes }
        let overflow = LiveQueuePolicy.overflow(index, capBytes: capBytes)
        let dropIDs = Set(overflow.map(\.id))
        if !dropIDs.isEmpty {
            index.removeAll { dropIDs.contains($0.id) }
            total = index.reduce(0) { $0 + $1.bytes }
        }
        lock.unlock()
        for old in overflow { deleteFiles(old) }
        return (item, overflow.count)
    }

    /// Yüklendi ya da kabul edilmez bulundu: diskten ve dizinden kaldırır.
    func remove(_ item: LiveQueueItem) {
        lock.lock()
        index.removeAll { $0.id == item.id }
        total = index.reduce(0) { $0 + $1.bytes }
        lock.unlock()
        deleteFiles(item)
    }

    private func deleteFiles(_ item: LiveQueueItem) {
        // Önce json: yarım silme "ses var, üst veri yok" bırakır ve açılışta temizlenir.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(item.id).json"))
        try? FileManager.default.removeItem(at: audioURL(item))
    }

    private func load() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        var loaded: [LiveQueueItem] = []
        var known = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let metaURL = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: metaURL),
                  let item = try? JSONDecoder().decode(LiveQueueItem.self, from: data),
                  manager.fileExists(atPath: audioURL(item).path) else {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
                continue
            }
            loaded.append(item)
            known.insert("\(item.id).\(item.ext)")
        }
        // Üst verisi olmayan ses dosyaları yarım yazmadır.
        for name in names where !name.hasSuffix(".json") && !known.contains(name) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        lock.lock()
        index = loaded.sorted { $0.t0 < $1.t0 }
        total = index.reduce(0) { $0 + $1.bytes }
        lock.unlock()
    }
}
