import SwiftUI

/// Ana ekrandaki ızgara düğmesi ve Ayarlar → Beceriler: bilgisayardaki beceri paketlerini
/// (hava, arama, pomodoro, su, kalori, şınav, tekrar kartları, sınav) telefondan kullanır.
struct SkillsView: View {
    @StateObject private var model: SkillsModel
    @Environment(\.scenePhase) private var scenePhase

    init(config: Config) {
        _model = StateObject(wrappedValue: SkillsModel(config: config))
    }

    var body: some View {
        Form {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(JuniorTheme.orange)
                    Button("Yeniden dene") { Task { await model.load() } }
                }
            }

            Section {
                ForEach(SkillPack.allCases) { pack in
                    NavigationLink {
                        SkillDetailView(pack: pack, model: model)
                    } label: {
                        SkillPackRow(pack: pack, overview: model.overview, loading: model.loading)
                    }
                }
            } header: {
                Text("Paketler")
            } footer: {
                Text("Hava durumu ve web arama telefondan her zaman kullanılabilir; masaüstündeki eklenti anahtarı yalnız "
                     + "bilgisayardaki asistanı etkiler. Diğer paketleri bilgisayardaki Junior'da Ayarlar > Eklentiler'den "
                     + "açıp kapatırsın; durum burada ve sesli komutlarda hemen geçerli olur. Kayıtlar bilgisayardaki "
                     + "Junior'da durur, masaüstüyle ortaktır. Sesle de olur: “Su içtim”, “20 şınav yaptım”, “Pomodoro başlat”. "
                     + "Pomodoro'yu bilgisayardan durdurursan telefondaki bildirim, Junior'ı bir kez açınca silinir.")
            }

            Section {
                ForEach(SkillPack.computerOnly) { item in
                    Label { Text(item.title) } icon: { SettingIcon(systemName: item.icon, color: Color.gray) }
                }
            } header: {
                Text("Yalnız bilgisayarda")
            } footer: {
                Text("Bu paketler bilgisayardaki dosyalara, yazıcıya ve hesaplara dokunduğu için telefona açılmaz. "
                     + "Bilgisayardaki Junior'a sesle ya da yazıyla söyleyebilirsin.")
            }
        }
        .navigationTitle("Beceriler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        // Öne dönünce özet ve pomodoro bildirimleri tazelenir (tur sesle ya da masaüstünden değişmiş olabilir).
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.load() } }
        }
    }
}

/// Ana ekrandan açılan sayfa: kendi gezinme yığını ve "Bitti" düğmesi.
struct SkillsSheet: View {
    let config: Config
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SkillsView(config: config)
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

private struct SkillPackRow: View {
    let pack: SkillPack
    let overview: SkillsOverview?
    let loading: Bool

    var body: some View {
        let on = pack.alwaysOn || overview?.enabled(pack) == true
        HStack(spacing: 12) {
            SettingIcon(systemName: pack.icon, color: on ? Self.color(pack) : Color.gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title)
                if let overview {
                    Text(overview.status(pack)).font(.footnote).foregroundStyle(.secondary)
                } else if pack.alwaysOn {
                    Text(pack == .weather ? "Bugün ve yarın" : "Hızlı, derin ya da haber")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if loading {
                    Text("Yükleniyor…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if overview != nil || pack.alwaysOn {
                Text(pack.badge(enabled: on))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(on ? JuniorTheme.green : Color.secondary)
            }
        }
    }

    static func color(_ pack: SkillPack) -> Color {
        switch pack {
        case .weather: return JuniorTheme.cyan
        case .search: return JuniorTheme.blue
        case .pomodoro: return JuniorTheme.red
        case .water: return JuniorTheme.cyan
        case .calories: return JuniorTheme.orange
        case .pushups: return JuniorTheme.green
        case .review: return JuniorTheme.violet
        case .quiz: return JuniorTheme.blue
        }
    }
}

/// Paket kapalıysa içeriği göstermez, nereden açılacağını söyler.
struct PackGate<Content: View>: View {
    let pack: SkillPack
    @ObservedObject var model: SkillsModel
    let content: () -> Content

    init(pack: SkillPack, model: SkillsModel, @ViewBuilder content: @escaping () -> Content) {
        self.pack = pack
        _model = ObservedObject(wrappedValue: model)
        self.content = content
    }

    var body: some View {
        if pack.alwaysOn || model.overview?.enabled(pack) == true {
            content()
        } else if model.overview != nil {
            Section {
                Label(pack.closedText, systemImage: "power")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let error = model.error {
            Section {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(JuniorTheme.orange)
                Button("Yeniden dene") { Task { await model.load() } }
            }
        } else {
            Section { ProgressView() }
        }
    }
}

/// Paketin son yanıtı (sesli komuttaki cümleyle aynı).
struct SkillNote: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Section {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Junior")
            }
        }
    }
}

/// Düğme etiketi: işlem sürerken dönen çark.
struct SkillButtonLabel: View {
    let title: String
    let systemImage: String
    let busy: Bool

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            if busy {
                Spacer()
                ProgressView()
            }
        }
    }
}

struct SkillDetailView: View {
    let pack: SkillPack
    @ObservedObject var model: SkillsModel

    var body: some View {
        Group {
            switch pack {
            case .weather: WeatherSkillView(model: model)
            case .search: SearchSkillView(model: model)
            case .pomodoro: PomodoroSkillView(model: model)
            case .water: WaterSkillView(model: model)
            case .calories: CaloriesSkillView(model: model)
            case .pushups: PushupsSkillView(model: model)
            case .review: ReviewSkillView(model: model)
            case .quiz: QuizSkillView(model: model)
            }
        }
        .navigationTitle(pack.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
    }
}
