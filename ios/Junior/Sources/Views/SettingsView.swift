import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: Config
    @ObservedObject var store: ConversationStore
    @ObservedObject var glasses: GlassesService
    @ObservedObject var live: LiveListenService
    @Environment(\.dismiss) private var dismiss

    @State private var tokenDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var permissionResult: String?
    @State private var askingPermissions = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    HStack(spacing: 14) {
                        CatBadge(phase: config.hasToken ? .done : .waiting, size: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Junior").font(JuniorTheme.rounded(.title2, .bold))
                            Text(config.hasToken ? "Bilgisayarındaki asistana bağlı" : "Henüz bilgisayara bağlı değil")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("https://sunucu-adresin", text: $config.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if config.hasToken {
                        Label("Belirteç kayıtlı", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(JuniorTheme.green)
                    }
                    SecureField(config.hasToken ? "Değiştirmek için yeni belirteç" : "MOBILE_API_TOKEN",
                                text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Belirteci kaydet") {
                        config.setToken(tokenDraft)
                        tokenDraft = ""
                        testResult = nil
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        testing = true
                        Task {
                            testResult = await store.testConnection()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Label { Text("Bağlantıyı dene") } icon: { SettingIcon(systemName: "bolt.horizontal.fill", color: JuniorTheme.green) }
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                    if config.hasToken {
                        Button("Belirteci sil", role: .destructive) {
                            config.setToken("")
                            testResult = nil
                        }
                    }
                } header: {
                    Text("Bilgisayar")
                } footer: {
                    Text("En kolayı: bilgisayardaki Junior'da Telefon bölümündeki QR kodu kamerayla okut. "
                         + "Belirteç cihazda Keychain içinde saklanır ve hiçbir yere gönderilmez.")
                }

                Section {
                    Toggle(isOn: $config.wakeWordEnabled) {
                        Label { Text("\"Hey Junior\" ile uyandır") } icon: { SettingIcon(systemName: "ear.fill", color: JuniorTheme.cyan) }
                    }
                    Toggle(isOn: $config.continuousEnabled) {
                        Label { Text("Sürekli sohbet") } icon: { SettingIcon(systemName: "bubble.left.and.bubble.right.fill", color: JuniorTheme.violet) }
                    }
                    .disabled(!config.wakeWordEnabled)
                    Toggle(isOn: $config.headsetMicEnabled) {
                        Label { Text("Gözlük mikrofonu") } icon: { SettingIcon(systemName: "eyeglasses", color: JuniorTheme.blue) }
                    }
                    Toggle(isOn: $config.serverRecognitionEnabled) {
                        Label { Text("Doğru tanıma (sunucu)") } icon: { SettingIcon(systemName: "waveform.badge.magnifyingglass", color: JuniorTheme.green) }
                    }
                    Toggle(isOn: $config.allDayRecordingEnabled) {
                        Label { Text("Gün boyu yerel kayıt") } icon: { SettingIcon(systemName: "record.circle", color: JuniorTheme.red) }
                    }
                } header: {
                    Text("Dinleme")
                } footer: {
                    Text("Uygulama açıkken (arka planda da) \"Hey Junior\" dinlenir; iOS kilitli ekranda özel "
                         + "uyandırma sözcüğüne izin vermiyor, orada \"Hey Siri, Junior'a sor …\" kullan. "
                         + "Gözlük mikrofonu açıkken gözlük bağlanınca mikrofon ondan alınır; telefon cepteyken "
                         + "gözlükten \"Junior\" demek için gerekli (ses bu sırada telefon görüşmesi kalitesinde çalar). "
                         + "Doğru tanıma açıkken söylediğin bilgisayardaki whisper ile yazıya çevrilir; "
                         + "ulaşılamazsa iPhone'un kendi tanıması kullanılır. Gün boyu yerel kayıt açıkken "
                         + "ses 60 saniyelik WAV parçaları olarak Files > JuniorRecordings içine yazılır; "
                         + "Claude'a veya NVIDIA'ya otomatik gönderilmez. Telefon görüşmesi, Siri veya uygulamayı "
                         + "zorla kapatma kaydı geçici olarak durdurabilir.")
                }

                LiveSettingsSection(config: config, live: live)

                Section {
                    Button {
                        askingPermissions = true
                        permissionResult = nil
                        Task {
                            permissionResult = await PhoneActionService.shared.requestAllPermissions()
                            askingPermissions = false
                        }
                    } label: {
                        Label("Telefon eylemleri izinlerini ver", systemImage: "checkmark.shield.fill")
                    }
                    .disabled(askingPermissions)
                    if let permissionResult {
                        Text(permissionResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Telefon eylemleri")
                } footer: {
                    Text("Hatırlatıcı, takvim, zamanlayıcı, rehber ve Apple Müzik izinlerini bir seferde sorar. "
                         + "iOS izin penceresini yalnız uygulama açıkken gösterebilir; telefon cepteyken sorulan "
                         + "ilk istek bu yüzden yapılamaz. Bir kez vermen yeterli.")
                }

                Section {
                    Toggle(isOn: $config.naturalVoiceEnabled) {
                        Label { Text("Doğal ses (sunucudan)") } icon: { SettingIcon(systemName: "speaker.wave.2.fill", color: JuniorTheme.orange) }
                    }
                    if !config.naturalVoiceEnabled, !SpeechService.hasUpgradedVoice {
                        Text("Yerleşik sıkıştırılmış ses kullanılacak; robotik duyulur.")
                            .font(.footnote)
                    }
                    Toggle(isOn: $config.liveActivityEnabled) {
                        Label { Text("Dynamic Island'da göster") } icon: { SettingIcon(systemName: "capsule.fill", color: Color.gray) }
                    }
                } header: {
                    Text("Ses ve görünüm")
                } footer: {
                    Text("Doğal ses açıkken yanıtlar bilgisayardaki nöral Türkçe sesle okunur; sunucuya ulaşılamazsa "
                         + "iOS'un kendi sesi devreye girer (Ayarlar > Erişilebilirlik > Sözlü İçerik > Sesler > "
                         + "Türkçe'den gelişmiş sesi indirirsen o kullanılır). Dynamic Island'da dinlerken, "
                         + "düşünürken ve konuşurken noktalı kedi ve son yanıt görünür.")
                }

                Section {
                    LabeledContent("Kayıt", value: glasses.registrationInfo)
                    LabeledContent("Kamera izni", value: glasses.permissionInfo)
                    LabeledContent("Görünen cihaz", value: glasses.deviceInfo)
                    Button {
                        Task { await glasses.register() }
                    } label: {
                        Label { Text("1. Uygulamayı Meta AI'a tanıt") } icon: { SettingIcon(systemName: "link", color: JuniorTheme.blue) }
                    }
                    Button {
                        Task { await glasses.connect() }
                    } label: {
                        Label { Text("2. Gözlüğe bağlan ve kamera izni ver") } icon: { SettingIcon(systemName: "camera.fill", color: JuniorTheme.cyan) }
                    }
                    .disabled(glasses.state == .connecting)
                    if case .failed(let reason) = glasses.state {
                        Text(reason).font(.footnote).foregroundStyle(JuniorTheme.red)
                    } else if glasses.state == .connecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(glasses.permissionInfo == "Meta AI'da onay bekleniyor"
                                 ? "Meta AI'da izni onayla ve Junior'a geri dön…"
                                 : "Gözlüğe bağlanıyor…")
                                .font(.footnote)
                        }
                    } else if glasses.isReady {
                        Label("Gözlük bağlı", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(JuniorTheme.green)
                    }
                } header: {
                    Text("Gözlük kamerası")
                } footer: {
                    Text("İlk kurulumda: 1'e dokun, Meta AI açılır, onayla ve geri dön. "
                         + "Sonra gözlük takılıyken 2'ye dokun: önce gözlüğe bağlanır, kamera izni "
                         + "yoksa Meta AI'ı açar; orada izin ver ve Junior'a geri dön. "
                         + "Sonrasında \"bu ne\" gibi görsel sorularda kare gözlükten kendiliğinden "
                         + "alınır. Meta AI'da gözlük için Developer Mode açık olmalı.")
                }
                .onAppear { glasses.observeRegistration() }

                Section {
                    LabeledContent("Sürüm", value: Bundle.main.appVersion)
                } header: {
                    Text("Bilgi")
                } footer: {
                    Text("Junior yanıtı bilgisayarındaki Claude oturumundan alır. Bilgisayar ve tünel açık olmalı.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground(tint: JuniorTheme.cyan.opacity(0.5)))
            #if DEBUG
            // CI ekran görüntüsü: sürekli dinleme bölümüne kaydır.
            .onAppear {
                if DemoMode.scene == "live" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        proxy.scrollTo("liveSection", anchor: .top)
                    }
                }
            }
            #endif
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(JuniorTheme.cyan)
        .preferredColorScheme(.dark)
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
