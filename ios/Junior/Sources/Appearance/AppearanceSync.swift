import SwiftUI
import UIKit

/// Masaüstündeki Görünüm ayarının (vurgu rengi, kedi yüzü, tema) sunucudaki kaydı.
/// Saf mantık: sunucu sözleşmesi `mobile_api/appearance.py`, masaüstü tarafı `shared/appearanceSync.ts`.
struct AppearanceRecord: Equatable {
    var accent = ""
    var catFace = false
    var theme = "dark"
    /// Son yazmanın zamanı (ms); 0: kayıt hiç yazılmamış.
    var updatedAt: Int64 = 0
    var source = ""
    /// Sunucuda hiç yazılmamış alanlar ("accent", "cat_face", "theme"); değerleri varsayılandır, uygulanmaz.
    var unset: [String] = []

    /// `GET/POST /v1/appearance` yanıtı: `{"appearance": {...}}`.
    static func parse(_ data: Data) -> AppearanceRecord? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["appearance"] as? [String: Any] else { return nil }
        var record = AppearanceRecord()
        if let accent = raw["accent"] as? String, let hex = normalizeHex(accent) { record.accent = hex }
        record.catFace = raw["cat_face"] as? Bool ?? false
        if let theme = raw["theme"] as? String, ["dark", "light", "system"].contains(theme) { record.theme = theme }
        if let stamp = (raw["updated_at"] as? NSNumber)?.int64Value, stamp > 0 { record.updatedAt = stamp }
        if let source = raw["source"] as? String, source == "desktop" || source == "phone" { record.source = source }
        if let unset = raw["unset"] as? [String] { record.unset = unset.filter { ["accent", "cat_face", "theme"].contains($0) } }
        return record
    }

    /// "#abc", "ABCDEF" → "#aabbcc"; geçersizse (boş dize dahil) nil.
    static func normalizeHex(_ raw: String) -> String? {
        var digits = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 else { return nil }
        return "#" + digits
    }

    /// #rrggbb → 0...1 aralığında bileşenler.
    static func components(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let normal = normalizeHex(hex), let value = UInt32(normal.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func hex(r: Double, g: Double, b: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

enum AppearanceSyncLogic {
    /// Koyu zeminde okunur kalması için en düşük göreli parlaklık.
    static let minLuminance = 0.28

    /// Sunucudaki kayıt bu telefonun bildiğinden yeniyse uygulanır; kayıt hiç yazılmadıysa dokunulmaz.
    static func shouldApply(server: AppearanceRecord, known: Int64) -> Bool {
        server.updatedAt > 0 && server.updatedAt > known
    }

    /// Yerel kayıt kurulurken değiştirilmeyen kedi yüzü değeri: eşzamanlama olmadıysa ekranda görünen
    /// (ifadeli) değer korunur; yalnız vurgu rengi değişince kedi sessizce "sade"ye dönmesin.
    static func baseCatFace(synced: Bool, catFace: Bool) -> Bool { synced ? catFace : true }

    /// Sunucu kaydındaki yazılmamış alanlar yerel değerle korunur; yazılmışlar sunucudan alınır.
    static func resolved(server: AppearanceRecord, accent: String, catFace: Bool) -> AppearanceRecord {
        var record = server
        if server.unset.contains("accent") { record.accent = accent }
        if server.unset.contains("cat_face") { record.catFace = catFace }
        return record
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Telefonda değiştirilen alanlar ve zaman damgası. Verilmeyen alan (örn. tema) yazılmaz;
    /// masaüstünün ayarı ezilmesin.
    static func pushBody(accent: String?, catFace: Bool?, now: Date) -> [String: Any] {
        var body: [String: Any] = ["updated_at": millis(now), "source": "phone"]
        if let accent { body["accent"] = AppearanceRecord.normalizeHex(accent) ?? "" }
        if let catFace { body["cat_face"] = catFace }
        return body
    }

    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Çok koyu vurgu koyu zeminde görünmez olur: yeterince parlayana dek beyaza doğru karıştırılır.
    static func readable(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        var color = (r: r, g: g, b: b)
        var step = 0
        while luminance(r: color.r, g: color.g, b: color.b) < minLuminance, step < 20 {
            color = (color.r + (1 - color.r) * 0.1, color.g + (1 - color.g) * 0.1, color.b + (1 - color.b) * 0.1)
            step += 1
        }
        return color
    }
}

/// Sunucuya henüz yazılmamış telefon değişiklikleri. Yazma başarısız olursa geri konur, yeniden denenir.
struct AppearancePending: Equatable {
    var accent: String?
    var catFace: Bool?

    var isEmpty: Bool { accent == nil && catFace == nil }

    /// Başarısız gönderimi geri koyar; bu arada daha yeni bir değer girilmişse o kalır.
    mutating func restore(_ failed: AppearancePending) {
        if accent == nil { accent = failed.accent }
        if catFace == nil { catFace = failed.catFace }
    }
}

/// Telefonun vurgu rengi ve kedi yüzü tercihi; masaüstüyle son yazan kazanır.
/// Tema değeri telefonda uygulanmaz (arayüz koyu tasarlandı); masaüstününki sunucuda olduğu gibi kalır.
@MainActor
final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()

    /// #rrggbb; boşsa varsayılan camgöbeği.
    @Published private(set) var accent: String
    @Published private(set) var catFace: Bool
    /// Bir kez sunucudan alındı ya da burada ayarlandı mı; değilse kedi eski (ifadeli) davranışta kalır.
    @Published private(set) var synced: Bool

    private var known: Int64
    private let defaults: UserDefaults
    private let client = JuniorClient()

    private enum Key {
        static let accent = "appearance.accent"
        static let catFace = "appearance.catFace"
        static let synced = "appearance.synced"
        static let known = "appearance.known"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = defaults.string(forKey: Key.accent) ?? ""
        catFace = defaults.bool(forKey: Key.catFace)
        synced = defaults.bool(forKey: Key.synced)
        known = Int64(defaults.integer(forKey: Key.known))
    }

    var tint: Color {
        guard let c = AppearanceRecord.components(hex: accent) else { return JuniorTheme.cyan }
        let r = AppearanceSyncLogic.readable(r: c.r, g: c.g, b: c.b)
        return Color(red: r.r, green: r.g, blue: r.b)
    }

    /// Kedi yüz ifadesi gösterir mi: eşzamanlama olmadıysa evet (eski davranış), olduysa masaüstü ayarı.
    var expressiveCat: Bool { synced ? catFace : true }

    /// Ayar ekranındaki renk seçici için.
    var pickerColor: Color { tint }

    private func store(_ record: AppearanceRecord) {
        accent = record.accent
        catFace = record.catFace
        synced = true
        known = max(known, record.updatedAt)
        defaults.set(accent, forKey: Key.accent)
        defaults.set(catFace, forKey: Key.catFace)
        defaults.set(true, forKey: Key.synced)
        defaults.set(Int(known), forKey: Key.known)
    }

    private func endpoint(_ config: Config) -> (URL, String)? {
        guard let token = config.token, !token.isEmpty, let url = config.url(path: "/v1/appearance") else { return nil }
        return (url, token)
    }

    /// Sunucudaki kaydı okur; daha yeniyse uygular. Ağ yoksa sessizce vazgeçer.
    func pull(config: Config) async {
        guard let (url, token) = endpoint(config),
              let data = try? await client.json(method: "GET", url: url, token: token, timeout: 8),
              let record = AppearanceRecord.parse(data) else { return }
        // Gönderilmemiş yerel değişiklik varken sunucu kaydı onu ezmesin; önce yazılır.
        guard pending.isEmpty else { return }
        if AppearanceSyncLogic.shouldApply(server: record, known: known) {
            store(AppearanceSyncLogic.resolved(server: record, accent: accent, catFace: expressiveCat))
        }
    }

    /// Ekran açıkken yarım dakikada bir sunucuya bakar (masaüstü 20 sn'de bir bakar).
    func keepSynced(config: Config) async {
        while !Task.isCancelled {
            if !pending.isEmpty { await push(config: config) }
            await pull(config: config)
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    func setAccent(_ hex: String, config: Config) async {
        let normal = AppearanceRecord.normalizeHex(hex) ?? ""
        guard normal != accent else { return }
        await write(accent: normal, catFace: nil, config: config)
    }

    func setCatFace(_ on: Bool, config: Config) async {
        guard on != catFace || !synced else { return }
        await write(accent: nil, catFace: on, config: config)
    }

    /// Önce yerelde uygular, sonra sunucuya yazar. Sunucu daha yeni bir kayıt tutuyorsa onu alır.
    private func write(accent newAccent: String?, catFace newCatFace: Bool?, config: Config) async {
        var local = AppearanceRecord(accent: newAccent ?? accent,
                                     catFace: newCatFace ?? AppearanceSyncLogic.baseCatFace(synced: synced, catFace: catFace))
        local.updatedAt = AppearanceSyncLogic.millis(Date())
        store(local)
        // Renk seçici sürüklenirken art arda değişir: yazma kısa bir bekleyişten sonra, tek istekle.
        if let newAccent { pending.accent = newAccent }
        if let newCatFace { pending.catFace = newCatFace }
        pushTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.push(config: config)
        }
        pushTask = task
        await task.value
    }

    private var pending = AppearancePending()
    private var pushTask: Task<Void, Never>?

    private func push(config: Config) async {
        let sent = pending
        guard !sent.isEmpty else { return }
        let body = AppearanceSyncLogic.pushBody(accent: sent.accent, catFace: sent.catFace, now: Date())
        pending = AppearancePending()
        guard let (url, token) = endpoint(config),
              let data = try? await client.json(method: "POST", url: url, token: token, body: body, timeout: 8) else {
            // Ağ yok ya da sunucu hata verdi: değişiklikler geri konur, keepSynced yeniden dener.
            pending.restore(sent)
            return
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              parsed["applied"] as? Bool == false,
              let record = AppearanceRecord.parse(data) else { return }
        // Masaüstü bu arada daha yeni bir değişiklik yazmış: o kazanır.
        known = 0
        store(AppearanceSyncLogic.resolved(server: record, accent: accent, catFace: expressiveCat))
    }
}

/// Ayarlar > Görünüm: vurgu rengi ve kedi yüzü; masaüstüyle ortak.
struct AppearanceSettingsSection: View {
    @ObservedObject var config: Config
    @ObservedObject private var appearance = AppearanceModel.shared

    var body: some View {
        Section {
            ColorPicker(selection: accentBinding, supportsOpacity: false) {
                Label { Text("Vurgu rengi") } icon: { SettingIcon(systemName: "paintpalette.fill", color: appearance.tint) }
            }
            if !appearance.accent.isEmpty {
                Button("Varsayılan renge dön") { Task { await appearance.setAccent("", config: config) } }
            }
            Toggle(isOn: catFaceBinding) {
                Label { Text("İfadeli kedi yüzü") } icon: { SettingIcon(systemName: "face.smiling", color: JuniorTheme.orange) }
            }
        } header: {
            Text("Görünüm")
        } footer: {
            Text("Vurgu rengi ve kedi yüzü bilgisayardaki Junior ile ortaktır; en son değiştirdiğin geçerli olur.")
        }
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { appearance.pickerColor },
            set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                let hex = AppearanceRecord.hex(r: Double(r), g: Double(g), b: Double(b))
                Task { await appearance.setAccent(hex, config: config) }
            })
    }

    private var catFaceBinding: Binding<Bool> {
        Binding(get: { appearance.expressiveCat },
                set: { on in Task { await appearance.setCatFace(on, config: config) } })
    }
}
