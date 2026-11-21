import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Paylaş menüsündeki "Junior": paylaşılan bağlantı ya da metni bilgisayardaki Junior'a
/// gönderir (Özetle / Araştır / Hafızaya kaydet). Eklenti küçük kalır: ağ isteği tek, 30 sn.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(context: extensionContext)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.loadItems() }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case sending(ShareAction)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var sharedURL: URL?
    @Published private(set) var sharedText: String?

    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    var preview: String {
        ShareRequest.content(url: sharedURL, text: sharedText) ?? ""
    }

    /// Paylaşılan öğelerden ilk bağlantıyı ve metni alır.
    func loadItems() async {
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if sharedText == nil, let title = item.attributedContentText?.string,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sharedText = title
            }
            for provider in item.attachments ?? [] {
                if sharedURL == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                    if let url = loaded as? URL {
                        sharedURL = url
                    } else if let data = loaded as? Data {
                        sharedURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let raw = loaded as? String {
                        sharedURL = URL(string: raw)
                    }
                }
                if sharedText == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                    if let text = loaded as? String {
                        sharedText = text
                    } else if let data = loaded as? Data {
                        sharedText = String(data: data, encoding: .utf8)
                    }
                }
            }
        }
        // Dosya bağlantısı (file://) paylaşılmaz: bilgisayar telefondaki dosyayı okuyamaz.
        if let url = sharedURL, url.isFileURL { sharedURL = nil }
        phase = preview.isEmpty ? .failed("Paylaşılan bir bağlantı ya da metin bulunamadı.") : .ready
    }

    func send(_ action: ShareAction) {
        guard let request = ShareRequest.make(action: action, url: sharedURL, text: sharedText) else {
            phase = .failed("Paylaşılan bir bağlantı ya da metin bulunamadı.")
            return
        }
        guard let credentials = SharedCredentials.read(),
              let url = ShareRequest.endpoint(base: credentials.baseURL, path: request.path) else {
            // Kopya yoksa iki neden olabilir: eşleştirilmemiş, ya da imzalama ortak grubu vermemiş
            // (imzasız CI derlemesi + SideStore/AltStore). İkincisinde "yeniden eşleştir" yanlış yön.
            phase = .failed(ShareRequest.missingCredentialsText(groupAvailable: SharedCredentials.sharedGroupAvailable()))
            return
        }
        phase = .sending(action)
        Task {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 30
            urlRequest.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: request.json)
            do {
                let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let failure = ShareRequest.failureText(status: status, data: data) {
                    phase = .failed(failure)
                    return
                }
                phase = .done(action.successText)
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                close()
            } catch {
                phase = .failed("Bilgisayara ulaşılamıyor. Bilgisayar ve tünel açık mı?")
            }
        }
    }

    func close() {
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: "xyz.jrbilge.junior.share", code: NSUserCancelledError))
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    private let cyan = Color(red: 0.36, green: 0.84, blue: 1.0)
    private let red = Color(red: 0.96, green: 0.31, blue: 0.37)
    private let green = Color(red: 0.20, green: 0.83, blue: 0.60)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(cyan)
                        .frame(width: 44, height: 44)
                        .background(cyan.opacity(0.14), in: Circle())
                    Text("Junior'a gönder").font(.title3.weight(.bold))
                    Spacer()
                }
                if !model.preview.isEmpty {
                    Text(model.preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                ForEach(ShareAction.allCases) { action in
                    Button { model.send(action) } label: {
                        HStack {
                            Label(action.title, systemImage: action.symbol)
                            Spacer()
                            if model.phase == .sending(action) { ProgressView() }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                status
                Spacer()
            }
            .padding(16)
            .navigationTitle("Junior")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { model.cancel() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var canSend: Bool {
        switch model.phase {
        case .ready, .failed: return !model.preview.isEmpty
        default: return false
        }
    }

    /// Eklenti küçük kalsın diye noktalı kedi (ActivityKit'e bağlı paylaşılan dosyalar) yerine simge.
    private var statusSymbol: String {
        switch model.phase {
        case .loading, .ready: return "square.and.arrow.up"
        case .sending: return "ellipsis"
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .loading:
            ProgressView("Paylaşılan okunuyor…")
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(green).font(.footnote)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(red).font(.footnote)
        default:
            EmptyView()
        }
    }
}
