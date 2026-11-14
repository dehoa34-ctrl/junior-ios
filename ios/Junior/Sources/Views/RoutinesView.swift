import SwiftUI

/// Ayarlar → Rutinler: bilgisayardaki rutinleri ve sessiz saatleri telefondan yönetir.
struct RoutinesView: View {
    @StateObject private var model: RoutinesModel
    @State private var reminderText = ""
    @State private var reminderTime = QuietHours.date(from: "09:00") ?? Date()
    @State private var weekdaysOnly = false

    init(config: Config) {
        _model = StateObject(wrappedValue: RoutinesModel(config: config))
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
                if let listing = model.listing {
                    if listing.broken {
                        Label("Bilgisayardaki rutin dosyası okunamadı; rutinler devre dışı.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(JuniorTheme.orange)
                    }
                    if listing.routines.isEmpty {
                        Text("Henüz rutin yok.").foregroundStyle(.secondary)
                    }
                    ForEach(listing.routines) { item in
                        RoutineRow(item: item, model: model)
                    }
                } else if model.loading {
                    ProgressView()
                }
            } header: {
                Text("Rutinler")
            } footer: {
                Text("Rutinler bilgisayardaki Junior sunucusunda durur; burada yaptığın değişiklik bilgisayarda da görünür. "
                     + "“Söyle” rutinleri telefona bildirim olarak gelir; “Yap” rutinlerini bilgisayardaki Junior çalıştırır, "
                     + "bilgisayardaki uygulama kapalıysa yanıt telefona bildirim olarak gönderilir.")
            }

            Section {
                Toggle("Sessiz saatler", isOn: Binding(
                    get: { model.listing?.quiet.enabled ?? false },
                    set: { value in Task { await model.setQuiet(enabled: value) } }))
                if let quiet = model.listing?.quiet {
                    DatePicker("Başlangıç", selection: Binding(
                        get: { QuietHours.date(from: quiet.from) ?? Date() },
                        set: { value in Task { await model.setQuiet(from: QuietHours.text(from: value)) } }),
                               displayedComponents: .hourAndMinute)
                    DatePicker("Bitiş", selection: Binding(
                        get: { QuietHours.date(from: quiet.to) ?? Date() },
                        set: { value in Task { await model.setQuiet(to: QuietHours.text(from: value)) } }),
                               displayedComponents: .hourAndMinute)
                    if quiet.enabled, model.listing?.quietNow == true {
                        Text("Şu an sessiz saat.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sessiz saatler")
            } footer: {
                Text("Bu aralıkta Junior kendiliğinden konuşmaz ve bildirim göndermez (yoklama, konu izleme). "
                     + "Belirli bir saate kurduğun hatırlatma, o saat sessiz aralığa düşse de gelir.")
            }

            Section {
                TextField("Ne hatırlatılsın?", text: $reminderText, axis: .vertical)
                DatePicker("Saat", selection: $reminderTime, displayedComponents: .hourAndMinute)
                Toggle("Yalnız hafta içi", isOn: $weekdaysOnly)
                Button {
                    let text = reminderText
                    let at = QuietHours.text(from: reminderTime)
                    let days = weekdaysOnly ? [1, 2, 3, 4, 5] : []
                    reminderText = ""
                    Task { await model.addReminder(text: text, at: at, days: days) }
                } label: {
                    Label("Hatırlatma kur", systemImage: "plus.circle.fill")
                }
                .disabled(reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Yeni hatırlatma")
            } footer: {
                Text("Daha ayrıntılı rutinleri (aylık, aralıklı, Junior’a iş verme) sesle ya da bilgisayardan kurabilirsin: "
                     + "“Her cuma 17:00’de raporu hatırlat.”")
            }
        }
        .navigationTitle("Rutinler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

private struct RoutineRow: View {
    let item: RoutineItem
    @ObservedObject var model: RoutinesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { item.enabled },
                set: { value in Task { await model.setEnabled(item, value) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.medium))
                    Text(item.whenText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("\(item.whatLabel): \(item.text)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if item.enabled, let next = item.next {
                Text("Sıradaki: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.unprompted {
                Text("Sessiz saatlerde bekler").font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await model.remove(item) }
            } label: {
                Label("Sil", systemImage: "trash")
            }
            Button {
                Task { await model.run(item) }
            } label: {
                Label("Şimdi", systemImage: "play.fill")
            }
            .tint(JuniorTheme.blue)
        }
    }
}
