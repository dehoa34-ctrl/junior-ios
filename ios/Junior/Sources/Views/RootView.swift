import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var showSkills = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photoItem: PhotosPickerItem?
    /// Secilen video Fotograflar'dan kopyalanirken (iCloud'dan inebilir)
    @State private var preparingVideo = false
    @FocusState private var composerFocused: Bool
    /// Bilgisayara ulasilabiliyor mu; ulasilamiyorsa kendisi yeniden dener.
    @StateObject private var server: ServerMonitor
    /// Bilgisayardan telefona gonderilen notlar, baglantilar, hatirlaticilar
    @StateObject private var phoneTasks: PhoneTaskService
    /// Telefonda sürekli dinleme: konuşma parçaları kesilip bilgisayara yüklenir.
    @StateObject private var live: LiveListenService
    /// Kedinin yüzü: son sonuç (mutlu / üzgün) ve son etkinlik.
    @ObservedObject private var mood = JuniorMood.shared
    /// Sohbetteki video bağlantısından açılan oynatıcı.
    @State private var playing: PlayableVideo?
    /// "Panodakini sor" önerileri; boş değilken seçim penceresi açıktır.
    @State private var clipboardOptions: [ClipboardAsk.Option] = []
    @State private var clipboardText = ""
    /// Gemini Live sesli oturumu (Ayarlar > Ses motoru); düşerse klasik yola döner.
    @StateObject private var gemini: GeminiLiveSession
    @AppStorage(VoiceEngine.storageKey) private var voiceEngine: VoiceEngine = .classic
    @Environment(\.scenePhase) private var scenePhase

    init(config: Config, speech: SpeechService) {
        self.config = config
        self.speech = speech
        #if DEBUG
        let demo = DemoMode.scene != nil
        #else
        let demo = false
        #endif
        // Eller serbest dongusu bu ucunu de tutar; hepsi burada bir kez kurulur
        // ki dongunun sahibi tek bir yer olsun.
        let wakeWord = WakeWordService()
        let glasses = GlassesService()
        let store = ConversationStore(config: config, speech: speech)
        _wakeWord = StateObject(wrappedValue: wakeWord)
        _glasses = StateObject(wrappedValue: glasses)
        _store = StateObject(wrappedValue: store)
        let handsFree = HandsFreeSession(wakeWord: wakeWord, speech: speech, glasses: glasses, store: store)
        _handsFree = StateObject(wrappedValue: handsFree)
        let gemini = GeminiLiveSession(config: config, speech: speech, store: store, hooks: GeminiLiveSession.Hooks(
            pauseWake: { [weak wakeWord] in wakeWord?.pauseForRecording() },
            resumeWake: { [weak wakeWord] in wakeWord?.resumeAfterRecording() },
            releaseMic: { [weak wakeWord] in
                if wakeWord?.running != true { MicrophoneHub.shared.stop() }
            },
            classic: { [weak wakeWord, weak handsFree, weak store] step in
                switch step {
                case .send(let text):
                    wakeWord?.resumeAfterRecording()
                    store?.send(text: text)
                case .listen:
                    handsFree?.beginTurn()
                }
            }))
        // Canlı oturum sürerken klasik döngü tur açmaz, uyandırmayı yeniden başlatmaz.
        handsFree.externalVoiceActive = { [weak gemini] in gemini?.isActive == true }
        _gemini = StateObject(wrappedValue: gemini)
        _server = StateObject(wrappedValue: ServerMonitor(
            healthURL: { [weak config] in config?.url(path: "/health") },
            probe: demo ? { (_: URL) async -> Bool in true } : nil))
        _phoneTasks = StateObject(wrappedValue: PhoneTaskService(config: config))
        _live = StateObject(wrappedValue: LiveListenService(config: config, speech: speech))
    }

    var body: some View {
        ZStack {
            AmbientBackground(tint: visualPhase == .waiting ? JuniorTheme.cyan.opacity(0.6) : visualPhase.color)
            VStack(spacing: 0) {
                header
                transcript
                dock
            }
        }
        .preferredColorScheme(.dark)
        .tint(JuniorTheme.cyan)
        .sheet(isPresented: $showSettings) { SettingsView(config: config, store: store, glasses: glasses, live: live) }
        .sheet(item: $playing) { video in videoSheet(video) }
        .confirmationDialog("Panodakini sor", isPresented: clipboardShown, titleVisibility: .visible) {
            clipboardButtons
        } message: {
            Text(String(clipboardText.prefix(160)))
        }
        .sheet(isPresented: $showSkills) { SkillsSheet(config: config) }
        .onAppear {
            #if DEBUG
            if let scene = DemoMode.scene {
                startDemo(scene)
                return
            }
            #endif
            handsFree.continuousEnabled = config.continuousEnabled
            // Uygulama yeniden açıldığında daha önce açıkça etkinleştirilmiş
            // yerel kayıt tercihini aynı mikrofon motoruna geri bağla.
            MicrophoneHub.shared.setAllDayRecording(config.allDayRecordingEnabled)
            syncWakeWord()
            wireNaturalVoice()
            wireRecognition()
            server.check()
            phoneTasks.start()
            store.resumeVideoJob()
            live.sync()
            JuniorNotifications.attach(config)
            RemoteConfirmCenter.shared.start()
            store.resumeRemoteResults()
            store.flushOfflineQueue()
            refreshGemini()
        }
        // One donunce yeniden bak: bilgisayar bu arada kapanmis olabilir.
        // Arka planda yeniden deneme dongusu durur; cepteyken aga cikmasin.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                MicrophoneHub.shared.refreshAllDay()
                server.check()
                phoneTasks.start()
                store.resumeVideoJob()
                live.sync()
                RemoteConfirmCenter.shared.start()
                store.resumeRemoteResults()
                // Pomodoro bu arada masaüstünden durmuş olabilir: bekleyen bildirim kalmasın.
                Task { await PomodoroAlertSync.refreshIfScheduled(config: config) }
                refreshGemini()
            } else if scenePhase == .background {
                server.pause()
                phoneTasks.pause()
                RemoteConfirmCenter.shared.pause()
            }
        }
        // Bilgisayar geri geldi: çevrimdışıyken sıraya giren komutlar sırayla gider.
        .onChange(of: server.serverUp) {
            if server.serverUp == true { store.flushOfflineQueue() }
        }
        // Komut sıraya girdiyse bağlantı durumu hemen yeniden denetlensin (başlık "ulaşılamıyor" desin).
        .onChange(of: store.offlineQueue.waiting.count) {
            if !store.offlineQueue.waiting.isEmpty { server.check() }
        }
        .onChange(of: config.continuousEnabled) {
            handsFree.continuousEnabled = config.continuousEnabled
        }
        .onChange(of: config.wakeWordEnabled) { syncWakeWord() }
        .onChange(of: config.phoneLiveEnabled) {
            // Duraklatılmışken anahtarı açmak "bir şey olmuyor" gibi görünüyordu.
            if config.phoneLiveEnabled, live.paused { live.paused = false } else { live.sync() }
        }
        .onChange(of: config.serverRecognitionEnabled) { wireRecognition() }
        .onChange(of: config.allDayRecordingEnabled) {
            MicrophoneHub.shared.setAllDayRecording(config.allDayRecordingEnabled)
        }
        // Ayarlar kapaninca yeni adresle hemen bakilir; yoksa uyari eski
        // (bos) adresin sonucunu gosterip "Yeniden dene"yi bekliyordu.
        .onChange(of: showSettings) {
            if !showSettings {
                syncWakeWord()
                server.check()
                refreshGemini()
            }
        }
        // Motor yeniden seçildi: geri düşüş engeli kalkar; klasiğe geçilince açık oturum kapanır.
        .onChange(of: voiceEngine) {
            gemini.allow()
            if voiceEngine == .classic { gemini.stop() }
        }
        // Adres Ayarlar'da yazilirken ya da QR eslestirmesiyle degisir; her
        // tusta degil, yazma durunca bakilir.
        .onChange(of: config.baseURL) { server.addressChanged() }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                defer { self.photoItem = nil }
                // Video: bilgisayarda kurgulanmak uzere eklenir; ne yapilacagini
                // kullanici yazar ya da soyler ("bunu editle").
                if photoItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    await attachVideo(photoItem)
                    return
                }
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
                let question = draft.isEmpty ? "Bu fotoğrafta ne görüyorsun? Kısa anlat." : draft
                draft = ""
                store.send(text: question, image: image)
            }
        }
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

    // MARK: - Durum

    /// Ekranın rengini ve kedinin halini belirleyen adım.
    private var visualPhase: JuniorActivityPhase {
        if gemini.isActive { return gemini.modelSpeaking ? .speaking : .listening }
        if speech.state == .listening { return .listening }
        switch handsFree.phase {
        case .capturing: return .looking
        case .thinking: return .thinking
        case .speaking: return .speaking
        default: break
        }
        if speech.transcribing || store.isSending { return .thinking }
        if speech.state == .speaking { return .speaking }
        return .waiting
    }

    private var isBusy: Bool { visualPhase != .waiting }

    /// Kedinin yüz ifadesi: o anki adım ve son sonuç (bitti → mutlu, olmadı → üzgün).
    private func catExpression(at now: Date) -> CatExpression {
        mood.expression(phase: isBusy ? visualPhase : .waiting, now: now)
    }

    // MARK: - Başlık

    private var header: some View {
        HStack(spacing: 12) {
            // Uzun boşlukta uyuklama ve sonucun yüzden silinmesi zamanla değişir.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                CatBadge(phase: isBusy ? visualPhase : .listening, size: 42, expression: catExpression(at: context.date))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Junior").font(JuniorTheme.rounded(.title3, .bold))
                headerStatus
            }
            Spacer()
            LiveIndicator(live: live)
            CircleIconButton(systemName: "square.and.pencil", label: "Yeni sohbet") { store.clear() }
                .disabled(store.messages.isEmpty)
                .opacity(store.messages.isEmpty ? 0.4 : 1)
            // Beceriler: hava, arama, pomodoro, su, kalori, şınav, tekrar kartları, sınav.
            CircleIconButton(systemName: "square.grid.2x2.fill", label: "Beceriler") { showSkills = true }
            CircleIconButton(systemName: "gearshape.fill", label: "Ayarlar") { showSettings = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// Başlığın altındaki küçük satır: o an ne yaptığı, yoksa bağlantı durumu.
    private var headerStatus: some View {
        let (text, color): (String, Color) = {
            if isBusy { return (visualPhase.title, visualPhase.color) }
            if !store.canSend { return ("Kurulum gerekli", JuniorTheme.orange) }
            switch server.serverUp {
            case true?: return ("Bilgisayar bağlı", JuniorTheme.green)
            case false?: return ("Bilgisayara ulaşılamıyor", JuniorTheme.orange)
            case nil: return ("Bağlanıyor…", Color.secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: text)
    }

    // MARK: - Konuşma

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.messages.isEmpty { emptyState }
                    ForEach(store.messages) { message in
                        MessageRow(message: message, onPlay: { playing = PlayableVideo(url: $0) }).id(message.id)
                    }
                    if store.isSending { TypingRow() }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.isSending) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [JuniorTheme.cyan.opacity(0.28), .clear],
                                         center: .center, startRadius: 10, endRadius: 110))
                    .frame(width: 220, height: 220)
                JuniorCat(phase: isBusy ? visualPhase : .listening, size: 128, glow: true,
                          expression: catExpression(at: Date()))
            }
            .padding(.top, 18)
            VStack(spacing: 8) {
                Text(Self.greeting).font(JuniorTheme.rounded(.largeTitle, .bold))
                Text(config.wakeWordEnabled
                     ? "\"Hey Junior\" de ya da mikrofona dokun."
                     : "Mikrofona dokun ya da yaz.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Suggestion.all) { suggestion in
                    Button { use(suggestion) } label: { SuggestionCard(suggestion: suggestion) }
                        .buttonStyle(PressScale())
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Günaydın"
        case 12..<18: return "İyi günler"
        case 18..<23: return "İyi akşamlar"
        default: return "İyi geceler"
        }
    }

    private func use(_ suggestion: Suggestion) {
        guard store.canSend else {
            showSettings = true
            return
        }
        switch suggestion.action {
        case .send(let text): store.send(text: text)
        case .glasses: captureFromGlasses()
        case .library: showLibrary = true
        }
    }

    // MARK: - Alt bölüm

    private var dock: some View {
        VStack(spacing: 10) {
            notices
            liveCard
            composer
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            LinearGradient(colors: [JuniorTheme.background.opacity(0), JuniorTheme.background.opacity(0.94)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var notices: some View {
        // Token/adres eksikse mikrofon dugmesi kapalidir. Sebebini
        // soylemezsek dugme sessizce olu gorunur; kullanici basar, hicbir
        // sey olmaz ve neyin eksik oldugunu bilemez.
        if !store.canSend {
            NoticeCard(icon: "qrcode.viewfinder", color: JuniorTheme.orange,
                       text: "Bilgisayara bağlı değil. Bilgisayardaki Junior'da Telefon bölümündeki QR'ı okut ya da Ayarlar'dan adresi gir.",
                       actionTitle: "Ayarlar") { showSettings = true }
        } else if server.serverUp == false {
            // Junior'in yaniti oradan geldigi icin, konusmaya baslamadan once bilmek gerekiyor.
            NoticeCard(icon: "wifi.exclamationmark", color: JuniorTheme.orange,
                       text: "Bilgisayara ulaşılamıyor. Bilgisayar ve tünel açık mı?",
                       actionTitle: "Yeniden dene") { server.check() }
        }
        if let error = store.errorText {
            NoticeCard(icon: "exclamationmark.triangle.fill", color: JuniorTheme.red, text: error,
                       actionTitle: store.retryable ? "Yeniden dene" : nil,
                       actionDisabled: store.isSending,
                       onClose: { store.errorText = nil }) { store.retry() }
        }
        if store.pendingTargetQuestion != nil { targetChooser }
        // Bilgisayardan onay istekleri ve çevrimdışı sırada bekleyen komutlar.
        RemoteConfirmCard(center: .shared)
        OfflineQueueCard(store: store)
        VideoJobRow(service: store.videoJobs)
        if preparingVideo || store.pendingVideo != nil { videoChip }
    }

    /// Dinlerken söylenen canlı yazılır; düşünürken/konuşurken o adım görünür;
    /// boştayken "Hey Junior" dinlemesinin hali.
    @ViewBuilder
    private var liveCard: some View {
        if gemini.isActive {
            GeminiLiveCard(session: gemini)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if speech.state == .listening || speech.transcribing {
            ListeningCard(route: speech.route, text: speech.partialText, transcribing: speech.transcribing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let status = handsFreeStatus {
            HStack(spacing: 12) {
                CatBadge(phase: visualPhase, size: 34)
                Text(status).font(.subheadline.weight(.medium))
                Spacer()
                WaveBars(active: true, color: visualPhase.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .card(radius: 18)
            .transition(.opacity)
        } else if config.wakeWordEnabled {
            HStack(spacing: 8) {
                PulseDot(color: wakeWord.running ? JuniorTheme.green : JuniorTheme.orange,
                         pulsing: wakeWord.running && !handsFree.continuousActive)
                Text(wakeWordStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(JuniorTheme.surface, in: Capsule())
            .frame(maxWidth: .infinity)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                // Pano yalnız buna basınca okunur; iOS o an yapıştırma iznini sorar.
                Button { askAboutClipboard() } label: {
                    Label("Panodakini sor", systemImage: "doc.on.clipboard")
                }
                Button { showCamera = true } label: {
                    Label("Fotoğraf çek", systemImage: "camera")
                }
                // Gozluk fotograflari Meta AI uygulamasindan Fotograflar'a
                // kaydediliyor; oradan sorabilmek icin galeri sart.
                Button { showLibrary = true } label: {
                    Label("Galeriden fotoğraf ya da video", systemImage: "photo.on.rectangle")
                }
                // Gozluk kamerasi: kare istek aninda alinir, onbellekten degil.
                Button { captureFromGlasses() } label: {
                    Label("Gözlükten çek", systemImage: "eyeglasses")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(JuniorTheme.surfaceStrong, in: Circle())
            }
            // Gemini Live açıkken fotoğraf/kamera/gözlük klasik yoldan yanıtlanır, sesler çakışırdı.
            .disabled(store.isSending || gemini.isActive)
            .accessibilityLabel("Ekle")

            TextField("Junior'a yaz…", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 46)
                .card(radius: 23)
                .onSubmit(sendDraft)

            if draft.isEmpty && store.pendingVideo == nil {
                // Kısa dokunuş eski tıkla-konuş; basılı tutma bas-konuş (bırakınca gönderir,
                // yukarı kaydırıp bırakınca iptal); Junior konuşurken basmak onu susturur.
                // Gemini Live seçiliyken dokunuş da basılı tutma da oturumu açar/kapatır.
                PushToTalkButton(listening: speech.state == .listening || gemini.isActive,
                                 speaking: speech.state == .speaking,
                                 enabled: !store.isSending && store.canSend, onAction: pushToTalk)
                    .opacity(store.isSending || !store.canSend ? 0.45 : 1)
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(JuniorTheme.micGradient, in: Circle())
                }
                .buttonStyle(PressScale())
                .disabled(store.isSending)
                .accessibilityLabel("Gönder")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draft.isEmpty)
    }

    private var targetChooser: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(JuniorTheme.cyan)
            Text("Nerede yapayım?").font(.subheadline.weight(.medium))
            Spacer()
            Button("Bilgisayarda") { store.answerTarget("computer") }
                .buttonStyle(.borderedProminent)
            Button("Telefonda") { store.answerTarget("phone") }
                .buttonStyle(.bordered)
        }
        .font(.subheadline)
        .padding(12)
        .card(radius: 18)
    }

    /// Eller serbest dongusunun o anki adimi. Dinleme kendi kartini zaten
    /// gosteriyor, orada tekrar etmeyelim.
    private var handsFreeStatus: String? {
        switch handsFree.phase {
        case .off, .waiting, .listening:
            if store.isSending { return "Düşünüyor…" }
            return nil
        case .capturing: return "Gözlükten kare alınıyor…"
        case .thinking: return handsFree.usedGlasses ? "Gördüğün soruluyor…" : "Düşünüyor…"
        case .speaking: return "Yanıtlıyor…"
        }
    }

    /// Uyandirmanin o anki hali. "Hey Junior calismiyor" dendiginde bakilacak
    /// tek yer: dinliyor mu, hangi tanima modunda, en son ne duydu.
    private var wakeWordStatus: String {
        if let message = wakeWord.message { return message }
        if handsFree.continuousActive { return "Sohbet açık — sorabilirsin, bitirmek için \"kapat\" de" }
        guard wakeWord.running else { return "\"Hey Junior\" kapalı" }
        var status = "\"Hey Junior\" dinleniyor"
        if let heard = wakeWord.lastHeard { status += " · duyulan: \(heard)" }
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

    /// Söylenenin sunucudaki whisper ile yazıya çevrilmesi. Kapalıyken kayıt
    /// kopyası hiç tutulmaz; Apple'ın metni olduğu gibi kullanılır.
    private func wireRecognition() {
        guard config.serverRecognitionEnabled else {
            speech.remoteSTT = nil
            return
        }
        speech.remoteSTT = { [weak config] wav in
            let settings: (url: URL, token: String)? = await MainActor.run {
                guard let config, let url = config.url(path: "/v1/stt"), let token = config.token else { return nil }
                return (url, token)
            }
            guard let settings else { throw JuniorError.notConfigured }
            return try await JuniorClient().stt(url: settings.url, token: settings.token, wav: wav)
        }
    }

    /// Secilen video: yazi alaninin ustunde durur, gonderilecek mesaja eklenir.
    private var videoChip: some View {
        HStack(spacing: 10) {
            if let video = store.pendingVideo {
                Image(systemName: "film")
                    .foregroundStyle(JuniorTheme.cyan)
                    .frame(width: 34, height: 34)
                    .background(JuniorTheme.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(video.name) · \(video.sizeLabel)").font(.caption.weight(.semibold)).lineLimit(1)
                    Text("Ne yapılacağını yaz ya da söyle (ör. \"bunu Reels'e uygun editle\"); bilgisayarda kurgulanır.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {
                    try? FileManager.default.removeItem(at: video.url)
                    store.pendingVideo = nil
                } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Video hazırlanıyor…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .card(radius: 16, tint: JuniorTheme.cyan)
    }

    private func attachVideo(_ item: PhotosPickerItem) async {
        preparingVideo = true
        defer { preparingVideo = false }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            store.errorText = "Video okunamadı. iCloud'daysa önce Fotoğraflar'da açıp indir, sonra tekrar seç."
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            store.errorText = "Video boş görünüyor."
            return
        }
        if let old = store.pendingVideo { try? FileManager.default.removeItem(at: old.url) }
        // Gecici adin basindaki benzersiz kisim gosterilmez.
        let shown = movie.url.lastPathComponent.split(separator: "-", maxSplits: 1).last.map(String.init) ?? "video"
        store.pendingVideo = PickedVideo(url: movie.url, name: shown, size: size)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        // Gemini Live açıkken yazılan canlı oturuma gider (GeminiComposerRoute): klasik yanıt
        // Gemini sesiyle aynı anda okunmasın, uyandırma dinlemesi oturum sürerken açılmasın.
        switch GeminiComposerRoute.decide(sessionActive: gemini.isActive, text: text, hasVideo: store.pendingVideo != nil) {
        case .gemini(let typed):
            gemini.sendText(typed)
            return
        case .ignore:
            return
        case .endSessionThenClassic:
            gemini.stop()
        case .classic:
            break
        }
        // Video ekliyse mesaj kurgu istegidir; gozlukten kare cekilmez.
        if store.pendingVideo != nil {
            store.send(text: text)
            return
        }
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
        composerFocused = false
        // Gemini Live açıksa aynı düğme oturumu kapatır.
        if gemini.isActive {
            gemini.stop()
        } else if speech.state == .listening {
            speech.stopListening()
        } else if gemini.route(for: voiceEngine) == .gemini, handsFree.phase == .waiting || handsFree.phase == .off {
            // Klasik tur sürerken (düşünüyor/konuşuyor) açılmaz: döngü o turu bitirmeli.
            gemini.start()
        } else {
            handsFree.beginTurn()
        }
    }

    // MARK: - Bas-konuş

    private func pushToTalk(_ action: PushToTalk.Action) {
        composerFocused = false
        // Gemini Live oturumu sürüyorsa ya da Gemini seçiliyse basılı tutma klasik kaydı açmaz:
        // Gemini sesi kendisi dinler, "bırakınca gönder" yoktur. Dokunuş ve basış oturumu açar/kapatır.
        if gemini.isActive || gemini.route(for: voiceEngine) == .gemini {
            switch action {
            case .tap, .startRecording:
                toggleMic()
            case .silence:
                if gemini.isActive { gemini.stop() } else { handsFree.interruptSpeaking() }
            case .none, .send, .cancel:
                break
            }
            return
        }
        switch action {
        case .none:
            break
        case .silence:
            handsFree.interruptSpeaking()
        case .tap:
            toggleMic()
        case .startRecording:
            // Basılıyken sessizlik dinlemeyi bitirmez; gönderen bırakmaktır (SpeechService.holdOpen).
            speech.holdOpen = true
            // Tıkla-konuşla açılmış dinleme sürüyorsa yenisi açılmaz; bırakınca o gönderilir.
            if speech.state != .listening { handsFree.beginTurn() }
        case .send:
            finishHold(cancel: false)
        case .cancel:
            finishHold(cancel: true)
        }
    }

    /// Basılı tutma bitti. Dinleme "bip" sesinden sonra (~0,2 sn, ilk seferde izin sorusundan
    /// sonra) açılır; çok kısa basışta henüz açılmamış olabilir, en çok 2 sn beklenir.
    private func finishHold(cancel: Bool) {
        Task { @MainActor in
            for _ in 0..<20 where speech.state != .listening && handsFree.phase == .listening {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Tutma her durumda kalkar: dinleme hiç açılmadıysa sonradan açılan dinleme
            // sessizlikle bitebilsin (dinleme bittiyse SpeechService zaten kaldırmıştır).
            defer { speech.holdOpen = false }
            guard speech.state == .listening else { return }
            if cancel { speech.cancelListening() } else { speech.stopListening() }
        }
    }

    // MARK: - Pano ve video

    private func askAboutClipboard() {
        guard store.canSend else {
            showSettings = true
            return
        }
        guard let text = ClipboardAsk.readNow(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.errorText = "Pano boş. Bir bağlantı ya da metin kopyalayıp yeniden dene."
            return
        }
        clipboardText = text
        clipboardOptions = ClipboardAsk.options(for: text)
    }

    private func askClipboard(_ option: ClipboardAsk.Option) {
        clipboardOptions = []
        store.send(text: option.prompt)
    }

    private var clipboardShown: Binding<Bool> {
        Binding(get: { !clipboardOptions.isEmpty }, set: { if !$0 { clipboardOptions = [] } })
    }

    @ViewBuilder
    private var clipboardButtons: some View {
        ForEach(clipboardOptions) { option in
            Button(option.title) { askClipboard(option) }
        }
        Button("Yazı alanına koy") {
            draft = String(clipboardText.prefix(JuniorLimits.maxMessageChars))
            clipboardOptions = []
        }
        Button("Vazgeç", role: .cancel) { clipboardOptions = [] }
    }

    private func videoSheet(_ video: PlayableVideo) -> some View {
        VideoPlayerSheet(source: video.url, config: config) { effect in
            switch effect {
            case .pauseWakeWord: handsFree.holdWakeWord(true)
            case .resumeWakeWord: handsFree.holdWakeWord(false)
            case .none: break
            }
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

    /// Gemini seçiliyse sunucudaki durumu okur: sorun bilgisayarda çözüldüyse geri düşüş engeli kalkar.
    private func refreshGemini() {
        guard voiceEngine == .geminiLive, store.canSend else { return }
        Task { await gemini.refreshStatus() }
    }

    private func syncWakeWord() {
        if config.wakeWordEnabled {
            handsFree.start()
        } else {
            handsFree.stop()
        }
    }

    #if DEBUG
    private func startDemo(_ scene: String) {
        server.check()
        if scene != "empty" { store.loadDemo(DemoMode.messages) }
        if scene == "listening" { speech.showDemoListening("Yarın sabah dokuzda toplantımı hatırlat") }
        if scene == "settings" { showSettings = true }
        if scene == "live" {
            live.loadDemo()
            showSettings = true
        }
    }
    #endif
}

// MARK: - Öneriler

private struct Suggestion: Identifiable {
    enum Action {
        case send(String)
        case glasses
        case library
    }

    let id: String
    let icon: String
    let color: Color
    let detail: String
    let action: Action

    static let all = [
        Suggestion(id: "Müzik çal", icon: "music.note", color: JuniorTheme.green,
                   detail: "Bilgisayarda Tarkan Şımarık", action: .send("Bilgisayarda Tarkan Şımarık çal")),
        Suggestion(id: "Bu ne?", icon: "eyeglasses", color: JuniorTheme.cyan,
                   detail: "Gözlükten bakıp anlatır", action: .glasses),
        Suggestion(id: "Video kurgula", icon: "film.stack", color: JuniorTheme.violet,
                   detail: "Galeriden seç, bilgisayar editlesin", action: .library),
        Suggestion(id: "Videoyu durdur", icon: "pause.fill", color: JuniorTheme.orange,
                   detail: "Bilgisayarda duraklatır", action: .send("Bilgisayarda videoyu duraklat")),
    ]
}

private struct SuggestionCard: View {
    let suggestion: Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(suggestion.color)
                .frame(width: 32, height: 32)
                .background(suggestion.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.id).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(12)
        .card(radius: 18)
    }
}

// MARK: - Parçalar

/// Büyük mikrofon düğmesi; dinlerken etrafında halkalar yayılır.
private struct MicButton: View {
    var listening: Bool
    var action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if listening {
                    ForEach(0..<2, id: \.self) { ring in
                        Circle()
                            .stroke(JuniorTheme.cyan.opacity(0.55), lineWidth: 2)
                            .scaleEffect(pulse ? 1.7 : 1)
                            .opacity(pulse ? 0 : 0.9)
                            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)
                                .delay(Double(ring) * 0.7), value: pulse)
                    }
                }
                Circle()
                    .fill(listening ? AnyShapeStyle(Color.white) : AnyShapeStyle(JuniorTheme.micGradient))
                    .shadow(color: JuniorTheme.cyan.opacity(listening ? 0.7 : 0.35), radius: listening ? 18 : 10)
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(listening ? Color.black : Color.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(PressScale())
        .onAppear { pulse = listening }
        .onChange(of: listening) { pulse = listening }
        .accessibilityLabel(listening ? "Dinlemeyi durdur" : "Konuş")
    }
}

/// Dinlerken: canlı yazı, hangi mikrofonun kullanıldığı, ses çubukları.
private struct ListeningCard: View {
    @ObservedObject var route: AudioRoute
    let text: String
    let transcribing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WaveBars(active: !transcribing)
                Text(transcribing ? "Yazıya çeviriyorum…" : "Dinliyorum")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JuniorTheme.cyan)
                Spacer()
                RouteLabel(route: route)
            }
            Text(text.isEmpty ? "Konuşabilirsin…" : text)
                .font(JuniorTheme.rounded(.title3, .medium))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(4)
                .animation(.easeOut(duration: 0.15), value: text)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(JuniorTheme.cyan.opacity(0.35), lineWidth: 1))
    }
}

/// Dinlerken hangi mikrofonun kullanildigini gosterir. Gozluk baglandiginda
/// burada gozlugun adi cikar; cikmiyorsa ses hala telefondan aliniyor demektir.
private struct RouteLabel: View {
    @ObservedObject var route: AudioRoute

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: route.current?.isBluetoothInput == true ? "eyeglasses" : "iphone")
            Text(route.current?.label ?? "Mikrofon").lineLimit(1)
            if route.routeChangedWhileListening {
                Image(systemName: "arrow.triangle.swap").foregroundStyle(JuniorTheme.orange)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(JuniorTheme.surface, in: Capsule())
    }
}

/// Atan nokta: uyandırma dinlemesi açıkken yavaşça nefes alır.
private struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing && on ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 1.1).repeatForever() : .default, value: on)
            .onAppear { on = true }
    }
}

/// Uyarı kartı: bağlantı yok, hata, kurulum eksik.
private struct NoticeCard: View {
    let icon: String
    let color: Color
    let text: String
    var actionTitle: String?
    var actionDisabled = false
    var onClose: (() -> Void)?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(color)
                        .disabled(actionDisabled)
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Kapat")
            }
        }
        .padding(12)
        .card(radius: 18, tint: color)
    }
}

