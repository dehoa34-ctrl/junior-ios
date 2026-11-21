import SwiftUI
import UIKit

/// Panodaki metne "Düzelt": yazım ve dilbilgisi; kod görünüyorsa hata düzeltme. Saf mantık.
///
/// İstek sunucunun sohbet ucuna (`POST /v1/chat`) gider: komut sözlüğünden geçmez, uzak iş
/// başlatmaz. Sonuç ekranda gösterilir; "Kopyala" ile panoya konur, sohbete yazılmaz.
enum ClipboardFix {
    /// Panodaki metin kod gibi görünüyor mu (kaba sezgi: ayraçlar, anahtar sözcükler, girinti).
    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") { return true }
        let markers = ["{", "}", ");", "=>", "->", "();", "</", "/>", "#include", "import ", "def ", "func ",
                       "function ", "const ", "let ", "var ", "class ", "return ", "SELECT ", "public ", "==", "!="]
        let hits = markers.filter { text.contains($0) }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        return hits >= 3 || (hits >= 2 && indented >= 1) || (hits >= 1 && lines.count >= 3 && indented * 2 >= lines.count)
    }

    /// Sunucuya gidecek istem. Yanıtın yalnız düzeltilmiş metin olması istenir.
    static func prompt(for raw: String) -> String {
        let clip = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ClipboardAsk.maxClipChars))
        if looksLikeCode(clip) {
            return "Aşağıdaki koddaki hataları düzelt (sözdizimi, mantık, yazım). Yalnız düzeltilmiş kodu ver; "
                + "açıklama, giriş ya da kapanış cümlesi yazma.\n\n\(clip)"
        }
        return "Aşağıdaki metnin yazım ve dilbilgisi hatalarını düzelt. Anlamı, dili ve üslubu değiştirme. "
            + "Yalnız düzeltilmiş metni ver; açıklama, giriş ya da tırnak ekleme.\n\n\(clip)"
    }

    /// Sunucu yanıtından kopyalanacak metin: boşluklar ve tek parça kod çiti (```) atılır.
    static func clean(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()          // ```swift gibi açılış satırı
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// `POST /v1/chat` yanıtındaki `reply`; yoksa nil.
    static func parseReply(_ data: Data) -> String? {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reply = parsed["reply"] as? String else { return nil }
        let cleaned = clean(reply)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// "Düzelt" sonucunu açan sayfanın isteği.
struct ClipboardFixRequest: Identifiable, Equatable {
    let id = UUID()
    let prompt: String
}

@MainActor
final class ClipboardFixModel: ObservableObject {
    enum State: Equatable {
        case working
        case done(String)
        case failed(String)
    }

    @Published private(set) var state: State = .working
    @Published private(set) var copied = false

    private let config: Config
    private let client = JuniorClient()

    init(config: Config) {
        self.config = config
    }

    func run(prompt: String) async {
        state = .working
        copied = false
        do {
            guard let token = config.token, !token.isEmpty else { throw JuniorError.notConfigured }
            guard let url = config.url(path: "/v1/chat") else { throw JuniorError.badAddress }
            let data = try await client.json(method: "POST", url: url, token: token,
                                             body: ["message": prompt], timeout: 90)
            guard let text = ClipboardFix.parseReply(data) else { throw JuniorError.server("Düzeltilmiş metin alınamadı.") }
            state = .done(text)
        } catch {
            state = .failed(RoutinesModel.describe(error))
        }
    }

    func copy() {
        guard case .done(let text) = state else { return }
        UIPasteboard.general.string = text
        copied = true
    }
}

/// Düzeltilmiş metni gösterir; "Kopyala" panoya koyar.
struct ClipboardFixSheet: View {
    let request: ClipboardFixRequest
    @StateObject private var model: ClipboardFixModel
    @Environment(\.dismiss) private var dismiss

    init(request: ClipboardFixRequest, config: Config) {
        self.request = request
        _model = StateObject(wrappedValue: ClipboardFixModel(config: config))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .working:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Düzeltiliyor…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done(let text):
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                case .failed(let message):
                    VStack(spacing: 12) {
                        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Yeniden dene") { Task { await model.run(prompt: request.prompt) } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Düzelt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if case .done = model.state {
                        Button(model.copied ? "Kopyalandı" : "Kopyala") { model.copy() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.run(prompt: request.prompt) }
    }
}
