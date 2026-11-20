import SwiftUI

/// Ayarlar → Görevler: arka plan araştırmalarını başlatır, izler, durdurur, yönlendirir; raporu gösterir.
struct TasksView: View {
    @StateObject private var model: TasksModel
    @State private var goal = ""
    @State private var minutes = 10
    @State private var later = false
    @State private var startAt = Date().addingTimeInterval(3600)
    @State private var steering: BackgroundTask?
    @State private var steerText = ""
    @State private var savedNote: String?

    init(config: Config) {
        _model = StateObject(wrappedValue: TasksModel(config: config))
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
                TextField("ör. 300 TL altındaki 3B yazıcıları karşılaştır", text: $goal, axis: .vertical)
                Stepper("Süre: \(minutes) dakika", value: $minutes, in: 2...120, step: minutes < 10 ? 1 : 5)
                Toggle("İleri bir saatte başlasın", isOn: $later)
                if later {
                    DatePicker("Başlama", selection: $startAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                Button {
                    let text = goal
                    goal = ""
                    Task { await model.start(goal: text, minutes: minutes, startAt: later ? startAt : nil) }
                } label: {
                    Label("Araştırmayı başlat", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Yeni araştırma")
            } footer: {
                Text("Junior soruları planlar, kaynakları tam okur, her alıntıyı sayfada doğrular ve kaynakçalı bir rapor yazar. "
                     + "İş bilgisayarda yürür; telefonu kapatsan da sürer, bitince bildirim gelir. Sesle de söyleyebilirsin: “On dakika araştır …”")
            }

            Section {
                if let tasks = model.tasks {
                    if tasks.isEmpty {
                        Text("Henüz görev yok.").foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { task in
                        TaskRow(task: task, model: model, steering: $steering)
                    }
                } else if model.loading {
                    ProgressView()
                }
            } header: {
                Text("Görevler")
            }
        }
        .navigationTitle("Görevler")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Çalışan görev varken liste kendiliğinden yenilenir.
            while !Task.isCancelled {
                await model.load()
                let active = model.tasks?.contains(where: \.isActive) ?? false
                try? await Task.sleep(nanoseconds: (active ? 5 : 30) * 1_000_000_000)
            }
        }
        .refreshable { await model.load() }
        .alert("Yönlendir", isPresented: Binding(get: { steering != nil }, set: { if !$0 { steering = nil } })) {
            TextField("ör. euro fiyatlarına da bak", text: $steerText)
            Button("Gönder") {
                if let task = steering {
                    let text = steerText
                    steerText = ""
                    Task { await model.steer(task, text: text) }
                }
                steering = nil
            }
            Button("Vazgeç", role: .cancel) { steering = nil }
        }
        .sheet(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.closeReport() } })) {
            if let report = model.report {
                NavigationStack {
                    ScrollView {
                        Text(LocalizedStringKey(report.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        if let savedNote {
                            Text(savedNote).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                        }
                    }
                    .navigationTitle("Rapor")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Kapat") { model.closeReport(); savedNote = nil }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                if let url = model.saveReport() {
                                    savedNote = "Dosyalar > Junior > JuniorReports > \(url.lastPathComponent) olarak kaydedildi."
                                }
                            } label: {
                                Label("Dosyalar’a kaydet", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: BackgroundTask
    @ObservedObject var model: TasksModel
    @Binding var steering: BackgroundTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.goal).font(.body.weight(.medium)).lineLimit(3)
                Spacer(minLength: 8)
                Text(task.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            let detail = task.detailText
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            if task.status == .running, let last = task.progress.last {
                Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if task.hasReport {
                Button {
                    Task { await model.openReport(task) }
                } label: {
                    Label("Raporu aç", systemImage: "doc.text.magnifyingglass")
                }
                .font(.footnote)
            }
        }
        .swipeActions(edge: .trailing) {
            if task.isActive {
                Button(role: .destructive) {
                    Task { await model.cancel(task) }
                } label: {
                    Label("Durdur", systemImage: "stop.fill")
                }
                Button {
                    Task { await model.finish(task) }
                } label: {
                    Label("Yeter, yaz", systemImage: "text.badge.checkmark")
                }
                .tint(JuniorTheme.green)
                Button {
                    steering = task
                } label: {
                    Label("Yönlendir", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                .tint(JuniorTheme.blue)
            }
        }
    }

    private var color: Color {
        switch task.status {
        case .running: return JuniorTheme.cyan
        case .paused, .queued: return JuniorTheme.orange
        case .done: return JuniorTheme.green
        case .failed: return JuniorTheme.red
        case .cancelled: return .secondary
        }
    }
}