/// Bilgisayarda kurgulanan videonun durumu: yukleme yuzdesi, bilgisayardaki
/// adim ("konusmayi yaziya ceviriyor"), indirme.
private struct VideoJobRow: View {
    @ObservedObject var service: VideoJobService

    var body: some View {
        if let line = service.statusLine {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack").foregroundStyle(JuniorTheme.violet)
                    Text(line).font(.caption).lineLimit(2)
                    Spacer()
                }
                if let progress = service.uploadProgress {
                    ProgressView(value: progress).tint(JuniorTheme.violet)
                }
            }
            .padding(12)
            .card(radius: 16)
        }
    }
}

/// Oynatıcı sayfasının konusu (sheet(item:) kimlik ister).
struct PlayableVideo: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct MessageRow: View {
    let message: ChatMessage
    /// Mesajda video bağlantısı varsa altında "Oynat" düğmesi çıkar.
    var onPlay: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            bubble
            if let onPlay, let video = VideoLink.first(in: message.text) {
                Button { onPlay(video) } label: {
                    Label("Videoyu oynat", systemImage: "play.rectangle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(JuniorTheme.cyan)
                .padding(.leading, message.role == .user ? 0 : 38)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(JuniorTheme.userBubble,
                                in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                           bottomTrailingRadius: 6, topTrailingRadius: 20,
                                                           style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                CatBadge(phase: .listening, size: 28)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(JuniorTheme.surface,
                                in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20,
                                                           bottomTrailingRadius: 20, topTrailingRadius: 20,
                                                           style: .continuous))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20,
                                                    bottomTrailingRadius: 20, topTrailingRadius: 20,
                                                    style: .continuous).stroke(JuniorTheme.stroke))
                    .textSelection(.enabled)
                Spacer(minLength: 28)
            }
        }
    }
}

