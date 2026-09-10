import SwiftUI
import PhotosUI
import UIKit

struct RootView: View {
    @ObservedObject var config: Config
    @ObservedObject var speech: SpeechService
    @StateObject private var store: ConversationStore

    @StateObject private var wakeWord = WakeWordService()
    @StateObject private var glasses = GlassesService()
    @StateObject private var handsFree: HandsFreeSession
    @State private var draft = ""
    @State private var showSettings = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photoItem: PhotosPickerItem?
    /// nil = henuz bakilmadi. false ise bilgisayar kapali ya da tunel dusuk.
    @State private var serverUp: Bool?
    @Environment(\.scenePhase) private var scenePhase

    init(config: Config, speech: SpeechService) {
        self.config = config
        self.speech = speech
        // Eller serbest dongusu bu ucunu de tutar; hepsi burada bir kez kurulur
        // ki dongunun sahibi tek bir yer olsun.
        let wakeWord = WakeWordService()
        let glasses = GlassesService()
        let store = ConversationStore(config: config, speech: speech)
        _wakeWord = StateObject(wrappedValue: wakeWord)
        _glasses = StateObject(wrappedValue: glasses)
        _store = StateObject(wrappedValue: store)
        _handsFree = StateObject(wrappedValue: HandsFreeSession(
            wakeWord: wakeWord, speech: speech, glasses: glasses, store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if serverUp == false { offlineBanner }
                if store.pendingTargetQuestion != nil { targetChooser }
                if let error = store.errorText { banner(error) }
                composer
            }
            .navigationTitle("Junior")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.clear() } label: { Image(systemName: "trash") }
                        .disabled(store.messages.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(config: config, store: store, glasses: glasses) }
            .onAppear {
                handsFree.continuousEnabled = config.continuousEnabled
                syncWakeWord()
                wireNaturalVoice()
                checkServer()
            }
            // One donunce yeniden bak: bilgisayar bu arada kapanmis olabilir.
            .onChange(of: scenePhase) { if scenePhase == .active { checkServer() } }
            .onChange(of: config.continuousEnabled) {
                handsFree.continuousEnabled = config.continuousEnabled
            }
            .onChange(of: config.wakeWordEnabled) { syncWakeWord() }
            .onChange(of: showSettings) { if !showSettings { syncWakeWord() } }
            .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) {
                guard let photoItem else { return }
                Task {
                    defer { self.photoItem = nil }
                    guard let data = try? await photoItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        store.errorText = "Fotoğraf okunamadı. Başka bir kare dene."
                        return
                    }
                    let question = draft.isEmpty ? "Bu fotoğrafta ne görüyorsun? Kısa anlat." : draft
                    draft = ""
                    store.send(text: question, image: image)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    let question = draft.isEmpty ? "Bu fotografta ne goruyorsun? Kisa anlat." : draft
                    draft = ""
                    store.send(text: question, image: image)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.messages.isEmpty { emptyState }
                    ForEach(store.messages) { message in
                        Bubble(message: message).id(message.id)
                    }
                    if store.isSending { TypingIndicator() }
                }
                .padding()
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mikrofona bas, konus.").font(.headline)
            Text("Ornekler:").font(.subheadline).foregroundStyle(.secondary)
            ForEach(["Bilgisayarda Tarkan Şımarık çal",
                     "Bilgisayarda videoyu duraklat",
                     "Bu fotoğrafta ne var? (kamera düğmesi)"], id: \.self) { example in
                Text("- " + example).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }

