import SwiftUI

/// Ayarlar > Ses motoru: Klasik / Gemini Live ve Gemini Live durum kartı.
///
/// Seçim yalnız telefonda (UserDefaults) durur. Anahtar, katman ve günlük sınır bilgisayardaki
/// Junior'dan ayarlanır; burası onları sunucunun durum ucundan okur, hiçbirini değiştirmez.
struct GeminiLiveSettingsSection: View {
    @ObservedObject var config: Config
    @StateObject private var model: GeminiStatusModel
    @AppStorage(VoiceEngine.storageKey) private var engine: VoiceEngine = .classic
    // Telefonun kendi gördüğü son hata (GeminiLiveSession yazar; sunucu bunu bilmez).
    @AppStorage(GeminiPhoneError.messageKey) private var phoneErrorMessage = ""
    @AppStorage(GeminiPhoneError.reasonKey) private var phoneErrorReason = ""
    @AppStorage(GeminiPhoneError.atKey) private var phoneErrorAt: Double = 0

    init(config: Config) {
        self.config = config
        _model = StateObject(wrappedValue: GeminiStatusModel(config: config))
    }

    var body: some View {
        let availability = GeminiStatusText.availability(status: model.status, loadError: model.error,
                                                         loading: model.loading)
        Section {
            ForEach(VoiceEngine.allCases) { option in
                // Anahtar yoksa Gemini seçilemez; zaten seçiliyse geri dönülebilsin diye kapanmaz.
                let disabled = option == .geminiLive && !availability.enabled && engine != .geminiLive
                Button {
                    engine = option
                } label: {
                    HStack {
                        Label {
                            Text(option.title).foregroundStyle(.primary)
                        } icon: {
                            SettingIcon(systemName: option == .classic ? "waveform" : "sparkles",
                                        color: option == .classic ? JuniorTheme.blue : JuniorTheme.violet)
                        }
                        Spacer()
                        if engine == option {
                            Image(systemName: "checkmark").foregroundStyle(JuniorTheme.cyan)
                        }
                    }
                    .opacity(disabled ? 0.45 : 1)
                }
                .disabled(disabled)
            }
            if let reason = availability.reason {
                Text(reason).font(.footnote).foregroundStyle(JuniorTheme.orange)
            }
            GeminiStatusCard(status: model.status, error: model.error, loading: model.loading,
                             phoneError: GeminiPhoneError.decode(message: phoneErrorMessage,
                                                                 reason: phoneErrorReason, at: phoneErrorAt))
            Button {
                Task { await model.load() }
            } label: {
                Label("Durumu yenile", systemImage: "arrow.clockwise")
            }
            .disabled(model.loading)
        } header: {
            Text("Ses motoru")
        } footer: {
            Text("Klasik: söylediğin yazıya çevrilir, bilgisayardaki Junior yanıtlar, yanıt seslendirilir. "
                 + "Gemini Live: konuş düğmesi bilgisayar üzerinden Google Gemini ile gerçek zamanlı sesli "
                 + "oturum açar, araya girebilirsin; düğmeye yeniden basınca kapanır. Günlük sınır dolarsa, "
                 + "bağlantı koparsa ya da Google reddederse tek cümleyle söyler ve klasik yola döner. "
                 + "\"Hey Junior\" her zaman klasik yolu kullanır.")
        }
        .task { await model.load() }
    }
}

/// Gemini Live durum kartı: katman (ücretsizde uyarı), bugünkü dakika / sınır, son hata.
struct GeminiStatusCard: View {
    let status: GeminiStatus?
    let error: String?
    let loading: Bool
    /// Yalnız telefonun gördüğü son hata (köprüye ulaşılamadı, zaman aşımı, tünel koptu).
    var phoneError: GeminiStatus.LastError? = nil

    var body: some View {
        let last = GeminiStatusText.latestError(server: status?.lastError, phone: phoneError)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(JuniorTheme.violet)
                Text("Gemini Live").font(.subheadline.weight(.semibold))
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else if let status {
                    Text(GeminiStatusText.tierTitle(status.tier))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((status.tier == "paid" ? JuniorTheme.green : JuniorTheme.orange).opacity(0.18), in: Capsule())
                }
            }
            if let status {
                let note = GeminiStatusText.tierNote(status.tier)
                Label(note.text, systemImage: note.warn ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(note.warn ? JuniorTheme.orange : Color.secondary)
                Text(GeminiStatusText.usage(status)).font(.footnote)
                ProgressView(value: status.capMinutes > 0 ? min(1, status.usedMinutes / status.capMinutes) : 0)
                    .tint(status.remainingMinutes > 0 ? JuniorTheme.violet : JuniorTheme.red)
                if !status.available, let message = status.message {
                    Text(message).font(.footnote).foregroundStyle(JuniorTheme.orange)
                }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(JuniorTheme.orange)
            }
            // Durum okunamasa da gösterilir: telefonun gördüğü hatalar tam da bu durumlarda olur.
            if let last {
                Text(GeminiStatusText.lastError(last)).font(.footnote).foregroundStyle(.secondary)
            }
            Text(GeminiStatusText.privacyNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Ana ekranda, Gemini Live oturumu açıkken: durum, son duyulan/söylenen, bitir düğmesi.
struct GeminiLiveCard: View {
    @ObservedObject var session: GeminiLiveSession

    private var title: String {
        switch session.phase {
        case .idle, .connecting: return "Gemini Live · bağlanıyor…"
        case .live: return session.modelSpeaking ? "Gemini Live · konuşuyor" : "Gemini Live · dinliyor"
        }
    }

    private var catPhase: JuniorActivityPhase {
        if session.modelSpeaking { return .speaking }
        return session.phase == .live ? .listening : .thinking
    }

    var body: some View {
        HStack(spacing: 12) {
            CatBadge(phase: catPhase, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(JuniorTheme.violet)
                if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            WaveBars(active: session.phase == .live, color: JuniorTheme.violet)
            Button("Bitir") { session.stop() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(JuniorTheme.violet)
                .accessibilityLabel("Gemini Live oturumunu bitir")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card(radius: 18, tint: JuniorTheme.violet)
    }
}