private struct TypingRow: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CatBadge(phase: .thinking, size: 28)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(JuniorTheme.violet)
                        .frame(width: 7, height: 7)
                        .opacity(animating ? 0.25 : 0.95)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                                   value: animating)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(JuniorTheme.surface, in: Capsule())
        }
        .onAppear { animating = true }
        .accessibilityLabel("Junior düşünüyor")
    }
}

#if DEBUG
/// CI'da simülatörden ekran görüntüsü almak için örnek ekranlar:
/// `-JuniorDemo empty|chat|listening|settings`. Yalnız hata ayıklama derlemesinde var.
enum DemoMode {
    static var scene: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-JuniorDemo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Config.init çağırır: örnek ekranlar "kurulum gerekli" uyarısı göstermesin.
    @MainActor
    static func prepare(_ config: Config) {
        guard scene != nil else { return }
        config.baseURL = "https://junior.example.com"
        if !config.hasToken { config.setToken(String(repeating: "d", count: 40)) }
        config.phoneLiveEnabled = scene == "live"
    }

    static let messages = [
        ChatMessage(role: .user, text: "Bilgisayarda Tarkan Şımarık çal"),
        ChatMessage(role: .assistant, text: "Spotify'da Tarkan – Şımarık çalıyor. Sesi biraz açayım mı?"),
        ChatMessage(role: .user, text: "Yarın hava nasıl olacak?"),
        ChatMessage(role: .assistant, text: "Yarın İstanbul'da parçalı bulutlu, en yüksek 19°C. Öğleden sonra hafif yağmur ihtimali var; şemsiyeni yanına al."),
    ]
}
#endif