    private var targetChooser: some View {
        HStack(spacing: 10) {
            Text("Nerede?").font(.callout).foregroundStyle(.secondary)
            Button("Bilgisayarda") { store.answerTarget("computer") }.buttonStyle(.borderedProminent)
            Button("Telefonda") { store.answerTarget("phone") }.buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Bilgisayara ulasilamiyorsa uyarir. Junior'in yaniti oradan geldigi
    /// icin, konusmaya baslamadan once bilmek gerekiyor.
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Bilgisayara ulaşılamıyor. Junior yanıt veremez; bilgisayar ve tünel açık mı?")
                .font(.footnote)
            Spacer()
            Button("Yeniden dene") { checkServer() }.font(.footnote.weight(.semibold))
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private func checkServer() {
        guard let url = config.url(path: "/health") else { serverUp = nil; return }
        Task { serverUp = await JuniorClient().isReachable(url: url) }
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote)
                if store.retryable {
                    Button("Yeniden dene") { store.retry() }
                        .font(.footnote.weight(.semibold))
                        .disabled(store.isSending)
                }
            }
            Spacer()
            Button { store.errorText = nil } label: { Image(systemName: "xmark") }
        }
        .padding(10)
        .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            // Token/adres eksikse mikrofon dugmesi kapalidir. Sebebini
            // soylemezsek dugme sessizce olu gorunur; kullanici basar, hicbir
            // sey olmaz ve neyin eksik oldugunu bilemez.
            if !store.canSend {
                Button { showSettings = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                        Text("Sunucu adresi ya da token eksik — Ayarlar'dan gir.")
                        Spacer()
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            if config.wakeWordEnabled, handsFreeStatus == nil,
               speech.state != .listening || handsFree.continuousActive {
                HStack(spacing: 6) {
                    Circle().fill(wakeWord.running ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(wakeWordStatus)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            if let status = handsFreeStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if speech.state == .listening {
                VStack(alignment: .leading, spacing: 4) {
                    RouteLabel(route: speech.route)
                        .overlay(alignment: .trailing) {
                            if wakeWord.running {
                                Text("Hey Junior açık").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    Text(speech.partialText.isEmpty ? "Dinliyorum..." : speech.partialText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            HStack(spacing: 12) {
                Menu {
                    Button { showCamera = true } label: {
                        Label("Fotoğraf çek", systemImage: "camera")
                    }
                    // Gozluk fotograflari Meta AI uygulamasindan Fotograflar'a
                    // kaydediliyor; oradan sorabilmek icin galeri sart.
                    Button { showLibrary = true } label: {
                        Label("Galeriden seç", systemImage: "photo.on.rectangle")
                    }
                    // Gozluk kamerasi: kare istek aninda alinir, onbellekten degil.
                    Button { captureFromGlasses() } label: {
                        Label("Gözlükten çek", systemImage: "eyeglasses")
                    }
                } label: {
                    Image(systemName: "camera.fill").font(.title3)
                }
                .disabled(store.isSending)

                TextField("Yaz ya da mikrofona bas", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendDraft)

                if draft.isEmpty {
                    Button(action: toggleMic) {
                        Image(systemName: speech.state == .listening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(speech.state == .listening ? Color.red : Color.accentColor)
                    }
                    .disabled(store.isSending || !store.canSend)
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                    }
                    .disabled(store.isSending)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .background(.bar)
        // Gercek Binding: kullanici uyariyi baska yolla kapatirsa da durum sifirlanir.
        .alert("İzin gerekli", isPresented: Binding(
            get: { speech.permissionMessage != nil },
            set: { if !$0 { speech.permissionMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) { speech.permissionMessage = nil }
        } message: {
            Text(speech.permissionMessage ?? "")
        }
    }

    /// Eller serbest dongusunun o anki adimi. Dinleme kendi satirini zaten
    /// gosteriyor, orada tekrar etmeyelim.
    private var handsFreeStatus: String? {
        switch handsFree.phase {
        case .off, .waiting, .listening: return nil
        case .capturing: return "Gözlükten kare alınıyor..."
        case .thinking: return handsFree.usedGlasses ? "Gördüğün soruluyor..." : "Düşünüyor..."
        case .speaking: return "Yanıtlıyor..."
        }
    }

    /// Uyandirmanin o anki hali. "Hey Junior calismiyor" dendiginde bakilacak
    /// tek yer: dinliyor mu, hangi tanima modunda, en son ne duydu.
    private var wakeWordStatus: String {
        if let message = wakeWord.message { return message }
        if handsFree.continuousActive { return "Sohbet açık — sorabilirsin, bitirmek için \"kapat\" de" }
        guard wakeWord.running else { return "\"Hey Junior\" kapalı" }
        var status = "\"Hey Junior\" dinleniyor (\(wakeWord.usingOnDevice ? "cihaz üstü" : "sunucu") tanıma)"
        if let heard = wakeWord.lastHeard { status += " — duyulan: \(heard)" }
        return status
    }

    /// Yanitlarin sunucudaki noral Turkce sesle okunmasi. Kapaliysa ya da
    /// sunucuya ulasilamazsa SpeechService kendi yerlesik sesine duser.
    private func wireNaturalVoice() {
        speech.remoteTTS = { [weak config] text in
            let settings: (url: URL, token: String)? = await MainActor.run {
                guard let config, config.naturalVoiceEnabled,
                      let url = config.url(path: "/v1/tts"), let token = config.token else { return nil }
                return (url, token)
            }
            guard let settings else { throw JuniorError.notConfigured }
            return try await JuniorClient().tts(url: settings.url, token: settings.token, text: text)
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        // Yazili soru da gorselse kare gozlukten cekilir; kullanicinin elle
        // fotograf cekmesi Developer Mode oncesinin kalintisiydi.
        if VisionIntent.needsPhoto(text) {
            captureFromGlasses(question: text)
        } else {
            store.send(text: text)
        }
    }

    /// Mikrofon dugmesi de uyandirma sozcugu ile ayni yoldan gecer; boylece
    /// uyandirma motorunun duraklatilip geri alinmasi tek yerde kalir.
    private func toggleMic() {
        if speech.state == .listening {
            speech.stopListening()
        } else {
            handsFree.beginTurn()
        }
    }

    private func captureFromGlasses(question explicit: String? = nil) {
        let question = explicit ?? (draft.isEmpty ? "Bu fotoğrafta ne görüyorsun? Kısa anlat." : draft)
        draft = ""
        Task {
            do {
                let data = try await glasses.capturePhoto()
                guard let image = UIImage(data: data) else {
                    store.errorText = "Gözlükten gelen kare okunamadı."
                    return
                }
                store.send(text: question, image: image)
            } catch {
                store.errorText = (error as? LocalizedError)?.errorDescription
                    ?? "Gözlükten fotoğraf alınamadı."
            }
        }
    }

    private func syncWakeWord() {
        if config.wakeWordEnabled {
            handsFree.start()
        } else {
            handsFree.stop()
        }
    }
}

/// Dinlerken hangi mikrofonun kullanildigini gosterir. Gozluk baglandiginda
/// burada gozlugun adi cikar; cikmiyorsa ses hala telefondan aliniyor demektir.
private struct RouteLabel: View {
    @ObservedObject var route: AudioRoute

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: route.current?.isBluetoothInput == true
                  ? "wave.3.right.circle.fill" : "mic.fill")
            Text(route.current?.label ?? "Mikrofon")
            if route.routeChangedWhileListening {
                Text("· ses yolu değişti").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                content
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                content
            }
        }
    }

    private var content: some View {
        Text(message.text)
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(animating ? 0.25 : 0.85)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                               value: animating)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .onAppear { animating = true }
    }
}
