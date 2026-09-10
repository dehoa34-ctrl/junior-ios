import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: Config
    @ObservedObject var store: ConversationStore
    @ObservedObject var glasses: GlassesService
    @Environment(\.dismiss) private var dismiss

    @State private var tokenDraft = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sunucu") {
                    TextField("https://sunucu-adresin", text: $config.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // Basligi ayri header olarak veriyoruz: Section(_ title:) footer: ile birlesmiyor.
                Section {
                    if config.hasToken {
                        Label("Token kayitli", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    SecureField(config.hasToken ? "Degistirmek icin yeni token" : "MOBILE_API_TOKEN",
                                text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Kaydet") {
                        config.setToken(tokenDraft)
                        tokenDraft = ""
                        testResult = nil
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if config.hasToken {
                        Button("Tokeni sil", role: .destructive) {
                            config.setToken("")
                            testResult = nil
                        }
                    }
                } header: {
                    Text("Erisim tokeni")
                } footer: {
                    Text("Token bilgisayardaki .env dosyasindaki MOBILE_API_TOKEN degeridir. Cihazda Keychain icinde saklanir ve hicbir yere gonderilmez.")
                }

                Section {
                    Button {
                        testing = true
                        Task {
                            testResult = await store.testConnection()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Baglantiyi dene")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("\"Hey Junior\" ile uyandır", isOn: $config.wakeWordEnabled)
                    Toggle("Sürekli sohbet", isOn: $config.continuousEnabled)
                        .disabled(!config.wakeWordEnabled)
                } header: {
                    Text("Uyandırma sözcüğü")
                } footer: {
                    Text("Açıkken uygulama sürekli dinler ve \"Hey Junior\" duyunca kaydı başlatır. "
                         + "Yalnız uygulama açıkken ya da arka planda çalışırken duyar; iOS sistem "
                         + "düzeyinde özel uyandırma sözcüğüne izin vermiyor. Mikrofonu sürekli açık "
                         + "tuttuğu için pil tüketir. Kilit ekranından erişim için \"Hey Siri, "
                         + "Junior'a sor …\" kullan. "
                         + "Sürekli sohbet açıkken yanıttan sonra doğrudan dinlemeye dönülür; "
                         + "her soru için yeniden \"Hey Junior\" demen gerekmez. Bitirmek için "
                         + "\"kapat\" de ya da bir şey söylemeden bekle.")
                }

                Section {
                    LabeledContent("Kayıt", value: glasses.registrationInfo)
                    LabeledContent("Kamera izni", value: glasses.permissionInfo)
                    LabeledContent("Görünen cihaz", value: glasses.deviceInfo)
                    Button("1. Uygulamayı Meta AI'a tanıt") {
                        Task { await glasses.register() }
                    }
                    Button("2. Kamera izni ver") {
                        Task { await glasses.requestCameraPermission() }
                    }
                    Button("3. Gözlüğe bağlan") {
                        Task { await glasses.connect() }
                    }
                    if case .failed(let reason) = glasses.state {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    } else if glasses.isReady {
                        Label("Gözlük bağlı", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Gözlük")
                } footer: {
                    Text("İlk kurulumda sırayla: 1'e dokun, Meta AI açılır, onayla ve geri dön. "
                         + "Sonra 2 ile kamera iznini ver — kayıt ile izin ayrı şeyler, "
                         + "\"Meta AI'a bağlandı\" yazması iznin verildiği anlamına gelmez. "
                         + "En son 3 ile bağlan. Sonrasında \"bu ne\" gibi görsel sorularda kare "
                         + "gözlükten kendiliğinden alınır. Meta AI'da Developer Mode açık olmalı.")
                }
                .onAppear { glasses.observeRegistration() }

                Section {
                    Toggle("Doğal ses (sunucudan)", isOn: $config.naturalVoiceEnabled)
                    if !config.naturalVoiceEnabled, !SpeechService.hasUpgradedVoice {
                        Text("Yerleşik sıkıştırılmış ses kullanılacak; robotik duyulur.")
                            .font(.footnote)
                    }
                } header: {
                    Text("Ses")
                } footer: {
                    Text("Açıkken yanıtlar bilgisayardaki nöral Türkçe sesle okunur (Meta AI "
                         + "kalitesine yakın). Sunucuya ulaşılamazsa iOS'un kendi sesi devreye "
                         + "girer. Yerleşik sesi iyileştirmek için: Ayarlar > Erişilebilirlik > "
                         + "Sözlü İçerik > Sesler > Türkçe'den Gelişmiş sesi indir.")
                }

                Section("Bilgi") {
                    LabeledContent("Surum", value: Bundle.main.appVersion)
                    Text("Junior yaniti bilgisayarindaki Claude oturumundan alir. Bilgisayar ve tunel acik olmalidir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
