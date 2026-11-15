import SwiftUI

/// Ayarlar → Hafıza: Junior'ın sakladığı notları gösterir, tek tek sildirir, yenisini ekler.
struct MemoryView: View {
    @StateObject private var model: MemoryModel
    @State private var query = ""
    @State private var draft = ""

    init(config: Config) {
        _model = StateObject(wrappedValue: MemoryModel(config: config))
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
                TextField("ör. Kahveyi sütsüz içerim", text: $draft, axis: .vertical)
                Button {
                    let text = draft
                    draft = ""
                    Task { await model.add(text) }
                } label: {
                    Label("Hatırla", systemImage: "plus.circle.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Yeni not")
            } footer: {
                Text("Sesle de söyleyebilirsin: “Hey Junior, şunu hatırla …”")
            }

            Section {
                if let notes = model.notes {
                    let shown = MemoryNote.filter(notes, query: query)
                    if notes.isEmpty {
                        Text("Henüz bir şey hatırlamıyorum.").foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("Eşleşen not yok.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text)
                            Text(note.learnedText).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.remove(note) }
                            } label: {
                                Label("Unut", systemImage: "trash")
                            }
                        }
                    }
                } else if model.loading {
                    ProgressView()
                }
            } header: {
                Text(model.total > 0 ? "Hatırladıklarım (\(model.total))" : "Hatırladıklarım")
            } footer: {
                Text("Notlar bilgisayardaki Junior’da durur ve masaüstüyle ortaktır. Hiçbir not kendiliğinden silinmez; "
                     + "silmek için notu sola kaydır.")
            }
        }
        .searchable(text: $query, prompt: "Notlarda ara")
        .navigationTitle("Hafıza")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}
